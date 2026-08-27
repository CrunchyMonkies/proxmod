# Packaging an extension

**Status:** Draft
**Applies to:** proxmod 0.2.2, Proxmox VE 9.x, Debian 13 (trixie)
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the worked example is
[`examples/proxmod-example-hello/`](../examples/proxmod-example-hello/), which
builds; proxmod's own `debian/` is the second worked example; the reasoning
behind each maintainer-script rule is traced to a confirmed defect in
[`patching.md`](patching.md)

There are two package shapes in this world. Nearly everyone wants the first.

---

## 1. Which shape are you building?

| | **Extension package** | **Framework package** |
|---|---|---|
| Example | `proxmod-example-hello` | `proxmod` |
| Ships | a Perl module, a manifest, a JS file | wrappers, drop-ins, maintainer scripts, triggers |
| Maintainer scripts | **none** | all three |
| Touches systemd | no | yes |
| Restarts a daemon | no — proxmod decides | yes, when something moved |
| Difficulty | a `Makefile` and `dh $@` | this whole document |

If you are adding a tab and an endpoint, you are building the left column, and
§2 is the entire job. §§3–7 are the reasoning behind proxmod's own package —
read them if you maintain proxmod, if you are debugging an upgrade, or if you
are building something else that has to survive a PVE upgrade.

---

## 2. The extension package

Three files, three directories, no maintainer scripts.

```
/usr/share/perl5/<Your>/<Namespace>.pm      # loaded by require() inside the daemons
/usr/share/proxmod/extensions.d/50-<id>.conf  # the manifest
/usr/share/proxmod/www/<id>.js              # the frontend asset
```

`debian/control`:

```
Package: acme-foo
Architecture: all
Depends:
 ${misc:Depends},
 ${perl:Depends},
 proxmod (>= 0.2.0),
Description: ...
```

`debian/rules`:

```make
#!/usr/bin/make -f
%:
	dh $@
```

And a `Makefile` with `build` and `install` targets — `dh`'s makefile
buildsystem calls `make build` then `make install DESTDIR=…`, and that is the
whole build:

```make
DESTDIR  ?=
prefix   ?= /usr
PERLDIR  := $(prefix)/share/perl5
SHAREDIR := $(prefix)/share/proxmod

build:
	perl -c -Iperl perl/Acme/Foo.pm

install:
	install -d $(DESTDIR)$(PERLDIR)/Acme
	install -m 0644 perl/Acme/Foo.pm $(DESTDIR)$(PERLDIR)/Acme/
	install -d $(DESTDIR)$(SHAREDIR)/extensions.d
	install -m 0644 conf/50-acme-foo.conf $(DESTDIR)$(SHAREDIR)/extensions.d/
	install -d $(DESTDIR)$(SHAREDIR)/www
	install -m 0644 www/acme-foo.js $(DESTDIR)$(SHAREDIR)/www/
```

That is it. **Writing into `/usr/share/proxmod/extensions.d` activates
proxmod's dpkg trigger**, proxmod's `postinst triggered` runs
`proxmod-reapply`, and the host converges. You do not restart a daemon, you do
not touch systemd, and you do not know or care whether proxmod is currently
loaded.

### Things not to do in an extension package

**Do not ship a maintainer script that restarts `pveproxy` or `pvedaemon`.** You
would be the second thing deciding when the hypervisor's API bounces. proxmod
restarts once per dpkg run, batched, and only when something actually moved; two
packages each restarting on their own postinst turn one interruption into
several.

**Do not depend on a specific `pve-manager` version.** Depend on `proxmod`.
Compatibility with Proxmox is proxmod's problem, and proxmod deliberately
declares no ceiling (§5).

**Do not install into `/usr/share/pve-manager` or `/usr/share/perl5/PVE`.**
Those are Proxmox's. Anything you put there shows up in `dpkg -V pve-manager`
or gets silently replaced by an upgrade — and it is exactly what proxmod exists
so that you never have to do.

**Do not make your Perl module's `id` and its path disagree.** The manifest
`id` is a URL path segment and must be unique host-wide; see
[`extension-manifest.md`](extension-manifest.md).

### Building and checking it

```sh
dpkg-buildpackage -us -uc -b
lintian ../acme-foo_*.deb
dpkg -c ../acme-foo_*.deb          # three files, three directories, nothing else
```

Then on a test host, the check that matters:

```sh
dpkg -i ../acme-foo_1.0.0_all.deb
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl   # must be silent
proxmod-verify
```

---

## 3. The framework package: what makes it different

proxmod owns three things an extension does not: **systemd drop-ins** naming an
`ExecStart` wrapper, **maintainer scripts** that converge the host, and
**triggers** that make the whole thing react to other packages.

Every rule below exists because getting it wrong produces a specific,
reproducible failure. Where the failure has been observed in prior art, it is
named.

### The `dh_fixperms` trap

`dh_fixperms` resets modes on everything outside the recognised binary
directories to `0644`. `/usr/lib/proxmod/proxmod-exec` is named by
`ExecStart=` in both daemons' drop-ins.

A `0644` wrapper is not a cosmetic defect. It is **both Proxmox daemons failing
to start**, with a systemd error that mentions permissions and does not mention
proxmod. The host loses its web interface and its API on the next restart, and
the message points at the wrong thing.

```make
override_dh_fixperms:
	dh_fixperms
	find debian/proxmod/usr/lib/proxmod debian/proxmod/usr/sbin \
	    -maxdepth 1 -type f -print0 2>/dev/null | xargs -0 -r chmod 0755
```

Explicit paths, not a blanket `chmod -R`; `find` rather than a glob, because a
glob matching nothing fails the build for no reason.

### Let one mechanism decide restarts

```make
override_dh_installsystemd:
	dh_installsystemd --no-restart-after-upgrade --no-stop-on-upgrade
```

The trigger converges, the boot unit converges, `postinst` calls
`proxmod-reapply` directly. Letting debhelper *also* restart things means two
mechanisms disagreeing about when the hypervisor's API is allowed to go away.

### One convergence routine, called from everywhere

`postinst configure`, `postinst triggered`, the boot-time unit and
`proxmodctl reapply` all call the same script,
`/usr/lib/proxmod/proxmod-reapply`. There is deliberately no second
implementation of "make the host match the package" in the source tree.

It is idempotent, takes an `flock`, skips while `/proxmox_install_mode` exists,
and — the part that matters —

> **restarts the daemons only if something actually changed, if
> `proxmod-verify` says the live daemons are not loaded, or if they loaded a
> registry that is no longer the one on disk.**

That last one is what makes installing or removing an extension package take
effect without `--force`: a manifest appearing in `extensions.d` changes nothing
the other conditions watch. See [ADR 0011](adr/0011-registry-fingerprint.md).

The prior art restarted `pveproxy` on *every* apt invocation via a
`DPkg::Post-Invoke` hook. On a busy host that is an outage on every
`apt install` of anything at all. The no-op case must cost one process and zero
restarts, and there is an integration test asserting `ExecMainStartTimestamp` is
unchanged after a no-op apt run.

---

## 4. Maintainer script ordering, with reasons

### `postinst`

```
configure  → converge
triggered  → converge, and exit 0 no matter what
```

`triggered` must **always exit 0**. A non-zero exit from a trigger leaves the
package half-configured and can stop an entire `apt dist-upgrade` — including
security updates for packages that have nothing to do with you. The failure is
in the journal and `proxmod-verify` will report it. Wedging dpkg is not an
improvement.

### `prerm` — the file this rule exists for

`/etc/systemd/system/pveproxy.service.d/10-proxmod.conf` names
`/usr/lib/proxmod/proxmod-exec` in `ExecStart=`. dpkg is about to delete that
wrapper.

**The drop-ins must be removed before the files they reference.** That means
`prerm`, not `postrm`. Otherwise `ExecStart` points at a file that no longer
exists, and the next restart of the Proxmox web interface — an upgrade, a
reboot, an administrator at 3am — fails with a systemd error naming neither
proxmod nor the reason.

This is also why the drop-ins are **not conffiles**: dpkg's conffile handling
would leave them behind for the administrator to resolve, which is the wrong
answer for a file whose entire content is a reference to something being
deleted. They ship to `/usr/share/proxmod/systemd/` and are `install -D`'d by
`postinst`.

**And `upgrade` does none of this.** Removing the drop-ins on upgrade would
restart both daemons stock, and then `postinst` would restart them again with
proxmod: two interruptions instead of none, in exchange for nothing.

> The prior art reverted its changes on upgrade — and thereby restored a stale
> pre-upgrade copy of a Proxmox file over the newer one dpkg had just unpacked.
> Reverting on upgrade is how that class of bug happens. See
> [`patching.md`](patching.md).

Managed patches are reverted first, while the engine and its state file still
exist: after dpkg has deleted `/usr/lib/proxmod`, nothing on the host knows
which files were edited or what they looked like before.

### `postrm`

Only `purge` does anything. Two rules:

**Prune directories with `rmdir`, never `rm -rf`.**
`/usr/share/proxmod/www` and `/usr/share/proxmod/extensions.d` are *shared* —
an extension package's files live there, and dpkg removes them on that
package's schedule, which may be after ours. `rmdir` fails harmlessly when the
directory is not empty, which is the correct outcome. Deleting another
package's files during our own removal is exactly the collateral damage this
project exists to argue against.

**Purge backups from a directory you own, enumerated from a state database.**

> The prior art kept its backup beside the original, as
> `/usr/share/perl5/PVE/API2/Hardware.pm.pre-gpu`, and its `postrm` never
> removed it. The file outlived the package, in a directory belonging to
> Proxmox, with nothing left on the host to explain it.

proxmod's backups live under `/var/lib/proxmod/backups/`, are deleted entry by
entry out of the state database as each patch is reverted, and the `postrm`
sweep is the backstop. Backups in a directory you own cannot be orphaned in
someone else's, and clearing them cannot delete someone else's file.

---

## 5. No version ceiling

proxmod's `control` deliberately has **no** `Breaks: pve-manager (>= 10~)`.

A ceiling would hold back a legitimate major upgrade of the hypervisor in order
to protect an add-on. That is a worse outcome than the one it prevents — the
administrator ends up choosing between security updates and a GPU tab, and
proxmod is not entitled to make them choose.

Instead every seam is probed at runtime and the feature that needed it disables
itself, feature by feature, down to "PVE exactly as shipped". See
[`compatibility.md`](compatibility.md).

---

## 6. Triggers, and why not an APT hook

| Mechanism | Fires on `dpkg -i`? | Only when relevant? | Ordered by dpkg? |
|---|---|---|---|
| **dpkg file + named triggers** | **yes** | yes, batched once per run | **yes** |
| APT `DPkg::Post-Invoke` | **no** | no — every apt run | no |
| systemd `PathChanged=` | indirectly | poorly, non-recursive | **no** — fires mid-unpack |
| boot-time oneshot | n/a | n/a | n/a |

dpkg triggers are also the **PVE-idiomatic** choice: pve-manager itself ships
`interest-noawait /usr/share/perl5/PVE` [PVE-F-010]. The precedent is Proxmox's
own.

APT `DPkg::Post-Invoke` fails on all three counts, and the middle one bites
hardest: it fires on every apt invocation, so a package using it restarts
`pveproxy` when you install `htop`. It also **never fires on `dpkg -i`**, which
is how an administrator installs a locally built `.deb` — so the thing that was
supposed to reapply the change does not run at the exact moment someone is
testing whether it works.

The boot-time oneshot is not a primary mechanism but is worth having as a
complement: it catches a host that was powered off in a bad state.

proxmod's interests:

```
interest-noawait /usr/share/proxmod/extensions.d   # an extension appears/changes/goes
interest-noawait /etc/proxmod/extensions.d         # the administrator's overlay
interest-noawait /usr/share/proxmod/www            # assets shipped after their manifest
interest-noawait /usr/share/proxmod/patches
interest-noawait /etc/proxmod/patches
interest-noawait /usr/share/perl5/PVE              # Proxmox itself
interest-noawait proxmod-reapply                   # named: dpkg-trigger proxmod-reapply
```

`-noawait` throughout: proxmod's `postinst` neither provides nor completes
anything the triggering package needs, so making it wait would only widen the
window in which an unrelated upgrade is blocked by us.

The named trigger lets a package or an administrator ask for convergence
explicitly — `dpkg-trigger proxmod-reapply` — without having to know which
paths are watched.

---

## 7. Never touch `/etc/pve`

Not in `postinst`, not in `prerm`, not in `postrm`, not in the boot unit, not
in `proxmod-reapply`.

`/etc/pve` is pmxcfs, a FUSE filesystem backed by the cluster. It is **routinely
unmounted during upgrades**, it can be read-only when the node lacks quorum, and
it does not exist at all early in boot. A maintainer script that reads or writes
there fails at precisely the moment it is most needed, and a hung FUSE mount can
block dpkg indefinitely.

Proxmox's own `postinst` guards with `test -f /etc/pve/local/pve-ssl.pem || exit 0`
[PVE-F-005]. proxmod goes further and does not go near it: `t/09-reapply.t`
asserts the string `/etc/pve/` appears in none of `proxmod-reapply`, the three
maintainer scripts, or the boot unit, and fails the build if it ever does.

---

## 8. Proving you left PVE pristine

This is the headline claim and it is mechanically checkable. Run it on a test
host, from a clean install through upgrade to purge.

```sh
# 1. baseline
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl
find /usr/share/pve-manager /usr/share/perl5/PVE -type f -print0 \
    | xargs -0 sha256sum | sort > /tmp/before.sha

# 2. install proxmod and your extension
apt install ./proxmod_*.deb ./acme-foo_*.deb
proxmod-verify

# 3. still pristine?
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl   # silent
find /usr/share/pve-manager /usr/share/perl5/PVE -type f -print0 \
    | xargs -0 sha256sum | sort | diff -u /tmp/before.sha -     # no output

# 4. survive an upgrade of the thing you are extending
apt install --reinstall pve-manager      # or a repacked newer version
proxmod-verify                            # exits 0, endpoint still answers

# 5. leave nothing behind
apt purge acme-foo proxmod
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl   # silent
systemctl is-active pveproxy pvedaemon                            # active
ls /etc/systemd/system/pve*.service.d/ 2>/dev/null                # no proxmod drop-in
find /usr/share/perl5/PVE -name '*.pre-*' -o -name '*.bak'        # nothing
```

Step 3 is the one that distinguishes this approach from patching, and step 5 is
the one that catches leaked backups. Both are in the QEMU integration suite; run
them by hand anyway the first time you package something.

### If a step fails

| Failure | Look at |
|---|---|
| `dpkg -V` reports a Proxmox file | Something patched. `proxmodctl patch status`, then [`patching.md`](patching.md) |
| `proxmod-verify` non-zero after install | [`verification.md`](verification.md), then `journalctl -u pveproxy \| grep proxmod` |
| Daemon inactive after install | `systemctl status pveproxy` — usually the `dh_fixperms` trap (§3) |
| Purge leaves a drop-in | `prerm` did not run its `remove` branch; check its exit status in the dpkg log |
| Purge leaves a `.pre-*` file in a PVE directory | A patch was not reverted before `/usr/lib/proxmod` went away |

---

## 9. Checklist

**Extension package**

- [ ] `Depends: proxmod (>= …)`; no dependency on a `pve-manager` version
- [ ] No maintainer scripts at all
- [ ] Exactly three installed paths, none of them Proxmox-owned
- [ ] `id` in the manifest matches the asset name and the module's registration
- [ ] `lintian` clean
- [ ] `dpkg -V pve-manager …` silent after install *and* after purge

**Framework package**

- [ ] `override_dh_fixperms` restores 0755 on everything under `/usr/lib/proxmod`
- [ ] `dh_installsystemd --no-restart-after-upgrade --no-stop-on-upgrade`
- [ ] Drop-ins installed by `postinst`, removed by `prerm`, and not conffiles
- [ ] `prerm` reverts on `remove` and does **nothing** on `upgrade`
- [ ] `postinst triggered` exits 0 unconditionally
- [ ] `postrm` prunes with `rmdir`, and purges backups from a state database
- [ ] No path under `/etc/pve` anywhere in any script
- [ ] The no-op apt run leaves `ExecMainStartTimestamp` unchanged
- [ ] One convergence routine, called by every entry point

---

## 10. Cutting a release

The unit suite runs on every push and again on the tag. It cannot make the
claims proxmod is sold on — no Proxmox file modified, a patch surviving a
`pve-manager` upgrade, purge leaving the host as it found it — because those are
claims about a live hypervisor and `t/lib` is a set of stubs. Only the QEMU
suite makes them, and it does not run on the release path: it needs KVM, a 5GB
image and an installer ISO, which [`testing.md`](testing.md) §6 explains and
this section does not relitigate.

What follows from that is not "run it in CI". It is that **the release has to
say whether it was run**, in a place a person deciding whether to install this
will see.

1. Bump `$VERSION` everywhere and `debian/changelog`. `prove t/11-conventions.t`
   is what tells you whether you got all of them.
2. `make lint && make test`, then `make deb && lintian ../proxmod_*_all.deb`.
3. `make e2e` on a PVE 9.x VM. Keep `test/qemu/.run/artifacts/`, or note the
   `e2e.yml` run.
4. Commit as `release: X.Y.Z`, with the semver class and what the bump touched
   — [`conventions.md`](conventions.md) §7.
5. Tag **annotated**, with the changelog summary and an `E2E:` line:

   ```text
   E2E: https://github.com/CrunchyMonkies/proxmod/actions/runs/… (PVE 9.1.1, all green)
   E2E: none — docs-only release, no code path changed
   ```

   `release.yml` refuses to publish a tag without one, and refuses a lightweight
   tag outright. It cannot check that the run happened and does not pretend to;
   the failure it is aimed at is tagging on a Friday having forgotten the suite
   exists. Either spelling passes — recording the decision is the point, and
   "none, because…" is a decision.
6. Push the commit, then the tag. `release.yml` re-runs lint and the unit suite
   against the exact tree, builds both packages, gates them on `lintian`,
   publishes the GitHub Release with the changelog entry as its body, and pushes
   the same bytes to `ghcr.io` from a second job that holds `packages: write`
   and nothing else.

**Before the 1.0 tag**, additionally: give the `publish-oci` job a GitHub
Environment with required reviewers. Nothing in this repository can configure
that, and an unconfigured environment protects nothing silently — which is why
it is written here rather than half-applied in the workflow.

---

## Reference

- [`examples/proxmod-example-hello/`](../examples/proxmod-example-hello/) — the whole extension shape, buildable
- [`extension-manifest.md`](extension-manifest.md) — every manifest field
- [`specifications.md`](specifications.md) §9 — normative package layout (`REQ-PKG-*`)
- [`patching.md`](patching.md) — the post-mortem behind half the rules above
- [`verification.md`](verification.md) — what `proxmod-verify` checks and why
- [`compatibility.md`](compatibility.md) — the no-ceiling policy in full
