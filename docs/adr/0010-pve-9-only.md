# ADR 0010 — Target Proxmox VE 9.x only

**Status:** Accepted
**Date:** 2026-08-08
**Applies to:** proxmod 0.4.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** [`docs/facts/pve-9.1.1.txt`](../facts/pve-9.1.1.txt),
harvested by [`scripts/extract-pve-source.sh`](../../scripts/extract-pve-source.sh)

---

## Context

proxmod's design rests on a set of specific facts about Proxmox internals —
`get_index` being a named sub, the shape of `server_config`, `perl -T` on both
daemons, the order of scripts in the index template, PVE's own reload behaviour
on upgrade. Each is recorded in [`pve-facts.md`](../pve-facts.md) with the file
and lines it came from.

Every one of those was read out of **pve-manager 9.1.1**, extracted read-only
from a 9.1-1 ISO. None was checked against 8.x.

## Decision

**PVE 9.x only.** 8.x is explicitly unsupported — not "probably
works", not "untested but likely fine".

This is a statement about what has been *verified*, and it is deliberately not
enforced with a `Breaks:` — see [ADR 0005](0005-no-pve-version-ceiling.md).
proxmod on an 8.x host will probe its seams and degrade like anywhere else.

## Why

Scope discipline, mostly. Supporting a second major version means a second fact
harvest, a second set of probes, a second set of fixtures for the injection
tests, and a second target in the QEMU suite — for a version whose users are on
a supported upgrade path to 9.x anyway.

More importantly: **claiming 8.x without the harvest would be exactly the kind
of unverified assertion this project's documentation convention forbids.** Every
Proxmox-internals claim in these docs cites a fact with a file and line behind
it. "Also works on 8" would have nothing behind it.

## Consequences

- The documentation's status blocks all read `Applies to: … Proxmox VE 9.x`, and
  the fact ledger has one harvest. Both are honest about their scope.
- An 8.x administrator installing proxmod gets the fail-safe path: whatever
  probes succeed, work; whatever do not, are logged and absent. They are not
  blocked, and they are not promised anything.
- Adding 8.x later is mechanical rather than architectural — run
  `make facts ISO=…` against an 8.x ISO, diff the harvest, and add probes where
  the seams differ. Nothing in the design forecloses it.
- The QEMU suite pins one image, which keeps it fast enough to actually run.

## Alternatives considered

**Support 8.x and 9.x from the start** — roughly doubles the verification
surface at the point where the design is least settled. Better done once the
9.x-only version has been exercised on real hosts.

**Say nothing about versions** — leaves the reader to guess what was verified,
which is the thing the whole citation convention exists to prevent.

**`Breaks: pve-manager (<< 9~)`** — would turn an honest scope statement into a
hard block on hosts where proxmod would degrade gracefully anyway. Rejected for
the same reason as an upper ceiling.
