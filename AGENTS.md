# AGENTS.md

Orientation for an agent or a new contributor arriving cold. **This file is a
map, not a rulebook.** Everything here is a pointer to the document that owns
the subject; if you find yourself about to restate a rule, link it instead. Two
copies of a rule is one copy that goes stale, and nobody knows which.

---

## The one thing that outranks everything

> **A missing extension is acceptable. A dead `pvedaemon` or `pveproxy` is not.**

proxmod runs as root inside two daemons that a hypervisor depends on. Every
failure path in this project execs stock Proxmox. If a change you are making has
a failure mode that leaves a daemon down, it is not finished — no matter what it
fixes.

The self-heal that enforces this is `panic_unwrap` in `exec/proxmod-reapply`: a
daemon that does not come back after a proxmod restart gets proxmod's drop-ins
removed and is restarted unmodified. Anything you add that can restart a daemon
has to be reachable by that.

## Where the law lives

| You are about to | Read first |
|---|---|
| Write any code at all | [`docs/conventions.md`](docs/conventions.md) — **project law** |
| Understand how the four layers fit | [`docs/architecture.md`](docs/architecture.md) |
| Claim anything about Proxmox internals | [`docs/pve-facts.md`](docs/pve-facts.md) — cite `[PVE-F-nnn]`, do not restate |
| Argue with a design decision | [`docs/decisions.md`](docs/decisions.md), [`docs/adr/`](docs/adr/) |
| Change what proxmod promises | [`docs/specifications.md`](docs/specifications.md) — `[REQ-*]` |
| Add or change a test | [`docs/testing.md`](docs/testing.md) |
| Touch anything in `debian/` | [`docs/packaging.md`](docs/packaging.md) |
| Touch the patch facility | [`docs/patching.md`](docs/patching.md) |
| Send a change | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| Report a vulnerability | [`SECURITY.md`](SECURITY.md) |

Several rules in `conventions.md` look like style and are not. `use strict` in a
frontend asset breaks ExtJS `callParent` at runtime, in the browser, on the panel
it belongs to. `eval "require $name"` with a name that came from a file is root
code execution inside `pvedaemon`. Read §3 and §4 before writing Perl or
JavaScript here, not after.

## The tree

| Path | What it is |
|---|---|
| `perl/Proxmod/` | The framework. Loaded into the live daemons; every rule about taint mode applies here |
| `exec/` | Runs when things are going wrong: the `ExecStart` wrapper, the convergence script, the patch engine |
| `bin/` | What an administrator runs: `proxmodctl`, `proxmod-verify` |
| `www/` | Frontend assets, and the loader template that is rendered per request |
| `conf/`, `patches/`, `systemd/` | What the package ships into `/etc` and `/usr/share` |
| `t/` | Unit tests. PVE stubs in `t/lib/`, real vendored fixtures in `t/fixtures/` |
| `test/integration/` | The QEMU suite, against a real Proxmox VE |
| `man/` | Hand-written roff. `docs/cli.md` is the long form of the same material |
| `docs/third_party/` | Vendored upstream Proxmox source. **Read-only.** Nothing builds, lints, installs or packages from here |

## What to run

```sh
make lint          # perl -T -c, shellcheck, node --check, plus one ExtJS rule
make test          # prove -r t/ — no Proxmox host needed
make deb           # build the package
```

**A skip is not a pass.** `lint-shell` and half of `lint-js` print "skipping"
and exit 0 when `shellcheck` or `node` are absent. If you are reporting a green
lint, confirm both tools are installed first.

`make e2e` boots a real Proxmox VE under QEMU and is the only thing that proves
the upgrade-survival claims. It is not on the push path; see
[`docs/testing.md`](docs/testing.md) §6 for why.

## Hazards specific to this project

**Taint mode.** Both daemons run under `perl -T` [PVE-F-002]. `PERL5LIB` is
ignored, `require` of a tainted string dies, `glob()` and `readdir` return
tainted strings, and `:encoding()` cannot open a tainted path. A change that
works in a plain `perl` and dies under `-T` will do so inside `pvedaemon`, at
startup, on somebody's host. `make lint` runs `perl -T -c`; that catches
compile-time problems, not runtime ones.

**`/etc/pve` is never touched** from a maintainer script, the convergence
routine or the boot unit. It is FUSE pmxcfs: unmounted during parts of an
upgrade, read-only without quorum, absent early in boot, and a hung mount can
block dpkg indefinitely — which is exactly when those three run. `t/09` asserts
the string does not appear in any of them.

**Seam drift is the standing risk.** proxmod attaches at seams Proxmox does not
document as stable. When a point release moves one, the symptom is a feature
that quietly stops working, not an error. The early-warning mechanism is the
fact harvest:

```sh
make facts ISO=/path/to/proxmox-ve_9.x-1.iso
git diff docs/facts/
```

A `!!` line in the harvest means the script could not find what it expected:
that seam moved, and every sentence citing the affected `[PVE-F-nnn]` needs
re-reading.

**Registered is not reachable.** An API method can install without complaint and
still be unreachable, because something upstream claimed a greedy path
[PVE-F-051]. Nothing logs that. `proxmod-verify` replays the registered routes
and resolves each one; that check is the reason it exists.

**Version numbers fan out.** A release touches `perl/Proxmod.pm`, every
`perl/Proxmod/*.pm`, `Proxmod.version` in `www/proxmod-ui.js`, the `Applies to:`
line of every document, the man pages and `debian/changelog`. Miss one and
nothing fails — it just lies.

## Working on a real host

Nothing in this repository needs a Proxmox host, and most changes should be
proven without one. When you do have one:

```sh
proxmodctl status          # the first question
proxmodctl doctor          # everything, for a bug report
proxmodctl logs            # what proxmod said, without the rest of the journal
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl   # must be silent
```

`dpkg -V` silent after install *and* after purge is the headline claim. If it
prints anything, proxmod modified a Proxmox-owned file, and that is a defect
regardless of what else works.

Stage a rollout: one non-critical node, restart both daemons, confirm the web
interface loads and an extension's tab appears, and only then the rest of the
cluster. `proxmodctl disable` is the way out, and it works even when proxmod
itself is broken — the `ExecStart` wrapper checks for `/etc/proxmod/disabled`
before it loads any proxmod code at all.

## Habits this project expects

- **Name a regression test after the defect it prevents.** `t/07`'s cases are
  called *stale-backup-restored-over-newer-file* and *revert-on-upgrade*.
- **Prove the test fails without the fix.** Stash the change, run the test,
  watch it fail. A regression test that passes against broken code documents
  nothing.
- **Cite, do not restate.** `[PVE-F-nnn]` for Proxmox internals, `[REQ-*]` or
  proxmod source for proxmod's own design.
- **Say what it costs.** A design note that reads as unbroken good news is
  unfinished.
- **Probe before you wrap.** `can()` before a glob wrap,
  `Ext.ClassManager.get()` before an ExtJS override.
- **Update the document in the same change.** If you changed a message, an exit
  status, a path or a manifest field, `docs/` is not a follow-up.
