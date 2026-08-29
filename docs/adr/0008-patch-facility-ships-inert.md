# ADR 0008 — A managed patch facility, shipped inert

**Status:** Accepted
**Date:** 2026-08-08
**Applies to:** proxmod 0.4.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** implemented in
[`perl/Proxmod/Patch.pm`](../../perl/Proxmod/Patch.pm); every spec in
[`patches/`](../../patches) has `"enabled": 0`; tested in `t/07-patch.t` with
regression cases named for the `pmxxpuiov` defects

---

## Context

[ADR 0001](0001-runtime-injection-over-file-patching.md) rejects file patching
as the mechanism. It does not make the need go away: sooner or later somebody
hits a seam proxmod cannot reach at runtime, and the only way through is to edit
a Proxmox file.

They will do it either way. The question is what they do it *with*.

## Decision

Ship `Proxmod::Patch` — a managed patch facility with a state database,
checksums, literal anchors, allowlisted roots and a safe revert — and ship it
**inert**: every spec in the package has `"enabled": 0`, so a default install
patches nothing.

Enabling a spec is an explicit, logged, per-spec act that forfeits proxmod's
update-survival guarantees, and the documentation says so before it says
anything else.

## Why

**The alternative to a managed patch is not "no patch". It is a `sed` in a
`postinst`.** That is what `pmxxpuiov` has, and it produced four confirmed
defects: a reapply script targeting a file the installer no longer patched, a
revert that could restore a stale backup over a newer Proxmox file, a leaked
backup, and an APT hook firing at the wrong times. Every one of those is
something a state database and a checksum comparison would have caught.

Giving the escape hatch a *floor* is worth more than pretending it is not
needed.

**Shipping inert keeps the default install's claim intact.** `dpkg -V
pve-manager` is clean on a fresh install and stays clean unless an administrator
deliberately turns something on. The example spec exists as a worked reference,
not as a feature.

**Deliberately unattractive.** The facility is documented last, in a section
that opens with a redirect table pointing at the runtime mechanism that already
solves most reasons people reach for it. That is not coyness — most patches
people want are `Proxmod::Frontend` or `Proxmod::API` calls they had not found.

## What the facility enforces

- **Literal anchors, never regexes.** A regex that matches something unintended
  in a Proxmox file after an upgrade is the failure mode; a literal anchor that
  no longer exists is a clean refusal.
- **Allowlisted roots**, with `/etc/pve` unreachable — `@NEVER` plus `t/07`
  guard it even if `@PATCH_ROOTS` is widened later.
- **Markers**, so two specs can coexist in one file and each can be removed
  independently.
- **Atomic writes**, so an interrupted patch cannot leave a half-written Perl
  module in `pvedaemon`'s path.
- **A checksum comparison before restoring**, so revert cannot put an older
  Proxmox file over a newer one.
- **Revert on `remove`, never on `upgrade`** — reverting on upgrade is precisely
  how the stale-file restore happens.
- **The same permission refusal as the loader**: `Proxmod::Patch` will not patch
  a file that is not root-owned or is group/world-writable, because
  `/usr/share/perl5/PVE/**` is executed as root.
- **Backups enumerated from the state database**, not a hardcoded list, so
  `postrm` cannot leak one.

## Consequences

- An enabled spec means `dpkg -V` is no longer clean, upgrades need reapply, and
  every guarantee in [`compatibility.md`](../compatibility.md) is off for that
  file. The documentation states this as an obligation checklist the operator
  takes on, not as a footnote.
- proxmod carries code that its own primary decision argues against. That is
  the cost of the position, and it is smaller than the cost of everyone
  re-inventing `sed`.
- The `t/07` regression cases are named for the prior art's defects, so the
  reasons are legible from the test names alone.

## Alternatives considered

**Do not ship it at all.** Cleanest position, and it exports the problem: the
next person writes a `postinst` `sed` with no state database, and proxmod's
documentation has nothing to say to them.

**Ship it enabled with a good example.** Destroys the headline claim on a
default install for the sake of a demonstration.

**A separate `proxmod-patch` package.** Considered, and rejected as ceremony —
inert code in the main package is already inert, and a second package implies
the facility is a peer of the runtime mechanism rather than a fallback from it.
