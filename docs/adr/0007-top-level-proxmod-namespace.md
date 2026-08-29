# ADR 0007 — A top-level `Proxmod` namespace, not `PVE::`

**Status:** Accepted
**Date:** 2026-08-08
**Applies to:** proxmod 0.4.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the file manifest is the `install` target in the
top-level [`Makefile`](../../Makefile), reproduced in
[`install.md`](../install.md) §3; QEMU test 2 asserts no dpkg-owned file under
`/usr/share/pve-manager` or `/usr/share/perl5/PVE` changes

---

## Context

A Perl module extending PVE could plausibly live at `PVE::Proxmod` or
`PVE::API2::Proxmod`. Frontend assets could go in `/usr/share/pve-manager/js/`.
`pmxxpuiov` did something close to this, registering its route directly inside
`PVE::API2::Hardware`.

## Decision

Everything proxmod owns lives under a name proxmod owns.

| | |
|---|---|
| Perl | `Proxmod::*` — top-level |
| Files | `/usr/share/proxmod`, `/etc/proxmod`, `/var/lib/proxmod`, `/usr/lib/proxmod` |
| API | `/nodes/{node}/proxmod/<id>`, `/cluster/proxmod/<id>` |
| URLs | `/proxmod/` |
| JS | the `Proxmod` global |
| CSS | `proxmod-<ext>-` |
| itemIds | `proxmod-<ext>[-<id>]` |

**proxmod never ships a file into a Proxmox-owned directory.** An extension gets
exactly one namespace — its `id` — and may only write inside it, across all six
axes.

## Why

**`PVE::` is Proxmox's.** A future Proxmox release adding `PVE::Proxmod`, or a
directory listing that assumes everything under `PVE/` is theirs, is their right
and not something to argue with after the fact.

**Shipping into a Proxmox-owned directory is a file conflict waiting to
happen** — and it makes the headline claim untestable. `dpkg -V pve-manager`
being clean is only meaningful if proxmod also put nothing new in Proxmox's
directories.

**Mounting under an existing PVE API subtree is fragile in a specific way.**
`pmxxpuiov` registered into `PVE::API2::Hardware`, so its route lived or died
with a class Proxmox owns and moves — it had already moved once, from `Nodes.pm`
to `Hardware.pm`, which is what desynchronised the reapply script. A dedicated
`proxmod` mount point moves only when proxmod moves it.

**A reserved prefix makes collisions between extensions decidable.** Two
extensions cannot both claim `proxmod-gpu-` because ids are unique in the
registry, which turns "did these two authors coordinate?" into a check the
registry already performs.

## Consequences

- proxmod endpoints appear at `/nodes/{node}/proxmod/…` rather than alongside
  the PVE endpoint they conceptually extend. That is slightly less discoverable
  and considerably more honest — it is visible in the API tree that this is not
  Proxmox's.
- `Proxmod::*` occupies a top-level CPAN-visible namespace. Acceptable for a
  distro-scoped package that is not going to CPAN.
- Extension authors must namespace six different kinds of identifier. The API
  and the documentation do most of it — `mount` derives the path, `addStyle`
  documents the CSS prefix, `addNodeTab` derives the `itemId` — but a hand-
  written `Ext.define` can still get it wrong. `proxmod-verify` does not check
  it; the conventions document does.

## Alternatives considered

**`PVE::Proxmod`** — reads as endorsed, is not, and risks a real collision.

**`/usr/share/pve-manager/js/proxmod/`** for assets — would put proxmod inside
the directory whose integrity is its headline claim, and would be deleted by a
sufficiently thorough `pve-manager` upgrade.

**No reserved prefixes, coordinate by convention** — works until two extensions
from different authors both define `.gpu-panel-header`, at which point one of
them silently restyles the other.
