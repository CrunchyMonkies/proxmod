# ADR 0005 — No version ceiling on `pve-manager`

**Status:** Accepted
**Date:** 2026-08-08
**Applies to:** proxmod 0.1.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** [`debian/control`](../../debian/control) has no
`Breaks:` on `pve-manager`; the degradation behaviour is in
[`compatibility.md`](../compatibility.md) §3

---

## Context

proxmod attaches to unpublished seams that can move in any Proxmox release.
Debian offers `Breaks: pve-manager (>= 10~)` to make that explicit, and it is
the conventional answer for a package that depends on another's internals.

## Decision

**No ceiling.** proxmod declares no upper bound on `pve-manager`. It installs on
a Proxmox it has never seen, probes each seam at runtime, and disables — feature
by feature — whatever it cannot find.

## Why

A ceiling holds back a legitimate major upgrade of the hypervisor in order to
protect an add-on. The administrator is then choosing between security updates
and a GPU tab, and in practice they resolve it with `--force` or by removing the
package mid-upgrade, neither of which anyone designed for.

**A stale add-on is a smaller problem than an unpatched hypervisor.** proxmod is
not entitled to make that trade on someone else's behalf.

This only works because the fail-safe posture is real. On an unknown Proxmox,
the floor is *Proxmox VE exactly as shipped*: the wrapper execs the daemon
unmodified when it cannot parse the invocation, each glob wrap is behind a
`can()` probe, each ExtJS override is behind an `Ext.ClassManager.get()` probe,
and every stage and every extension runs in its own `eval`. The worst case is a
log line and a missing tab.

## Consequences

- **The failure mode is a degraded feature, not a refused upgrade.** That is a
  deliberate trade of loudness for availability, and it is why
  [ADR 0009](0009-verify-the-running-daemon.md) and the monitoring obligation in
  [`verification.md`](../verification.md) exist. Silent degradation is only
  acceptable if something asks.
- **Probes cannot catch a seam that stays but changes meaning.** A release that
  keeps `get_index` but changes what the index contains passes every probe. The
  fact ledger is the tool for that: `make facts ISO=… && git diff docs/facts/`
  runs offline against an ISO, and a diff is the signal to re-read the claims
  that cite it.
- proxmod must keep the degradation table honest — for every seam, what it does
  and what the symptom is. That is `compatibility.md` §3 and §4.

## Alternatives considered

**`Breaks: pve-manager (>= 10~)`** — rejected above.

**A ceiling with an override flag** — a flag nobody reads until an upgrade is
already blocked, at which point they set it without reading. Same outcome, more
machinery.

**Refuse to load at runtime on an unknown major version** — the same harm as a
ceiling, delayed until after the upgrade, and it discards perfectly good
per-seam degradation in favour of an all-or-nothing guess based on a version
string.
