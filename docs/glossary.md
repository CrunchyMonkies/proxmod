# Glossary

**Status:** Draft
**Applies to:** proxmod 0.2.2, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** Proxmox terms cite [`pve-facts.md`](pve-facts.md);
proxmod terms name the source file that defines them

Terms used across this documentation, with the meaning proxmod gives them.
Proxmox's own vocabulary comes first because the rest builds on it.

---

## Proxmox VE

**pvedaemon** — the privileged API daemon. Runs as **root**, listens on
`127.0.0.1:85` only, with `trusted_env => 1` and three worker processes
[PVE-F-053]. Anything needing root runs here.

**pveproxy** — the public API and web server. Runs as **`www-data`**, listens on
`:8006`, `trusted_env => 0`, three workers [PVE-F-053]. It authenticates and
checks permissions, then forwards `protected` methods to `pvedaemon`. Every
request reaches it first.

**`protected => 1`** — a method flag meaning "must run as root". When `pveproxy`
resolves such a method it proxies the call to `pvedaemon` over the localhost
socket instead of running it. This is the privilege bridge, and the reason
permission checks happen in an unprivileged process.

**`proxyto`** — routes a method to a specific node's `pvedaemon` in a cluster,
rather than answering locally.

**`PVE::RESTHandler`** — the base class every API class inherits. Holds the
method tree, does JSON Schema validation, and implements `register_method` and
`find_handler`.

**`register_method`** — how an endpoint is declared. **Dies** on a duplicate
path, method or name [PVE-F-051], which is why proxmod's wrapper is idempotent.

**`find_handler`** — resolves a path to a method. Registration succeeding and an
endpoint being reachable are different questions; `proxmod-verify` replays
routes through this to tell them apart.

**`fragmentDelimiter => ''`** — makes a path parameter greedy, so it swallows
the whole remaining path. A subtree registered this way **shadows anything
registered under it later** — the worked failure case is `content/{volume}`.
Never mount inside one.

**`permissions`** — the access-control block on a method. Absent, PVE silently
treats the method as **`root@pam` only** [PVE-F-050], with no error and nothing
in the documentation. proxmod makes it a required argument
([ADR 0006](adr/0006-permissions-are-mandatory.md)).

**`{ user => 'world' }`** — no authentication at all. Correct for the ticket
endpoint, almost never for anything else.

**pmxcfs / `/etc/pve`** — the clustered configuration filesystem, a FUSE mount
backed by SQLite and corosync. Unmounted during parts of an upgrade, read-only
without quorum, absent early in boot. **Never written from a maintainer script
or at boot.**

**`get_index`** — the named sub in `PVE::Service::pveproxy` that renders the web
interface's HTML [PVE-F-020]. Named, therefore glob-wrappable, which is why
proxmod's frontend needs no file mutation. It renders four different bodies —
the main interface, novnc, xtermjs and mobile [PVE-F-022].

**`server_config`** — `pveproxy`'s routing configuration, holding `{pages}`
(exact matches) and `{dirs}` (prefix matches) [PVE-F-024]. Both are served
**without authentication**.

**`pvemanagerlib.js`** — the single concatenated JavaScript bundle containing
every `PVE.*` class. No module system, one global scope.

**`PVE.panel.Config`** — the base class of every per-object configuration view:
the datacenter, a node, a guest, a storage, a pool, a zone [PVE-F-030]. It is a
card layout with a **tab bar** across the top and a **menu tree** down the left,
both built by the same `insertNodes` [PVE-F-031]. Everything `Proxmod.ui` adds
to the interface goes through it.

**`insertNodes`** — `PVE.panel.Config`'s method for adding entries to that
panel. Always appends, throws on a duplicate `itemId`, mutates the item it is
given, and **descends into** `groups` without ever creating one
[PVE-F-032][PVE-F-033]. Its signature is not API; `Proxmod.ui` exists so that
extensions never call it.

**UPID** — the identifier of a background task started with `fork_worker`.
Returned immediately; the interface polls it.

**hookscript** — an official, published extension point: a script PVE runs at
defined points in a guest's lifecycle. Prefer it when it fits.

## proxmod

**extension** — a package that adds a backend module, a frontend asset, or both,
via a manifest. Ships **three files and no maintainer scripts**.

**manifest** — the JSON drop-in in `extensions.d/` that names an extension's id,
module and assets. The only thing proxmod reads at boot.
[`extension-manifest.md`](extension-manifest.md).

**id** — an extension's identity, matching `[a-z0-9][a-z0-9_-]{0,63}`. It is
also its namespace on every axis: API path, URL, CSS prefix, `itemId`.

**registry** — the merged, ordered set of manifests. Drop-ins from
`/usr/share/proxmod/extensions.d` (package-owned) overlaid by
`/etc/proxmod/extensions.d` (admin-owned), **later winning by basename**.

**masking** — disabling a packaged extension by placing an empty file, or a
symlink to `/dev/null`, at the same basename under `/etc`. Survives reinstalling
the extension package.

**seam** — an unpublished internal of Proxmox that proxmod attaches to: a named
sub, a class name, a config structure. Every seam is probed at runtime and has a
`[PVE-F-nnn]` entry behind it.

**fact ledger** — [`pve-facts.md`](pve-facts.md) plus `docs/facts/`. Each
`[PVE-F-nnn]` names the file and lines it was read from, regenerable offline
with `make facts ISO=…`. A diff in the harvest is the signal to re-read the
claims citing it.

**the prime directive** — *a missing extension is acceptable; a dead `pvedaemon`
or `pveproxy` is not.* The rule every fallback in the project resolves to.

**runtime injection** — proxmod's mechanism: add `-MProxmod` to both daemons'
`ExecStart` and do everything from inside the running process, mutating no
Proxmox file. [ADR 0001](adr/0001-runtime-injection-over-file-patching.md).

**`proxmod-exec`** — the `ExecStart` wrapper. Reads the base unit's real
invocation, re-execs with `-MProxmod`, and **execs the daemon unmodified on any
anomaly**.

**the `ExecReload` override** — rewrites PVE's graceful reload to a real
restart. Mandatory: PVE's reload `exec()`s the original argv, which does not
contain `-MProxmod`, so without the override a reload silently unloads proxmod
and leaves a healthy-looking daemon serving nothing.

**kill switch** — `/etc/proxmod/disabled`. Present, the wrapper starts both
daemons exactly as Proxmox ships them. `proxmodctl disable`.

**loader / `loader.js`** — the single injected script, generated per request
from the live registry, which loads each extension's asset in order. Exactly one
`<script>` tag is ever injected, no matter how many extensions are installed
([ADR 0004](adr/0004-one-frontend-injection-point.md)). A loader that cannot be
built returns **HTTP 200 with an inert comment**, not a 500.

**convergence / `proxmod-reapply`** — the single idempotent routine that
re-asserts the systemd drop-ins. Called by dpkg triggers, the boot unit and
`proxmodctl reapply`. Restarts only when something changed or the running
daemons are not loaded.

**drift** — the live unit's `ExecStart` no longer resolving to proxmod's
wrapper. Usually another package's drop-in winning the `ExecStart=` race — only
one can set it. Detected as `drift.<unit>`; not automatically resolvable.

**`--live-only`** — the narrow check `proxmod-reapply` uses to decide whether to
restart: *are the running daemons loaded?* Deliberately not widened — a failing
HTTP check is not a reason to bounce `pvedaemon`.

**managed patch facility / `Proxmod::Patch`** — the escape hatch for the rare
case runtime injection cannot reach. Literal anchors, allowlisted roots,
checksummed revert, a state database. **Ships inert** — every packaged spec has
`"enabled": 0`. Enabling one forfeits every update-survival guarantee
([ADR 0008](adr/0008-patch-facility-ships-inert.md)).

**tab** — a card an extension adds to the **tab bar** across the top of a config
panel, beside Summary, Notes and the rest. Registered with `Proxmod.ui.addTab`
and friends. Use one when your card is one more view of the object already
selected.

**menu item** — a card an extension adds to the **menu tree** down the left of a
config panel, at the bottom, under a shared `Proxmod` node. Use one when the
extension owns a place rather than a view. Two kinds:

- **screen** — a tree node of its own, with its own card, activated by selecting
  it. `Proxmod.ui.addMenuScreen`.
- **section** — a fragment rendered inside the parent node's card, alongside
  every other extension's. `Proxmod.ui.addMenuSection`.

**target** — the config panel an extension is registering against, named rather
than classed: `datacenter`, `node`, `qemu`, `lxc`, `storage`, `pool`, `zone`,
`network`, plus the sets `guest` and `all` [PVE-F-034]. `Proxmod.ui.targets`
maps each to the `PVE.*` class it stands for, so a Proxmox that renames one
costs that target and nothing else.

**`[REQ-*]`** — a normative requirement in [`specifications.md`](specifications.md),
prefixed `FW`, `BE`, `FE`, `PKG`, `SEC` or `MF`.

## Debian and systemd

**dpkg trigger** — a package's declared interest in a path, batched once per
dpkg run and ordered by dpkg. proxmod's activation mechanism, and Proxmox's own
[PVE-F-010]. `interest-noawait` means the triggering package is not held waiting
on proxmod.

**`DPkg::Post-Invoke`** — an APT hook. Fires on **every** apt invocation and
**never** on `dpkg -i`. Rejected ([ADR 0003](adr/0003-dpkg-triggers-over-apt-hooks.md));
in the prior art it meant installing `htop` restarted the web interface.

**drop-in** — a `.conf` under `<unit>.service.d/` that overrides part of a unit
without editing the packaged file. **Only one may set `ExecStart=`.**

**taint mode (`-T`)** — Perl's mode treating external input as unsafe. Both PVE
daemons run under it [PVE-F-002]. `require` of a tainted string dies
[PVE-F-042], and **`PERL5LIB` and `PERL5OPT` are ignored** — which is why
injection has to happen on the command line.

**conffile** — a config file dpkg tracks for local modification. proxmod's
systemd drop-ins are deliberately **not** conffiles: `prerm` must remove the
loader before dpkg deletes the module it names.

**`dpkg -V`** — verifies installed files against their recorded checksums.
`dpkg -V pve-manager libpve-common-perl libpve-http-server-perl` being silent
after installing proxmod is the headline claim, and is asserted by the QEMU
suite.

---

## Reference

- [`pve-internals.md`](pve-internals.md) — the Proxmox terms in context
- [`architecture.md`](architecture.md) — the proxmod terms in context
- [`pve-facts.md`](pve-facts.md) — every `[PVE-F-nnn]` above
- [`specifications.md`](specifications.md) §3 — normative terminology
