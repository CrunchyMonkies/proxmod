# proxmod — specification

**Status:** Draft
**Applies to:** proxmod 0.1.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** every Proxmox-internals claim is cited as `[PVE-F-nnn]`
into [`pve-facts.md`](pve-facts.md), whose evidence is re-derivable offline from
an installer ISO with `make facts`. Every requirement is checkable by the
procedure named against it in [§16](#16-conformance-checklist).

This document is **normative**. It says what proxmod is required to do, what an
extension is required to do, and — just as importantly — what proxmod does not
promise. It is not a tutorial; the teaching guides listed in
[§18](#18-references) are.

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**
and **MAY** are to be interpreted as described in RFC 2119.

Requirements carry stable identifiers — `[REQ-BE-014]` — grouped by prefix:

| Prefix | Area |
|---|---|
| `FW` | The framework itself: runtime, configuration, failure handling, observability, and the managed patch facility |
| `BE` | Backend (Perl REST API) extensions |
| `FE` | Frontend (ExtJS) extensions |
| `MF` | The manifest and the extension registry |
| `PKG` | Packaging, installation, upgrade and removal |
| `SEC` | The security model |

Requirement identifiers are never reused. A withdrawn requirement is struck
through and kept.

---

## Table of contents

0. [Document control](#0-document-control)
1. [Overview](#1-overview)
2. [Scope, goals and non-goals](#2-scope-goals-and-non-goals)
3. [Terminology](#3-terminology)
4. [The extension model](#4-the-extension-model)
5. [Runtime architecture](#5-runtime-architecture)
6. [Backend extension specification](#6-backend-extension-specification)
7. [Frontend extension specification](#7-frontend-extension-specification)
8. [Manifest and registry](#8-manifest-and-registry)
9. [Package layout and file manifest](#9-package-layout-and-file-manifest)
10. [Configuration](#10-configuration)
11. [Security model](#11-security-model)
12. [Versioning and PVE compatibility](#12-versioning-and-pve-compatibility)
13. [Update survival: guarantees and non-guarantees](#13-update-survival-guarantees-and-non-guarantees)
14. [Failure modes and fail-safe posture](#14-failure-modes-and-fail-safe-posture)
15. [Observability and verification](#15-observability-and-verification)
16. [Conformance checklist](#16-conformance-checklist)
17. [The managed patch facility](#17-the-managed-patch-facility)
18. [References](#18-references)
- [Appendix A — reserved namespaces](#appendix-a--reserved-namespaces)
- [Appendix B — manifest JSON Schema](#appendix-b--manifest-json-schema)
- [Appendix C — requirement index](#appendix-c--requirement-index)

---

## 0. Document control

| | |
|---|---|
| Specification version | 0.1.0 — tracks the `proxmod` package version |
| Target platform | Proxmox VE 9.x on Debian 13 (trixie) |
| Last verified against | pve-manager 9.1.1, libpve-common-perl and libpve-http-server-perl as shipped in `proxmox-ve_9.1-1.iso` |
| Verified on | 2026-08-08 |
| Fact ledger | [`docs/pve-facts.md`](pve-facts.md), evidence in [`docs/facts/`](facts/) |

**Re-verification obligation.** Every claim about Proxmox internals in this
document is a citation into the fact ledger and nothing else. After a Proxmox
point release, re-derive the ledger's evidence and read the diff:

```sh
make facts ISO=/path/to/proxmox-ve_9.x-1.iso
git diff docs/facts/
```

That diff is the list of assumptions that moved. Any fact whose evidence changed
invalidates every requirement citing it until it is re-verified, and this
document's *Last verified against* line MUST be updated in the same commit.

**Status transitions.** This document leaves Draft when [§16](#16-conformance-checklist)
passes end to end on a live host under `test/qemu/`, and when it contains no
`UNVERIFIED` markers.

---

## 1. Overview

proxmod installs backend REST API endpoints and frontend web-interface
components into a running Proxmox VE host, and keeps them working across
`apt full-upgrade`.

It does so **without modifying a single file that Proxmox owns**. The whole
design follows from that constraint:

```
             systemd drop-in                     dpkg trigger
                   │                                   │
                   ▼                                   ▼
  ExecStart=/usr/lib/proxmod/proxmod-exec      proxmod-reapply
                   │  (re-execs the real daemon                 (idempotent
                   │   command with -MProxmod)                   convergence)
                   ▼
        perl -T -MProxmod /usr/bin/pveproxy
                   │
                   │ INIT { Proxmod::Boot::boot() }
                   ▼
        ┌──────────────────────────────┐
        │ Proxmod::Registry            │  read /usr/share/proxmod/extensions.d
        │   ↓                          │  overlaid by /etc/proxmod/extensions.d
        │ Proxmod::Backend  → PVE tree │  require + proxmod_register($api)
        │ Proxmod::Frontend → index    │  glob-wrap get_index / init
        └──────────────────────────────┘
```

Nothing above writes to disk at any point. `dpkg -V pve-manager` is clean after
installing proxmod, after installing an extension, and after upgrading Proxmox —
and that is the single property this specification exists to protect.

**The prime directive**, which every requirement below is subordinate to:

> A missing extension is acceptable. A dead `pvedaemon` or `pveproxy` is not.

Everything degrades toward "Proxmox VE exactly as shipped". A consequence is
that failure is *silent* by design, which is why [§15](#15-observability-and-verification)
imposes a monitoring obligation rather than treating verification as optional.

---

## 2. Scope, goals and non-goals

### 2.1 Goals

| | |
|---|---|
| G1 | An extension can add REST API endpoints under a namespace that cannot collide with Proxmox's or with another extension's |
| G2 | An extension can add UI components to the web interface, with no file of Proxmox's edited and no build step |
| G3 | Installing, upgrading and removing an extension is `apt install` / `apt remove`, with **no maintainer scripts in the extension package** |
| G4 | A `pve-manager` upgrade leaves nothing to reapply, because proxmod never wrote anywhere Proxmox writes |
| G5 | Any failure — of proxmod, of one extension, of the seam itself — degrades to stock Proxmox rather than to a broken host |
| G6 | The state of all of the above is reportable in one command, from the *running* daemon, and is machine-readable |
| G7 | Every claim about Proxmox internals is re-derivable offline from an installer ISO by someone with no PVE host |

### 2.2 Non-goals

| | |
|---|---|
| N1 | **Not an official Proxmox extension point.** proxmod attaches at seams that are implementation detail. Proxmox may move them at any release. [§12](#12-versioning-and-pve-compatibility) is about surviving that, not preventing it |
| N2 | Not a replacement for the extension points Proxmox *does* support — storage plugins, authentication plugins, hookscripts. Where one of those fits, it is the better answer |
| N3 | Not a sandbox. Backend extension code runs as root inside `pvedaemon` with no isolation. [§11](#11-security-model) says what that means and what proxmod checks instead |
| N4 | Not a cluster-aware distribution mechanism. proxmod configures one host. Installing the same packages on every node is the administrator's job (or their configuration management's) |
| N5 | Not PVE 8.x or earlier, and not PBS or PMG. [§12](#12-versioning-and-pve-compatibility) |
| N6 | Not a general file-patching tool. [§17](#17-the-managed-patch-facility) exists, ships inert, and is deliberately unattractive |

### 2.3 In scope for this document

The framework's runtime behaviour, the contract an extension codes against, the
package layout, the security model, and the guarantees around updates. Not in
scope: how to *write* a good extension (see the teaching guides), and Proxmox's
own internals beyond the cited facts.

---

## 3. Terminology

| Term | Meaning |
|---|---|
| **Host** | One Proxmox VE machine. proxmod's unit of configuration |
| **Framework** | The `proxmod` package: the Perl modules, the wrapper, the convergence script and the tooling |
| **Extension** | A unit of added functionality, identified by an **extension id**, described by one **manifest** |
| **Extension package** | The `.deb` that ships an extension. Depends on `proxmod`; ships no maintainer scripts |
| **Manifest** | A JSON drop-in file in an extensions directory that declares one extension |
| **Registry** | The merged, ordered, validated set of enabled manifests, produced by `Proxmod::Registry::load()` |
| **Backend extension** | An extension with a `backend` block: a Perl module that registers REST endpoints |
| **Frontend extension** | An extension with a `frontend` block: one or more JavaScript assets |
| **Seam** | A point in Proxmox's own code that proxmod attaches to at runtime without modifying it |
| **Injection** | Adding `-MProxmod` to a daemon's command line via a systemd drop-in |
| **Convergence** | Making the host's actual state match what proxmod requires — `proxmod-reapply` |
| **Kill switch** | `/etc/proxmod/disabled`; checked before any proxmod code loads |
| **Wrapped daemon** | `pvedaemon` or `pveproxy` — the two units proxmod injects into |
| **Managed patch** | An administrator-enabled modification of a Proxmox-owned file, [§17](#17-the-managed-patch-facility). Not used by extensions |

---

## 4. The extension model

### 4.1 Identity

**[REQ-MF-001]** Every extension MUST have an **extension id** matching
`^[a-z0-9][a-z0-9_-]{0,63}$`, unique across the host.

**[REQ-MF-002]** The extension id MUST be treated as an identifier, not a
display name: it appears in URL paths, in log lines and in JavaScript. It MUST
NOT be changed across versions of an extension without treating that as a
rename of the extension.

**[REQ-MF-003]** Two manifests declaring the same id MUST NOT both load. The
registry loads the first in load order and logs the other as shadowed.

### 4.2 The namespace rule

This is the rule that makes collisions structurally impossible rather than a
matter of good manners.

**[REQ-BE-001]** An extension MUST confine everything it creates to a namespace
derived from its own id. Concretely, across all five surfaces:

| Surface | The extension `foo` may create | It MUST NOT create |
|---|---|---|
| REST paths | `/nodes/{node}/proxmod/foo/...`, `/cluster/proxmod/foo/...` | anything else in PVE's tree |
| Perl packages | its own top-level package, e.g. `AcmeFoo::*` | anything under `PVE::` or `Proxmod::` |
| JavaScript globals | one global, or nothing — preferably a property of `Proxmod.ext.foo` | anything under `PVE.*` or `Ext.*` |
| CSS classes | `proxmod-foo-*` | any Proxmox or ExtJS class name |
| Files | `/usr/share/proxmod/www/<name>.js`, `/usr/share/proxmod/extensions.d/NN-<name>.conf`, its own Perl module path | any file owned by another package |

**[REQ-BE-002]** An extension MUST NOT write to any file owned by another
package at install time or at run time. The framework provides no mechanism for
doing so; [§17](#17-the-managed-patch-facility) is an administrator facility,
not an extension facility.

**[REQ-BE-003]** proxmod claims exactly one path segment from Proxmox —
`proxmod` — per supported scope. A Proxmox release that adds a new endpoint can
therefore collide with exactly one name, and that collision is detected and
reported at boot ([§15](#15-observability-and-verification)) rather than
producing a silently unreachable subtree.

### 4.3 Shapes an extension may take

An extension MUST declare a `backend`, a `frontend`, or both
**[REQ-MF-004]** — a manifest that declares neither usable block is ignored with
a warning, because it can only be a packaging mistake.

| Shape | Consequence |
|---|---|
| Backend only | Endpoints appear. Requires a daemon restart to take effect |
| Frontend only | Assets appear. **No daemon restart required** — the loader is generated per request from the live registry |
| Both | Both of the above |

---

## 5. Runtime architecture

### 5.1 The injection seam

**[REQ-FW-001]** proxmod MUST reach the wrapped daemons via a command-line
`-M<module>` added by a systemd `ExecStart` drop-in, and MUST NOT rely on
`PERL5LIB`, `PERL5OPT`, or any other environment variable to load code into
them. Both daemons run `#!/usr/bin/perl -T` and taint mode causes perl to ignore
those variables entirely [PVE-F-002]; an `Environment=` drop-in is inert, the
daemon starts perfectly, and nothing says why the extensions are missing.

**[REQ-FW-002]** Every Perl module proxmod loads into a daemon MUST live in a
directory that is in perl's *default* `@INC` — `/usr/share/perl5` on Debian
[PVE-F-003] — for the same reason.

**[REQ-FW-003]** The `ExecStart` drop-in MUST name a wrapper
(`/usr/lib/proxmod/proxmod-exec`), not a hardcoded command line. The wrapper
MUST read the daemon's real `ExecStart` out of the **base** unit at start time
and re-execute it with `-MProxmod` added, so that a Proxmox release changing the
invocation or perl's flags does not require a proxmod release.

**[REQ-FW-004]** The wrapper MUST read the base unit only, never systemd's
merged configuration — the merged `ExecStart` is proxmod's own drop-in, and
following it would recurse.

**[REQ-FW-005]** The wrapper MUST start the daemon **exactly as Proxmox ships
it** on every condition it cannot handle safely, and MUST log the reason with
the `proxmod:` prefix. The complete list of such conditions:

| Condition | Behaviour |
|---|---|
| the unit file cannot be found or read | start `/usr/bin/<svc> start` |
| the unit has no `ExecStart` | start `/usr/bin/<svc> start` |
| the `ExecStart` uses quoting, `$`, or a systemd `%` specifier | start `/usr/bin/<svc> start` — it cannot be word-split safely |
| the script named by `ExecStart` is not executable | start `/usr/bin/<svc> start` |
| the kill switch `/etc/proxmod/disabled` exists | start the real script, uninjected |
| any guarded path fails the ownership/permission check ([§11](#11-security-model)) | start the real script, uninjected |
| the script's shebang is not a perl interpreter | start the real script, uninjected |
| that interpreter is not executable | start the real script, uninjected |
| `perl <flags> -MProxmod -c -e 1` fails | start the real script, uninjected |

**[REQ-FW-006]** The wrapper MUST probe with `-c` (compile only) and not by
running the module, so that the probe cannot execute proxmod's boot path twice.
The probe MUST cover `Proxmod` only, and MUST NOT cover `Proxmod::Boot`: `Boot`
is loaded at runtime inside an `eval`, so a broken `Boot` costs the extensions
and not the daemon, and refusing to start injected over it would be an
overreaction.

**[REQ-FW-007]** The wrapper MUST refuse to start anything at all if invoked
with a service name other than `pvedaemon` or `pveproxy` (exit 64). This is the
one non-fail-safe case, because there is no daemon to fall back to starting.

### 5.2 `ExecReload` and why it is overridden

**[REQ-FW-008]** proxmod's drop-in MUST override `ExecReload` to a full restart
of the unit.

PVE's own reload is an in-process `exec()` of the original `argv`, which does
not contain `-MProxmod`. A plain `systemctl reload pveproxy` would therefore
unload proxmod silently, leaving a daemon that looks healthy and serves none of
the extensions. This is not hypothetical: `pve-manager`'s own `postinst` runs
`deb-systemd-invoke reload-or-try-restart pveproxy.service` on every upgrade
[PVE-F-005], and `reload-or-try-restart` prefers reload. Without the override
proxmod would come undone on exactly the event it exists to survive. *With* it,
Proxmox's own upgrade path re-injects proxmod for free.

**[REQ-FW-009]** The reload override MUST use `--no-block` and MUST tolerate
failure (`ExecReload=-/bin/systemctl --no-block restart ...`). A unit cannot
wait for its own restart job from inside its own `ExecReload`; blocking would
deadlock, and a failed reload marking the unit failed would be a worse outcome
than a reload that did nothing.

### 5.3 Boot sequence inside the daemon

**[REQ-FW-010]** `Proxmod.pm` MUST be trivial, dependency-free beyond core Perl,
and MUST do no work of its own. It is the only piece of proxmod whose failure to
compile stops a daemon starting.

**[REQ-FW-011]** `Proxmod.pm` MUST perform its work from an `INIT { }` block —
not compile time, not run time. At compile time `PVE::Service::pveproxy` does
not exist yet and there is nothing to attach to; by run time `init()` and
`run()` have been called and wrapping them is too late. `INIT` runs after the
whole program is compiled and before its first statement, which is precisely the
window required.

**[REQ-FW-012]** `Proxmod.pm` MUST load `Proxmod::Boot` at runtime inside an
`eval` and MUST NOT `use` it, so that a broken, half-upgraded or deleted
`Boot.pm` costs an extension and not a host. On failure it MUST print one
`proxmod: error:` line to STDERR and return normally.

**[REQ-FW-013]** `Proxmod::Boot::boot()` MUST be idempotent within a process: a
second call logs and returns.

**[REQ-FW-014]** `boot()` MUST return without loading anything when
`/etc/proxmod/disabled` exists, and MUST log that it did so.

**[REQ-FW-015]** `boot()` MUST determine which daemon it is running inside and
MUST load nothing when that is not `pvedaemon` or `pveproxy`. `pvesh` and an
administrator's `perl -MProxmod` both reach this code, and neither is a daemon
proxmod extends.

**[REQ-FW-016]** Each boot stage — registry load, backend install, frontend
install — MUST run inside its own `eval`, and a stage that dies MUST NOT prevent
the following stages from running or the daemon from starting.

**[REQ-FW-017]** The frontend stage MUST run in `pveproxy` only. `pvedaemon`
never renders a page; wrapping it there would be pure risk for no gain.

**[REQ-FW-018]** On completion `boot()` MUST emit exactly one line of the form

```
proxmod: booted daemon=<name> extensions=<n> failed=<n>
```

This line is the contract with `proxmod-verify` ([§15](#15-observability-and-verification)),
which greps for it in the journal of the *running process*. Changing its shape
in one place and not the other is how a verification tool starts lying.

### 5.4 Process placement

| Daemon | User | proxmod loads | Why |
|---|---|---|---|
| `pvedaemon` | root | backend | Bound to `127.0.0.1:85`; executes `protected => 1` methods [PVE-F-053] |
| `pveproxy` | `www-data` | backend + frontend | Bound to `:8006`; answers unprotected methods itself, renders the index [PVE-F-053] |
| `pvestatd` | root | — | Not wrapped. It serves no API and renders no page |

**[REQ-BE-004]** A backend extension SHOULD register in **both** wrapped daemons
(the manifest default). Every request reaches `pveproxy` first, and it must find
the method in its own tree before it can decide to proxy it; `pvedaemon` then
finds it again to run it [PVE-F-052]. An extension loaded into only one daemon
answers **501 Not Implemented** — not 404 — from the other.

---

## 6. Backend extension specification

### 6.1 The entry point

**[REQ-BE-005]** A backend extension MUST provide a Perl module, named by its
manifest, that defines a sub `proxmod_register`. It is called once per wrapped
daemon start with a `Proxmod::API` object scoped to that extension:

```perl
package AcmeFoo::API;

use strict;
use warnings;
use base 'PVE::RESTHandler';

sub proxmod_register {
    my ($api) = @_;

    $api->mount(scope => 'node', subclass => __PACKAGE__);

    $api->add_method({
        class       => __PACKAGE__,
        name        => 'index',
        path        => '',
        method      => 'GET',
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
        description => 'Everything Acme knows about this node.',
        parameters  => {
            additionalProperties => 0,
            properties => {
                node => get_standard_option('pve-node'),
            },
        },
        returns => { type => 'object' },
        code    => sub { ... },
    });
}

1;
```

**[REQ-BE-006]** The module MUST compile standalone under `perl -c`, and MUST
NOT assume that any PVE module is loaded at compile time beyond those it `use`s
itself.

**[REQ-BE-007]** `proxmod_register` MUST be safe to call more than once per
process. `Proxmod::API`'s methods are idempotent; an extension that keeps its own
side-effecting state MUST guard it.

**[REQ-BE-008]** The extension MUST NOT call
`PVE::RESTHandler->register_method` directly. Nothing prevents it, but every
rule that registration enforces is a `die` inside a daemon that is starting, and
`Proxmod::API` converts each of them into a check that happens before PVE's
registry is mutated. See [PVE-F-051].

### 6.2 Mounting

**[REQ-BE-009]** An extension MUST obtain its subtree with `$api->mount(...)`,
which places it at:

| Scope | Path |
|---|---|
| `node` (default) | `/nodes/{node}/proxmod/<id>` |
| `cluster` | `/cluster/proxmod/<id>` |

**[REQ-BE-010]** `mount` MUST be idempotent for the same `(scope, subclass)`
pair and MUST die — visibly, before touching PVE's registry — when a *different*
class attempts to take a subtree that is already claimed. A silent win would
make two extensions' behaviour depend on load order.

**[REQ-BE-011]** After mounting its root class, proxmod MUST push a probe path
through `PVE::API2->find_handler` and report a mismatch as a warning naming the
class that actually answers. A mount that registers cleanly and does not resolve
is otherwise indistinguishable from a working one until a user reports a 404.

**[REQ-BE-012]** An extension MUST NOT mount into, or register any method
underneath, a subtree registered with `fragmentDelimiter => ''`. Such a subtree
collapses every remaining path fragment into one string [PVE-F-051], so a method
registered below it either never resolves or resolves to the right class and the
wrong method. The worked example is
`/nodes/{node}/storage/{storage}/content/{volume}`: a method registered under
`content` is answered by the `{volume}` handler, and a check that compared class
names alone would call that healthy.

**[REQ-BE-013]** An extension MUST NOT register a path component at a level that
already holds a `{param}` regex, or a `{param}` at a level that already holds
named folders. `PVE::RESTHandler` dies with *"path match error - regex and fixed
items"* [PVE-F-051], and inside `pvedaemon` that is a daemon that does not start.
Confining extensions beneath `proxmod/<id>` makes this unreachable in practice;
it is stated because an extension that mounts a nested subclass of its own can
still reach it.

### 6.3 Methods

**[REQ-BE-014]** Every registered method MUST carry a `permissions` key.

This is the most important requirement in this section. A method with no
`permissions` key is not an error and is not logged: `check_api2_permissions`
returns early for `root@pam` and raises a permission exception for everyone else
[PVE-F-050]. The endpoint therefore works perfectly for its author — who is
logged in as `root@pam` — and denies every other user with a message that names
no method. It is the exact trap that forced a comparable single-endpoint
extension to exist at all.

`Proxmod::API::add_method` refuses to register a method with no `permissions`
key. The three ways to satisfy it, all explicit:

| Value | Meaning |
|---|---|
| `permissions => undef` | PVE's `root@pam`-only default, chosen deliberately and in writing |
| `permissions => { user => 'all' }` | Any authenticated user |
| `permissions => { check => [...] }` | An ACL check — the normal case |

**[REQ-BE-015]** `permissions => { user => 'world' }` makes an endpoint callable
with **no authentication at all**. An extension SHOULD NOT use it. proxmod MUST
log a warning naming the method when one does, so that an administrator can
discover it from the journal rather than from a scanner.

**[REQ-BE-016]** A method whose work requires root MUST declare
`protected => 1`, which routes it to `pvedaemon`. A method that does not require
root MUST NOT declare it: `protected` methods are proxied and cost a round trip.

**[REQ-BE-017]** A method that reads or writes cluster-wide state SHOULD declare
`proxyto => 'node'` (or the appropriate value) rather than assuming it runs on
the node named in its path.

**[REQ-BE-018]** Long-running work MUST be run through `$rpcenv->fork_worker`
(inherited from `PVE::RESTEnvironment`) and MUST return a UPID, not block the
daemon.
`pvedaemon` defaults to **three** worker processes [PVE-F-053]: a `protected`
method that blocks for thirty seconds removes a third of the host's capacity to
execute any privileged API call at all for that whole time.

**[REQ-BE-019]** After registering a method on a class it mounted, proxmod MUST
replay the route through `find_handler` and compare the returned method info by
**reference identity** to the hash it registered. Comparing class names alone is
insufficient — inside a greedy subtree the right class answers with the wrong
method [PVE-F-051] — and the mismatch MUST be logged as a warning naming the
method that actually answers.

**[REQ-BE-020]** `add_method` MUST accept only `GET`, `POST`, `PUT` and
`DELETE`, the methods PVE dispatches.

**[REQ-BE-021]** Registering the same `(class, method, path)` twice MUST be a
no-op that logs at debug level, not a `die`. `PVE::RESTHandler` dies on a
duplicate [PVE-F-051]; an extension listed twice, or a module reachable under two
names, MUST NOT be able to take `pvedaemon` down over it.

### 6.4 Environment and system access

**[REQ-BE-022]** An extension MUST NOT depend on any environment variable being
set. `pvedaemon` starts with a cleared environment; a test override plumbed only
through an env var is unreachable in production, which is a defect the prior art
shipped. Extensions needing a test seam MUST read it from a configuration file,
optionally *also* honouring an env var for hand-started daemons.

**[REQ-BE-023]** Any value an extension derives from disk — `readdir`, `glob`, a
config file — is tainted [PVE-F-041] and MUST be rebuilt from a strict capture
before it reaches `require`, `open` for writing, `system`, `exec`, or a
subprocess. `require` of a tainted string dies [PVE-F-042].

**[REQ-BE-024]** An extension MUST NOT open a file with an `:encoding()` layer
when the path is tainted: perl loads `PerlIO::encoding` lazily and treats that
`require` as insecure under `-T` [PVE-F-040]. Read bytes and decode afterwards.

**[REQ-BE-025]** An extension MUST NOT read or write `/etc/pve` from any code
that runs during a daemon's startup path. It is a FUSE filesystem (pmxcfs) that
is not mounted early in boot and is routinely unmounted during upgrades. Access
from a *request* handler is normal and expected; access from `proxmod_register`
is not.

### 6.5 Isolation

**[REQ-FW-019]** proxmod MUST load and register each extension inside its own
`eval`. One extension whose module does not compile, or whose
`proxmod_register` dies, MUST cost exactly itself: every other extension still
loads, and the daemon still starts.

**[REQ-FW-020]** A failed extension MUST produce one `proxmod: error: extension
<id>: not loaded: <reason>` line, and MUST be counted in the `failed=` field of
the `booted` line.

**[REQ-FW-021]** proxmod MUST NOT pass a module name from a manifest to
`eval "require $module"`. It MUST convert the validated name to a relative path
and `require` that, keeping a string that came from disk out of the compiler
entirely.

---

## 7. Frontend extension specification

### 7.1 The single injection point

**[REQ-FE-001]** proxmod MUST insert **exactly one** `<script>` tag into the
rendered index page, pointing at `/proxmod/loader.js`. Extensions MUST NOT have
any mechanism for adding a tag of their own. One injection point means one thing
to verify, one thing to break, and a bounded blast radius when it does.

**[REQ-FE-002]** The tag MUST be inserted by wrapping
`PVE::Service::pveproxy::get_index` at runtime and mutating the response body
[PVE-F-020]. It MUST NOT be inserted by modifying `index.html.tpl` or any other
file on disk.

**[REQ-FE-003]** The insertion point MUST be immediately before the inline
`<script>` block that calls `Ext.onReady` — the last script in `<head>`
[PVE-F-021]. At that point every `PVE.*` class is defined and no ready handler
has been registered, so an extension can override a class and still be in place
before the workspace is built.

**[REQ-FE-004]** If that anchor cannot be found, proxmod MUST fall back to
immediately after the `pvemanagerlib.js` script tag, and if neither is present
MUST leave the page untouched and log a warning. It MUST NOT guess.

**[REQ-FE-005]** Injection MUST be idempotent: a body already containing
`/proxmod/loader.js` MUST be returned unchanged. A reload, or a second copy of
proxmod, MUST NOT produce two tags.

**[REQ-FE-006]** Injection MUST be a no-op on every page `get_index` serves
other than the manager index — the noVNC, xterm.js and mobile bodies
[PVE-F-022]. This MUST be structural (keying on a marker that appears only in the
manager index) rather than a list of exceptions to maintain.

**[REQ-FE-007]** proxmod MUST NOT set or adjust `Content-Length` after mutating
the body: `PVE::APIServer::AnyEvent::response` recomputes it from the content
[PVE-F-026]. Setting it would be the bug, not the fix.

**[REQ-FE-008]** When no enabled extension declares a frontend asset, proxmod
MUST NOT wrap anything and MUST NOT alter the index. proxmod's footprint on a
host with no frontend extension is zero bytes of changed HTML.

### 7.2 Serving assets

**[REQ-FE-009]** Extension assets MUST be served from a single flat directory,
`/usr/share/proxmod/www`, under the URL prefix `/proxmod/`.

**[REQ-FE-010]** The static route MUST be added by assigning a **string literal**
into `$self->{server_config}{dirs}` from a wrapper around `init()`
[PVE-F-024]. proxmod MUST NOT call `PVE::APIServer::AnyEvent::add_dirs`: it walks
the tree with `File::Find` and registers every subdirectory as its own alias,
and under `-T` every path it produces is tainted [PVE-F-025]. A literal cannot be
tainted by construction — which is also why the directory is flat.

**[REQ-FE-011]** `/proxmod/loader.js` MUST be registered in
`$self->{server_config}{pages}`, which is matched on the exact path and checked
*before* `dirs` [PVE-F-024], so the dynamic loader wins over any file that
happens to be called `loader.js`.

**[REQ-FE-012]** The loader MUST be generated per request from the live registry.
This is what makes a frontend-only extension take effect with **no daemon
restart**.

**[REQ-FE-013]** The loader body MUST be byte-identical for an identical
registry, so that two hosts in a cluster can be diffed.

**[REQ-FE-014]** A failure to build the loader MUST return HTTP 200 with an inert
comment body, not a 500. The tag is already in the page; a 500 puts a red line
in every administrator's console on every page load and changes nothing about
the outcome.

**[REQ-FE-015]** Asset filenames MUST match
`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.js$`. No directories, no traversal. The name
is interpolated into a URL served without authentication, and MUST be re-checked
on the way out of the registry as well as on the way in.

**[REQ-FE-016]** A manifest naming an asset that is not installed MUST be logged
against the extension id and skipped. The browser would otherwise report it as an
error from a URL nobody recognises.

**[REQ-FE-017]** proxmod's own `proxmod-ui.js` MUST be loaded before any
extension's asset, and extension assets MUST be loaded in registry order.

**[REQ-FE-018]** `loader-runtime.js` — the template the loader is rendered from —
MUST NOT be installed under `/usr/share/proxmod/www`. Everything in that
directory is served to anyone who can reach :8006, and a browser fetching the
template directly would receive an unsubstituted placeholder.

### 7.3 The JavaScript contract

The Proxmox web interface is one concatenated bundle with no module loader and
one global scope. There is no `import`, no bundler, and no build step.

**[REQ-FE-019]** An extension asset MUST be plain ES5-compatible JavaScript
evaluated in global scope, MUST NOT assume any loader, and MUST NOT throw at
parse time.

**[REQ-FE-020]** An extension MUST use the `Proxmod` global rather than
manipulating `PVE.*` classes directly. proxmod maintains **one** override chain
per target class and wraps every extension callback, so a broken extension
degrades to a missing tab instead of a blank interface.

| API | Purpose |
|---|---|
| `Proxmod.version` | The framework version the page was served by |
| `Proxmod.log.debug/warn/error(msg, err)` | Console output tagged with proxmod |
| `Proxmod.guard(what, fn)` | Run `fn`, catching and reporting anything it throws |
| `Proxmod.api.url(ext, path, node)` | Build `/nodes/<node>/proxmod/<ext>/<path>` or the cluster equivalent |
| `Proxmod.api.storeUrl(ext, path, node)` | The same, prefixed `/api2/json` — for an `Ext.data.Store` |
| `Proxmod.api.request({ext, path, node, ...})` | `Proxmox.Utils.API2Request` with the path built and `node` supplied |
| `Proxmod.ui.addNodeTab(spec)` | Add a tab to the node view |
| `Proxmod.ui.addQemuTab(spec)` / `addLxcTab(spec)` / `addGuestTab(spec)` | Add a tab to a guest view; `addGuestTab` adds to both |
| `Proxmod.ui.addDatacenterTab(spec)` | Add a tab to the datacenter view |
| `Proxmod.ui.addTab(target, spec)` | Add a tab to any key of `Proxmod.ui.targets` |
| `Proxmod.ui.addMenuScreen(spec)` | Add a node to the config panel's left-hand menu tree, with a card of its own |
| `Proxmod.ui.addMenuSection(spec)` | Add a section to the menu parent's own card |
| `Proxmod.ui.addMenuItem(spec)` | Either of the two, selected by `spec.mode` |
| `Proxmod.ui.configureMenu(spec)` | Title, icon, layout and initial state of a menu parent |
| `Proxmod.ui.addStyle(ext, css)` | Inject a stylesheet scoped to the extension |
| `Proxmod.ui.registrations()` | What has been registered, for debugging |

**[REQ-FE-021]** Every `spec` passed to a `Proxmod.ui` helper MUST carry
`ext` (the extension id) and an `xtype`. `Proxmod.ui` uses `ext` to attribute
failures and to namespace generated ids.

**[REQ-FE-022]** An extension MUST give every tab it adds an `itemId` that is
unique on the host and namespaced to the extension. `insertNodes` throws on a
duplicate `itemId` [PVE-F-032]; the throw is caught, but the tab is lost.

**[REQ-FE-023]** proxmod MUST NOT hand `insertNodes` a `groups` array it does not
own a copy of: `insertNodes` calls `shift()` on `item.groups` [PVE-F-032], so a
shared array is consumed on first use and every later insertion behaves
differently.

**[REQ-FE-024]** Any override proxmod or an extension installs MUST call
`callParent` **first** and treat its own work as optional [PVE-F-031]. An
override that does its own work before the parent's leaves the component
half-constructed when it throws.

**[REQ-FE-025]** An extension MUST NOT put a secret, a token, an internal
hostname or any other non-public value in a frontend asset. `/` and everything
under `/proxmod/` are served **without authentication** [PVE-F-023].

**[REQ-FE-026]** An extension MUST encode any value it renders that came from a
guest, a user, or a remote system. ExtJS templates do not escape by default.

### 7.4 The config-panel menu

Every panel in [PVE-F-034]'s type-to-class map, `tag` excepted, is a
`PVE.panel.Config` subclass and carries a `treelist` menu built by the same
`insertNodes` used for tabs. An extension may own an entry in it.

**[REQ-FE-027]** `Proxmod.ui` MUST expose every target in that map except `tag`,
and MUST forward the selected object's identity to each item it inserts under
the names PVE's own panels use — `nodename`, `vmid`, `storage`, `pool`, `zone`,
`zoneType` [PVE-F-034]. An extension card MUST NOT parse the URL for them.

**[REQ-FE-028]** A menu item MUST be one of two kinds: a **screen**, which is a
tree node with a card of its own, or a **section**, which is rendered inside the
parent node's card. Both MUST be registered through the same call and MUST
differ only in `mode`.

**[REQ-FE-029]** Menu items MUST be inserted after `callParent`, so they land at
the bottom of the menu [PVE-F-033]. proxmod MUST NOT reorder Proxmox's own
entries.

**[REQ-FE-030]** A menu parent MUST be inserted before any child that names it
in `groups`, and if the parent's insertion is refused its children MUST be
skipped. `insertNodes` descends into groups and never creates one [PVE-F-033]:
inserting a child whose group is absent appends it at the **top level**,
silently, which scatters an extension's screens through the menu rather than
failing visibly.

**[REQ-FE-031]** Ordering among proxmod's own items MUST be deterministic across
page loads: by `weight`, then by registration order. Menu contents that shuffle
between loads are indistinguishable from a bug.

**[REQ-FE-032]** By default every extension MUST share one parent node. An
extension MAY request a top-level node of its own (`standalone`), and when it
has exactly one screen and no sections that screen MUST *be* the node rather
than be wrapped in one.

**[REQ-FE-033]** A parent card with no sections registered MUST render a
placeholder naming its child screens. `activateCard` shows whatever the card
holds, so an empty card is a blank pane rather than an error.

---

## 8. Manifest and registry

### 8.1 Location and precedence

**[REQ-MF-005]** Manifests MUST be read from, in this order:

| Directory | Owner | Purpose |
|---|---|---|
| `/usr/share/proxmod/extensions.d/` | package | An extension `.deb` drops its manifest here |
| `/etc/proxmod/extensions.d/` | administrator | Overlay: overrides or masks a packaged manifest |

**[REQ-MF-006]** Precedence MUST be **by basename**, not by id: a file of the
same name in `/etc` replaces the packaged one outright. An administrator who
needs to change one field copies the file and edits it, and `dpkg` will never
silently revert them.

**[REQ-MF-007]** An `/etc` manifest MAY mask a packaged extension entirely.
Masking MUST be reported at debug level, not silently.

**[REQ-MF-008]** Manifest filenames SHOULD be `NN-<name>.conf` with a two-digit
sort prefix, matching the drop-in convention used everywhere else on the system.

### 8.2 Format

Manifests are JSON. The parser is deliberately relaxed — `//` and `#` comments
and trailing commas are accepted **[REQ-MF-009]** — so that a manifest an
administrator has edited under `/etc` survives a stray comma rather than
disappearing. Packaged manifests SHOULD be plain JSON.

Full schema in [Appendix B](#appendix-b--manifest-json-schema). Fields:

| Field | Type | Default | Rules |
|---|---|---|---|
| `id` | string | — | **required**; `^[a-z0-9][a-z0-9_-]{0,63}$` |
| `version` | string | `"0"` | Informational; also the asset cache-busting token |
| `enabled` | boolean | **`true`** | Absent means enabled |
| `order` | integer | `50` | `0`–`9999`. Ties broken by manifest basename |
| `requires` | array of id | `[]` | Load-order dependencies |
| `backend.module` | string | — | Perl package name; validated against a strict pattern |
| `backend.daemons` | array | `["pvedaemon","pveproxy"]` | Subset of the wrapped daemons |
| `frontend.assets` | array of filename | `[]` | Bare `.js` filenames under `/usr/share/proxmod/www` |

**[REQ-MF-010]** `enabled` absent MUST mean **enabled**. (Note the deliberate
asymmetry with a patch spec, where absent means *disabled* — [§17](#17-the-managed-patch-facility).
An extension manifest exists because somebody installed an extension package; a
patch spec exists because somebody shipped an example.)

**[REQ-MF-011]** Load order MUST be `order` ascending, ties broken by manifest
basename, then topologically adjusted for `requires`. It MUST NOT depend on
`readdir` order.

**[REQ-MF-012]** An extension whose `requires` names a missing extension, or
participates in a cycle, MUST NOT load — and neither MUST anything that depends
on it. An extension whose prerequisite never loaded is more likely to misbehave
than to degrade gracefully.

### 8.3 Validation

**[REQ-MF-013]** Every manifest MUST be parsed inside its own `eval`. A manifest
that is malformed, unreadable, or throws MUST be logged with its path and the
reason, and MUST NOT prevent any other manifest from loading.

**[REQ-MF-014]** Every field the framework will use MUST be validated against a
strict pattern and **rebuilt from the capture** before use, because every value
read off disk is tainted [PVE-F-041]:

| Field | Pattern |
|---|---|
| `id` | `^([a-z0-9][a-z0-9_-]{0,63})$` |
| `backend.module` | `^([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*)$` |
| `frontend.assets[]` | `^([A-Za-z0-9][A-Za-z0-9._-]{0,127}\.js)$` |
| `order` | `^([0-9]{1,4})$` |
| `version` (as a cache token) | `^([A-Za-z0-9][A-Za-z0-9._+~-]{0,31})$` |

**[REQ-MF-015]** A field that fails validation MUST cause the smallest sensible
unit to be dropped — one asset, one daemon name, or the whole extension — and
MUST be logged naming the extension. It MUST NOT be coerced or repaired.

**[REQ-MF-016]** The manifest reader MUST open manifests as bytes and let the
JSON layer handle UTF-8. It MUST NOT use an `:encoding()` layer [PVE-F-040].

---

## 9. Package layout and file manifest

### 9.1 The framework package

**[REQ-PKG-001]** The `proxmod` package MUST install exactly this set of paths,
and MUST NOT install into any directory owned by another package:

| Path | Mode | Purpose |
|---|---|---|
| `/usr/share/perl5/Proxmod.pm` | 0644 | The `-M` entry point [REQ-FW-002] |
| `/usr/share/perl5/Proxmod/*.pm` | 0644 | `Boot`, `Log`, `Registry`, `API`, `Backend`, `Frontend`, `Patch` |
| `/usr/lib/proxmod/proxmod-exec` | **0755** | The `ExecStart` wrapper |
| `/usr/lib/proxmod/proxmod-reapply` | **0755** | Convergence |
| `/usr/lib/proxmod/proxmod-patch` | **0755** | [§17](#17-the-managed-patch-facility) |
| `/usr/sbin/proxmod-verify` | **0755** | Verification |
| `/usr/sbin/proxmodctl` | **0755** | Administration |
| `/usr/share/proxmod/loader-runtime.js` | 0644 | Loader template — deliberately *not* under `www/` [REQ-FE-018] |
| `/usr/share/proxmod/www/proxmod-ui.js` | 0644 | The `Proxmod` JS global |
| `/usr/share/proxmod/www/` | 0755 | **Shared** — extension packages install here |
| `/usr/share/proxmod/extensions.d/` | 0755 | **Shared** — extension packages install here |
| `/usr/share/proxmod/patches/` | 0755 | Example patch specs, all disabled |
| `/usr/share/proxmod/systemd/*.service.d/10-proxmod.conf` | 0644 | Drop-in sources, copied into `/etc` by `postinst` |
| `/usr/lib/systemd/system/proxmod-verify.service` | 0644 | Boot-time safety net |
| `/etc/proxmod/proxmod.conf` | 0644 | Conffile |
| `/etc/proxmod/extensions.d/`, `/etc/proxmod/patches/` | 0755 | Administrator overlays |
| `/var/lib/proxmod/` | 0755 | Runtime state: the reapply lock, the patch state DB |

**[REQ-PKG-002]** The build MUST restore mode 0755 on `/usr/lib/proxmod/*` and
`/usr/sbin/*` after `dh_fixperms`, which resets modes outside the recognised bin
directories to 0644. A 0644 `proxmod-exec` is not a cosmetic defect: it is both
daemons failing to start, with a systemd error that says nothing about proxmod.

**[REQ-PKG-003]** The systemd drop-ins MUST be installed into
`/etc/systemd/system/<unit>.service.d/` by `postinst` and MUST NOT be dpkg
conffiles. `prerm` has to remove the drop-in **before** dpkg deletes the wrapper
it names; a conffile is removed by dpkg on its own schedule, and a restart in the
window between the two would leave a daemon pointing at an `ExecStart` that no
longer exists.

**[REQ-PKG-004]** The package MUST use `debhelper-compat (= 13)`,
`Rules-Requires-Root: no`, and source format `3.0 (native)`.

**[REQ-PKG-005]** The package MUST NOT declare a version ceiling on
`pve-manager`. A `Breaks: pve-manager (>= 10~)` would block a legitimate major
upgrade of the hypervisor, which is a worse outcome than the failure it prevents.
The runtime seams probe and fail safe instead [REQ-FW-005], and
`proxmod-verify` reports.

**[REQ-PKG-006]** `dh_installsystemd` MUST be invoked with
`--no-restart-after-upgrade --no-stop-on-upgrade`. The trigger, the boot-time
unit and `postinst` all converge the host themselves; letting debhelper *also*
restart things would mean two mechanisms deciding when the daemons bounce.

### 9.2 The extension package

**[REQ-PKG-007]** An extension package MUST require **no maintainer scripts**.
It MUST declare `Depends: proxmod (>= <version>)` and ship at most three kinds of
file:

```
/usr/share/perl5/<Its>/<Own>/<Namespace>.pm      the backend module
/usr/share/proxmod/extensions.d/NN-<name>.conf   the manifest
/usr/share/proxmod/www/<name>.js                 the frontend asset
```

Writing into a watched directory activates proxmod's dpkg trigger, and
`proxmod-reapply` converges the host [§13](#13-update-survival-guarantees-and-non-guarantees).

**[REQ-PKG-008]** An extension package MUST NOT install a systemd drop-in for
`pvedaemon` or `pveproxy`, MUST NOT modify `/etc/proxmod/proxmod.conf`, and MUST
NOT call `proxmod-reapply`, `systemctl restart pveproxy`, or `proxmodctl` from a
maintainer script. Convergence is proxmod's job and doing it twice means two
restarts.

**[REQ-PKG-009]** An extension package MAY ship an example manifest in `/etc`
only if it is a conffile it owns. It MUST NOT write into
`/etc/proxmod/extensions.d/` at run time.

### 9.3 Removal

**[REQ-PKG-010]** `prerm` MUST remove proxmod's systemd drop-ins and restart the
wrapped daemons **stock** before dpkg removes any file the package owns.

**[REQ-PKG-011]** `postrm` MUST prune shared directories with `rmdir`, never
`rm -rf`. `/usr/share/proxmod/www` and `/usr/share/proxmod/extensions.d` hold
other packages' files, and dpkg removes those on its own schedule, which may be
after proxmod's removal. An `rmdir` that fails because the directory is not empty
is the correct outcome.

**[REQ-PKG-012]** `purge` MUST remove everything proxmod created at run time:
the reapply lock, the patch state database, patch backups, and the kill switch.
Backups MUST be enumerated from the state database, with a bounded sweep of
proxmod's own backup directory as a backstop — never a hardcoded list of paths
inside another package's directory.

**[REQ-PKG-013]** After `apt purge proxmod`, `dpkg -V pve-manager
libpve-common-perl libpve-http-server-perl` MUST be clean and both wrapped
daemons MUST be running.

---

## 10. Configuration

**[REQ-FW-022]** proxmod's configuration MUST be a single conffile,
`/etc/proxmod/proxmod.conf`, in `key = value` form with `#` comments.

| Key | Default | Meaning |
|---|---|---|
| `debug` | `0` | Log one line per extension per daemon start to the journal |

**[REQ-FW-023]** proxmod MAY additionally honour `PROXMOD_DEBUG` in the
environment, but MUST NOT rely on it: `pvedaemon` starts with a cleared
environment, so on a real host the config file is the switch that works. This is
stated explicitly because it is the trap the prior art fell into
[REQ-BE-022].

**[REQ-FW-024]** The kill switch MUST be the *existence* of
`/etc/proxmod/disabled`, not a value in a config file. It is checked by the
`ExecStart` wrapper before any proxmod Perl is loaded [REQ-FW-005], so it still
works when proxmod itself is broken — which is precisely when it is needed.

**[REQ-FW-025]** `Proxmod::Log` MUST parse the one setting it needs out of
`proxmod.conf` itself and MUST NOT depend on `Proxmod::Registry` or any config
layer. Everything else logs, including the code that reads the registry.

---

## 11. Security model

### 11.1 The trust boundary

**Anything proxmod loads runs as root inside `pvedaemon`, unsandboxed.** There
is no privilege separation, no capability drop and no confinement. The
consequences are stated plainly because the design depends on them being
understood:

**[REQ-SEC-001]** Every one of the following is, in effect, root-owned code on
the host. A non-root-owned or group/world-writable entry in any of them is
**unauthenticated remote root code execution**:

```
/usr/share/perl5/Proxmod.pm      /usr/share/proxmod
/usr/share/perl5/Proxmod         /usr/share/proxmod/www
/usr/lib/proxmod                 /usr/share/proxmod/extensions.d
/etc/proxmod                     /etc/proxmod/extensions.d
```

**[REQ-SEC-002]** The `ExecStart` wrapper MUST check, at every daemon start, that
each of those paths is owned by root and is neither group- nor world-writable,
and MUST start the daemon **uninjected** — logging each offending path — when
one is not. The extension disappears; the host does not.

**[REQ-SEC-003]** Installing an extension package MUST be understood as granting
that package root on the host. This is not different from any other Debian
package, and it is stated so that nobody mistakes proxmod's isolation of
*failures* ([REQ-FW-019]) for isolation of *privilege*. It is not.

### 11.2 Unauthenticated surfaces

**[REQ-SEC-004]** `/` and everything under `/proxmod/` are served without
authentication [PVE-F-023]. Nothing under `/usr/share/proxmod/www` may contain a
secret, a credential, an internal hostname, or any value not safe to publish.

**[REQ-SEC-005]** The generated `/proxmod/loader.js` MUST contain nothing but the
ids and URLs of the installed extension assets. Everything in it is public by
construction.

**[REQ-SEC-006]** A dynamic page handler registered in `{pages}` is reached
before authentication. proxmod MUST NOT register any handler there that reads
host state.

### 11.3 Taint and injection

**[REQ-SEC-007]** No value that came from disk may reach `require`, `eval
STRING`, `system`, `exec`, or an `open` for writing without being matched against
a strict pattern and rebuilt from the capture [PVE-F-041], [PVE-F-042].

**[REQ-SEC-008]** proxmod MUST NOT use `eval "require $module"` anywhere
[REQ-FW-021].

**[REQ-SEC-009]** Values interpolated into the generated loader MUST be
re-validated at the point of interpolation, not only at the point of parsing. The
cost is one regex; the cost of being wrong is script injection into the
administrative interface of a hypervisor.

### 11.4 Access control

**[REQ-SEC-010]** Access control for extension endpoints is PVE's, and is
declared per method [REQ-BE-014]. proxmod MUST NOT implement an access-control
layer of its own, and MUST NOT weaken PVE's: the framework's index endpoint is
`{ user => 'all' }` and lists extension ids and versions only.

**[REQ-SEC-011]** proxmod MUST NOT read or write `/etc/pve` from a maintainer
script, from `proxmod-reapply`, or from the boot-time unit — both because it is
FUSE and unreliable at those moments [REQ-BE-025], and because it holds the
cluster's authentication material.

### 11.5 Threats explicitly not mitigated

| Threat | Status |
|---|---|
| A malicious extension package | **Not mitigated.** It has root by construction [REQ-SEC-003] |
| A malicious administrator | Out of scope |
| An extension exhausting `pvedaemon`'s worker pool | Not mitigated; [REQ-BE-018] is guidance, not enforcement |
| Another framework winning the `ExecStart=` drop-in race | **Detected, not prevented** — [§13.3](#133-non-guarantees) |
| Local privilege escalation via a mis-permissioned proxmod path | Mitigated by [REQ-SEC-002], and reported by `proxmod-verify` |

---

## 12. Versioning and PVE compatibility

**[REQ-PKG-014]** proxmod MUST use semantic versioning. The **major** version
changes when the extension contract in [§6](#6-backend-extension-specification)
or [§7](#7-frontend-extension-specification) changes incompatibly; the minor
version when the contract grows; the patch version otherwise.

**[REQ-PKG-015]** An extension package MUST declare
`Depends: proxmod (>= X.Y)` naming the lowest version whose contract it uses.

**[REQ-PKG-016]** proxmod supports **Proxmox VE 9.x only**. PVE 8 is not
supported and is not tested; the seams differ.

**[REQ-FW-026]** Every seam proxmod attaches to MUST be probed before use, and a
missing seam MUST disable only the feature that needed it. proxmod MUST NOT
gate any behaviour on a parsed `pve-manager` version number: a version test is a
guess about the seam, and probing is the answer itself.

**[REQ-FW-027]** A seam that is absent MUST produce a warning naming the seam,
so that the first sign of an incompatible Proxmox release is a log line and a
red `proxmod-verify`, not a support request.

**Compatibility posture on a new PVE release**, in order:

1. `make facts ISO=…` and read `git diff docs/facts/` — the assumptions that moved.
2. `prove -r t/` — the unit tests run the real vendored `index.html.tpl`.
3. The QEMU suite under `test/qemu/`.
4. `proxmod-verify` on an upgraded host.

---

## 13. Update survival: guarantees and non-guarantees

This is proxmod's central claim, so it is stated as precisely as it can be.

### 13.1 Why there is nothing to reapply

**[REQ-PKG-017]** proxmod MUST NOT write to any path owned by another package.
It follows that a `pve-manager` upgrade cannot overwrite anything proxmod owns,
and that the "reapply the patches" step other approaches need **does not exist**
here. What can be lost on an upgrade is not a file but a *process state* — a
daemon restarted without `-MProxmod` — and that is what convergence addresses.

### 13.2 The convergence mechanisms

**[REQ-PKG-018]** The primary mechanism MUST be **dpkg triggers**, watching:

| Trigger | Fires when |
|---|---|
| `/usr/share/proxmod/extensions.d` | An extension package appears, changes, or goes away |
| `/etc/proxmod/extensions.d` | An administrator or config-management tool drops a manifest |
| `/usr/share/proxmod/www` | A frontend asset ships in a later upload than its manifest |
| `/usr/share/proxmod/patches`, `/etc/proxmod/patches` | A patch spec changes ([§17](#17-the-managed-patch-facility)) |
| `/usr/share/perl5/PVE` | Proxmox itself was upgraded — including `libpve-*`, which does not run pve-manager's reload |
| `proxmod-reapply` (named) | A package or an administrator asks explicitly, with `dpkg-trigger proxmod-reapply` |

All are `interest-noawait`: proxmod's `postinst` neither provides nor completes
anything the triggering package needs, so making it wait would only widen the
window in which an unrelated upgrade can be blocked by proxmod.

This choice is not incidental. The alternatives, and why they were rejected:

| Mechanism | Fires on `dpkg -i`? | Only when relevant? | Ordered by dpkg? | Verdict |
|---|---|---|---|---|
| dpkg file + named triggers | **yes** | yes, batched once per run | yes | **primary** — and Proxmox's own precedent [PVE-F-010] |
| APT `DPkg::Post-Invoke` | **no** | no, every apt run | no | rejected |
| systemd `PathChanged=` | indirectly | poorly, non-recursive | **no** — fires mid-unpack | rejected as primary |
| boot-time oneshot | n/a | n/a | n/a | **adopted as a complement** |

**[REQ-PKG-019]** A boot-time oneshot (`proxmod-verify.service`) MUST run
convergence after `pvedaemon` and `pveproxy`, covering what a trigger cannot see:
a host restored from backup or cloned from a template, a drop-in removed by hand,
a dpkg run interrupted between unpack and trigger processing, or a proxmod that
self-healed on the last boot for a cause since fixed.

**[REQ-PKG-020]** That unit MUST NOT depend on `pve-cluster`. `proxmod-reapply`
never reads `/etc/pve`, and making proxmod's recovery path depend on the cluster
filesystem being healthy would fail exactly when the web interface is most wanted
back.

### 13.3 Convergence semantics

**[REQ-PKG-021]** `proxmod-reapply` MUST be idempotent, MUST take an exclusive
lock, and MUST exit **0** from the trigger path under all circumstances. A
non-zero exit from a trigger can wedge an entire `apt dist-upgrade`.

**[REQ-PKG-022]** It MUST skip entirely when `/proxmox_install_mode` exists,
mirroring `pve-manager`'s own guard [PVE-F-005].

**[REQ-PKG-023]** It MUST restart the wrapped daemons **only** when something
actually changed, or when `proxmod-verify --live-only` reports that the running
daemons are not loading proxmod. A converger that restarts on every apt run is a
converger administrators disable.

**[REQ-PKG-024]** It MUST run `systemctl daemon-reload` only when a drop-in
actually changed.

**[REQ-PKG-025]** If a wrapped daemon does not come back after a proxmod-caused
restart, `proxmod-reapply` MUST remove its own drop-ins and restart that daemon
**unmodified**, then report failure. Self-healing to stock Proxmox is the
required outcome; leaving a hypervisor without its API is not.

**[REQ-PKG-026]** A failure in the managed patch facility MUST be reported in the
exit status only *after* every daemon is back up, and MUST NOT be able to reach
the self-healing path. A patch is an administrator's optional extra; it must not
be able to tear out the framework.

### 13.4 Guarantees

Given [REQ-PKG-017] through [REQ-PKG-026], proxmod guarantees that after an
`apt full-upgrade` that upgrades `pve-manager`:

| | |
|---|---|
| **U1** | `dpkg -V pve-manager libpve-common-perl libpve-http-server-perl` is clean |
| **U2** | No proxmod file was overwritten, because none is in a Proxmox-owned path |
| **U3** | The drop-ins are re-asserted and the daemons re-injected, by the trigger, by pve-manager's own reload landing on the overridden `ExecReload` [REQ-FW-008], or by the boot-time unit |
| **U4** | An apt run that changes nothing relevant causes **no restart** — `ExecMainStartTimestamp` is unchanged |
| **U5** | If any of this fails, the host is running stock Proxmox with a working API and web interface, and `proxmod-verify` is red |

### 13.5 Non-guarantees

Stated as plainly as the guarantees, because a framework that oversells this is
worse than one that does not exist.

| | |
|---|---|
| **N-U1** | A Proxmox release that moves or renames a seam will disable the feature that used it. proxmod detects and reports; it does not adapt |
| **N-U2** | A second framework that also overrides `ExecStart=` in a drop-in **does not compose**: the file that sorts last wins outright and the other silently stops loading. proxmod detects this and reports it as drift; it cannot prevent it. The mitigation available is to make the other mechanism a proxmod extension |
| **N-U3** | An extension whose own code is incompatible with a new Proxmox release is the extension's problem. proxmod isolates the failure; it does not fix it |
| **N-U4** | Nothing here is guaranteed across a **major** PVE upgrade (9 → 10). Re-verify [§12](#12-versioning-and-pve-compatibility) |
| **N-U5** | An administrator who enables a managed patch ([§17](#17-the-managed-patch-facility)) has opted out of U1 and U2 for the file they patched, by design and in writing |

---

## 14. Failure modes and fail-safe posture

**[REQ-FW-028]** Every failure mode MUST degrade toward stock Proxmox. The
following table is normative — it is the complete list of what each failure
costs:

| Failure | Cost | Daemons | Detected by |
|---|---|---|---|
| `Proxmod.pm` will not compile | everything | **start unmodified** (the wrapper probes first) | wrapper journal line, `proxmod-verify` |
| `Proxmod::Boot` dies | everything | start, injected but inert | `proxmod: error:` + missing `booted` line |
| Registry unreadable | all extensions | start | `could not read extension registry` |
| One manifest malformed | that extension | start | `manifest invalid, ignoring: <path>` |
| One extension's module does not compile | that extension | start | `extension <id>: not loaded` |
| `proxmod_register` dies | that extension | start | as above |
| A method registers but does not resolve | that endpoint | start | route post-check warning [REQ-BE-019] |
| The `get_index` seam is gone | all frontends | start | `index injection: not installed` |
| The `init` seam is gone | all frontends | start | `static routes: not installed` |
| The loader cannot be built | all frontends, this request | start | 200 + inert body, journal line [REQ-FE-014] |
| One asset missing on disk | that asset | start | `asset not installed, skipping it` |
| A guarded path is group-writable | everything | **start unmodified** | wrapper `error:` lines, `proxmod-verify` |
| Kill switch set | everything | start unmodified | `disabled by /etc/proxmod/disabled` |
| Another framework won the `ExecStart` race | everything | start, running the other framework | `proxmod-verify` drift check |
| A daemon fails to come back after our restart | everything | **drop-ins removed, restarted stock** | `proxmod-reapply` non-zero, unit failed |

**[REQ-FW-029]** Every wrapper installed on a Proxmox sub MUST call the original
**first**, MUST treat its own work as optional, and MUST return the original's
return value whatever happens to proxmod's half.

**[REQ-FW-030]** The frontend's two stages MUST be installed in the order
*routes, then injection*. If the routes fail, the injection is never reached, so
there is no tag pointing at a URL nothing serves; if the injection fails, the
routes are live but unreferenced, which costs nothing.

**[REQ-FW-031]** proxmod MUST NOT `die` out of any code path that runs inside a
daemon. Every entry point from PVE into proxmod is inside an `eval` with
`$SIG{__DIE__}` localised to `DEFAULT`, so that a PVE or extension `__DIE__`
handler cannot convert proxmod's contained failure into an uncontained one.

---

## 15. Observability and verification

### 15.1 Logging

**[REQ-FW-032]** All proxmod output from inside a daemon MUST go to STDERR,
which systemd wires to the journal. There is nothing to rotate and no permission
to get wrong, and proxmod's messages appear next to the PVE messages that explain
them.

**[REQ-FW-033]** Every line MUST be prefixed `proxmod:`, and a message MUST NOT
contain a newline — a wrapped line would produce a journal entry without the
prefix, which `proxmod-verify` would not see and an administrator would not
associate with proxmod. Multi-line messages MUST be collapsed.

**[REQ-FW-034]** The prefix and the `booted` line's shape are **contract**
between `Proxmod::Log`, `Proxmod::Boot` and `bin/proxmod-verify`. They MUST NOT
be changed in one place alone.

| Level | Shape | When |
|---|---|---|
| info | `proxmod: <msg>` | boot, mount, per-extension registration |
| warn | `proxmod: warn: <msg>` | something degraded; a feature is missing |
| error | `proxmod: error: <msg>` | something failed; extensions are missing |
| debug | `proxmod: debug: <msg>` | only when `debug = 1` [REQ-FW-022] |

### 15.2 `proxmod-verify`

**[REQ-FW-035]** The **primary** gate MUST be the journal of the *running
process*, read from the unit's last start onward:

```sh
journalctl -u <unit> --since "$(systemctl show -p ExecMainStartTimestamp --value <unit>)"
```

containing the `booted` line and no fail-safe line. It MUST NOT be a fresh
`perl -MProxmod -e1`.

This is the single most important requirement in this section, because the two
answers come apart exactly when it matters. A comparable tool for a single
endpoint shipped a check that ran a new `perl`, found the module loadable, and
reported success — while the module had in fact never once loaded inside the
daemon, because taint mode ignores `PERL5LIB` [PVE-F-002] and the injection was
never reaching it. A fresh interpreter cannot answer *"is the code serving
requests our code"*. Only the running process's own log can.

**[REQ-FW-036]** `proxmod-verify` MUST additionally check:

| Check | What it catches |
|---|---|
| installed | proxmod present, kill switch state |
| drift | the **live** `ExecStart`/`ExecReload` still resolve to proxmod's — this is the `ExecStart=` race, N-U2 |
| live | the primary gate above, per wrapped daemon |
| http | the index carries **exactly one** loader tag; `/proxmod/loader.js` and every declared asset return 200 |
| structure | a `find_handler` replay per registered route, catching greedy-param shadowing [REQ-BE-019] |

**[REQ-FW-037]** Findings MUST be levelled. Only `error` decides the exit status;
`warn` is reported but does not, because degradation is designed behaviour and an
administrator who deliberately disabled an extension MUST NOT get a red alert
for it.

**[REQ-FW-038]** Exit status MUST be `0` healthy, `1` something is wrong, `64`
bad usage. `--json` MUST produce the same findings machine-readably; `--quiet`
MUST produce no output.

**[REQ-FW-039]** `proxmod-verify` MUST produce a report on a broken host. A
missing `systemctl`, `journalctl` or `curl` MUST be a defined finding, not a
crash — the only host this tool is ever run on is a suspect one.

**[REQ-FW-040]** The documentation MUST state the **monitoring obligation** that
follows from silent failure: wire `proxmod-verify --json` into monitoring, and
re-run it after every `pve-manager` upgrade. A framework that fails invisibly and
does not say this is not fail-safe, it is merely quiet.

### 15.3 `proxmodctl`

**[REQ-FW-041]** `proxmodctl` MUST provide, and MUST NOT require an administrator
to know any of proxmod's paths to use:

| Command | Effect |
|---|---|
| `status`, `status --json` | `proxmod-verify` |
| `list` | The installed extensions |
| `reapply`, `reapply --force` | Converge; `--force` restarts even when nothing changed |
| `enable` / `disable` | Remove/create the kill switch and restart the daemons |
| `logs [-f]` | What proxmod said in the daemons' journals |
| `patch <sub>` | [§17](#17-the-managed-patch-facility) |
| `doctor` | `status` plus the context to paste into a bug report |

**[REQ-FW-042]** Any `proxmodctl` command that restarts a daemon MUST say so in
its help text, together with the fact that running guests are unaffected and open
web sessions reconnect.

---

## 16. Conformance checklist

An implementation, or a release, conforms when every row passes. "Unit" is
`prove -r t/`, which needs no Proxmox host; "QEMU" is `test/qemu/`.

### 16.1 Framework

| # | Requirement | How it is checked | Where |
|---|---|---|---|
| C-01 | [REQ-FW-001], [REQ-FW-002] | The drop-in's `ExecStart` names the wrapper; no `Environment=` anywhere | Unit `t/08`, QEMU |
| C-02 | [REQ-FW-005] | Wrapper `--dry-run` with a fake `systemctl` and a fake unit, once per fail-safe condition; each starts the daemon unmodified | Unit `t/08` |
| C-03 | [REQ-FW-006] | Probe uses `-c`; a `Proxmod::Boot` that dies still yields an injected command | Unit `t/08` |
| C-04 | [REQ-FW-008], [REQ-FW-009] | `systemctl reload pveproxy` **and** `deb-systemd-invoke reload-or-try-restart pveproxy.service` leave the tag present | QEMU |
| C-05 | [REQ-FW-010], [REQ-FW-012] | `Boot` made to die; the daemon starts and logs one `error:` line | Unit `t/01` |
| C-06 | [REQ-FW-014], [REQ-FW-024] | `touch /etc/proxmod/disabled` + restart: daemons active, no tag | Unit `t/08`, QEMU |
| C-07 | [REQ-FW-015] | `boot('pvestatd')` and `boot(undef)` outside a daemon load nothing | Unit `t/03` |
| C-08 | [REQ-FW-018], [REQ-FW-034] | The `booted` line's exact shape, asserted from both `Boot` and `proxmod-verify` | Unit `t/03`, `t/10` |
| C-09 | [REQ-FW-019], [REQ-FW-020] | A manifest naming a module that dies at `require`: both daemons active, the good extension registered, exactly one failure reported | Unit `t/05`, **QEMU** |
| C-10 | [REQ-FW-028], [REQ-FW-029] | Each wrapper made to throw; the original's return value is unchanged | Unit `t/06` |
| C-11 | [REQ-FW-031] | `Boot`, `Backend`, `Frontend` and `API` each localise `$SIG{__DIE__}` around their `eval`; a wrapper made to throw does not escape it | Unit `t/00`, `t/06` |

### 16.2 Backend

| # | Requirement | How it is checked | Where |
|---|---|---|---|
| C-20 | [REQ-BE-009], [REQ-BE-010] | Double `mount` is a no-op; a conflicting `mount` dies before PVE's registry is touched | Unit `t/04` |
| C-21 | [REQ-BE-011] | With the parent class moved, the probe mismatch is logged | Unit `t/04` |
| C-22 | [REQ-BE-014] | `add_method` with no `permissions` key dies with an actionable message | Unit `t/04` |
| C-23 | [REQ-BE-015] | `user => 'world'` registers **and** warns | Unit `t/04` |
| C-24 | [REQ-BE-019] | A greedy-subtree route resolves to the right class and wrong method, and is reported as shadowed | Unit `t/04` |
| C-25 | [REQ-BE-021] | The same `(class, method, path)` twice is a debug no-op, not a die | Unit `t/04` |
| C-26 | [REQ-FW-021], [REQ-SEC-008] | No `eval "require` in the tree; a tainted module name is rejected before `require` | Unit `t/00`, `t/05` |
| C-27 | end-to-end | Install `proxmod-example-hello`; the endpoint returns 200 and the journal shows registration | **QEMU** |

### 16.3 Frontend

| # | Requirement | How it is checked | Where |
|---|---|---|---|
| C-40 | [REQ-FE-001], [REQ-FE-003] | Injection against the **real vendored** `index.html.tpl`: exactly one tag, at the correct anchor | Unit `t/06` |
| C-41 | [REQ-FE-005] | Injecting twice yields one tag | Unit `t/06` |
| C-42 | [REQ-FE-006] | No-op against the vendored noVNC and xterm.js bodies | Unit `t/06` |
| C-43 | [REQ-FE-008] | With no frontend extension, the body is byte-identical to Proxmox's | Unit `t/06` |
| C-44 | [REQ-FE-010] | `dirs` is assigned a literal; `add_dirs` is not called anywhere | Unit `t/06`, `t/00` |
| C-45 | [REQ-FE-012], [REQ-FE-013] | The loader is generated from the registry and is byte-stable for an identical registry | Unit `t/06` |
| C-46 | [REQ-FE-014] | A broken runtime template yields 200 and an inert body | Unit `t/06` |
| C-47 | [REQ-FE-015] | Asset names with `/`, `..`, or no `.js` are refused | Unit `t/02`, `t/06` |
| C-48 | live | The served index carries exactly one loader tag; `/proxmod/loader.js` → 200 | **QEMU** |
| C-49 | [REQ-FE-012] | Installing a frontend-only extension takes effect with **no** daemon restart | QEMU |

### 16.4 Manifest and registry

| # | Requirement | How it is checked | Where |
|---|---|---|---|
| C-60 | [REQ-MF-006], [REQ-MF-007] | `/etc` overrides and masks by basename | Unit `t/02` |
| C-61 | [REQ-MF-011] | Order is `order` then basename, independent of `readdir` order | Unit `t/02` |
| C-62 | [REQ-MF-012] | A missing or circular `requires` drops the extension and its dependents | Unit `t/02` |
| C-63 | [REQ-MF-013] | A malformed manifest never costs another manifest | Unit `t/02` |
| C-64 | [REQ-MF-014] | Each pattern rejects its adversarial input | Unit `t/02` |
| C-65 | [REQ-MF-016] | No `:encoding(` on a path derived from `readdir` anywhere | Unit `t/00` |

### 16.5 Packaging and update survival

| # | Requirement | How it is checked | Where |
|---|---|---|---|
| C-80 | [REQ-PKG-001] | `make install DESTDIR=…` produces exactly the specified manifest | Unit |
| C-81 | [REQ-PKG-002] | `/usr/lib/proxmod/*` and `/usr/sbin/*` are 0755 in the built `.deb` | Unit, `lintian` |
| C-82 | [REQ-PKG-017] — **the headline test** | After install: `dpkg -V pve-manager libpve-common-perl libpve-http-server-perl` clean, and the sha256 of every dpkg-owned file under `/usr/share/pve-manager` and `/usr/share/perl5/PVE` unchanged | **QEMU** |
| C-83 | [REQ-PKG-018] | Installing an extension with `dpkg -i` (not apt) converges the host | QEMU |
| C-84 | U3 | Repack the real `pve-manager` deb as a higher version and `apt install` it — exercising prerm/postinst/triggers, not a reinstall: verify 0, tag present, endpoint answers, `dpkg -V` clean | **QEMU** |
| C-85 | U4 | A no-op apt run leaves `ExecMainStartTimestamp` **unchanged** | QEMU |
| C-86 | [REQ-PKG-025] | A daemon that will not come back: drop-ins removed, daemon restarted stock, non-zero exit | Unit `t/09` |
| C-87 | [REQ-PKG-021] | `proxmod-reapply` exits 0 from the trigger path even when convergence failed | Unit `t/09` |
| C-88 | [REQ-PKG-010]–[REQ-PKG-013] | `apt purge`: drop-ins gone, daemons active, `dpkg -V pve-manager` clean, another package's file under `/usr/share/proxmod/www` untouched | **QEMU** |
| C-89 | [REQ-SEC-011] | The string `/etc/pve` appears in no maintainer script, in `proxmod-reapply`, or in the boot-time unit | Unit `t/09` |

### 16.6 Security

| # | Requirement | How it is checked | Where |
|---|---|---|---|
| C-100 | [REQ-SEC-002] | `chmod g+w /usr/share/perl5/Proxmod.pm` + restart: daemon active, **not** injected, `proxmod-verify` fails loudly | Unit `t/08`, **QEMU** |
| C-101 | [REQ-SEC-005] | The generated loader contains nothing but ids and URLs | Unit `t/06` |
| C-102 | [REQ-SEC-009] | An adversarial id or version in a manifest cannot reach the loader body | Unit `t/06` |

### 16.7 Managed patches

| # | Requirement | How it is checked | Where |
|---|---|---|---|
| C-120 | [REQ-FW-100] | Every shipped spec is disabled, **and** validates against the production allowlist | Unit `t/07` |
| C-121 | [REQ-FW-104] — regression *stale-backup-restored-over-newer-file* | The backup is re-taken on every apply; a revert after an upgrade never restores a pre-upgrade file | Unit `t/07` |
| C-122 | [REQ-FW-106] — regression *revert-on-upgrade* | `prerm`'s `remove` branch reverts; its `upgrade` branch does not | Unit `t/07` |
| C-123 | [REQ-FW-107] — regression *leaked-backup* | Purge clears every backup; none is left in a Proxmox directory | Unit `t/07` |
| C-124 | [REQ-FW-102] | `/etc/pve` is refused even with the allowlist widened | Unit `t/07` |
| C-125 | [REQ-FW-108] | Nothing loaded inside a daemon references `Proxmod::Patch` | Unit `t/07` |
| C-126 | [REQ-PKG-026] | A failing patch never tears out the drop-ins and never causes a restart | Unit `t/09` |

---

## 17. The managed patch facility

Read [§13.5](#135-non-guarantees) first. Enabling anything in this section opts
the patched file out of every guarantee in [§13.4](#134-guarantees).

### 17.1 Why it exists at all

Some things cannot be done from a seam. When that is true, the alternative to a
managed patch is not "no patch" — it is an administrator with `sed` in a cron
job, with no record of what changed, no checksum, and no way to undo it. This
facility exists so that the escape hatch has a state database, checksums,
backups taken at the right moment, and a `revert` that is safe. It is
deliberately unattractive, it ships **inert**, and no extension can reach it.

The design is shaped by four defects confirmed in prior art that patched Proxmox
files, and each has a regression test named for it ([§16.7](#167-managed-patches)).

### 17.2 Requirements

**[REQ-FW-100]** Every patch spec proxmod ships MUST be disabled. A spec's
`enabled` field MUST be **explicit**: absent means disabled. (The opposite of a
manifest [REQ-MF-010], because the failure modes are opposite.)

**[REQ-FW-101]** Patch specs MUST be read from
`/usr/share/proxmod/patches` and `/etc/proxmod/patches`, and MUST be converged
only by `proxmod-reapply` and `proxmodctl`.

**[REQ-FW-102]** A spec MUST be refused unless its target is an absolute path,
free of `..` and newlines, **inside** an explicit allowlist of Proxmox-owned
roots, and **outside** an explicit denylist. The denylist MUST include
`/etc/pve` and MUST be honoured even if the allowlist is widened.

| Allowlist | Denylist |
|---|---|
| `/usr/share/pve-manager` | `/etc/pve` |
| `/usr/share/perl5/PVE` | |
| `/usr/share/javascript/proxmox-widget-toolkit` | |

**[REQ-FW-103]** A target MUST additionally be refused if it is a symlink, does
not exist, is not owned by root, or is group- or world-writable. Patching a
writable root-loaded file would convert a patch facility into a privilege
escalation.

**[REQ-FW-104]** The backup MUST be taken **on every apply**, from the file as
it is at that moment, and MUST NOT be reused from a previous apply. This single
line is the *stale-backup* defect: the prior art kept the first backup it ever
took, so after a Proxmox upgrade its backup was a pre-upgrade file, and reverting
**downgraded the host**.

**[REQ-FW-105]** Every applied patch MUST be delimited by
`proxmod:begin <id>` / `proxmod:end <id>` markers in the target's comment
syntax, MUST be idempotent, and MUST NOT rewrite the file (or change its mtime)
when the block is already present and current.

**[REQ-FW-106]** `revert` MUST restore the backup **only** when both the current
file and the backup match the checksums recorded at apply time. Otherwise it MUST
remove proxmod's own delimited block in place, log why, and leave the rest of the
file alone. Restoring a backup over a file that has since changed is how the
prior art downgraded a host.

**[REQ-FW-107]** `prerm` MUST revert on `remove` and `deconfigure` and MUST NOT
revert on `upgrade`. `postrm purge` MUST leave no backup behind. Backups MUST
live under `/var/lib/proxmod/backups`, never beside the original — the prior art
left `Hardware.pm.pre-gpu` in a Proxmox directory forever, with nothing on the
host to explain it.

**[REQ-FW-108]** `Proxmod::Patch` MUST NOT be reachable from any module loaded
inside a daemon. It runs from a CLI and from convergence only.

**[REQ-FW-109]** All writes MUST be atomic (write-then-rename) and backups MUST
be mode 0600.

**[REQ-FW-110]** A patch failure MUST NOT prevent proxmod's own convergence from
completing, MUST NOT cause a restart on its own beyond the one a changed file
justifies, and MUST be visible in `proxmodctl patch status` and in the exit
status only after every daemon is up [REQ-PKG-026].

### 17.3 What it is not

It is not an extension mechanism [REQ-BE-002]. A manifest cannot request a
patch, an extension package MUST NOT ship an enabled spec, and no part of the
extension contract in [§6](#6-backend-extension-specification) or
[§7](#7-frontend-extension-specification) depends on it. If a feature needs a
patch, the correct first response is to ask Proxmox for a seam.

---

## 18. References

### Within this repository

| Document | Contents |
|---|---|
| [`pve-facts.md`](pve-facts.md) | The fact ledger — every `[PVE-F-nnn]` cited above, with evidence |
| [`facts/`](facts/) | Raw evidence, regenerable offline with `make facts` |
| `pve-internals.md` | How Proxmox VE actually works: processes, request lifecycle, the REST tree, the UI build, and a seam inventory labelling what is official and what is not |
| `backend-extensions.md` | Writing a backend extension, end to end |
| `frontend-extensions.md` | Writing a frontend extension, end to end |
| `packaging.md` | The two package shapes, maintainer-script ordering, triggers vs APT hooks |
| `patching.md` | The escape hatch, and the full post-mortem of the prior art |
| `perl-api.md`, `js-api.md` | Reference for `Proxmod::API` and the `Proxmod` global |
| `security.md`, `verification.md`, `troubleshooting.md`, `compatibility.md` | Operational guidance |
| `adr/` | Architecture decision records, notably `0001-runtime-injection-over-file-patching` |
| `examples/proxmod-example-hello/` | A complete, buildable extension package — the contract in executable form |

### Proxmox source read for this specification

All read offline from `proxmox-ve_9.1-1.iso` with `scripts/extract-pve-source.sh`:

| Package | Files |
|---|---|
| `pve-manager` | `usr/bin/{pveproxy,pvedaemon,pvestatd}`, `PVE/Service/{pveproxy,pvedaemon}.pm`, `PVE/HTTPServer.pm`, `usr/share/pve-manager/index.html.tpl`, `js/pvemanagerlib.js`, `DEBIAN/{postinst,triggers}` |
| `libpve-http-server-perl` | `PVE/APIServer/AnyEvent.pm` |
| `libpve-common-perl` | `PVE/RESTHandler.pm` |
| `libpve-access-control` | `PVE/RPCEnvironment.pm` |

### External

- Debian Policy Manual §6 (maintainer scripts) and §7 (dependencies)
- `deb-triggers(5)`, `dpkg-trigger(1)`
- `systemd.unit(5)`, `systemd.service(5)` — drop-in and `ExecStart=` reset semantics
- `perlsec(1)` — taint mode
- ExtJS 7.0.0 documentation — `Ext.define`, `override`, `callParent`

---

## Appendix A — reserved namespaces

Reserved to proxmod. An extension MUST NOT use any of these [REQ-BE-001].

| Namespace | Reserved for |
|---|---|
| REST path segment `proxmod` under `/nodes/{node}/` and `/cluster/` | The framework's mount points |
| Extension ids `proxmod`, `proxmod-*` | The framework |
| Perl package `Proxmod` and `Proxmod::*` | The framework |
| JavaScript global `Proxmod` | The framework |
| CSS prefix `proxmod-ui-` | The framework. Extensions use `proxmod-<id>-` |
| URL prefix `/proxmod/` | Asset serving. `/proxmod/loader.js` is the framework's |
| Asset filename `proxmod-ui.js` | The framework |
| Journal prefix `proxmod:` | The framework and its extensions' framework-mediated messages |
| Files `/usr/share/proxmod/loader-runtime.js`, `/usr/lib/proxmod/*`, `/usr/sbin/proxmod*` | The framework |
| dpkg trigger name `proxmod-reapply` | The framework (an extension MAY *activate* it; none needs to) |
| Systemd units `proxmod-*.service` | The framework |
| Patch spec ids and marker `proxmod:begin`/`proxmod:end` | [§17](#17-the-managed-patch-facility) |

Owned by Proxmox and never written by proxmod or an extension: `/etc/pve`
(anything at all), `/usr/share/pve-manager/*`, `/usr/share/perl5/PVE/*`,
`/usr/share/javascript/*`, and any systemd unit not named `proxmod-*` — except
proxmod's own drop-ins under `/etc/systemd/system/pve{daemon,proxy}.service.d/`.

---

## Appendix B — manifest JSON Schema

Normative for [§8](#8-manifest-and-registry). The parser additionally accepts
`//` and `#` comments and trailing commas [REQ-MF-009], which JSON Schema cannot
express.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/CrunchyMonkies/proxmod/schema/manifest-1.json",
  "title": "proxmod extension manifest",
  "type": "object",
  "required": ["id"],
  "additionalProperties": false,
  "properties": {
    "id": {
      "type": "string",
      "pattern": "^[a-z0-9][a-z0-9_-]{0,63}$",
      "description": "Unique across the host. Appears in REST paths, log lines and JavaScript; not a display name."
    },
    "version": {
      "type": "string",
      "pattern": "^[A-Za-z0-9][A-Za-z0-9._+~-]{0,31}$",
      "default": "0",
      "description": "Informational, and the cache-busting token on this extension's asset URLs."
    },
    "enabled": {
      "type": "boolean",
      "default": true,
      "description": "Absent means enabled. Set false to keep a manifest installed but inert."
    },
    "order": {
      "type": "integer",
      "minimum": 0,
      "maximum": 9999,
      "default": 50,
      "description": "Load order. Ties are broken by manifest basename, never by readdir order."
    },
    "requires": {
      "type": "array",
      "default": [],
      "items": { "type": "string", "pattern": "^[a-z0-9][a-z0-9_-]{0,63}$" },
      "description": "Extension ids that must load first. A missing or circular dependency drops this extension and everything depending on it."
    },
    "backend": {
      "type": "object",
      "required": ["module"],
      "additionalProperties": false,
      "properties": {
        "module": {
          "type": "string",
          "pattern": "^[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*$",
          "description": "Perl package defining proxmod_register(). Reached by require() inside a daemon under -T, so it is untainted against this pattern first."
        },
        "daemons": {
          "type": "array",
          "default": ["pvedaemon", "pveproxy"],
          "minItems": 1,
          "uniqueItems": true,
          "items": { "enum": ["pvedaemon", "pveproxy"] },
          "description": "Both is the default and almost always right: pveproxy answers unprotected methods itself."
        }
      }
    },
    "frontend": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "assets": {
          "type": "array",
          "default": [],
          "items": {
            "type": "string",
            "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\\.js$"
          },
          "description": "Bare filenames under /usr/share/proxmod/www. No directories: this name is interpolated into a URL pveproxy serves without authentication."
        }
      }
    }
  },
  "anyOf": [
    { "required": ["backend"] },
    { "required": ["frontend"] }
  ]
}
```

---

## Appendix C — requirement index

### `FW` — framework

| ID | Summary | § |
|---|---|---|
| REQ-FW-001 | Inject via command-line `-M`, never an environment variable | 5.1 |
| REQ-FW-002 | Modules live in a default `@INC` directory | 5.1 |
| REQ-FW-003 | `ExecStart` names a wrapper that reads the real command at start time | 5.1 |
| REQ-FW-004 | The wrapper reads the base unit, never the merged configuration | 5.1 |
| REQ-FW-005 | Nine fail-safe conditions, each starting the daemon as shipped | 5.1 |
| REQ-FW-006 | Probe with `-c`, and only `Proxmod` | 5.1 |
| REQ-FW-007 | Refuse an unknown service name outright (exit 64) | 5.1 |
| REQ-FW-008 | `ExecReload` overridden to a full restart | 5.2 |
| REQ-FW-009 | The reload override is `--no-block` and failure-tolerant | 5.2 |
| REQ-FW-010 | `Proxmod.pm` is trivial and does no work | 5.3 |
| REQ-FW-011 | Work happens in `INIT`, not compile or run time | 5.3 |
| REQ-FW-012 | `Boot` is loaded at runtime inside an `eval` | 5.3 |
| REQ-FW-013 | `boot()` is idempotent per process | 5.3 |
| REQ-FW-014 | The kill switch loads nothing | 5.3 |
| REQ-FW-015 | Load nothing outside `pvedaemon`/`pveproxy` | 5.3 |
| REQ-FW-016 | Each boot stage is independently contained | 5.3 |
| REQ-FW-017 | The frontend stage runs in `pveproxy` only | 5.3 |
| REQ-FW-018 | Exactly one `booted daemon=… extensions=… failed=…` line | 5.3 |
| REQ-FW-019 | Per-extension `eval` isolation | 6.5 |
| REQ-FW-020 | A failed extension logs once and is counted | 6.5 |
| REQ-FW-021 | Never `eval "require $module"` | 6.5 |
| REQ-FW-022 | One conffile, `key = value` | 10 |
| REQ-FW-023 | Never depend on an environment variable | 10 |
| REQ-FW-024 | The kill switch is a file's existence, checked before any Perl | 10 |
| REQ-FW-025 | `Proxmod::Log` depends on nothing of proxmod's | 10 |
| REQ-FW-026 | Probe seams; never gate on a parsed PVE version | 12 |
| REQ-FW-027 | A missing seam warns, naming the seam | 12 |
| REQ-FW-028 | The normative failure table | 14 |
| REQ-FW-029 | Wrappers call the original first and return its value | 14 |
| REQ-FW-030 | Routes are installed before injection | 14 |
| REQ-FW-031 | Never `die` out of a daemon code path | 14 |
| REQ-FW-032 | Log to STDERR, which is the journal | 15.1 |
| REQ-FW-033 | Prefix `proxmod:`; never a newline in a message | 15.1 |
| REQ-FW-034 | Prefix and `booted` shape are cross-program contract | 15.1 |
| REQ-FW-035 | The primary gate is the running process's journal | 15.2 |
| REQ-FW-036 | The five verification checks | 15.2 |
| REQ-FW-037 | Only `error` decides the exit status | 15.2 |
| REQ-FW-038 | Exit 0 / 1 / 64; `--json`, `--quiet` | 15.2 |
| REQ-FW-039 | Produce a report on a broken host | 15.2 |
| REQ-FW-040 | State the monitoring obligation | 15.2 |
| REQ-FW-041 | `proxmodctl`'s command set | 15.3 |
| REQ-FW-042 | Restarting commands say so | 15.3 |
| REQ-FW-100 | Shipped patch specs are disabled; `enabled` is explicit | 17.2 |
| REQ-FW-101 | Spec locations, converged only by reapply and ctl | 17.2 |
| REQ-FW-102 | Target allowlist and denylist; `/etc/pve` always refused | 17.2 |
| REQ-FW-103 | Refuse symlinks, non-root-owned and writable targets | 17.2 |
| REQ-FW-104 | Re-take the backup on every apply | 17.2 |
| REQ-FW-105 | Delimited, idempotent, mtime-stable | 17.2 |
| REQ-FW-106 | Revert only on a checksum match; otherwise remove the block | 17.2 |
| REQ-FW-107 | Revert on remove, never on upgrade; backups outside Proxmox dirs | 17.2 |
| REQ-FW-108 | `Proxmod::Patch` is unreachable from a daemon | 17.2 |
| REQ-FW-109 | Atomic writes, 0600 backups | 17.2 |
| REQ-FW-110 | A patch failure cannot damage the framework | 17.2 |

### `BE` — backend extensions

| ID | Summary | § |
|---|---|---|
| REQ-BE-001 | The namespace rule, across all five surfaces | 4.2 |
| REQ-BE-002 | Never write another package's files | 4.2 |
| REQ-BE-003 | proxmod claims one path segment per scope | 4.2 |
| REQ-BE-004 | Register in both daemons | 5.4 |
| REQ-BE-005 | `proxmod_register($api)` is the entry point | 6.1 |
| REQ-BE-006 | The module compiles standalone | 6.1 |
| REQ-BE-007 | `proxmod_register` is safe to call twice | 6.1 |
| REQ-BE-008 | Never call `register_method` directly | 6.1 |
| REQ-BE-009 | Mount via `$api->mount` | 6.2 |
| REQ-BE-010 | `mount` is idempotent; a conflict dies before PVE is touched | 6.2 |
| REQ-BE-011 | Probe the mount through `find_handler` | 6.2 |
| REQ-BE-012 | Never mount under a greedy `fragmentDelimiter => ''` subtree | 6.2 |
| REQ-BE-013 | Never mix named folders and a `{param}` at one level | 6.2 |
| REQ-BE-014 | **Every method carries a `permissions` key** | 6.3 |
| REQ-BE-015 | `world` warns | 6.3 |
| REQ-BE-016 | `protected => 1` only when root is genuinely needed | 6.3 |
| REQ-BE-017 | Declare `proxyto` rather than assuming the node | 6.3 |
| REQ-BE-018 | Long work goes through `fork_worker` | 6.3 |
| REQ-BE-019 | Post-check the route by reference identity | 6.3 |
| REQ-BE-020 | `GET`/`POST`/`PUT`/`DELETE` only | 6.3 |
| REQ-BE-021 | Duplicate registration is a no-op, not a die | 6.3 |
| REQ-BE-022 | Never depend on the environment | 6.4 |
| REQ-BE-023 | Untaint everything read from disk | 6.4 |
| REQ-BE-024 | No `:encoding()` on a tainted path | 6.4 |
| REQ-BE-025 | No `/etc/pve` on a startup path | 6.4 |

### `FE` — frontend extensions

| ID | Summary | § |
|---|---|---|
| REQ-FE-001 | Exactly one injected tag; extensions cannot add their own | 7.1 |
| REQ-FE-002 | Injected by wrapping `get_index`, never by editing a file | 7.1 |
| REQ-FE-003 | Anchored before the `Ext.onReady` block | 7.1 |
| REQ-FE-004 | One fallback anchor, then leave the page alone | 7.1 |
| REQ-FE-005 | Injection is idempotent | 7.1 |
| REQ-FE-006 | Structural no-op on the non-index pages | 7.1 |
| REQ-FE-007 | Never touch `Content-Length` | 7.1 |
| REQ-FE-008 | Zero footprint with no frontend extension | 7.1 |
| REQ-FE-009 | One flat asset directory under `/proxmod/` | 7.2 |
| REQ-FE-010 | Route added as a literal; never `add_dirs` | 7.2 |
| REQ-FE-011 | The loader is a `{pages}` entry | 7.2 |
| REQ-FE-012 | Generated per request from the live registry | 7.2 |
| REQ-FE-013 | Byte-stable for an identical registry | 7.2 |
| REQ-FE-014 | A loader failure is a 200 with an inert body | 7.2 |
| REQ-FE-015 | Asset filename pattern, re-checked on the way out | 7.2 |
| REQ-FE-016 | A missing asset is logged against its extension | 7.2 |
| REQ-FE-017 | `proxmod-ui.js` first, then registry order | 7.2 |
| REQ-FE-018 | The loader template is not served | 7.2 |
| REQ-FE-019 | ES5, global scope, no loader, no parse-time throw | 7.3 |
| REQ-FE-020 | Use the `Proxmod` global, not `PVE.*` directly | 7.3 |
| REQ-FE-021 | Every `spec` carries `ext` and an `xtype` | 7.3 |
| REQ-FE-022 | Namespaced, host-unique `itemId` | 7.3 |
| REQ-FE-023 | Never share a `groups` array with `insertNodes` | 7.3 |
| REQ-FE-024 | `callParent` first | 7.3 |
| REQ-FE-025 | Nothing secret in an asset | 7.3 |
| REQ-FE-026 | Encode everything rendered | 7.3 |
| REQ-FE-027 | Every config-panel target, with its identity forwarded | 7.4 |
| REQ-FE-028 | A menu item is a screen or a section | 7.4 |
| REQ-FE-029 | Menu items land at the bottom; PVE's own are not reordered | 7.4 |
| REQ-FE-030 | Parent before children, or no children at all | 7.4 |
| REQ-FE-031 | Deterministic ordering: weight, then registration | 7.4 |
| REQ-FE-032 | One shared parent by default; standalone is opt-in | 7.4 |
| REQ-FE-033 | A parent card with no sections renders a placeholder | 7.4 |

### `MF` — manifest and registry

| ID | Summary | § |
|---|---|---|
| REQ-MF-001 | Extension id pattern and uniqueness | 4.1 |
| REQ-MF-002 | The id is an identifier, not a display name | 4.1 |
| REQ-MF-003 | A duplicate id shadows and is logged | 4.1 |
| REQ-MF-004 | Declare a backend, a frontend, or both | 4.3 |
| REQ-MF-005 | Two directories, package then administrator | 8.1 |
| REQ-MF-006 | Precedence by basename | 8.1 |
| REQ-MF-007 | Masking is allowed and reported | 8.1 |
| REQ-MF-008 | `NN-<name>.conf` naming | 8.1 |
| REQ-MF-009 | Relaxed JSON | 8.2 |
| REQ-MF-010 | `enabled` absent means enabled | 8.2 |
| REQ-MF-011 | Deterministic load order | 8.2 |
| REQ-MF-012 | A broken dependency drops the dependents too | 8.2 |
| REQ-MF-013 | Per-manifest `eval` | 8.3 |
| REQ-MF-014 | Validate and rebuild every used field | 8.3 |
| REQ-MF-015 | Drop the smallest unit; never coerce | 8.3 |
| REQ-MF-016 | Read bytes, not `:encoding()` | 8.3 |

### `PKG` — packaging

| ID | Summary | § |
|---|---|---|
| REQ-PKG-001 | The framework's exact file manifest | 9.1 |
| REQ-PKG-002 | Restore 0755 after `dh_fixperms` | 9.1 |
| REQ-PKG-003 | Drop-ins installed by `postinst`, not as conffiles | 9.1 |
| REQ-PKG-004 | debhelper 13, `Rules-Requires-Root: no`, native format | 9.1 |
| REQ-PKG-005 | No version ceiling on `pve-manager` | 9.1 |
| REQ-PKG-006 | `dh_installsystemd` does not restart | 9.1 |
| REQ-PKG-007 | An extension package needs no maintainer scripts | 9.2 |
| REQ-PKG-008 | An extension package never converges the host itself | 9.2 |
| REQ-PKG-009 | No run-time writes into `/etc/proxmod/extensions.d` | 9.2 |
| REQ-PKG-010 | `prerm` removes drop-ins and restarts stock first | 9.3 |
| REQ-PKG-011 | Prune with `rmdir`, never `rm -rf` | 9.3 |
| REQ-PKG-012 | Purge removes runtime state and backups from the state DB | 9.3 |
| REQ-PKG-013 | After purge, `dpkg -V` is clean and the daemons run | 9.3 |
| REQ-PKG-014 | Semantic versioning tied to the extension contract | 12 |
| REQ-PKG-015 | Extensions depend on the version whose contract they use | 12 |
| REQ-PKG-016 | PVE 9.x only | 12 |
| REQ-PKG-017 | Never write a path owned by another package | 13.1 |
| REQ-PKG-018 | dpkg triggers are the primary mechanism | 13.2 |
| REQ-PKG-019 | A boot-time oneshot complements them | 13.2 |
| REQ-PKG-020 | That unit does not depend on `pve-cluster` | 13.2 |
| REQ-PKG-021 | Idempotent, locked, always exits 0 from a trigger | 13.3 |
| REQ-PKG-022 | Skip during `/proxmox_install_mode` | 13.3 |
| REQ-PKG-023 | Restart only when something changed or the live check fails | 13.3 |
| REQ-PKG-024 | `daemon-reload` only on a real change | 13.3 |
| REQ-PKG-025 | Self-heal to stock if a daemon does not come back | 13.3 |
| REQ-PKG-026 | A patch failure cannot reach the self-healing path | 13.3 |

### `SEC` — security

| ID | Summary | § |
|---|---|---|
| REQ-SEC-001 | The eight paths that are root code | 11.1 |
| REQ-SEC-002 | The wrapper refuses to inject over a writable guarded path | 11.1 |
| REQ-SEC-003 | Installing an extension grants it root | 11.1 |
| REQ-SEC-004 | `/` and `/proxmod/` are unauthenticated | 11.2 |
| REQ-SEC-005 | The loader contains ids and URLs only | 11.2 |
| REQ-SEC-006 | No `{pages}` handler reads host state | 11.2 |
| REQ-SEC-007 | Untaint before `require`, `exec`, or a write | 11.3 |
| REQ-SEC-008 | Never `eval "require …"` | 11.3 |
| REQ-SEC-009 | Re-validate at the point of interpolation | 11.3 |
| REQ-SEC-010 | Access control is PVE's, declared per method | 11.4 |
| REQ-SEC-011 | Never touch `/etc/pve` from a script or at boot | 11.4 |
