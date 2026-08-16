# Compatibility with Proxmox VE

**Status:** Draft
**Applies to:** proxmod 0.1.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the seam list is the set of `[PVE-F-nnn]` entries in
[`pve-facts.md`](pve-facts.md), each regenerable with
`make facts ISO=…`; the probe-and-degrade behaviour is in
[`perl/Proxmod/Boot.pm`](../perl/Proxmod/Boot.pm) and
[`perl/Proxmod/Frontend.pm`](../perl/Proxmod/Frontend.pm)

---

## 1. What is supported

**Proxmox VE 9.x.** Verified against pve-manager 9.1.1.

proxmod does not use a published extension interface, because Proxmox does not
offer one for what proxmod does. It attaches to *seams* — named subs, class
names, config structures — that exist for Proxmox's own reasons and could change
in any release. See [`pve-internals.md`](pve-internals.md) §12 for which
Proxmox mechanisms **are** official (storage plugins, auth plugins, hookscripts,
ACL roles); prefer them when they fit.

## 2. There is no version ceiling, on purpose

proxmod's `debian/control` has **no** `Breaks: pve-manager (>= 10~)`.

A ceiling would hold back a legitimate major upgrade of the hypervisor in order
to protect an add-on. The administrator would be choosing between security
updates and a GPU tab, and proxmod is not entitled to make them choose. A stale
add-on is a smaller problem than an unpatched hypervisor.

So proxmod installs on a Proxmox it has never seen, probes each seam at runtime,
and disables — feature by feature — whatever it cannot find. The floor is
"Proxmox VE exactly as shipped".

## 3. What happens on a Proxmox proxmod has not seen

The prime directive: **a missing extension is acceptable; a dead `pvedaemon` or
`pveproxy` is not.**

| If this changed | Then | Symptom |
|---|---|---|
| The daemon's shebang or invocation | The wrapper execs it unmodified | `live.<unit>` error; nothing else changes |
| `PVE::Service::pveproxy::get_index` is gone | The `get_index` wrap is skipped | No loader tag; the backend still works |
| `server_config`'s shape changed | The `init` wrap is skipped | `/proxmod/` not served; the backend still works |
| The index anchor moved | Injection is skipped with a warning | No loader tag; everything else works |
| `PVE.node.Config` was renamed | That target refuses registration | Tabs on that target are missing; others work |
| `insertNodes` changed | Registration fails inside a guard | One tab missing, panel intact |
| `PVE::API2::Nodes::Nodeinfo` moved | `mount` dies inside its `eval` | That extension is disabled; others load |
| `register_method`'s rules changed | `add_method` dies, or the post-check warns | That endpoint is unreachable; others work |
| Something else entirely | The stage fails inside its `eval` | Logged; the daemon starts |

Every one of these is a **log line and a degraded feature**, never a failed
daemon. Each stage — boot, backend, frontend, and each individual extension —
runs inside its own `eval` with `$SIG{__DIE__}` localised, so an extension that
installs a die handler cannot escape.

### Where a seam probe sits

Wrapping is behind a `can()` check on the target sub, and defining an ExtJS
override is behind an `Ext.ClassManager.get()` check. The second matters more
than it looks: defining an override for a class that does not exist leaves it
pending in `Ext.Loader` **forever** — a *stuck* interface, not a degraded one.
Probing turns that into a missing tab.

## 4. The seams, and what depends on each

| Seam | Fact | Used for | If it moves |
|---|---|---|---|
| `perl -T` on both daemons | [PVE-F-002] | why module names are untainted | proxmod still works; the discipline is just unnecessary |
| `/usr/share/perl5` in `@INC` | [PVE-F-003] | where extensions install | nothing loads |
| `pve-manager` reloads on upgrade | [PVE-F-005] | `ExecReload` override necessity | possibly nothing; check `reload.<unit>` |
| `get_index` is a named sub | [PVE-F-020] | the frontend injection | no loader tag |
| The index script order | [PVE-F-021] | where the tag goes | injection skipped |
| `get_index` renders four pages | [PVE-F-022] | not injecting into novnc/mobile | a tag in the wrong body |
| `/` is unauthenticated | [PVE-F-023] | the no-secrets rule | a security assumption to re-check |
| `server_config`'s two tables | [PVE-F-024] | serving `/proxmod/` | assets 404 |
| `Content-Length` recomputed | [PVE-F-026] | mutating the response body | a truncated index — would be loud |
| The four `PVE.*.Config` classes | [PVE-F-030] | tab targets | tabs on that target missing |
| `insertNodes` | [PVE-F-031] [PVE-F-032] | tab insertion | tabs missing |
| `register_method` path rules | [PVE-F-051] | endpoint registration | endpoints unreachable |
| The request lifecycle | [PVE-F-052] | registering in both daemons | 501s |
| Where each daemon listens | [PVE-F-053] | the `protected`/worker model | performance assumptions change |

`[PVE-F-026]` is the one where degradation would not be graceful. proxmod
mutates the index response body, and `Content-Length` being recomputed from
`$resp->content` is what makes that safe. If that ever stopped being true the
symptom would be a truncated index — immediate and obvious, not silent.

## 5. Checking a new Proxmox release

You do not need a running host.

```sh
make facts ISO=/path/to/proxmox-ve_9.2-1.iso
git diff docs/facts/
```

`scripts/extract-pve-source.sh` runs a read-only ISO → deb → tar pipeline and
harvests each fact's evidence into `docs/facts/pve-<version>.txt`. Every
Proxmox-internals claim in the documentation cites a `[PVE-F-nnn]` entry, and
each entry names the file and lines it came from.

**A diff in the harvest is the signal to re-read the claims that cite it.** A
`!!` line means the harvest could not find what it expected — that seam moved.

Then, on a test host:

```sh
apt install ./proxmod_*.deb
proxmod-verify
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl
```

And the QEMU integration suite, which does the whole cycle offline against the
repo inside the ISO.

## 6. What verification cannot tell you

The probes ask "does this exist" and "does this resolve". They cannot ask "does
this still mean what it meant".

A Proxmox release that keeps `get_index` but changes what the index contains,
or keeps `PVE.node.Config` but changes how `PVE.panel.Config` builds its store,
would pass every probe and misbehave. That is what the fact ledger is for: the
harvest diff catches changes the runtime probes cannot.

## 7. Extension compatibility

An extension declares `Depends: proxmod (>= 0.1.0)` and **no** dependency on a
`pve-manager` version. Compatibility with Proxmox is proxmod's problem.

Within proxmod, the promise for 0.x:

- **`Proxmod::API`** — `mount`, `add_method`, `assert_route`, `id`, `daemon` are
  the interface. Anything else in `Proxmod::*` is internal and may change.
- **`Proxmod` (JS)** — `version`, `guard`, `log`, `api.*`, `ui.*` are the
  interface. Anything else on the global is internal.
- **The manifest** — fields may be added; existing ones will not change meaning
  without a major version bump.
- **On-disk paths** — `/usr/share/proxmod/extensions.d`,
  `/usr/share/proxmod/www`, `/etc/proxmod` are stable.

Before 1.0, a minor release may change internals. It will not silently change
the meaning of a manifest field or an installed path.

## 8. Proxmox VE 8 and earlier

Not supported by 0.1.0. Several seams differ, and the `-T`/`ExecReload`
analysis was done against 9.x only.

Supporting 8.x is not obviously hard — it is a second fact harvest and a second
set of probes — but it is untested, and claiming it without the harvest would be
exactly the kind of unverified assertion this project's documentation
convention forbids.

---

## Reference

- [`pve-facts.md`](pve-facts.md) — the ledger, and how to regenerate it
- [`pve-internals.md`](pve-internals.md) §12 — official versus community seams
- [`verification.md`](verification.md) — what to run after an upgrade
- [`decisions.md`](decisions.md) — why no version ceiling, in ADR form
- [`specifications.md`](specifications.md) §12–13 — normative versioning and update-survival
