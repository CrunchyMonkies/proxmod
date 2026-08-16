# ADR 0003 — dpkg triggers, not an APT hook

**Status:** Accepted
**Date:** 2026-08-08
**Applies to:** proxmod 0.2.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** [`debian/proxmod.triggers`](../../debian/proxmod.triggers)
and [`exec/proxmod-reapply`](../../exec/proxmod-reapply); tested in `t/09-reapply.t`
and by QEMU tests 8 and 9

---

## Context

Two things need to converge after the system changes: proxmod's systemd drop-ins
must exist (an aggressive `systemctl revert`, a restored backup, or an
interrupted install could remove them), and installing an *extension* package
must take effect without that package shipping any maintainer scripts.

`pmxxpuiov` used an APT `DPkg::Post-Invoke` hook. Proxmox itself uses dpkg
triggers [PVE-F-010].

## Decision

**dpkg triggers as the primary mechanism**, with a boot-time oneshot as a
complement.

```
interest-noawait /usr/share/proxmod/extensions.d
interest-noawait /usr/share/proxmod/www
interest-noawait /etc/proxmod/extensions.d
```

All paths, plus the boot unit and `proxmodctl reapply`, run the same routine:
`/usr/lib/proxmod/proxmod-reapply`.

## Why

| | dpkg triggers | APT `DPkg::Post-Invoke` | systemd `PathChanged=` |
|---|---|---|---|
| Fires on `dpkg -i` | **yes** | no | indirectly |
| Only when relevant | **yes** — a watched path changed | no — every apt run | poorly, non-recursive |
| Ordered against dpkg | **yes** | no | **no** — fires mid-unpack |
| Batched | **yes**, once per run | per invocation | no |
| Precedent in PVE | **yes** [PVE-F-010] | no | no |

The `DPkg::Post-Invoke` row is not theoretical. In `pmxxpuiov` it meant
installing `htop` restarted the hypervisor's web interface, and installing the
extension with `dpkg -i` did nothing at all.

`PathChanged=` is disqualified by ordering alone: firing between unpack and
configure means converging against a half-installed package.

The boot unit is a complement, not a primary. It catches a host restored from a
backup, or a dpkg run interrupted between unpack and trigger processing. It
adds nothing on a healthy boot and costs one `flock` and a few `systemctl show`
calls.

## The rules the trigger path must obey

- **Always exit 0.** A non-zero exit from a dpkg trigger can wedge an entire
  `apt dist-upgrade`, including security updates for unrelated packages. proxmod
  is not entitled to do that.
- **`flock`.** Triggers, the boot unit and `proxmodctl` can overlap.
- **Skip while `/proxmox_install_mode` exists**, mirroring PVE's own guard.
- **`daemon-reload` only if something changed.**
- **Restart only if something changed, or `proxmod-verify --live-only` says the
  running daemons are not loaded.** This is the single condition that prevents
  the restart-on-every-apt-run behaviour, and why `--live-only` must stay narrow
  — a failing HTTP check is not a reason to bounce `pvedaemon`.
- **Self-heal.** If a daemon does not come back, remove proxmod's own drop-ins
  and restart it stock.

## Consequences

- An extension package ships **three files and no maintainer scripts**. Writing
  into a watched path is the entire activation protocol.
- Convergence has exactly one implementation, so the two-edit-sites drift that
  broke `pmxxpuiov`'s reapply cannot happen here.
- `interest-noawait` means the triggering package is not held in a
  `triggers-awaited` state, so a broken proxmod cannot block another package
  from configuring.
- Triggers fire on *changes to watched paths*, not on `pve-manager` upgrades.
  Update survival does not depend on them — the `ExecReload` override handles
  that. Triggers are for extensions and for repairing drift.

## Alternatives considered

**A `.path` unit plus a debounce timer** — reinvents batching that dpkg already
does correctly, and still fires mid-unpack.

**Requiring extension packages to call `proxmodctl reapply` in `postinst`** —
puts the burden on every consumer, and a consumer that forgets produces a
silently inert extension. The whole point of the contract is that there is
nothing to forget.
