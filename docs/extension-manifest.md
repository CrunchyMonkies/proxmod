# The extension manifest

**Status:** Draft
**Applies to:** proxmod 0.1.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** every field, default, pattern and rejection below was
read out of [`perl/Proxmod/Registry.pm`](../perl/Proxmod/Registry.pm); parsing
and ordering are unit-tested in `t/02-registry.t`

A manifest tells proxmod that an extension exists, what to load, and in what
order. It is one JSON file in a drop-in directory.

```jsonc
{
    "id": "acme-foo",
    "version": "1.0.0",
    "order": 50,
    "backend":  { "module": "Acme::Foo", "daemons": ["pvedaemon", "pveproxy"] },
    "frontend": { "assets": ["acme-foo.js"] }
}
```

---

## 1. Where manifests live

| Directory | Owner | Purpose |
|---|---|---|
| `/usr/share/proxmod/extensions.d/` | packages | where an extension `.deb` writes |
| `/etc/proxmod/extensions.d/` | administrator | overrides the above |

Files are read from both, and **later directories win by basename** — the same
rule systemd uses for units. Filenames conventionally start with the order
number: `50-acme-foo.conf`.

An administrator disables a packaged extension by **masking** it: an empty file,
or a symlink to `/dev/null`, at the same basename under `/etc`. That survives
reinstalling the extension package, which editing the packaged file does not.

```sh
ln -sf /dev/null /etc/proxmod/extensions.d/50-acme-foo.conf   # off
rm /etc/proxmod/extensions.d/50-acme-foo.conf                 # on again
```

Writing into either directory fires proxmod's dpkg trigger and the host
converges — see [`packaging.md`](packaging.md) §6.

## 2. Format

JSON, in a `.conf` file. The suffix is the drop-in convention; the content is
JSON because manifests need arrays and nesting.

The parser is **relaxed**: a trailing comma, or a `#` or `//` comment, is
forgiven. That is for the benefit of a hand-edited file under `/etc` — a
manifest an administrator edited at 3am should not vanish over a stray comma.
**Packaged manifests should be plain, strict JSON** anyway.

---

## 3. Fields

### `id` — required

```
^[a-z0-9][a-z0-9_-]{0,63}$
```

Lowercase letters, digits, `-` and `_`; must start alphanumeric; 64 characters
maximum.

This is not a display name. It is:

- the API path segment — `/nodes/{node}/proxmod/<id>/…`
- the namespace for generated `itemId`s — `proxmod-<id>-…`
- the CSS class prefix convention — `proxmod-<id>-…`
- the `ext` argument to every `Proxmod.api` and `Proxmod.ui` call

It must be **unique across the host**. A duplicate `id` is not merged: the first
manifest in load order wins, the later one is logged and ignored. Prefix with
your project or vendor name if there is any chance of collision.

A bad or missing `id` rejects the whole manifest — nothing else can be
attributed without it.

### `version` — optional, default `"0"`

Free-form. Reported by `proxmod-verify` and in the loader comment. Not used for
dependency resolution; `requires` names extensions, not versions.

### `enabled` — optional, default `true`

`false` disables without deleting. Note the direction: **absent means enabled**,
so shipping a manifest activates an extension. (Patch specs are the opposite —
absent means disabled — because a patch that quietly starts working is a
different kind of surprise. See [`patching.md`](patching.md).)

Masking from `/etc` is usually the better tool for an administrator; `enabled`
is for a package that ships something it does not want on by default.

### `order` — optional, default `50`

An integer `0`–`9999`. Lower loads first. Ties break by **basename**, so the
result never depends on `readdir` order.

Use it for load order only. If your extension genuinely needs another one to be
loaded first, say so with `requires` — that is checked, and `order` is not.

Anything outside the range is logged and the default is used; the manifest is
not rejected.

### `requires` — optional, default `[]`

A list of extension ids (a bare string is accepted as a one-element list). The
named extensions must be present and enabled, and they load first.

**An extension whose prerequisite did not load is dropped**, and so is anything
that depended on *it*, transitively. That is deliberate: an extension running
without its prerequisite is more likely to misbehave than to degrade gracefully.
The journal says which, and why — missing, or part of a cycle.

Cycles are detected and every extension in the cycle is dropped.

### `backend` — optional

```jsonc
"backend": {
    "module":  "Acme::Foo",
    "daemons": ["pvedaemon", "pveproxy"]
}
```

**`backend.module`** — required if `backend` is present.

```
^[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*$
```

A Perl package name, in a file findable in the default `@INC` — in practice
`/usr/share/perl5/` [PVE-F-003]. proxmod `require`s it and then calls its
`proxmod_register`; see [`backend-extensions.md`](backend-extensions.md).

That pattern is not cosmetic. The daemons run under `perl -T`, and **`require`
of a tainted string dies** [PVE-F-042] — inside the daemon, at startup, which
would be a dead hypervisor API. The name is untainted by matching this pattern
and rebuilding from the capture. A module name that does not match is refused
and the backend half is skipped.

**`backend.daemons`** — optional, defaults to **both**.

Valid values: `pvedaemon`, `pveproxy`. `pvestatd` is deliberately not accepted —
it serves no REST API and does not run under taint mode, so there is nothing
there to attach to.

**Both is almost always right.** Every request reaches `pveproxy` first, and it
must find the method in its own tree before it can decide to proxy it to
`pvedaemon` [PVE-F-052]. Register in only one and the other answers **501 Not
Implemented** — not 404 — for every request that lands there. Unknown names are
logged and dropped; if that leaves the list empty, the backend half is skipped.

### `frontend` — optional

```jsonc
"frontend": { "assets": ["acme-foo.js"] }
```

**`frontend.assets`** — a list of plain filenames under
`/usr/share/proxmod/www/`.

```
^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.js$
```

**No directories, no slashes, `.js` only.** This name is interpolated into a URL
that `pveproxy` serves to **unauthenticated** clients [PVE-F-023]: a path
component here would be a directory traversal into a read of any file the
web server can reach. A name that does not match is logged and dropped.

Assets load in manifest order, after `proxmod-ui.js`, before any `Ext.onReady`
handler has run [PVE-F-021].

A frontend-only change needs **no daemon restart** — the loader is generated per
request from the live registry.

### At least one half

A manifest with neither a usable `backend` nor a usable `frontend` is rejected
and logged. Note *usable*: a manifest whose `backend.module` failed validation
and which has no `frontend` is rejected on this rule, so a typo'd module name
does not leave a silently inert extension behind.

---

## 4. What happens when a manifest is wrong

The governing rule: **one bad manifest must never cost the others.** Nothing in
the parser is fatal, and everything rejected is logged with the id or path.

| Problem | Result |
|---|---|
| File unreadable | Ignored, warned |
| Empty file / symlink to `/dev/null` | **Masked** — a deliberate off switch, logged at debug |
| Invalid JSON | Ignored, warned with the parse error |
| Top level is not an object | Ignored, warned |
| Bad or missing `id` | Ignored, warned |
| Duplicate `id` | Later one ignored, warned, naming both files |
| Bad `order` | Default 50, warned |
| Malformed entry in `requires` | That entry dropped, warned |
| `backend` not an object | Backend skipped, warned |
| Bad `backend.module` | Backend skipped, warned |
| Unknown daemon name | That name dropped, warned |
| All daemon names unknown | Backend skipped, warned |
| Bad asset name | That asset dropped, warned |
| Neither half usable | Manifest ignored, warned |
| `requires` unsatisfiable | Extension dropped with its dependents, warned |

To see them:

```sh
journalctl -u pveproxy -u pvedaemon | grep proxmod
proxmod-verify --json          # includes each extension and its state
```

---

## 5. Two worked manifests

**Both halves** — the shipped example,
[`examples/proxmod-example-hello/conf/50-proxmod-example-hello.conf`](../examples/proxmod-example-hello/conf/50-proxmod-example-hello.conf):

```jsonc
{
    "id": "example-hello",
    "version": "0.1.0",
    "order": 50,
    "backend": {
        "module": "ProxmodExample::Hello",
        "daemons": ["pvedaemon", "pveproxy"]
    },
    "frontend": {
        "assets": ["proxmod-example-hello.js"]
    }
}
```

**Frontend only**, loading after it, and only if it loaded:

```jsonc
{
    "id": "acme-theme",
    "version": "1.0.0",
    "order": 90,
    "requires": ["example-hello"],
    "frontend": { "assets": ["acme-theme.js"] }
}
```

---

## 6. Checklist

- [ ] `id` matches the pattern, is unique host-wide, and matches the asset name
      and the `ext` argument used in your JavaScript
- [ ] Filename is `NN-<id>.conf`, with `NN` matching `order`
- [ ] Packaged manifest is strict JSON — no comments, no trailing commas
- [ ] `backend.module` is a real, installed Perl package under `/usr/share/perl5`
- [ ] `backend.daemons` omitted, or both — unless you can say why not
- [ ] Every asset is a bare `*.js` filename, present in `/usr/share/proxmod/www/`
- [ ] `requires` names ids, not package names or versions
- [ ] `journalctl | grep proxmod` is silent after install

---

## Reference

- [`specifications.md`](specifications.md) §8 and Appendix B — normative rules (`REQ-MF-*`) and the JSON Schema
- [`perl/Proxmod/Registry.pm`](../perl/Proxmod/Registry.pm) — the implementation, and the source of every rule above
- [`backend-extensions.md`](backend-extensions.md) — what `backend.module` must provide
- [`frontend-extensions.md`](frontend-extensions.md) — what an asset may do
- [`packaging.md`](packaging.md) — how the file gets onto the host
