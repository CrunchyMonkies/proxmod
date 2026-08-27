# ADR 0009 — Verify the running daemon, not a fresh process

**Status:** Accepted
**Date:** 2026-08-08
**Applies to:** proxmod 0.2.2, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** implemented in
[`bin/proxmod-verify`](../../bin/proxmod-verify); tested in `t/10-verify.t`

---

## Context

proxmod fails quietly by design. A broken extension does not stop a daemon, a
failed trigger does not stop `apt`, and a moved seam disables one feature. That
is the right posture for something attached to a hypervisor's control plane, and
it means **nothing will tell you when proxmod stops working**.

So verification is not a nicety here; it is the other half of the fail-safe
design. The question is what it should actually check.

The obvious implementation is `perl -MProxmod -e1` — does the module load?

## Decision

The primary gate is the **live running daemon**:

```sh
journalctl -u <unit> --since "$(systemctl show -p ExecMainStartTimestamp --value <unit>)"
```

— does the journal, since *this process* started, contain proxmod's boot line?

Not a fresh `perl`. Then, on top: live HTTP checks, a `find_handler` structural
replay, and a drift report on the **live** `ExecStart`/`ExecReload`.

## Why

A fresh `perl` proves the module compiles on this host today. It proves nothing
about the process currently serving your API, which started earlier, possibly
with a different command line, possibly before an upgrade replaced something
underneath it.

That gap is not hypothetical. `pve-token-copy`'s own verification passed while
its endpoint had never once loaded: the module compiled fine outside the daemon,
and `-T` refused it inside. Everything looked correct and nothing worked.

The general rule, which the documentation states for anyone writing similar
tooling: **verify the running system, not a fresh process that resembles it.**

The same reasoning drives the other checks:

- `drift.<unit>` reads the **live** unit, so it detects another package's
  drop-in having won the `ExecStart=` race.
- `reload.<unit>` is the check most likely to fire after an upgrade, because a
  missing `ExecReload` override means proxmod disappears at the next reload with
  no other symptom.
- `structure` replays routes through `find_handler`, because registration
  succeeding and an endpoint being reachable are different questions — a path
  behind a greedy `fragmentDelimiter => ''` subtree registers perfectly and
  never resolves [PVE-F-051].

**Only `error` sets the exit status.** proxmod degrading *is* the designed
behaviour, and an administrator who disabled an extension should not get a red
alert for it. Warnings are reported and must be read.

## Consequences

- **Verification requires root and a persistent journal.** Without either it
  degrades to a warning rather than a failure, which is the honest answer — it
  cannot see, so it does not claim.
- **The documentation carries a monitoring obligation**, stated as an
  obligation: wire `proxmod-verify --json` into monitoring and alert on
  `healthy: false`, and run it after every `pve-manager` upgrade. A fail-safe
  design that nobody asks about is a silently broken one.
- **`--live-only` must stay narrow.** `proxmod-reapply` uses it to decide
  whether to restart. If it were widened to include the HTTP checks, a 404 on
  one asset would become a hypervisor API interruption — and a restart would not
  fix it anyway.
- **Runtime checks cannot ask "does this still mean what it meant".** A Proxmox
  release that keeps a seam but changes its behaviour passes everything. That is
  what the fact ledger and `make facts ISO=…` are for; `proxmod-verify` does not
  pretend to cover it.

## Alternatives considered

**`perl -MProxmod -e1`** — the check that failed on the prior art. Retained
nowhere.

**A heartbeat endpoint the framework registers** — would prove `pvedaemon`
loaded proxmod, and says nothing about `pveproxy`, adds an endpoint to the
attack surface, and cannot report *why* something failed. The journal already
carries the reason.

**A state file written at boot** — cheaper than reading the journal, and it can
be stale in exactly the case that matters: written by a previous process, still
present, still saying "fine".
