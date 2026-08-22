# Installing proxmod

**Status:** Draft
**Applies to:** proxmod 0.2.1, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the file manifest is the `install` target of the
[`Makefile`](../Makefile) and [`debian/`](../debian/); the removal behaviour is
the maintainer scripts, tested in `t/09-reapply.t` and the QEMU suite

---

## 1. Before you start

- **Proxmox VE 9.x.** proxmod 0.2.1 targets 9.x only.
- **Root on the node.** Cluster-wide? Install on every node — proxmod is
  per-host, like `pveproxy` itself.
- **Installing restarts `pvedaemon` and `pveproxy`.** Running guests are
  unaffected; open web-interface sessions reconnect. Do it in a window where a
  few seconds of API interruption is fine.
- **A test host first**, if this is a cluster you care about.

## 2. Install

```sh
apt install ./proxmod_0.2.1_all.deb
```

Then, in order:

```sh
proxmod-verify                      # exits 0
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl   # silent
```

The second one is the claim: **no Proxmox-owned file was modified.** If it
prints anything, something else on this host is patching Proxmox — see
[`patching.md`](patching.md).

Now reload the web interface in a browser and check the page source contains one
`<script src="/proxmod/loader.js…">`, or from the shell:

```sh
curl -sk https://localhost:8006/ | grep -c '/proxmod/loader.js'    # 1
```

Nothing visible changes yet. proxmod on its own adds no tabs and no endpoints —
it is the thing extensions plug into.

### Install an extension

```sh
apt install ./proxmod-example-hello_0.2.0_all.deb
proxmodctl list
```

No restart needed on your part: writing into
`/usr/share/proxmod/extensions.d/` fires proxmod's dpkg trigger, proxmod sees
that the registry the daemons loaded is no longer the registry on disk, and
converges — which for an extension means a restart of `pvedaemon` and
`pveproxy`, since a running daemon reads the registry once at startup. Reload
the browser; a **Hello** tab appears on each node.

Removing one is the same in reverse: `apt remove` fires the same trigger and the
extension stops answering. Neither needs `--force`, and neither restarts
anything on an apt run that did not touch an extension.

To check the backend half from the shell, go through the live daemon rather than
`pvesh` — `pvesh` builds its own API tree in its own process, which was not
started through proxmod's wrapper and so has no extensions in it:

```sh
TICKET=$(pvesh get /access/ticket --username root@pam --password ... --output-format json)
curl -sk -b "PVEAuthCookie=..." \
    "https://localhost:8006/api2/json/nodes/$(hostname)/proxmod/example-hello/greet"
```

Easier: click the tab.

## 3. What got installed

| Path | |
|---|---|
| `/usr/share/perl5/Proxmod.pm`, `/usr/share/perl5/Proxmod/` | the framework, loaded into both daemons |
| `/usr/lib/proxmod/proxmod-exec` | the `ExecStart` wrapper |
| `/usr/lib/proxmod/proxmod-reapply` | the convergence routine |
| `/usr/lib/proxmod/proxmod-patch` | the patch engine (inert) |
| `/usr/sbin/proxmodctl`, `/usr/sbin/proxmod-verify` | the CLI |
| `/usr/share/proxmod/www/proxmod-ui.js` | the JS API |
| `/usr/share/proxmod/loader-runtime.js` | deliberately **outside** `www/` — not served |
| `/usr/share/proxmod/extensions.d/` | where extension packages write |
| `/usr/share/proxmod/patches/` | shipped patch specs, all disabled |
| `/usr/share/proxmod/systemd/` | drop-in sources |
| `/etc/proxmod/proxmod.conf` | conffile; your edits survive upgrades |
| `/etc/proxmod/extensions.d/`, `/etc/proxmod/patches/` | your overrides |
| `/var/lib/proxmod/` | the reapply lock, patch state, patch backups |
| `/etc/systemd/system/{pvedaemon,pveproxy}.service.d/10-proxmod.conf` | installed by `postinst`, removed by `prerm` |
| `/lib/systemd/system/proxmod-verify.service` | boot-time safety net |

Nothing under `/usr/share/pve-manager`, nothing under `/usr/share/perl5/PVE`,
and nothing at all under `/etc/pve`.

### The two systemd drop-ins

```ini
[Service]
ExecStart=
ExecStart=/usr/lib/proxmod/proxmod-exec pveproxy
ExecReload=
ExecReload=-/bin/systemctl --no-block restart pveproxy.service
```

`ExecStart` runs the wrapper, which reads the base unit's *real* `ExecStart`,
adds `-MProxmod`, and execs — so it survives Proxmox changing the invocation,
and it starts the daemon unmodified on any anomaly.

`ExecReload` is rewritten to a **restart**, and this is not optional. PVE's own
reload is an in-process `exec()` of the original `argv`, which does not contain
`-MProxmod`; a plain `systemctl reload pveproxy` would silently unload proxmod
and leave a daemon that looks healthy and serves none of the extensions. It
matters more than it sounds, because `pve-manager`'s own `postinst` runs
`deb-systemd-invoke reload-or-try-restart` on every upgrade [PVE-F-005] — which
prefers reload. With the override, Proxmox's own upgrade path re-injects proxmod
for us.

## 4. Configuration

`/etc/proxmod/proxmod.conf` is a dpkg conffile: your edits survive upgrades, and
dpkg asks before replacing it.

```ini
# Verbose logging to both daemons' journals. Off by default.
debug = 0
```

`PROXMOD_DEBUG` in the environment also works, but only when a daemon is started
by hand — systemd starts `pvedaemon` with a cleared environment, so on a real
host the config file is the switch that works.

Extensions are configured by their own drop-ins under
`/etc/proxmod/extensions.d/` — see [`extension-manifest.md`](extension-manifest.md).

## 5. Turning it off without uninstalling

```sh
proxmodctl disable      # or: touch /etc/proxmod/disabled; systemctl restart pvedaemon pveproxy
proxmodctl enable
```

Both daemons then start **exactly as Proxmox ships them**. The kill switch is
checked by the `ExecStart` wrapper before any proxmod code is loaded at all, so
it works even when proxmod itself is broken. It is the thing to reach for at
3am.

## 6. Upgrading

```sh
apt install ./proxmod_0.2.1_all.deb
proxmod-verify
```

`prerm` does **nothing** on `upgrade` — deliberately, see
[`packaging.md`](packaging.md) §4 — and `postinst configure` converges, so the
daemons restart once rather than twice.

### After a Proxmox upgrade

There is nothing to reapply. Everything proxmod owns lives where Proxmox never
writes, and `pve-manager`'s own `postinst` restarts the daemons through our
drop-ins.

Check anyway:

```sh
proxmod-verify
```

A `reload.<unit>` warning means the `ExecReload` override is not in place and
the next reload will unload proxmod. Run `proxmodctl reapply`.

This is the one recurring obligation proxmod asks of you — see
[`verification.md`](verification.md), and wire `proxmod-verify --json` into
monitoring, because proxmod's failures are quiet by design.

## 7. Removing

```sh
apt remove proxmod        # drop-ins removed, daemons restarted stock, config kept
apt purge proxmod         # the above, plus /etc/proxmod and /var/lib/proxmod
```

Remove extension packages first, or leave them — their files are inert without
proxmod.

Verify it left no trace:

```sh
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl   # silent
systemctl is-active pvedaemon pveproxy                            # active active
ls /etc/systemd/system/pve*.service.d/ 2>/dev/null                # no 10-proxmod.conf
curl -sk https://localhost:8006/ | grep -c '/proxmod/loader.js'   # 0
find /usr/share/perl5/PVE -name '*.pre-*' -o -name '*.bak'        # nothing
```

`purge` prunes shared directories with `rmdir`, never `rm -rf`: if another
package still owns files in `/usr/share/proxmod/www`, those directories stay,
and that is the correct outcome.

## 8. Building from source

```sh
make check                 # prove -r t/, no Proxmox needed
make lint
dpkg-buildpackage -us -uc -b
lintian ../proxmod_*.deb
```

To re-derive the Proxmox internals facts for a new point release, without a PVE
host:

```sh
make facts ISO=/path/to/proxmox-ve_9.1-1.iso
```

That regenerates `docs/facts/pve-9.1.1.txt` from a read-only ISO→deb→tar
pipeline, and every claim in the documentation cites an entry in it. See
[`pve-facts.md`](pve-facts.md).

## 9. If something goes wrong

```sh
proxmodctl doctor
```

Then [`troubleshooting.md`](troubleshooting.md). If the web interface is down
and you need it back now:

```sh
touch /etc/proxmod/disabled
systemctl restart pvedaemon pveproxy
```

---

## Reference

- [`getting-started.md`](getting-started.md) — build your first extension
- [`cli.md`](cli.md) — every command
- [`verification.md`](verification.md) — what `proxmod-verify` checks
- [`troubleshooting.md`](troubleshooting.md) — symptom-first
- [`compatibility.md`](compatibility.md) — what happens on a Proxmox proxmod has not seen
