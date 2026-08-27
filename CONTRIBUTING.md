# Contributing to proxmod

proxmod runs inside `pvedaemon` and `pveproxy` on somebody's hypervisor. The
prime directive follows from that and outranks everything else here:

> **A missing extension is acceptable. A dead `pvedaemon` or `pveproxy` is not.**

Every failure path in this project execs stock Proxmox. If a change you are
making has a failure mode that leaves a daemon down, it is not finished.

---

## Before you start

Read, in this order:

1. [`docs/getting-started.md`](docs/getting-started.md) — what proxmod is and
   how to run it.
2. [`docs/conventions.md`](docs/conventions.md) — **project law.** Namespaces,
   the taint-mode rules, the JavaScript rules, what the tests enforce. Several
   of these look like style and are not: `use strict` in an asset breaks ExtJS,
   `eval "require $name"` with a name from a file is root code execution.
3. [`docs/architecture.md`](docs/architecture.md) — how the four layers fit.

If you are writing an *extension* rather than changing proxmod itself, you want
[`docs/backend-extensions.md`](docs/backend-extensions.md),
[`docs/frontend-extensions.md`](docs/frontend-extensions.md) and
[`examples/proxmod-example-hello/`](examples/proxmod-example-hello/) instead.
You do not need to touch this repository at all.

## Running the tests

No Proxmox host is required. The PVE stubs live in `t/lib/`.

```sh
make lint          # perl -T -c, shellcheck, node --check, plus one ExtJS rule
make test          # prove -r t/
make deb           # build the package
```

Both `make lint` and `make test` must be green, and green for the right reason:
`lint-shell` and `lint-js` skip when `shellcheck` or `node` are missing, so
install both rather than reading a skip as a pass.

The QEMU integration suite (`make e2e`) boots a real Proxmox VE and is the only
thing that proves the upgrade-survival claims. It needs an image and takes a
while; CI runs it on demand rather than per push. See
[`docs/testing.md`](docs/testing.md).

## What a change looks like here

**Cite, do not restate.** Any claim about Proxmox internals cites a
`[PVE-F-nnn]` entry in [`docs/pve-facts.md`](docs/pve-facts.md), which names the
file and lines it was read from. Claims about proxmod's own design cite proxmod
source or a `[REQ-*]` in [`docs/specifications.md`](docs/specifications.md).
Adding a fact is a four-step process; §8 of `conventions.md` has it.

**Name a regression test after the defect it prevents.** `t/07`'s cases are
called *stale-backup-restored-over-newer-file* and *revert-on-upgrade* so that
the reason survives without a comment. A test named `test_apply_3` has already
lost the argument it was written to win.

**Prove the test fails without the fix.** Stash the source change, run the test,
watch it fail. A regression test that passes against the broken code documents
nothing.

**Say what it costs.** Design notes state the trade they made; ADRs have
consequences that are not benefits. A section that reads as unbroken good news
is unfinished.

**Probe before you wrap.** `can()` before a glob wrap,
`Ext.ClassManager.get()` before an ExtJS override. A seam that moved should
produce a missing feature and a log line, never a stuck interface.

## Commits

Conventional Commits: `type(scope): summary`, present tense, imperative, one
concern per commit. See §7 of [`docs/conventions.md`](docs/conventions.md) for
the types and scopes in use, and for what a release commit has to say.

Reference `[REQ-*]` or `[PVE-F-nnn]` in the body where a change is driven by
one.

## Pull requests

- One concern. A PR that fixes a defect *and* tidies the file around it costs
  the reviewer the ability to see either.
- Include the failing-then-passing test in the same PR as the fix.
- If you changed anything an administrator sees — a message, an exit status, a
  path, a manifest field — update the document that describes it in the same
  PR. `docs/` is not a follow-up.
- `make lint && make test` green, and `dpkg -V pve-manager` silent after
  installing your build on a test host, if you have one.

## Reporting a vulnerability

Not here — see [`SECURITY.md`](SECURITY.md).

## Licence

By contributing you agree that your contribution is licensed under
AGPL-3.0-or-later, matching the rest of the project. See [`LICENSE`](LICENSE).
