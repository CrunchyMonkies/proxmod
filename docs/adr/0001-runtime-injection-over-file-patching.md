# ADR 0001 — Runtime injection over file patching

**Status:** Accepted
**Date:** 2026-08-08
**Applies to:** proxmod 0.4.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the defect analysis cites `~/dev/pmxxpuiov` by file and
line; the injection mechanism is verified by `[PVE-F-020]`–`[PVE-F-026]` and
implemented in [`perl/Proxmod/Frontend.pm`](../../perl/Proxmod/Frontend.pm)

---

## Context

Proxmox VE offers no extension point for adding a REST endpoint or a tab to the
web interface. Storage plugins, auth plugins and hookscripts are official, but
none of them cover this. Anything that adds a tab is using a seam Proxmox did
not publish.

Two prior in-house projects solved it in opposite ways.

**`pmxxpuiov` (pve-gpu-manager)** patches Proxmox's own files: `sed` into
`/usr/share/pve-manager/index.html.tpl` for a `<script>` tag, `awk` into
`/usr/share/perl5/PVE/API2/Hardware.pm` for the route, and an
`/etc/apt/apt.conf.d/` `DPkg::Post-Invoke` hook to reapply after upgrades.

**`pve-token-copy`** (in `proxmox-csi-plugin/hack/`) mutates zero Proxmox files:
a trivial Perl module in `/usr/share/perl5/`, a systemd `ExecStart` drop-in
adding `-MPVECSICopy`, and `ExecReload` rewritten to a full restart.

Both are single-purpose, neither is documented, and the mechanism question was
never settled. proxmod has to pick one.

## Decision

**Runtime injection.** proxmod adds `-MProxmod` to both daemons' `ExecStart` via
a systemd drop-in and does everything else from inside the running process. It
ships **no** modification to any Proxmox-owned file.

A managed patch facility exists as a documented escape hatch and ships inert —
see [ADR 0008](0008-patch-facility-ships-inert.md).

## Why

### File patching failed in practice, at four confirmed points

Not hypothetically. In the code we have:

1. **The reapply script patches the wrong file.**
   `~/dev/pmxxpuiov/src/scripts/reapply-patches.sh` still targets `Nodes.pm`
   while `debian/postinst` patches `Hardware.pm`. The route is patched at
   install and **never reapplied after a PVE upgrade**. The frontend tab
   survives, so the interface looks healthy while the API behind it is gone.
   Two edit sites drifted from each other, which is what two edit sites do.

2. **A stale backup can be restored over a newer Proxmox file.**
   `backup_if_needed` keeps a `.pre-gpu` copy and the revert path restores it
   unconditionally. If Proxmox shipped a newer `Hardware.pm` in between, the
   revert silently installs the old one — a downgrade of a hypervisor's API
   module, with no checksum comparison anywhere.

3. **`postrm` leaks the backup forever.** `Hardware.pm.pre-gpu` is never
   removed, because the removal list was written by hand and the patch target
   changed after it.

4. **The APT hook fires at the wrong times.** `DPkg::Post-Invoke` runs on every
   `apt` invocation — installing `htop` restarts `pveproxy` — and never on
   `dpkg -i`.

A fifth, found while writing this up: `~/dev/pmxxpuiov/debian/postrm:15-17` does
`rm -f /etc/pve/local/gpu-sriov.conf`. That is a write to pmxcfs from a
maintainer script, on a FUSE filesystem that is routinely unmounted mid-upgrade.

None of these are sloppiness — the package is otherwise careful. They are what
happens when correctness depends on keeping N patch sites, a reapply script, a
backup policy and a removal list in agreement across releases nobody has seen
yet. **The bug class is structural, and it does not go away with more care.**

### The mechanism is available and verified

The frontend was the open question — patching `index.html.tpl` looked
unavoidable. It is not:

- `pages => { '/' => sub { get_index(...) } }` calls a **named sub**
  [PVE-F-020], so the glob can be replaced from inside the process.
- The handler returns an `HTTP::Response` whose `content` can be mutated, and
  `Content-Length` is recomputed downstream [PVE-F-026].
- `server_config` holds a `{dirs}` table [PVE-F-024], so a static route can be
  added with a literal assignment.

Backend registration was never in doubt — `register_method` is a normal function
call.

### The properties that follow are the whole argument

| | Patching | Runtime injection |
|---|---|---|
| After a PVE upgrade | reapply, or it is broken | **nothing to reapply** |
| `dpkg -V pve-manager` | reports every patched file | **silent, forever** |
| Two extensions on one file | race, last writer wins | independent |
| Removal | restore a backup and hope | delete a drop-in |
| Partial failure | a half-patched Perl module | one `eval` logs and moves on |
| A moved seam | a broken `sed`, unnoticed | a probe fails, a feature is missing |

The second row is the headline, and it is testable: the QEMU suite asserts
`dpkg -V pve-manager libpve-common-perl libpve-http-server-perl` is clean after
install, after an upgrade, and after purge.

## Consequences

**Accepted costs.**

- **The seams are unpublished.** They can move in any release, and proxmod has
  no promise from Proxmox. Mitigated by probing every seam at runtime, degrading
  per feature, and keeping a fact ledger that can be re-harvested from an ISO
  without a running host.
- **`ExecStart=` is a single slot.** Only one drop-in can set it; two frameworks
  wrapping the same daemon conflict. `proxmod-verify` detects this and cannot
  resolve it. Mitigated by proxmod being able to load a *list* of modules — the
  way out is for the other wrapper to become an extension.
- **`ExecReload` must be overridden**, because PVE's graceful reload `exec()`s
  the original argv and would drop `-MProxmod` silently. This is load-bearing
  and unit-tested.
- **`pvesh` does not see proxmod endpoints**, because it builds its own tree in
  a process that did not go through the wrapper.
- **A restart is needed for a backend change.** Patching had the same cost.
  Frontend-only extensions need none — `loader.js` is generated per request.

**Gained.**

- Update survival becomes convergence on files proxmod owns, not repair of files
  Proxmox owns.
- Failure isolation becomes possible at all: an `eval` around a `require` has no
  equivalent in a `sed` pipeline.
- The strongest claim proxmod makes — *Proxmox's files are byte-identical* — is
  mechanically checkable by a tool the administrator already trusts.

## Alternatives considered

**Patch, but manage it properly** — a state database, checksums, markers,
allowlisted roots. This is genuinely better than `sed`, and it is exactly what
`Proxmod::Patch` implements. It still leaves `dpkg -V` dirty and still needs a
reapply on every upgrade. Kept as an escape hatch, not as the mechanism.

**A `PERL5OPT` environment variable** — would avoid touching systemd at all.
Impossible: both daemons run under `perl -T`, and **taint mode ignores
`PERL5LIB` and `PERL5OPT`** [PVE-F-002]. This is not a preference; there is no
environment variable that does this.

**A separate service behind a reverse proxy** — clean, and it forfeits
everything that made the request worth making: no tab in the Proxmox interface,
no PVE ticket authentication, no ACL integration, a second port to secure.
Correct for a large standalone application; wrong for a tab and an endpoint.

**Asking Proxmox for an extension point** — the right long-term answer and not
available on the timescale of this work. If one appears, proxmod's job becomes
smaller, which would be a good outcome.

---

## Reference

- [`patching.md`](../patching.md) §2 — the post-mortem in full
- [`architecture.md`](../architecture.md) — what was built on this decision
- [`pve-facts.md`](../pve-facts.md) — `[PVE-F-002]`, `[PVE-F-020]`–`[PVE-F-026]`
- [ADR 0002](0002-systemd-drop-in-execstart-wrapper.md) — how the module is injected
- [ADR 0008](0008-patch-facility-ships-inert.md) — why the escape hatch exists anyway
