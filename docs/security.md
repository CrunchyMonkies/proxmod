# Security model

**Status:** Draft
**Applies to:** proxmod 0.2.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the refusals and validations below are implemented in
[`exec/proxmod-exec`](../exec/proxmod-exec),
[`perl/Proxmod/Registry.pm`](../perl/Proxmod/Registry.pm),
[`perl/Proxmod/API.pm`](../perl/Proxmod/API.pm) and
[`perl/Proxmod/Patch.pm`](../perl/Proxmod/Patch.pm); tested in `t/00`, `t/03`,
`t/04`, `t/07`, `t/08`

---

## 1. The one sentence

**Everything proxmod loads runs as root inside `pvedaemon`.**

`/usr/share/perl5/Proxmod*`, `/usr/share/proxmod/extensions.d/`, `/etc/proxmod/`
and anything named by `ExecStart=` are executable-equivalent paths on a
hypervisor. A file in any of them that a non-root user can write is
**unauthenticated remote root on every guest this host runs**, because root on
the hypervisor is root on all of them.

Every rule below follows from that sentence.

---

## 2. Trust boundaries

| Boundary | Who is on the far side | Enforced by |
|---|---|---|
| The network → `pveproxy` | anyone who can reach :8006 | PVE ticket auth, then ACLs |
| `pveproxy` → `pvedaemon` | `www-data` → root | `protected => 1` and a localhost socket [PVE-F-053] |
| The filesystem → proxmod | anyone who can write those paths | `proxmod-exec`'s permission refusal |
| A manifest → `require` | whoever installed the extension package | strict package-name capture |
| An extension → PVE's API tree | the extension author | `mount` namespacing, and the permissions check |
| proxmod → the browser | every logged-in user, and every logged-out one | output encoding, and no secrets in assets |

Two of these are unusual and worth stating plainly.

**`/` and everything under `/proxmod/` are served without authentication**
[PVE-F-023]. The index, `loader.js`, `proxmod-ui.js` and every extension asset
are readable by anyone who can reach port 8006, logged in or not.

**`pveproxy` runs as `www-data`, not root** [PVE-F-053]. It enforces
permissions *before* proxying anything to `pvedaemon`. That is a real boundary,
not advisory — and it is why a `protected` method's `permissions` block is
checked by an unprivileged process, which is the correct design.

---

## 3. The refusal that matters most

`proxmod-exec` refuses to inject — and starts the daemon **exactly as Proxmox
ships it** — when any of

```
/usr/share/perl5/Proxmod*
/usr/share/proxmod/extensions.d
/etc/proxmod
```

is not owned by root, or is group- or world-writable.

It is a pre-flight check, before any proxmod Perl is loaded, so it holds even
when proxmod itself is broken. It presents as `live.<unit>` failing while
`drift.<unit>` passes; the journal says why.

**Do not work around it.** Fix the mode, and then find out what made those files
writable — a config management tool running as a non-root user, an rsync with
the wrong flags, a tarball with a bad umask — because whatever it was can do it
again.

```sh
find /usr/share/perl5/Proxmod* /usr/share/proxmod/extensions.d /etc/proxmod \
     \( ! -user root -o -perm /022 \) -print
```

The same check governs the patch engine: `Proxmod::Patch` refuses to patch a
file that is not root-owned or is group/world-writable, for the same reason —
`/usr/share/perl5/PVE/**` is executed by `pvedaemon` as root.

## 4. Nothing from disk reaches the compiler

A manifest is a file on disk. Under `perl -T` it is tainted [PVE-F-002], and
`require` of a tainted string dies [PVE-F-042] — inside the daemon, at startup.

Getting that wrong in the *unsafe* direction is worse than a dead daemon:
`eval "require $module"` with a name from a file is arbitrary code execution as
root.

So:

- `Proxmod::Registry` accepts a module name only if it matches
  `^[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*$`, and **rebuilds it from
  the capture**.
- `Proxmod::Backend` checks it again before loading.
- The name is converted to a relative path and *that* is `require`d — a string
  from disk never reaches the Perl compiler.
- `t/00-compile.t` fails the build if `eval "..."` appears anywhere in the code
  that runs inside a daemon.

The same discipline applies to every string from a manifest or a patch spec.
Untaint by matching a strict pattern and rebuilding; never with `=~ /(.*)/s`,
which launders without checking.

## 5. Asset names are path components in an unauthenticated URL

`frontend.assets` entries must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.js$`.

**No slashes, no `..`, `.js` only.** These names are interpolated into a URL
`pveproxy` serves to unauthenticated clients. A path component here is a
directory traversal into a read of any file the web server can reach.

Related: proxmod registers the static route by assigning a **literal** into
`$cfg->{dirs}`, deliberately *not* via `add_dirs()`, which walks the tree with
`File::Find` and hands back tainted strings [PVE-F-025]. `t/00-compile.t` fails
the build if `add_dirs` appears in proxmod's code.

And `loader-runtime.js` lives at `/usr/share/proxmod/loader-runtime.js` —
**outside** `www/` — precisely so that it is not served.

## 6. Permissions are a required decision

`add_method` **dies** if `permissions` is missing. There is no default.

To Proxmox, a method with no `permissions` key is not an error: it is a working
endpoint that only `root@pam` may call, with nothing said about it anywhere
[PVE-F-050]. It works perfectly in testing as root and returns 403 for every
real caller. That silence is what made `pve-token-copy` necessary in the first
place, and it is a security problem in both directions — people work around the
403 by handing out `root@pam` credentials.

| Value | Who |
|---|---|
| `undef` | `root@pam` only, chosen deliberately |
| `{ user => 'all' }` | any authenticated user |
| `{ user => 'world' }` | **anyone. No authentication at all.** |
| `{ check => [...] }` | an ACL check — what you almost always want |

`{ user => 'world' }` is what PVE uses for the ticket endpoint. An extension
almost never wants it. proxmod **logs a warning naming your method** when you
use it, so an administrator can find it in the journal.

Guidance:

- Ask for the narrowest privilege that does the job — `Sys.Audit` to read,
  `Sys.Modify` to change. Widening because it is easier to reason about locks
  out the people who should have access.
- **Test as a non-root user with a real ACL.** Testing as root proves nothing
  about permissions.
- Check per object, not per endpoint: `['perm', '/vms/{vmid}', […]]`, not a
  blanket `/`.
- `protected => 1` puts your code in the root process. Do not set it on a method
  that does not need it.

## 7. Extension code is trusted, and bounded anyway

An extension is a root-privileged Perl module. proxmod does not sandbox it and
cannot: it runs in the same interpreter as `pvedaemon`. **Installing an
extension is trusting its author with root on the hypervisor**, exactly like any
other Debian package.

What the isolation *does* buy: a broken extension costs its own tab or endpoint
and nothing else. Each `proxmod_register` runs inside its own `eval` with
`$SIG{__DIE__}` localised, so it cannot escape by installing a die handler.
That is a **reliability** boundary, not a security one. Do not read it as
containment.

Two things proxmod cannot protect you from, and no wrapper could:

- an infinite loop in `proxmod_register` — **the daemon does not start**;
- a `protected` method that blocks — `pvedaemon` runs three workers
  [PVE-F-053], so thirty seconds of blocking removes a third of the host's
  privileged API capacity for thirty seconds.

## 8. Rules for extension authors

**Shell out with a list, never a string.**

```perl
PVE::Tools::run_command(['/usr/sbin/smartctl', '-i', $dev]);   # yes
system("smartctl -i $dev");                                     # root command injection
```

`$dev` must have come from a schema-validated parameter or a pattern you matched
yourself. Declared parameters arrive untainted — `PVE::RESTHandler::handle`
validates against your `parameters` schema and then runs `untaint_recursive`.
Anything read off disk or out of a command does not.

**Encode every value you render.** ExtJS does not escape by default —
`displayfield`, `XTemplate`, column renderers and tooltips all render HTML.
Guest names, VM notes and storage descriptions are user-controlled, and a
hypervisor's admin interface is a high-value place to land a script.

```js
Ext.String.htmlEncode(value)      // in code
'{name:htmlEncode}'               // in an XTemplate
```

Encode numbers too. "It is declared as a number in the schema" is a statement
about your server; this code runs in someone else's browser on a value that
arrived over the network.

**No secrets in a frontend asset.** No tokens, no hostnames, no internal paths,
no comments about your infrastructure. It is served unauthenticated.

**Never log a ticket, password, token or private key.** The journal is readable
by more people than the API is.

**Never write to `/etc/pve` from a maintainer script or at boot.** It is pmxcfs,
a FUSE filesystem: unmounted during parts of an upgrade, read-only without
quorum, absent early in boot. A hung FUSE mount can block dpkg indefinitely.
`t/09-reapply.t` fails the build if the string appears in any of proxmod's
maintainer scripts, its converge routine, or its boot unit.

**Validate everything in `parameters`.** `additionalProperties => 0` plus a
pattern or enum per property. The schema is the boundary; anything you accept
outside it, you validate yourself.

## 9. Attack surface added, honestly

Installing proxmod adds:

| Surface | Exposure | Mitigation |
|---|---|---|
| `/proxmod/loader.js` | unauthenticated GET | generated from the registry; contains only asset names |
| `/proxmod/*.js` | unauthenticated GET | strict filename pattern; no directories |
| One `<script>` tag in the index | unauthenticated GET | byte-level, idempotent, one tag |
| `/nodes/{node}/proxmod/*`, `/cluster/proxmod/*` | authenticated, ACL-checked | `permissions` is mandatory |
| A wrapper in both daemons' `ExecStart` | root at start | fail-safe; refuses on unsafe permissions |
| `/etc/proxmod`, `/usr/share/proxmod` | root-owned | permission refusal in the wrapper |
| The patch engine | inert | every shipped spec disabled; allowlisted roots; `/etc/pve` unreachable |

With **no** extensions installed, proxmod adds one unauthenticated URL serving a
generated comment, one script tag, and a root-owned wrapper that starts the
daemons the same way Proxmox does.

Each extension adds its own surface, and that is on the extension.

## 10. Reporting a vulnerability

Open an issue at <https://github.com/CrunchyMonkies/proxmod> for anything that
is not itself a live exploit path. For something exploitable, contact the
maintainers privately first.

Especially interested in: any way to reach `require`, `eval` or a shell with a
string from a file; any path where an unprivileged user's input reaches the root
daemon without a permissions check; and any way to make the wrapper inject when
it should refuse.

---

## Reference

- [`specifications.md`](specifications.md) §11 — normative requirements (`REQ-SEC-*`)
- [`perl-api.md`](perl-api.md) §3, §5 — permissions and taint, in detail
- [`js-api.md`](js-api.md) §6 — output encoding
- [`patching.md`](patching.md) — the risks of the one facility that modifies Proxmox files
- [`pve-internals.md`](pve-internals.md) §6, §9 — PVE's auth model and Perl under `-T`
