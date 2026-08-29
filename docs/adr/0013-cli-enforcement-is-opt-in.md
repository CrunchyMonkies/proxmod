# ADR 0013 — Enforcement on the command line is opt-in, and patched

**Status:** Accepted
**Date:** 2026-08-29
**Applies to:** proxmod 0.4.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.2.6 (biglarry, live)
**Verification method:** the bypass was reproduced on a live host and is recorded
as `[PVE-F-055]`; the specs are in
[`patches/`](../../patches) with `"enabled": 0`, covered by `t/07-patch.t`

---

## Context

`proxmod-pool-quota` wraps `PVE::API2::Qemu::create_vm` and nine other seams, and
on a live host every one of them was confirmed installed. A create issued through
the REST API against an over-quota pool was refused. The same create, same node,
same limit, same second, issued as `qm create`, **succeeded**.

`qm`, `pct` and `pvesh` are not clients of `pvedaemon`. Each is an eight-line
stub that loads `PVE::CLI::qm` (or `::pct`, `::pvesh`) and dispatches in its own
process, to the same `PVE::API2` classes the daemons use. The seam is right there;
what is missing is proxmod. [ADR 0002](0002-systemd-drop-in-execstart-wrapper.md)
gets proxmod into the daemons through a systemd `ExecStart` drop-in, and a command
somebody types has no `ExecStart`.

`Proxmod::Boot` compounded it deliberately: it refused to run anywhere that was
not a known daemon, naming `pvesh` in the comment as a context nobody had tested.

## Decision

proxmod will run inside `qm`, `pct` and `pvesh` when an extension asks for it by
name in `backend.daemons` **and** an operator has enabled the patch spec that
loads it there. Three specs ship in `patches/`, all `"enabled": 0`, inserting
`use Proxmod;` into the three `PVE::CLI` modules.

A default install patches nothing and behaves exactly as before.

## Why this and not something else

**There is no runtime way in.** Every mechanism proxmod prefers needs something
already loaded in the target process, and nothing is. The only door is the file
the CLI loads.

**`PERL5OPT` cannot do it, and the reason is worth recording.** `qm` and `pvesh`
are `#!/usr/bin/perl`, but `pct` is `#!/usr/bin/perl -T`, and taint mode ignores
`PERL5OPT` `[PVE-F-002]`. It would enforce on VMs, silently not on containers —
the worst possible shape for a control — and it is a global environment variable
affecting every Perl process on the host.

**The binaries are out of reach, and should stay so.** `/usr/sbin/qm` is not under
`Proxmod::Patch`'s `@PATCH_ROOTS`, and adding `/usr/sbin` and `/usr/bin` to that
allowlist to reach it would be a far worse trade than the patch. The
`PVE::CLI::*` modules are already under `/usr/share/perl5/PVE`, so no allowlist
changes.

**This is what [ADR 0008](0008-patch-facility-ships-inert.md) built the facility
for**: *"sooner or later somebody hits a seam proxmod cannot reach at runtime, and
the only way through is to edit a Proxmox file."* This is that case. The
difference from the example spec is that the example is deliberately a bad idea —
proxmod already does that job at runtime — and this one has no runtime
alternative at all.

## Why opt-in rather than on

**It forfeits the headline claim.** `dpkg -V qemu-server pve-container
pve-manager` stops being silent. That claim is the strongest thing proxmod says
about itself and is not something to spend on every user's behalf.

**The blast radius is the primary tool for managing guests.** Once enabled, every
`qm` invocation loads proxmod and every extension that named `qm`. A broken
proxmod is then a broken `qm`. Three existing mitigations carry it — `Proxmod.pm`'s
`INIT` is eval-guarded and never dies, each extension loads in its own `eval`, and
`/etc/proxmod/disabled` turns everything off without removing a package — but the
risk is real and belongs to whoever accepts it.

**Most people do not need it.** A quota is a boundary for *delegated* callers: the
web interface, API clients, automation with a scoped token. Anyone who can run
`qm create` can also edit `/etc/pve/qemu-server/100.conf` directly, or remove the
package. Closing the CLI door while those stand open is worth doing for an
operator who wants a guardrail against their own mistakes, and is not worth
forcing on one who wanted a boundary against other people.

**Extensions must ask, too.** A CLI name in `backend.daemons` is required, and the
default when the key is absent stays daemons-only. An extension written before
this existed must not begin running inside a command somebody types, least of all
one that then wraps a method and can refuse it.

## Consequences

- proxmod runs somewhere it previously refused to, so `Proxmod::Registry` grows a
  notion of a known **CLI** distinct from a known daemon. The distinction is
  consulted at three sites and each needs it: a CLI has a real terminal, so its
  log output goes there and not to syslog; it renders no pages, so the frontend
  stage is skipped; it is transient, so nothing durable is recorded from it.
- `Proxmod::API::scope_available` had to exist. `qm` and `pct` do not load
  `PVE::API2::Cluster`, so a cluster-scoped `mount` dies there — and since an
  extension registers routes and installs wraps in one call, that would take the
  wraps with it, which are the whole reason for being in a CLI.
- **`pvesh` gains proxmod's endpoints only halfway, and the half it does not
  gain is a fact about `pvesh`, not a bug here.** Verified: `pvesh ls
  /cluster/proxmod/pool-quota` lists all four endpoints, and `pvesh get` on one
  of them still says *"No 'get' handler defined"*. `PVE::CLI::pvesh` extracts the
  schema for the requested path at **module top level** (`pvesh.pm:276`), which
  runs while the program is still compiling — before `Proxmod.pm`'s `INIT` block
  has mounted anything. `ls` resolves at runtime and sees the tree; `get`,
  `create`, `set` and `delete` resolve at compile time and do not.

  Enforcement is unaffected and was verified working: `pvesh create
  /nodes/<node>/qemu -pool <over-quota>` is refused with a 403, because the
  wraps are installed by `INIT` and the command runs after it. Reaching the
  other half would mean the `pvesh` spec forcing `Proxmod::Boot::boot` at
  compile time rather than going through `Proxmod.pm`, making it structurally
  different from the other two specs — not worth it for a listing that `ls`
  already gives.
- Every `PVE` upgrade rewrites the patched module and drops the patch;
  `proxmod-reapply` puts it back. That is the cost ADR 0001 named, now genuinely
  being paid by anyone who enables this.
- **Every invocation of a patched CLI prints proxmod's boot warnings to stderr.**
  In a daemon these are one-time lines in the journal; in a CLI they are per
  command. `stdout` stays clean — verified, `pvesh get /version --output-format
  json` is unpolluted JSON — so scripts parsing output are unaffected, but an
  operator sees them every time. Measured cost of the load itself is about
  **20 ms per invocation, roughly 2%**, which is not the thing to worry about.

## Alternatives considered

**Ship it enabled.** Rejected: it spends the `dpkg -V` claim for everybody to
serve the minority who want CLI enforcement, and it puts proxmod in the path of
`qm` on hosts whose owners never asked.

**A wrapper in `/usr/local/sbin`,** which precedes `/usr/sbin` in root's `PATH`
and would leave every Proxmox file untouched. Rejected twice over: `/usr/local` is
the local administrator's, and Debian policy forbids a package installing there;
and it would be bypassed by any absolute-path invocation, which is what scripts
tend to use — a control that works only when invoked casually.

**Do nothing and document it,** which is where this stood before. Defensible, and
what the package shipped: `REQ-ENF-017` and `[PVE-F-055]` state the bound
precisely. Rejected because "we know how to close this and chose not to" is a
worse answer than an off-by-default switch, once the switch costs nothing to
someone who leaves it off.

---

## Reference

- [ADR 0001](0001-runtime-injection-over-file-patching.md) — why patching is the last resort
- [ADR 0008](0008-patch-facility-ships-inert.md) — the facility this uses, and why it ships inert
- [`patching.md`](../patching.md) — enabling a spec, and what you take on
- [`extension-manifest.md`](../extension-manifest.md) — naming a CLI in `backend.daemons`
