# Decision log

**Status:** Draft
**Applies to:** proxmod 0.1.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** each ADR names the source file that implements it and
the test that covers it

The architecture decisions behind proxmod, each with its alternatives and its
costs. If something in the codebase looks over-cautious or roundabout, the
reason is here.

---

## The record

| # | Decision | Status |
|---|---|---|
| [0001](adr/0001-runtime-injection-over-file-patching.md) | Runtime injection over file patching | Accepted |
| [0002](adr/0002-systemd-drop-in-execstart-wrapper.md) | A systemd drop-in and an `ExecStart` wrapper | Accepted |
| [0003](adr/0003-dpkg-triggers-over-apt-hooks.md) | dpkg triggers, not an APT hook | Accepted |
| [0004](adr/0004-one-frontend-injection-point.md) | One frontend injection point feeding a generated loader | Accepted |
| [0005](adr/0005-no-pve-version-ceiling.md) | No version ceiling on `pve-manager` | Accepted |
| [0006](adr/0006-permissions-are-mandatory.md) | `permissions` is a mandatory argument to `add_method` | Accepted |
| [0007](adr/0007-top-level-proxmod-namespace.md) | A top-level `Proxmod` namespace, not `PVE::` | Accepted |
| [0008](adr/0008-patch-facility-ships-inert.md) | A managed patch facility, shipped inert | Accepted |
| [0009](adr/0009-verify-the-running-daemon.md) | Verify the running daemon, not a fresh process | Accepted |
| [0010](adr/0010-pve-9-only.md) | Target Proxmox VE 9.x only | Accepted |

---

## The through-line

One directive generates most of the rest:

> **A missing extension is acceptable. A dead `pvedaemon` or `pveproxy` is
> not.**

It explains why the wrapper execs the daemon unmodified on any anomaly (0002),
why there is no version ceiling and every seam is probed instead (0005), why the
frontend loader returns an inert 200 rather than a 500 (0004), and why every
stage and every extension runs inside its own `eval`.

It also creates the one problem the rest of the design has to answer: **if
proxmod fails quietly, nothing tells you it failed.** That is what 0009 is for,
and it is why the monitoring obligation is stated as an obligation rather than a
suggestion.

The second through-line is narrower and just as load-bearing: **the prior art's
defects were structural, not careless.** `pmxxpuiov` is a carefully written
package that still ended up patching the wrong file on upgrade, because
correctness depended on keeping several edit sites, a reapply script, a backup
policy and a removal list in agreement across releases nobody had seen yet.
0001, 0003 and 0008 are all responses to that specific observation.

## Decisions taken with the requester

Four were settled directly rather than derived, and are recorded here so they
are not mistaken for engineering conclusions:

- **Ship documentation *and* a working framework `.deb`**, not one or the other.
- **Runtime injection is primary; a managed patch facility is a documented
  fallback only.** → 0001, 0008.
- **The frontend gets exactly one injection point**, feeding a loader and a
  drop-in directory. → 0004.
- **Target PVE 9.x.** → 0010.

## Smaller decisions, recorded where they live

Not everything warrants an ADR. These are documented at the point of use:

| Decision | Where |
|---|---|
| Drop-ins installed by `postinst`, not shipped as conffiles | [`packaging.md`](packaging.md) §4 |
| `override_dh_fixperms` restoring 0755 on `/usr/lib/proxmod/*` | [`packaging.md`](packaging.md) §3 |
| Revert patches on `remove` only, never on `upgrade` | [`packaging.md`](packaging.md) §4, ADR 0008 |
| `rmdir` and a state-database enumeration in `postrm`, never `rm -rf` | [`packaging.md`](packaging.md) §4 |
| Never write to `/etc/pve` from a maintainer script or at boot | [`packaging.md`](packaging.md) §7, [`security.md`](security.md) §8 |
| `INIT { }` rather than compile-time in `Proxmod.pm` | [`architecture.md`](architecture.md) §3 |
| A literal `{dirs}` assignment rather than `add_dirs()` | [`architecture.md`](architecture.md) §3, [`security.md`](security.md) §5 |
| `loader-runtime.js` installed outside `www/` so it is not served | [`security.md`](security.md) §5 |
| One ExtJS override chain per target class | [`js-api.md`](js-api.md) §4 |
| `Ext.ClassManager.get()` probing before defining an override | [`frontend-extensions.md`](frontend-extensions.md) §4 |
| Extension load order: `requires` topologically sorted, then `order`, then filename | [`extension-manifest.md`](extension-manifest.md) |
| Masking a packaged extension by basename from `/etc` | [`extension-manifest.md`](extension-manifest.md) |
| `--live-only` deliberately narrow | [`verification.md`](verification.md) §4 |
| Trigger paths always exit 0 | ADR 0003 |

## Writing a new ADR

Number sequentially, file as `docs/adr/NNNN-kebab-title.md`, add a row to the
table above.

Keep the shape: the standard four-line status block, then **Context** (what
forced a decision), **Decision** (what was chosen, stated flatly), **Why**,
**Consequences** — *including the costs accepted* — and **Alternatives
considered**, each with the reason it lost.

Two conventions this project holds to:

- **Every Proxmox-internals claim cites a `[PVE-F-nnn]` entry** in
  [`pve-facts.md`](pve-facts.md). If the fact is not in the ledger, harvest it
  before citing it.
- **State the costs.** An ADR whose Consequences section contains only benefits
  has not finished thinking. Every decision here gave something up, and the next
  person to revisit one needs to know what.

A decision that is later reversed keeps its file and gets `Status: Superseded by
ADR NNNN`. Do not delete the reasoning — the reversal is only legible next to
what it replaced.

---

## Reference

- [`architecture.md`](architecture.md) — what these decisions built
- [`specifications.md`](specifications.md) — the normative requirements
- [`patching.md`](patching.md) §2 — the prior-art post-mortem cited throughout
- [`pve-facts.md`](pve-facts.md) — the fact ledger
