# Command-line tools

**Status:** Draft
**Applies to:** proxmod 0.2.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** usage text, options, exit codes and check ids below
were read out of [`bin/proxmodctl`](../bin/proxmodctl),
[`bin/proxmod-verify`](../bin/proxmod-verify) and
[`exec/proxmod-patch`](../exec/proxmod-patch); `proxmod-verify` is unit-tested
in `t/10-verify.t`

| Command | Where | For |
|---|---|---|
| `proxmodctl` | `/usr/sbin` | administrators. Start here |
| `proxmod-verify` | `/usr/sbin` | monitoring, and the detail behind `status` |
| `proxmod-patch` | `/usr/lib/proxmod` | the patch engine; reach it via `proxmodctl patch` |
| `proxmod-reapply` | `/usr/lib/proxmod` | convergence. Called by dpkg, systemd and `proxmodctl` |
| `proxmod-exec` | `/usr/lib/proxmod` | the `ExecStart` wrapper. **Never run by hand** |

The last two exist to be called by something else. They are documented here so
that a journal line naming them makes sense, not so that you invoke them.

---

## 1. `proxmodctl`

```
usage: proxmodctl <command> [options]

  status            is proxmod working? (proxmod-verify)
  status --json     the same, for monitoring
  list              the extensions this host has installed
  reapply           converge the systemd drop-ins and restart if needed
  reapply --force   restart the wrapped daemons even if nothing changed
  enable            remove the kill switch and restart the daemons
  disable           stop loading proxmod, and restart the daemons stock
  logs [-f]         what proxmod said in the daemons' journals
  patch <sub>       the managed patch facility; `patch` on its own for help
  doctor            status, plus the context you would paste into a bug report
```

`enable`, `disable` and `reapply` restart `pvedaemon` and `pveproxy`. **Running
guests are not affected**; open web-interface sessions reconnect. `status`,
`list`, `logs` and `doctor` change nothing and need no privileges beyond reading
the journal.

### The three you will actually use

```sh
proxmodctl status        # after an upgrade, or when something looks wrong
proxmodctl logs          # what proxmod said, without the rest of the journal
proxmodctl doctor        # the whole picture, for a bug report
```

`doctor` is `status` plus versions, the live `ExecStart` and `ExecReload` of
both units, the registry, and the patch state. Paste its output into an issue.

### `disable` and `enable`

```sh
proxmodctl disable       # touch /etc/proxmod/disabled, restart both daemons
proxmodctl enable        # remove it, restart both daemons
```

`disable` is the thing to reach for at 3am. It leaves the package installed and
starts both daemons **exactly as Proxmox ships them** — the kill switch is
checked by the `ExecStart` wrapper before any proxmod code is loaded at all, so
it still works when proxmod itself is broken.

The equivalent without proxmodctl, for when even that is not working:

```sh
touch /etc/proxmod/disabled
systemctl restart pvedaemon pveproxy
```

---

## 2. `proxmod-verify`

```
usage: proxmod-verify [--json] [--quiet] [--live-only] [--registry-only]
                      [--no-http] [--url URL]

  --json       machine-readable report on stdout
  --quiet      no output; the exit status is the answer
  --live-only  check only whether the running daemons have proxmod loaded
  --registry-only
               check only whether they loaded the registry that is on disk
               now; prints that registry's fingerprint on stdout
               exit: 0 up to date, 1 out of date, 2 could not tell
  --no-http    skip the checks that talk to the live web interface
  --url URL    base URL of the local pveproxy (default https://127.0.0.1:8006)

exit: 0 healthy, 1 a check failed, 64 bad usage
```

### What it checks, in order

| Group | Question |
|---|---|
| `installed` | Are the systemd drop-ins shipped, and in place? |
| `disabled` | Is the kill switch set? (informational, not a failure) |
| `drift.<unit>` | Does the **live** unit's `ExecStart` resolve to proxmod's wrapper, and does `ExecReload` restart rather than reload? |
| `live.<unit>` | Does the **running** daemon's journal, since its current start, say proxmod booted? |
| `extensions.<unit>` | Did every extension load in that daemon? |
| `registry.<unit>` | Is the registry it loaded still the registry on disk? |
| `http.index` | Does the index carry **exactly one** loader tag? |
| `http.loader` | Is `/proxmod/loader.js` served? |
| `http.asset<n>` | Is every asset the loader references actually served? |
| `structure` | Replayed against the API tree: do the registered routes resolve? |

### The primary gate is the running daemon

`live.<unit>` reads

```sh
journalctl -u <unit> --since "$(systemctl show -p ExecMainStartTimestamp --value <unit>)"
```

and looks for proxmod's boot line — **not** a fresh `perl -MProxmod -e1`.

That distinction is the entire point. A fresh `perl` proves the module compiles
on this host today. It proves nothing about the process that is currently
serving your API, which was started earlier, possibly with a different command
line, possibly before an upgrade replaced something underneath it. This is
exactly the class of check that would have caught `pve-token-copy`'s taint-mode
bug, where its verify passed while the endpoint had never once loaded.

### `error` versus `warn`

Only `error` sets the exit status. `warn` is reported and does not fail, because
proxmod **degrading is designed behaviour** — an administrator who disabled an
extension, or a seam that a new Proxmox release moved, should not produce a red
monitoring alert.

The one to know: `reload.<unit>` warns when a unit will lose proxmod on reload.
That means the `ExecReload` override is not in place, and the next
`systemctl reload pveproxy` — or the next `pve-manager` upgrade, which runs
`reload-or-try-restart` [PVE-F-005] — will silently unload proxmod. Run
`proxmodctl reapply`.

### `--live-only` and `--registry-only`

The two narrow questions `proxmod-reapply` asks before deciding whether to
restart anything: *are they loaded*, and *did they load what is on disk now*.
Kept as separate flags so that widening either cannot silently widen the other.

**Neither must be widened.** A failing HTTP check is not a reason to bounce
`pvedaemon` — a 404 on one asset would become a hypervisor API interruption.

`--registry-only` is also the honest way to ask a whole cluster whether its
nodes agree:

```sh
for n in $(pvecm nodes | awk 'NR>2 {print $3}'); do
    printf '%-16s %s\n' "$n" "$(ssh "$n" proxmod-verify --registry-only)"
done
```

Nodes with the same extensions installed print the same fingerprint. A node
that prints a different one has a different set, or a different proxmod.

### Monitoring

```sh
proxmod-verify --json
```

Wire this in. proxmod's failures are quiet by design — a missing extension does
not stop a daemon, and a trigger that fails does not stop `apt` — so **nothing
will tell you** unless you ask. Run it after every `pve-manager` upgrade, and on
a schedule.

```jsonc
{
  "healthy": false,
  "findings": [
    { "id": "live.pveproxy", "level": "error",
      "title": "pveproxy is running WITHOUT proxmod", "detail": "..." }
  ]
}
```

---

## 3. `proxmodctl patch`

```
  status        every patch spec on this host, and whether it is applied
  converge      apply enabled specs, undo ones that are no longer enabled
  apply <id>    apply one spec (it must be enabled)
  revert <id>   undo one patch
  revert-all    undo every patch proxmod applied
```

On a default install `status` lists the shipped example spec as disabled and
`converge` does nothing. Read [`patching.md`](patching.md) before enabling
anything — patching a Proxmox file gives up every upgrade guarantee proxmod
has.

`converge` also runs automatically from `proxmod-reapply`, so an enabled patch
is reapplied after an upgrade by the same trigger that converges everything
else.

---

## 4. `proxmod-reapply`

```
usage: proxmod-reapply [--trigger] [--force] [--remove] [--quiet]
```

The single convergence point. Called by `postinst configure`, by
`postinst triggered`, by `proxmod-verify.service` at boot, and by
`proxmodctl reapply`. There is deliberately no second implementation of "make
the host match the package" anywhere in the source tree.

It takes an `flock`, skips while `/proxmox_install_mode` exists, re-asserts the
drop-ins, runs `daemon-reload` **only if something changed**, and restarts the
daemons **only if something changed or `proxmod-verify --live-only` says they
are not loaded**. If a daemon does not come back, it removes proxmod's own
drop-ins and restarts it stock.

`--trigger` always exits 0: a non-zero exit from a dpkg trigger can wedge an
entire `apt dist-upgrade`, including security updates for packages that have
nothing to do with proxmod.

`--remove` converges to "proxmod is not installed". Used by `prerm` on
`remove`, and **never** on `upgrade` — see [`packaging.md`](packaging.md) §4.

Run it by hand as `proxmodctl reapply`.

---

## 5. `proxmod-exec`

The `ExecStart` wrapper named by the systemd drop-ins. **Do not run it by
hand.**

It reads the base unit's real `ExecStart` via `systemctl show -p FragmentPath`,
parses the shebang, and re-execs the daemon with `-MProxmod` added. On **any**
anomaly it execs the daemon unmodified: a shebang it does not recognise, a
failed probe, the kill switch at `/etc/proxmod/disabled`, or — importantly —
any of `/usr/share/perl5/Proxmod*`, `/usr/share/proxmod/extensions.d` or
`/etc/proxmod` being non-root-owned or group/world-writable.

That last check is not paranoia. Everything it guards is executed as root inside
`pvedaemon`; a writable entry there is unauthenticated root RCE on the
hypervisor. See [`security.md`](security.md).

---

## 6. Recipes

```sh
# Is proxmod working right now?
proxmodctl status

# Something is wrong and I need the whole picture
proxmodctl doctor

# What did proxmod say, live?
proxmodctl logs -f
journalctl -u pveproxy -u pvedaemon -f | grep proxmod    # the same, by hand

# I just upgraded Proxmox
proxmodctl status
# a `reload.<unit>` warning → proxmodctl reapply

# Turn it off, keep the package
proxmodctl disable

# Emergency, when proxmodctl itself is not working
touch /etc/proxmod/disabled && systemctl restart pvedaemon pveproxy

# What is installed?
proxmodctl list

# Did anything patch a Proxmox file?
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl
proxmodctl patch status

# Force a restart even though nothing changed
proxmodctl reapply --force

# Ask for convergence from another package's maintainer script
dpkg-trigger proxmod-reapply
```

### Exit codes

| | |
|---|---|
| 0 | healthy / done |
| 1 | a check failed, or the command failed |
| 64 | bad usage |

`proxmod-reapply --trigger` is the exception: always 0, on purpose.

---

## Reference

- [`verification.md`](verification.md) — every check, what it means, and what to do
- [`troubleshooting.md`](troubleshooting.md) — symptom-first
- [`patching.md`](patching.md) — before you enable a patch spec
- [`packaging.md`](packaging.md) — where the trigger and the maintainer scripts fit
