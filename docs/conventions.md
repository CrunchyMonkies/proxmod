# Conventions

**Status:** Draft
**Applies to:** proxmod 0.2.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the namespace rules are enforced by
[`perl/Proxmod/Registry.pm`](../perl/Proxmod/Registry.pm) and
[`perl/Proxmod/API.pm`](../perl/Proxmod/API.pm); the code prohibitions are
enforced by `t/00-compile.t` and `t/09-reapply.t`

How this project writes code and documentation. Some of these are enforced by
tests; those are marked. The rest are conventions, and the reason each exists is
stated so it can be argued with.

---

## 1. Documentation

**Every document opens with the same four-line status block.**

```markdown
**Status:** Draft | Stable
**Applies to:** proxmod <version>, Proxmox VE <series>
**Last verified against:** pve-manager <version> (<date>)
**Verification method:** <how a reader could check this themselves>
```

The fourth line is the one that matters. It names the file, the test or the
command that backs the document, so a reader can check rather than trust.

**Every claim about Proxmox internals cites a `[PVE-F-nnn]` entry** in
[`pve-facts.md`](pve-facts.md). Each entry names the file and lines it was read
from, and is regenerable offline:

```sh
make facts ISO=/path/to/proxmox-ve_9.1-1.iso
git diff docs/facts/
```

Do not restate a Proxmox internal inline — cite it. The point is that when a
release moves a seam, the harvest diff tells you exactly which sentences need
re-reading. A claim without a citation cannot be maintained.

Cite only for facts about **Proxmox**. Statements about proxmod's own design
cite proxmod's source or a `[REQ-*]` in [`specifications.md`](specifications.md).

**No document leaves Draft while it contains an `UNVERIFIED` marker.** Mark what
you have not checked rather than writing around it.

**Say what it costs.** Every design note states the trade it made, and every ADR
has consequences that are not benefits. A section that reads as unbroken good
news is unfinished.

**Symptom first in operator documents.** An administrator arrives with "the tab
is gone", not with "the `get_index` wrap failed". Index on what they see.

## 2. Namespaces

proxmod never ships a file into a Proxmox-owned directory
([ADR 0007](adr/0007-top-level-proxmod-namespace.md)).

| Axis | proxmod owns | an extension owns |
|---|---|---|
| Perl | `Proxmod::*` | a namespace you own — *not* `PVE::`, *not* `Proxmod::` |
| Files | `/usr/share/proxmod`, `/etc/proxmod`, `/var/lib/proxmod`, `/usr/lib/proxmod` | `www/<id>*.js`, `extensions.d/NN-<id>.conf` |
| API | `/nodes/{node}/proxmod`, `/cluster/proxmod` | `…/proxmod/<id>/…` |
| URL | `/proxmod/` | `/proxmod/<id>*.js` |
| JS | the `Proxmod` global | one global, or none |
| CSS | `proxmod-` | `proxmod-<id>-` |
| itemId / xtype | `proxmod-` | `proxmod-<id>[-…]` |

**An extension may only write inside its own id, on every one of those axes.**
`addNodeTab` derives the `itemId` from `ext` for exactly this reason — setting
one by hand is how two extensions collide.

The example package's Perl namespace is `ProxmodExample::`, not
`Proxmod::Example::`. `Proxmod::` is the framework's.

## 3. Perl

**Both daemons run under `perl -T`** [PVE-F-002]. Everything below follows.

**Untaint by matching a strict pattern and rebuilding from the capture.** Never
`=~ /(.*)/s`, which launders without checking.

```perl
$module =~ /\A([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*)\z/ or return;
$module = $1;                       # rebuilt, and actually validated
```

**Nothing from disk reaches the compiler.** A validated module name is converted
to a relative path and *that* is `require`d. `eval "require $name"` with a name
from a file is root RCE, and `t/00-compile.t` **fails the build** if `eval "…"`
appears in daemon-resident code.

**`add_dirs` is banned** — it walks with `File::Find` and returns tainted
strings [PVE-F-025]. Assign a literal into `$cfg->{dirs}`. Enforced by
`t/00-compile.t`.

**`:encoding(…)` is banned** in daemon-resident code — it cannot open a tainted
path. Enforced by `t/00-compile.t`.

**`/etc/pve` is never touched** from a maintainer script, the converge routine
or the boot unit. It is FUSE pmxcfs: unmounted during parts of an upgrade,
read-only without quorum, absent early in boot, and a hung mount can block dpkg
indefinitely. Enforced by `t/09-reapply.t`, and by `Proxmod::Patch::@NEVER` with
`t/07`.

**Every stage runs in its own `eval` with `local $SIG{__DIE__} = 'DEFAULT'`.**
The `local` matters: an extension that installs a die handler must not be able
to escape through it.

**Shell out with a list.** `run_command(['prog', $arg])`, never
`system("prog $arg")`.

**Probe before you wrap.** `can()` before a glob wrap, `Ext.ClassManager.get()`
before an ExtJS override. A seam that moved should produce a missing feature and
a log line, never a stuck interface.

## 4. JavaScript

One concatenated bundle, one global scope, no module system, ES3-era syntax.

**Wrap each asset in an IIFE.** One accidental global is one collision.

**No `'use strict'`.** ExtJS resolves `callParent` by reading `Function.caller`
on the calling method and V8 returns `null` for that when the caller is strict,
so a strict `initComponent` dies inside ExtJS with *Cannot read properties of
null (reading 'apply')* and takes its panel with it. Strictness is inherited by
nested functions, so the directive is all-or-nothing per file: leave it out.

**`callParent` first** in an override, before your own work — the parent builds
the thing you are about to modify.

**One override per class per extension.** A chain of N overrides is N chances
for one extension's missing `callParent` to swallow another's.

**Encode every rendered value**, including numbers. ExtJS does not escape by
default, and guest names, notes and storage descriptions are user-controlled.

```js
Ext.String.htmlEncode(value)    // in code
'{name:htmlEncode}'             // in an XTemplate
```

**Reserved words need bracket access** for ES3 parsers:
`Proxmod.api['delete'](…)`.

**No secrets in an asset.** `/` and everything under `/proxmod/` are served
without authentication [PVE-F-023] — including to logged-out clients.

## 5. Shell

`set -eu`, and `shellcheck` clean.

**The trigger path always exits 0.** A non-zero exit from a dpkg trigger can
wedge an entire `apt dist-upgrade`, including security updates for unrelated
packages.

**`flock` anything that converges.** Triggers, the boot unit and `proxmodctl`
can overlap.

**Fail toward stock Proxmox.** On any anomaly, `proxmod-exec` execs the daemon
unmodified. That is the shape of every fallback in this project.

## 6. Tests

`prove -q -r t/` runs with **no PVE installed** — stubs live in `t/lib/`.

**Name a regression test after the defect it prevents.** `t/07`'s cases are
named for the prior art's failures — *stale-backup-restored-over-newer-file*,
*revert-on-upgrade*, *leaked-backup* — so the reason is legible from the test
name alone.

**Test against real fixtures.** The injection test runs against
`t/fixtures/index.html.9.1.1.tpl`, vendored from the ISO, not against a
hand-written approximation of it.

**Verify the running system, not a fresh process that resembles it.**
([ADR 0009](adr/0009-verify-the-running-daemon.md).)

## 7. Commits and versions

Present tense, imperative, one concern per commit. Reference `[REQ-*]` or
`[PVE-F-nnn]` where a change is driven by one.

`0.MINOR.PATCH` until 1.0. A minor release may change proxmod internals; it will
not silently change the meaning of a manifest field or an installed path.

## 8. Adding a fact

1. `make facts ISO=…` and confirm the harvest finds it.
2. Add the entry to [`pve-facts.md`](pve-facts.md) with the file, the lines and
   what it means.
3. Cite it. A fact nothing cites should not be in the ledger.

A `!!` line in the harvest means the script could not find what it expected —
that seam moved, and every claim citing it needs re-reading.

---

## Reference

- [`decisions.md`](decisions.md) — the reasons behind most of the above
- [`specifications.md`](specifications.md) — the normative requirements
- [`pve-facts.md`](pve-facts.md) — the ledger
- [`security.md`](security.md) — why the Perl and JS rules are not style
