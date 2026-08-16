# Architecture

**Status:** Draft
**Applies to:** proxmod 0.2.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the module and file inventory is the repository; each
Proxmox-internals claim cites [`pve-facts.md`](pve-facts.md); the runtime
behaviour described here is exercised by `prove -r t/`

How proxmod fits together, and why it is shaped this way. For the normative
version see [`specifications.md`](specifications.md); for the decisions and
their alternatives see [`decisions.md`](decisions.md).

---

## 1. The prime directive

> **A missing extension is acceptable. A dead `pvedaemon` or `pveproxy` is
> not.**

Every layer degrades toward "Proxmox VE exactly as shipped". If you are reading
proxmod's source and a design choice looks over-cautious, this is why.

## 2. The idea

Proxmox's daemons are Perl programs. Perl can load an extra module from the
command line. systemd lets you change a unit's `ExecStart` without editing the
unit.

So: **add one `-MProxmod` to both daemons' command lines, and do everything else
from inside the running process.**

That single move is the whole design. Nothing is patched, so there is nothing to
reapply after an upgrade, and `dpkg -V pve-manager` stays silent forever.

```
 dpkg trigger ─┐
 boot unit ────┼──▶ proxmod-reapply ──▶ /etc/systemd/system/{pvedaemon,pveproxy}.service.d/
 proxmodctl ───┘                                          10-proxmod.conf
                                                                │
                                        ExecStart=/usr/lib/proxmod/proxmod-exec <daemon>
                                                                │
                                    reads the base unit's real ExecStart, adds -MProxmod
                                                                │
                                                     ┌──────────┴──────────┐
                                                     ▼                     ▼
                                                 pvedaemon               pveproxy
                                                 (root, :85)        (www-data, :8006)
                                                     │                     │
                                                 Proxmod.pm            Proxmod.pm
                                                     │                     │
                                                Proxmod::Boot         Proxmod::Boot
                                                     │                     │
                                          ┌──────────┘          ┌──────────┴──────────┐
                                          ▼                     ▼                     ▼
                                    Backend                Backend               Frontend
                                  (API tree)              (API tree)      (index tag + /proxmod/)
```

## 3. The chain, link by link

### `proxmod-exec` — the `ExecStart` wrapper

Named by both drop-ins. Reads the base unit's *real* `ExecStart` via
`systemctl show -p FragmentPath`, parses the shebang, re-execs with `-MProxmod`
added.

It reads the invocation rather than hardcoding it, so it survives Proxmox
changing the command line. And **on any anomaly it execs the daemon
unmodified**: an unrecognised shebang, a failed probe, the kill switch at
`/etc/proxmod/disabled`, or unsafe permissions on anything it is about to load.

That last refusal is a security boundary, not tidiness — see
[`security.md`](security.md) §3.

Why the command line at all? The daemons run under `perl -T`, and **taint mode
ignores `PERL5LIB` and `PERL5OPT`** [PVE-F-002]. There is no environment
variable that does this. The module must sit in a default `@INC` directory
[PVE-F-003] and load via `-M`.

### The `ExecReload` override — not optional

```ini
ExecReload=
ExecReload=-/bin/systemctl --no-block restart pveproxy.service
```

PVE's own reload is an in-process `exec()` of the original `argv`, which does
not contain `-MProxmod`. A plain `systemctl reload pveproxy` would silently
unload proxmod and leave a daemon that looks healthy and serves nothing.

It matters more than it sounds: `pve-manager`'s own `postinst` runs
`deb-systemd-invoke reload-or-try-restart` on every upgrade [PVE-F-005], which
prefers reload. Without the override proxmod would come undone on exactly the
event it exists to survive. **With it, Proxmox's own upgrade path re-injects
proxmod for us** — which is the neatest part of the whole design.

### `Proxmod.pm` — the shim

Byte-trivial and must always compile, because a syntax error here is a dead
hypervisor API. All work is behind an `eval` in `Proxmod::Boot`.

It uses `INIT { }` rather than compile time. At `INIT`,
`PVE::Service::pveproxy` is compiled but `init()` and `run()` have not been
called — exactly the window in which the UI seam can be wrapped.

### `Proxmod::Boot` — the isolation layer

Detects which daemon it is in, checks the kill switch, reads the registry, and
runs two stages: frontend injection and backend registration.

**Each stage, and each individual extension, runs inside its own `eval` with
`local $SIG{__DIE__} = 'DEFAULT'`.** The localisation matters: an extension that
installs a die handler must not be able to escape through it. One broken
extension is one log line.

It emits one boot line per daemon — the string `proxmod-verify` greps for.

### `Proxmod::Registry` — what to load, in what order

Drop-ins from `/usr/share/proxmod/extensions.d/` (package-owned) overlaid by
`/etc/proxmod/extensions.d/` (admin-owned), **later winning by basename**, so an
administrator masks a packaged extension with an empty file or a symlink to
`/dev/null` — which survives reinstalling the extension package.

Everything from a manifest is tainted. Module names are validated against a
strict package-name pattern and **rebuilt from the capture**, because `require`
of a tainted string dies [PVE-F-042] and, worse, `eval "require $name"` with a
name from disk is root RCE.

`requires` is topologically sorted, keeping declared order where dependencies
allow. An extension whose prerequisite did not load is dropped, and so is
anything that depended on it.

Nothing in the parser is fatal. One malformed manifest must never cost the
others.

### `Proxmod::API` — what extension authors touch

`mount(scope =>, subclass =>)` attaches a `PVE::RESTHandler` subclass under
`/nodes/{node}/proxmod/<id>` or `/cluster/proxmod/<id>`. `add_method(%args)`
registers one endpoint.

Three deliberate behaviours:

- **Idempotent.** `register_method` *dies* on a duplicate path [PVE-F-051], and
  an extension listed twice must not be able to take `pvedaemon` down.
- **`permissions` is mandatory.** A method with no `permissions` key is a
  working endpoint that only `root@pam` may call, with nothing said anywhere
  [PVE-F-050] — the exact trap that made `pve-token-copy` necessary. There is no
  default; you choose.
- **A post-check.** After registering, `add_method` pushes a synthetic request
  through `find_handler` and asks what it actually resolves to. Registration
  succeeding and reachability are different questions — a path behind a greedy
  `fragmentDelimiter => ''` subtree registers perfectly and never resolves.

### `Proxmod::Frontend` — the zero-mutation web interface

Two independently-`eval`'d glob wraps on `PVE::Service::pveproxy`, each behind
its own `can()` probe:

1. **Wrap `init`** to add `$cfg->{dirs}{'/proxmod/'}` and register
   `pages{'/proxmod/loader.js'}` as a dynamic handler. The dirs entry is a
   **literal**, therefore untainted — deliberately not `add_dirs()`, which
   snapshots subdirectories with `File::Find` and yields tainted strings
   [PVE-F-025].
2. **Wrap `get_index`** to inject exactly one `<script src="/proxmod/loader.js">`
   immediately after `pvemanagerlib.js` and before the inline `Ext.onReady`
   [PVE-F-021] — so every `PVE.*` class exists but no ready handler has run.
   Byte-level, ASCII-only, idempotent, and a no-op on the novnc, xtermjs and
   mobile bodies [PVE-F-022].

This works because `pages => { '/' => sub { get_index(...) } }` calls a **named
sub** [PVE-F-020], so the glob can be replaced. `Content-Length` is recomputed
from `$resp->content` [PVE-F-026], so mutating the body is safe.

`loader.js` is generated **per request** from the live registry — which is why a
frontend-only extension needs no daemon restart at all. A loader proxmod cannot
build returns **HTTP 200 with an inert comment**, not a 500: a 500 would put a
red line in every administrator's console on every page load and change nothing.

### `proxmod-ui.js` — the JS API

Wraps the `Ext.define({override: 'PVE.node.Config'})` idiom into
`Proxmod.ui.addNodeTab` and friends, maintaining **one** override chain per
target class — a chain of N overrides is N chances for one extension's
`callParent` to swallow another's — and guarding every callback so a broken
extension degrades the interface rather than blanking it.

## 4. Update survival

The strongest claim: **after a `pve-manager` upgrade there is nothing to
reapply**, because everything proxmod owns lives where Proxmox never writes.

What remains is keeping the systemd drop-ins present, which is convergence, and
there is exactly one implementation of it.

```
postinst configure  ─┐
postinst triggered  ─┤
proxmod-verify.svc  ─┼──▶ /usr/lib/proxmod/proxmod-reapply
proxmodctl reapply  ─┘
```

`proxmod-reapply` takes an `flock`, skips while `/proxmox_install_mode` exists,
re-asserts the drop-ins, runs `daemon-reload` **only if something changed**, and
restarts the daemons only when one of four things is true: a drop-in changed, a
managed patch changed a file, `proxmod-verify --live-only` says the daemons are
not loading proxmod at all, or `proxmod-verify --registry-only` says they loaded
a registry that is no longer the one on disk.

That fourth reason is what makes installing or removing an extension take
effect. Nothing the other three watch changes when a package drops a manifest
into `extensions.d`, so each daemon logs a fingerprint of the registry it
loaded and `proxmod-verify` recomputes it — see
[ADR 0011](adr/0011-registry-fingerprint.md). A restart there is behind a
loop-breaker, so daemons that cannot load the new registry converge once and
then say so rather than restarting on every trigger.

The narrowness of those conditions is the whole answer to the prior art's worst
behaviour: an APT `DPkg::Post-Invoke` hook that restarted `pveproxy` on every
apt invocation, so installing `htop` bounced the hypervisor's web interface.

If a daemon does not come back, `proxmod-reapply` **removes proxmod's own
drop-ins and restarts it stock**.

The trigger path always exits 0. A non-zero exit from a dpkg trigger can wedge
an entire `apt dist-upgrade`, including security updates for unrelated packages.

**dpkg triggers, not an APT hook**: batched once per dpkg run, ordered by dpkg,
fire on `dpkg -i` as well as apt, and fire only when a watched path changed —
none of which is true of `DPkg::Post-Invoke`. They are also what Proxmox itself
uses [PVE-F-010]. The boot-time unit is a complement, not a primary: it catches
a host restored from a backup, or a dpkg run interrupted between unpack and
trigger processing.

## 5. The consumer contract

An extension package ships three files and **no maintainer scripts**:

```
/usr/share/perl5/<Its>/<Own>/<Namespace>.pm
/usr/share/proxmod/extensions.d/50-<id>.conf
/usr/share/proxmod/www/<id>.js
```

Writing into proxmod's watched paths activates the trigger, and
`proxmod-reapply` converges. The extension does not know or care whether proxmod
is currently loaded.

## 6. Namespacing

Everything proxmod owns is under a name it owns:

| | |
|---|---|
| Perl | `Proxmod::*` — top-level, deliberately **not** under `PVE::` |
| Files | `/usr/share/proxmod`, `/etc/proxmod`, `/var/lib/proxmod`, `/usr/lib/proxmod` |
| API | `/nodes/{node}/proxmod/<id>`, `/cluster/proxmod/<id>` |
| URLs | `/proxmod/` |
| JS | the `Proxmod` global |
| CSS | `proxmod-<ext>-` |
| itemIds | `proxmod-<ext>[-<id>]` |

proxmod never ships a file into a Proxmox-owned directory. An extension gets one
namespace — its `id` — and may only write inside it across all six.

## 7. The escape hatch

`Proxmod::Patch` is a managed patch facility, and it **ships inert**: every spec
in the package has `"enabled": 0`.

It exists so that the patch someone writes anyway is a *declared* one with a
state database behind it, rather than a `sed` in a maintainer script. It uses
literal anchors (never regexes), allowlisted roots, markers so two patches can
coexist, atomic writes, and a revert that compares a checksum before restoring —
so it cannot put an older Proxmox file over a newer one.

Enabling a spec gives up every update-survival guarantee proxmod has. See
[`patching.md`](patching.md).

## 8. Known limitations

Stated plainly, because they are real:

- **Only one drop-in can set `ExecStart=`.** Two frameworks wrapping the same
  daemon conflict; the last drop-in alphabetically wins. `proxmod-verify`
  detects it and cannot resolve it. The way out is for the other module to
  become a proxmod extension.
- **Extensions are trusted with root.** proxmod isolates failures, not
  privilege. An extension runs in the same interpreter as `pvedaemon`.
- **An infinite loop in `proxmod_register` stops the daemon starting.** No
  wrapper can catch that.
- **The probes ask "does this exist", not "does this still mean what it
  meant".** A Proxmox change that keeps a seam but changes its behaviour passes
  every probe. The fact ledger is the tool for that; the runtime is not.
- **`pvesh` will not see proxmod endpoints.** It builds its own API tree in its
  own process, which was not started through the wrapper.

## 9. Where things are in the source

| Path | |
|---|---|
| `perl/Proxmod.pm` | the trivial shim, `INIT`-deferred |
| `perl/Proxmod/Boot.pm` | daemon detection, kill switch, per-extension isolation |
| `perl/Proxmod/Registry.pm` | manifests, ordering, untainting |
| `perl/Proxmod/API.pm` | the surface extension authors code against |
| `perl/Proxmod/Backend.pm` | loads and registers each extension |
| `perl/Proxmod/Frontend.pm` | the glob wraps and the dynamic loader |
| `perl/Proxmod/Patch.pm` | the escape hatch |
| `perl/Proxmod/Log.pm` | journal output |
| `www/proxmod-ui.js` | the JS API |
| `www/loader-runtime.js` | the loader's static half — **outside `www/`** once installed, so it is not served |
| `exec/proxmod-exec` | the fail-safe `ExecStart` wrapper |
| `exec/proxmod-reapply` | the single convergence routine |
| `bin/proxmod-verify`, `bin/proxmodctl` | verification and administration |
| `debian/proxmod.triggers` | the update-survival core |
| `examples/proxmod-example-hello/` | the contract, buildable |
| `scripts/extract-pve-source.sh` | re-derive the fact ledger from an ISO |

---

## Reference

- [`specifications.md`](specifications.md) — the normative version
- [`decisions.md`](decisions.md) — the decisions, with alternatives and consequences
- [`pve-internals.md`](pve-internals.md) — the Proxmox side
- [`pve-facts.md`](pve-facts.md) — every `[PVE-F-nnn]` cited above
- [`security.md`](security.md) — the trust boundaries
