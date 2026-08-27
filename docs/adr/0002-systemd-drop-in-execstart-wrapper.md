# ADR 0002 — A systemd drop-in and an `ExecStart` wrapper

**Status:** Accepted
**Date:** 2026-08-08
**Applies to:** proxmod 0.2.2, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** implemented in [`exec/proxmod-exec`](../../exec/proxmod-exec)
and [`systemd/`](../../systemd); tested in `t/08-exec.t` with a fake `systemctl`
on `PATH`

---

## Context

[ADR 0001](0001-runtime-injection-over-file-patching.md) requires
`Proxmod.pm` to be loaded into `pvedaemon` and `pveproxy` without editing a file
Proxmox owns. Something has to change how those processes start.

## Decision

Ship a drop-in per daemon at `/etc/systemd/system/<unit>.service.d/10-proxmod.conf`
that replaces `ExecStart` with `/usr/lib/proxmod/proxmod-exec <daemon>`, and
overrides `ExecReload` to a real restart.

`proxmod-exec` reads the **base unit's** real `ExecStart` via
`systemctl show -p FragmentPath`, parses the shebang, and re-execs with
`-MProxmod` inserted.

## Why

**Not `PERL5OPT`.** Both daemons run `perl -T`, and taint mode ignores
`PERL5LIB` and `PERL5OPT` [PVE-F-002]. The module must sit in a default `@INC`
directory [PVE-F-003] and load from the command line.

**A drop-in, not an edited unit file.** dpkg owns the unit; an edit would be
clobbered and would show in `dpkg -V`. Drop-ins are the supported mechanism and
compose with the package.

**Read the invocation, do not hardcode it.** If proxmod hardcoded
`/usr/bin/perl -T /usr/bin/pveproxy start`, a Proxmox change to the command line
would produce a daemon started the wrong way. Reading `FragmentPath` means a
changed command line is *carried through* rather than replaced.

**`ExecReload` is not optional.** PVE's graceful reload is an in-process
`exec()` of the original `argv`, which does not contain `-MProxmod`. Without the
override, `systemctl reload pveproxy` unloads proxmod and leaves a daemon that
looks perfectly healthy and serves nothing. It matters more than it sounds:
`pve-manager`'s own `postinst` runs `reload-or-try-restart` on every upgrade
[PVE-F-005], so proxmod would come undone on exactly the event it exists to
survive. **With the override, Proxmox's own upgrade path re-injects proxmod.**

**Fail safe, always.** On an unrecognised shebang, a failed probe, the kill
switch at `/etc/proxmod/disabled`, or unsafe permissions on anything about to be
loaded, `proxmod-exec` execs the daemon **exactly as Proxmox ships it**. A
missing extension is acceptable; a dead hypervisor API is not.

The permission refusal is a security boundary, not tidiness: everything in
`/usr/share/perl5/Proxmod*`, `/usr/share/proxmod/extensions.d` and
`/etc/proxmod` executes as root inside `pvedaemon`, so a group-writable entry
there is unauthenticated root on the hypervisor and every guest it runs.

**Not conffiles.** The drop-ins ship to `/usr/share/proxmod/systemd/` and
`postinst` installs them, because `prerm` must remove the loader *before* dpkg
deletes the module it names. A conffile is removed too late and in the wrong
order.

## Consequences

- Only one drop-in can set `ExecStart=`; the last one alphabetically wins. Two
  frameworks wrapping the same daemon conflict. `proxmod-verify` reports it as
  `drift.<unit>` and cannot fix it — the resolution is for the other module to
  become a proxmod extension.
- The `ExecReload` override turns a graceful reload into a restart. `pveproxy`
  restarts in well under a second; the trade is a moment of interruption for
  never silently losing the framework.
- Anything that inspects `ExecStart` sees proxmod's wrapper, not `pveproxy`. It
  is honest — proxmod *is* in the start path — but it is visible.
- `proxmod-exec` runs as root at daemon start, before any proxmod Perl. It is
  deliberately small and shell, and it is the one component whose failure mode
  had to be "start the daemon anyway".

## Alternatives considered

**A wrapper package replacing `pveproxy`** — a diversion, dpkg conflicts, and a
permanent maintenance burden against upstream.

**`LD_PRELOAD` or a Perl `sitecustomize.pl`** — `sitecustomize` requires `-f`
handling and applies to *every* Perl process on the host, including `pvesh`,
`pvesm` and every hook script. Far too broad.

**A systemd generator** — would work and is harder to inspect, harder to
disable, and runs earlier than anything needs to. A drop-in an administrator can
read with `systemctl cat pveproxy` is worth more than the elegance.
