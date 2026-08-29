# Patching Proxmox files: the last resort

**Status:** Draft
**Applies to:** proxmod 0.4.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the post-mortem in §2 cites file and line in
`~/dev/pmxxpuiov` as it stood on 2026-08-08 and each defect was read directly;
the engine's behaviour is unit-tested in `t/07-patch.t`

proxmod ships a patch engine. **Every spec it ships is disabled**, installing
proxmod modifies no Proxmox file, and `dpkg -V pve-manager` stays silent on a
default install.

This document is mostly an argument for leaving it that way.

---

## 1. Read this before enabling anything

A patch is an edit to a file that belongs to another package. That single fact
produces all of the following, and none of them are avoidable by writing the
patch more carefully:

- **The next upgrade overwrites it.** dpkg unpacks the maintainer's version.
  Your edit is gone until something reapplies it, which means you now own a
  reapply mechanism, and §2 is about what happens when that mechanism is subtly
  wrong.
- **`dpkg -V pve-manager` reports the file forever.** Every integrity check on
  the host, and every support engineer, now has a finding to explain.
- **Two packages patching the same file race.** Neither knows about the other.
  Backups taken by the second capture the first's edit as "original".
- **The anchor moves.** You matched a line in someone else's source. A point
  release rewrites it and your patch either fails loudly or — worse — matches
  the wrong line.
- **Restoring a backup can be worse than not restoring it.** If the backup
  predates an upgrade, putting it back means installing an *older* Proxmox file
  over a newer one. Silently.

proxmod exists because none of that is necessary for the two things people
actually want. Before you enable a spec:

| You want | Do this instead |
|---|---|
| A script tag in the web interface | A frontend extension — [`frontend-extensions.md`](frontend-extensions.md) |
| A REST endpoint | A backend extension — [`backend-extensions.md`](backend-extensions.md) |
| To run code on guest start/stop | A PVE **hookscript** — official, supported |
| A new storage type | A PVE **storage plugin** — official, supported |
| A new authentication realm | A PVE **auth plugin** — official, supported |
| To restrict what a user can do | An **ACL role**, not a patch |
| To change a string in the UI | A frontend extension overriding the component |
| To change Proxmox's *behaviour* in a way none of the above reaches | …then read on |

That last row is the only legitimate one, and it is rarer than it feels.

---

## 2. The post-mortem: pve-gpu-manager

The strongest argument against patching is not theoretical. `~/dev/pmxxpuiov`
(pve-gpu-manager) adds a GPU tab and a `/nodes/{node}/hardware/gpu` endpoint by
patching Proxmox's files: `sed` into `index.html.tpl` for a script tag, `awk`
into `PVE/API2/Hardware.pm` for the route, and an
`/etc/apt/apt.conf.d/99-pve-gpu-reapply` `DPkg::Post-Invoke` hook to reapply
after upgrades.

It is competently written. It has a test suite, an e2e harness, idempotency
checks, backups and a revert path. It still contains **four confirmed defects
plus one hazard**, every one of them a direct consequence of the mechanism
rather than of carelessness.

### Defect 1 — the reapply script patches the wrong file

`debian/postinst:6` patches `Hardware.pm`:

```sh
HARDWARE_PM="/usr/share/perl5/PVE/API2/Hardware.pm"
```

`src/scripts/reapply-patches.sh:9`, the script the APT hook runs after every
upgrade, patches `Nodes.pm`:

```sh
NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
```

The route was moved from `Nodes.pm` to `Hardware.pm` at some point and the
reapply script was not updated with it. So **after a `pve-manager` upgrade the
backend route is never reapplied.** The frontend patch *is* reapplied — the tab
still appears — so the interface looks correct and every API call behind it
fails.

The project's own tests do not catch it, because they disagree with each other
in the same way: `scripts/e2e.sh:361` greps for `PVE::API2::Hardware::GPU`,
while `test/qemu/test-plugin.sh:64` greps `Nodes.pm`.

This is what patching costs. Two places encode "which Proxmox file holds our
edit", they drift, and the drift is invisible until an upgrade.

### Defect 2 — reverting on upgrade restores a stale file

`debian/prerm:50`:

```sh
case "$1" in
    remove|upgrade|deconfigure)
        restore_backup "$INDEX_TPL"
        restore_backup "$HARDWARE_PM"
```

`upgrade` is in that list. And `restore_backup` (`prerm:13`) does an
unconditional `cp -p "$backup" "$file"`.

Combined with `backup_if_needed` (`postinst:17`), which only takes a backup
**if one does not already exist**:

```sh
if [ ! -f "$backup" ] && [ -f "$file" ]; then
    cp "$file" "$backup"
fi
```

…the backup is taken once, at first install, and never refreshed. So on any
upgrade of pve-gpu-manager itself, `prerm` copies a **months-old copy of
`Hardware.pm`** over whatever Proxmox currently ships. If a PVE upgrade landed
in between, the newer Proxmox file is silently replaced by the older one — bug
fixes and security fixes included — and dpkg has no idea, because the file
belongs to a different package than the one being upgraded.

This is the single most dangerous behaviour in the prior art, and it is why
proxmod's `prerm` does **nothing at all** on `upgrade`.

### Defect 3 — the backup leaks forever

`debian/postinst:6` backs up `Hardware.pm`, creating
`/usr/share/perl5/PVE/API2/Hardware.pm.pre-gpu`.

`debian/postrm:6,21` cleans up:

```sh
NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
...
for f in "${INDEX_TPL}.pre-gpu" "${NODES_PM}.pre-gpu"; do
```

The same `Nodes.pm`/`Hardware.pm` drift again — this time in the cleanup list.
`Hardware.pm.pre-gpu` is **never removed by anything**. After `apt purge` it
sits in a Proxmox-owned directory, containing a stale copy of a Proxmox file,
with nothing left on the host to explain what put it there.

A backup stored beside the original, in someone else's directory, can be
orphaned in someone else's directory. proxmod's live under
`/var/lib/proxmod/backups/` and are enumerated from a state database, not from a
hardcoded list that can drift.

### Defect 4 — the reapply hook never fires when it matters

`debian/pve-gpu-manager/etc/apt/apt.conf.d/99-pve-gpu-reapply`:

```
DPkg::Post-Invoke { "if [ -x /usr/lib/pve-gpu/reapply-patches.sh ]; then /usr/lib/pve-gpu/reapply-patches.sh; fi"; };
```

Two problems, opposite in direction:

- **It fires on every apt invocation**, relevant or not. `apt install htop`
  runs the patcher and — because the patcher restarts `pveproxy` — bounces the
  hypervisor's web interface. On a busy host that is an outage caused by an
  unrelated package.
- **It never fires on `dpkg -i`.** APT hooks are APT's, not dpkg's. An
  administrator installing a locally built `.deb` — which is exactly how you
  test this package — gets no reapply at all.

dpkg triggers have neither problem: they are batched once per dpkg run, ordered
by dpkg, fire only when a watched path is written, and fire on `dpkg -i`. They
are also what Proxmox itself uses [PVE-F-010]. See
[`packaging.md`](packaging.md) §6.

### Hazard 5 — `postrm` writes to `/etc/pve`

`debian/postrm:15-17`:

```sh
rm -f /etc/pve/local/gpu-sriov.conf
rm -f /etc/pve/local/gpu-vf-templates.conf
```

`/etc/pve` is pmxcfs, a FUSE filesystem backed by the replicated cluster
database. It is unmounted during parts of an upgrade, read-only without quorum,
and absent early in boot. A maintainer script touching it can hang on a dead
FUSE mount and take dpkg with it.

Proxmox's own `postinst` guards every such access with
`test -f /etc/pve/local/pve-ssl.pem || exit 0` [PVE-F-005]. proxmod does not
guard — it does not go there at all, and `t/09-reapply.t` fails the build if the
string ever appears in a maintainer script or the boot unit.

### What the post-mortem is actually saying

None of these are stupid mistakes. They are the *characteristic* mistakes of the
mechanism:

| Defect | Root cause |
|---|---|
| 1, 3 | The target file's identity is duplicated across scripts, and duplicates drift |
| 2 | Backup-and-restore has no way to know whether the backup is still current |
| 4 | The reapply mechanism has to be bolted on, and the obvious choice is wrong |
| 5 | Patching pulls you into maintainer scripts, where the hazards live |

Write the patch more carefully and you get different instances of the same four.
The only way out is to not need a reapply mechanism, which is the whole design
of proxmod: nothing to reapply, because nothing was changed.

---

## 2a. The one patch proxmod recommends

Everything above argues against patching, and everything above still holds. There
is exactly one case where proxmod ships specs it expects somebody to enable, and
it is worth understanding why this one is different from the example spec.

`patches/60-cli-qm.conf`, `61-cli-pct.conf` and `62-cli-pvesh.conf` insert
`use Proxmod;` into `PVE::CLI::qm`, `::pct` and `::pvesh`. That makes a seam wrap
apply to `qm create` and not only to the REST API. Without it, an extension that
refuses an over-quota create refuses it through the web interface and lets it
through from a root shell — verified on a live host, same node and same second
`[PVE-F-055]`.

**Why this is not the example spec.** The example patches the index template,
which proxmod already does at runtime without touching the file: patching there
gives up every guarantee in exchange for nothing. Here there is **no runtime
alternative**. proxmod enters a daemon through a systemd `ExecStart` drop-in, and
a command somebody types has no `ExecStart`. This is precisely the case
[ADR 0008](adr/0008-patch-facility-ships-inert.md) predicted: a seam proxmod
cannot reach at runtime.

**What you take on.** All of §1's obligations, plus two specific to this:

- `dpkg -V qemu-server pve-container pve-manager` stops being silent for three
  files. That is proxmod's strongest claim about itself, spent here deliberately.
- Every `qm` invocation now loads proxmod and every extension that named `qm`.
  **If proxmod is broken, `qm` is broken** — the primary tool for managing guests
  on the node. Three things carry that, and it is worth knowing them before you
  need them: `Proxmod.pm`'s `INIT` block is wrapped in an `eval` and never dies,
  each extension loads inside its own `eval`, and `/etc/proxmod/disabled` turns
  the lot off without removing a package.

**Two costs that are smaller than they sound, and one that is not.**

*Startup* is fine. Measured on a live host (pve-manager 9.2.6, two extensions
loaded): ten `qm list` invocations took 8.19 s and 8.11 s unpatched, 8.36 s
patched — about **20 ms per invocation, roughly 2%**. If you run `qm` in a tight
loop thousands of times a day, measure it yourself; for everyone else it is
noise.

*`stdout` is untouched.* `pvesh get /version --output-format json` is unpolluted
JSON with the patch on. Scripts that parse output keep working.

*`stderr` is not.* Every invocation of a patched CLI prints proxmod's boot lines,
and any warning an extension emits at registration — a seam it could not wrap,
a scope it could not mount — appears **on every command**, not once at boot. On
this host `pct` printed two such warnings each time, both correct and both
expected. Nothing is broken by it, but an operator who has not seen it before
will reasonably think something is.

**One thing this does not do.** `pvesh` still cannot `get` proxmod's own
endpoints, only `ls` them: `PVE::CLI::pvesh` extracts the schema for the
requested path while the program is still compiling, which is before proxmod's
`INIT` has mounted anything. Enforcement in `pvesh` works regardless — a
`pvesh create` into an over-quota pool is refused — because the wraps are
installed by then and the command runs afterwards. See
[ADR 0013](adr/0013-cli-enforcement-is-opt-in.md).

Leaving all three disabled is a perfectly good answer. A quota is a boundary for
*delegated* callers — the web interface, API clients, scoped automation — and
anyone who can run `qm create` can also edit the guest config directly or remove
the package.

## 3. If you still need a patch

proxmod's managed facility exists so that the patch you write anyway is a
*declared* one with a state database behind it, rather than a `sed` in a
maintainer script.

### What it gives you over a hand-rolled patch

- **One place records the target**, so defect 1 cannot happen.
- **Backups live in `/var/lib/proxmod/backups/` and are enumerated from
  `/var/lib/proxmod/patches.state`**, so defect 3 cannot happen.
- **Revert never blindly restores.** It compares a recorded checksum first, and
  if the file changed underneath, it surgically removes proxmod's own marked
  block instead of restoring an older file — so defect 2 cannot happen.
- **Convergence runs from the dpkg trigger**, not an APT hook, so defect 4
  cannot happen.
- **`/etc/pve` is unreachable**, so hazard 5 cannot happen.
- **A literal anchor that must match exactly once.** Not a regex.
- **Markers**, so two patches to one file coexist and either can be removed.

What it does **not** give you: any of the upgrade guarantees in
[`specifications.md`](specifications.md) §13. The moment you enable a spec, the
"nothing to reapply" claim stops applying to this host.

### The spec format

```jsonc
{
    "id": "example-index-banner",
    "description": "Example only (disabled).",

    // Absent or 0 means nothing happens.
    "enabled": 0,

    // Must sit under an allowed root. /etc/pve is refused outright.
    "target": "/usr/share/pve-manager/index.html.tpl",

    // A LITERAL string that must appear EXACTLY ONCE in the target.
    "anchor": "    <script type=\"text/javascript\" src=\"...pvemanagerlib.js...\"></script>",

    // after | before | replace
    "position": "after",

    // Inserted verbatim, wrapped in proxmod:begin/end markers.
    "text": "    <!-- proxmod example patch -->",

    // Optional; inferred from the target's extension.
    "comment": "html"
}
```

Specs are read from `/usr/share/proxmod/patches` (package-owned) overlaid by
`/etc/proxmod/patches` (administrator-owned), later winning by basename.

### Rules the engine enforces, and why

**The anchor is a literal, never a regex.** A regex is how a patch silently
matches the wrong line three point releases later. If the anchor appears twice,
or not at all, proxmod refuses and says so — and "not at all" almost always
means an upgrade rewrote the file and the spec needs revisiting. A loud refusal
is the correct outcome; a clever fallback match is not.

**Allowlisted roots, not a denylist.** Only these three:

```
/usr/share/pve-manager
/usr/share/perl5/PVE
/usr/share/javascript/proxmox-widget-toolkit
```

The set of directories it is ever reasonable to patch is small and known; the
set of files that must never be touched is unbounded and includes things nobody
would think to enumerate. `/etc/pve` is additionally in an explicit `@NEVER`
list so that a future edit widening the roots still cannot reach it.

**The target must be root-owned and not group- or world-writable.** A patched
file under `/usr/share/perl5/PVE` is executed by `pvedaemon` as root. Patching a
file anyone can then rewrite is unauthenticated root RCE on the hypervisor. The
ownership check is overridable only so unit tests can run as a normal user; the
writability check is not overridable at all.

**Unknown file extension means a rejected spec, not a guessed comment style.**
Getting the delimiter syntax wrong does not corrupt the file subtly — it breaks
it outright the next time a daemon parses it.

**Writes are atomic**, via a temporary file in the same directory plus rename,
preserving mode. A `pvedaemon` reading a half-written `.pm` is a dead daemon.

### Using it

```sh
proxmodctl patch status          # every spec, and whether it is applied
proxmodctl patch converge        # apply enabled, undo no-longer-enabled
proxmodctl patch apply <id>
proxmodctl patch revert <id>
proxmodctl patch revert-all
```

`converge` runs automatically from `proxmod-reapply`, so a patch is reapplied
after an upgrade by the same trigger that converges everything else. On a stock
host it walks two directories, finds nothing enabled, and returns.

A patch that actually changed a file counts as a reason to restart the daemons —
the changed file is either Perl already loaded into a running process or
JavaScript cached by a browser.

### Before you enable a spec, and after

Enable one and you have taken on an obligation:

- [ ] Re-read the anchor against the **current** `pve-manager` on every upgrade
- [ ] Wire `proxmod-verify --json` into monitoring — patch failures are quiet by
      design, because the alternative is wedging dpkg
- [ ] Expect `dpkg -V pve-manager` to be noisy, and tell whoever runs the
      integrity checks why
- [ ] Record why a runtime extension was not sufficient, in the spec's
      `description`, for whoever inherits this host
- [ ] Have a plan for the release where the anchor is gone

And revisit it: the reason a patch was needed is often a missing seam, and the
right long-term fix is usually a proxmod feature, a PVE plugin, or a patch sent
upstream to Proxmox — where it becomes everyone's supported code instead of your
host's local divergence.

---

## Reference

- [`patches/50-example-index-banner.conf`](../patches/50-example-index-banner.conf) — the shipped example, disabled
- [`specifications.md`](specifications.md) §17 — the normative description of the facility
- [`specifications.md`](specifications.md) §13 — the guarantees you give up
- [`packaging.md`](packaging.md) §4 — maintainer-script rules, each traced to a defect above
- [`frontend-extensions.md`](frontend-extensions.md), [`backend-extensions.md`](backend-extensions.md) — what to do instead
- [`security.md`](security.md) — why a writable patched file is a root compromise
