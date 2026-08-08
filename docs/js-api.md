# The JavaScript API

**Status:** Draft
**Applies to:** proxmod 0.1.0, Proxmox VE 9.x (ExtJS 7.0)
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** every signature, default and failure mode below was
read out of [`www/proxmod-ui.js`](../www/proxmod-ui.js); injection and loader
generation are unit-tested in `t/05` and `t/06`

Reference for the `Proxmod` global. For the guided introduction, read
[`frontend-extensions.md`](frontend-extensions.md) first.

Two globals matter and they differ by one letter:

- **`Proxmox`** (no *d*) belongs to Proxmox. Created inline in
  `index.html.tpl`, carries the CSRF token. **Never assign to it.**
- **`Proxmod`** is ours. It is the entire namespace an extension is allowed to
  touch, besides the one class name it defines for itself.

The one-letter difference is unfortunate and permanent.

---

## 1. Meta

### `Proxmod.version`

String — the framework version that served this page. `'0.1.0'`.

### `Proxmod.guard(what, fn)`

Runs `fn`, catching anything it throws. Returns `fn`'s value, or `undefined` if
it threw; logs `proxmod: <what> failed` with the exception.

```js
Proxmod.guard('acme-foo reload', function () { me.reload(); });
```

proxmod already wraps every callback it makes *into* extension code. Use this
for the callbacks you attach yourself — component listeners, timers, anything
ExtJS will call later — where proxmod's wrapper is not in the stack.

### `Proxmod.log`

```js
Proxmod.log.debug(message)
Proxmod.log.warn(message, err)
Proxmod.log.error(message, err)
```

Console output, prefixed `proxmod: `, so a support request containing a console
dump is immediately attributable. No-ops when there is no console.

---

## 2. `Proxmod.api`

proxmod's REST namespace is fixed: an extension answers below
`/nodes/{node}/proxmod/<id>` or `/cluster/proxmod/<id>` and nowhere else.
Building the URL here rather than in each extension is what makes that true in
practice as well as on paper.

### `Proxmod.api.url(ext, path, node)` → string

The bare API path, as `Proxmox.Utils.API2Request` wants it — that helper
prepends `/api2/extjs` itself.

```js
Proxmod.api.url('acme-foo', 'status', 'pve1')  // '/nodes/pve1/proxmod/acme-foo/status'
Proxmod.api.url('acme-foo', 'status')          // '/cluster/proxmod/acme-foo/status'
Proxmod.api.url('acme-foo')                    // '/cluster/proxmod/acme-foo'
```

Omit `node` for the cluster path. Leading slashes on `path` are stripped.

### `Proxmod.api.storeUrl(ext, path, node)` → string

The same, prefixed `/api2/json`, for the places that want an absolute URL —
`Proxmox.data.ObjectStore` and `Ext.data.Store` both do.

```js
proxy: { type: 'proxmox', url: Proxmod.api.storeUrl('acme-foo', 'items', nodename) }
```

### `Proxmod.api.request(opts)`

| Option | | |
|---|---|---|
| `ext` | **required** | Your extension id |
| `path` | | Path below your extension root |
| `node` | | Node name; omit for the cluster scope |
| `method` | default `'GET'` | |
| `params` | | Request parameters |
| `waitMsgTarget` | | Component to mask while in flight |
| `success` | | `function (response) { … }` |
| `failure` | | Defaults to an `Ext.Msg.alert` showing `response.htmlStatus` |

Calling without `ext` logs an error and returns without making a request.

`params.node` is filled in from `node` when you did not set it yourself. `{node}`
is a declared parameter of every node-scoped method and PVE validates it against
the path, so sending it is not optional — this just means you never have to
remember.

**The `success` callback receives the whole response.** What your Perl method
returned is at `response.result.data`. This catches everyone once.

```js
Proxmod.api.request({
    ext: 'acme-foo',
    path: 'status',
    node: me.nodename,
    waitMsgTarget: me,
    success: function (response) {
        var data = response.result.data;
        me.down('#state').setValue(Ext.String.htmlEncode(data.state));
    },
});
```

The default `failure` shows the error rather than swallowing it. Override it
when you want different handling; do not override it with an empty function.

### `Proxmod.api.get/post/put/delete(ext, path, opts)`

Shorthands. `opts` is everything `request` takes except `ext`, `path` and
`method`.

```js
Proxmod.api.get('acme-foo', 'status', { node: n, success: fn });
Proxmod.api.post('acme-foo', 'refresh', { node: n, params: { force: 1 } });
Proxmod.api['delete']('acme-foo', 'items/3', { node: n });
```

`delete` is a reserved word in ES3; bracket notation is the portable form.

---

## 3. `Proxmod.ui`

### The targets

```js
Proxmod.ui.targets
// { node: 'PVE.node.Config', qemu: 'PVE.qemu.Config',
//   lxc: 'PVE.lxc.Config', datacenter: 'PVE.dc.Config' }
```

Every one of these is a `PVE.panel.Config` subclass, which is the only reason
the `insertNodes` mechanism works at all [PVE-F-030].

### `Proxmod.ui.addTab(target, spec)` → boolean

`target` is a key of `Proxmod.ui.targets`. Returns `false` and logs on an
unknown target, a missing `ext`, a missing `xtype`, or a target class this
Proxmox does not have.

### The named helpers

```js
Proxmod.ui.addNodeTab(spec)         // → addTab('node', spec)
Proxmod.ui.addQemuTab(spec)
Proxmod.ui.addLxcTab(spec)
Proxmod.ui.addDatacenterTab(spec)
Proxmod.ui.addGuestTab(spec)        // qemu AND lxc; true only if both succeeded
```

`addGuestTab` exists because "add a tab to every VM" means both guest types in
practice, and forgetting the container half is the standard first mistake.

### The spec

| Field | | |
|---|---|---|
| `ext` | **required** | Your extension id — attributes failures, namespaces the `itemId` |
| `xtype` | **required** | Widget alias to instantiate (or set `item.xtype`) |
| `title` | | Tab label; defaults to `item.title`, then to `ext` |
| `iconCls` | | e.g. `'fa fa-cube'` |
| `id` | | Suffix for the generated `itemId`, for a second tab from one extension |
| `itemId` | | Override the generated id. Don't — see below |
| `groups` | | ExtJS tab grouping |
| `after` | | An existing tab's `itemId` to sit after; best-effort |
| `item` | | Extra config merged into the instantiated component |

Registration is **deferred**. The spec is recorded now and turned into a
component every time a matching panel is constructed — so a tab registered
before the workspace exists appears on every node you click, not just the first.

**Do not set `itemId`.** The generated `proxmod-<ext>[-<id>]` is unique by
construction. `insertNodes` throws `'itemId already exists'` on a duplicate
[PVE-F-032], and it throws it from inside `initComponent` — which would blank
the panel. proxmod checks `savedItems` first and skips with a warning instead,
which is cheaper and quieter, but only the generated id is guaranteed not to
collide in the first place.

**`item` is rebuilt per panel instance**, deliberately: `insertNodes` mutates
what it is given — it `shift()`s `groups` empty and sets `header` — so a shared
object works once and then silently misplaces the tab on every panel after the
first.

Your component is handed `pveSelNode`, and `nodename` when the panel has one.

**`after` is best-effort.** `insertNodes` always appends, so proxmod moves the
tab afterwards by walking the panel's tree store. If anything is not as
expected, the tab stays where it landed. A tab in the wrong place is a cosmetic
problem and is not worth an exception during `initComponent`.

### `Proxmod.ui.addStyle(ext, css)`

Writes `css` into a `<style id="proxmod-style-<ext>">` in `<head>`, creating it
once and replacing its content thereafter — so reloading an asset cannot
accumulate duplicates.

```js
Proxmod.ui.addStyle('acme-foo', '.proxmod-acme-foo-bad { color: #d9534f; }');
```

Prefix every class `proxmod-<ext>-`. There is one selector namespace in this
page and it is shared with Proxmox.

### `Proxmod.ui.registrations()` → array

```js
[{ target: 'node', ext: 'acme-foo', itemId: 'proxmod-acme-foo' }, …]
```

For `proxmod-verify` and the browser console. Nothing else should use it.

---

## 4. The one override per class

proxmod installs **exactly one** `Ext.define({override: …})` per target class,
on first registration, no matter how many extensions add tabs. A chain of N
overrides is N chances for one extension's `callParent` to swallow another's.

Inside it:

```js
initComponent: function () {
    me.callParent(arguments);          // FIRST
    Proxmod.guard('adding tabs to ' + target, function () { applyTabs(key, me); });
}
```

**`callParent` first** because `PVE.panel.Config.initComponent` consumes
`me.items`, deletes it, and builds the tree store — only after that does
`insertNodes` exist to be called [PVE-F-031]. Pushing onto `me.items` before
`callParent` works too, but only for the top level, and it breaks the moment a
tab wants a group.

**The seam probe.** Before defining the override, proxmod checks
`Ext.ClassManager.get(target)`. Defining an override for a class that does not
exist leaves it pending in `Ext.Loader` forever — a *stuck* interface, not a
degraded one. Refusing means an extension written for a Proxmox that renamed the
class degrades to a missing tab. If you write your own override, probe the same
way.

---

## 5. What kills what

| You do | Result |
|---|---|
| Throw in a registration call | Logged; that tab is skipped, others still register |
| Throw in your `initComponent` | That tab's panel fails; the rest of the interface survives |
| Throw in an unguarded listener | Uncaught — wrap it in `Proxmod.guard` |
| Register a colliding `itemId` | Warned and skipped |
| Register for a class this PVE lacks | Warned, `addTab` returns `false` |
| Assign to `Proxmox` | You have broken the web interface for everyone |
| Create a second global | You are squatting on a name you do not own |
| Render an unencoded API value | Stored XSS in the hypervisor's admin interface |

---

## 6. Non-negotiables

**Encode everything.** ExtJS does not escape by default — `displayfield`,
`XTemplate`, column renderers and tooltips all render HTML. Guest names, VM
notes and storage descriptions are user-controlled.

```js
Ext.String.htmlEncode(value)      // in code
'{name:htmlEncode}'               // in an XTemplate
```

**No secrets in the file.** Assets under `/proxmod/` are served to anyone who
can reach port 8006, logged in or not [PVE-F-023]. No tokens, no hostnames, no
internal paths.

**ES5, no build step.** One concatenated bundle, one global scope, no module
loader, no transpiler. `node --check yourfile.js` before you ship.

**Guard the entry.**

```js
if (typeof Proxmod === 'undefined' || !Proxmod.ui) { return; }
```

proxmod can be disabled by an administrator without your package being removed.

---

## Reference

- [`frontend-extensions.md`](frontend-extensions.md) — the guided version, with a worked example
- [`examples/proxmod-example-hello/www/proxmod-example-hello.js`](../examples/proxmod-example-hello/www/proxmod-example-hello.js) — the reference asset
- [`specifications.md`](specifications.md) §7 — normative requirements (`REQ-FE-*`)
- [`pve-internals.md`](pve-internals.md) §10 — how the interface is built and served
- [`extension-manifest.md`](extension-manifest.md) — how your asset gets loaded
</content>
</invoke>
