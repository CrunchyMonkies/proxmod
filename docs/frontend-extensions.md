# Writing a frontend extension

**Status:** Draft
**Applies to:** proxmod 0.4.0, Proxmox VE 9.x (ExtJS 7.0)
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the worked example is
[`examples/proxmod-example-hello/www/proxmod-example-hello.js`](../examples/proxmod-example-hello/www/proxmod-example-hello.js);
injection is unit-tested against the real vendored `index.html.tpl`;
Proxmox-internals claims cite [`pve-facts.md`](pve-facts.md)

A frontend extension adds components to the Proxmox web interface. It is **one
JavaScript file** and a manifest entry. No build step, no bundler, no
transpiler, and — unlike a backend extension — **no daemon restart**.

Read [`pve-internals.md`](pve-internals.md) §10 first. This document assumes it.

---

## 1. The environment you are writing for

Four facts shape everything below.

**There is no module system.** The Proxmox web interface is one concatenated
file, `pvemanagerlib.js`, evaluated in one global scope. No `import`, no
`require`, no bundler, no source map. Your file is another `<script>` in the
same scope. Wrap it in an IIFE and touch exactly one global — your own class
name.

**Your file is served without authentication** [PVE-F-023]. Anyone who can reach
port 8006 can read it, logged in or not. No hostnames, no tokens, no internal
paths, no comments about your infrastructure.

**A thrown exception can blank the entire interface.** ExtJS builds the
workspace synchronously; an exception inside `initComponent` takes the panel and
everything after it. proxmod calls into your registrations inside a `try`/`catch`
so a broken extension degrades to a missing tab — but that protection stops at
the boundary. Code inside your own component's callbacks is on its own.

**Strict mode is not available.** ExtJS resolves `callParent` by reading
`Function.caller` on the calling method, and V8 hands out `null` for that
whenever the caller is a strict-mode function. A `'use strict'` anywhere above
an override therefore turns every `callParent` under it into

```
Uncaught TypeError: Cannot read properties of null (reading 'apply')
    at constructor.callParent (ext-all.js)
```

and the panel that override belongs to never builds. Strictness is inherited by
every nested function, so there is no opting one method back out: leave the
directive out of the file. `pvemanagerlib.js` and `ext-all.js` are sloppy mode
for the same reason.

### When your code runs

proxmod injects exactly one `<script>` tag into the index, immediately before
the inline `Ext.onReady` block [PVE-F-021], [PVE-F-003]. That tag loads
`/proxmod/loader.js`, which loads `proxmod-ui.js` and then every extension asset
in registry order.

So by the time your file runs:

- every `PVE.*` and `Proxmox.*` class **is defined**;
- `gettext` and the translations **are available**;
- **no** `Ext.onReady` handler has run, and the workspace does not exist yet.

That window is the whole point: you can override a component that has not been
constructed. Anything needing a live workspace goes in your own
`Ext.onReady`.

---

## 2. Hello, world

```jsonc
// /usr/share/proxmod/extensions.d/50-acme-foo.conf
{
    "id": "acme-foo",
    "version": "1.0.0",
    "frontend": { "assets": ["acme-foo.js"] }
}
```

```js
// /usr/share/proxmod/www/acme-foo.js
(function () {
    // No 'use strict' — see §1. It would break every callParent below.

    // proxmod may be absent — an administrator can disable it, and this file
    // could be loaded by something else. Fail into doing nothing.
    if (typeof Proxmod === 'undefined' || !Proxmod.ui) {
        return;
    }

    Ext.define('AcmeFoo.Panel', {
        extend: 'Ext.panel.Panel',
        alias: 'widget.acmeFooPanel',

        title: gettext('Acme Foo'),
        border: false,
        padding: 10,

        nodename: undefined,          // handed in by the tab host

        initComponent: function () {
            var me = this;
            if (!me.nodename) {
                throw 'no node name specified';
            }

            me.items = [{
                xtype: 'displayfield',
                fieldLabel: gettext('Message'),
                itemId: 'message',
                value: '',
            }];

            me.callParent();          // FIRST
            me.reload();
        },

        reload: function () {
            var me = this;
            Proxmod.api.get('acme-foo', 'status', {
                node: me.nodename,
                waitMsgTarget: me,
                success: function (response) {
                    var data = response.result.data;
                    me.down('#message').setValue(
                        Ext.String.htmlEncode(data.message));
                },
            });
        },
    });

    Proxmod.ui.addNodeTab({
        ext: 'acme-foo',
        title: gettext('Acme Foo'),
        iconCls: 'fa fa-cube',
        xtype: 'acmeFooPanel',
        after: 'system',
    });
}());
```

Drop the file in, drop the manifest in, reload the browser. **No restart** —
the loader is generated per request from the live registry.

---

## 3. The `Proxmod` global

The only interface you should use. Everything in it is written to fail into
doing nothing rather than to throw.

### Meta

```js
Proxmod.version                  // the framework version that served this page
Proxmod.guard('what', fn)        // run fn, catching and reporting anything it throws
Proxmod.log.debug(msg)
Proxmod.log.warn(msg, err)
Proxmod.log.error(msg, err)
```

`Proxmod.log` output is prefixed, so a support request containing a console dump
is immediately attributable. Use `Proxmod.guard` around anything you attach to a
component's lifecycle:

```js
listeners: {
    activate: function () { Proxmod.guard('acme-foo reload', function () { me.reload(); }); },
},
```

### API

Your endpoints live at a path derived from your extension id, and this is where
that rule is enforced in practice rather than on paper.

```js
Proxmod.api.url(ext, path, node)       // '/nodes/pve1/proxmod/acme-foo/status'
Proxmod.api.storeUrl(ext, path, node)  // '/api2/json' + the above — for a Store
Proxmod.api.request({ ext, path, node, method, params,
                      waitMsgTarget, success, failure })
Proxmod.api.get(ext, path, opts)       // shorthands for the four verbs
Proxmod.api.post(ext, path, opts)
Proxmod.api.put(ext, path, opts)
Proxmod.api['delete'](ext, path, opts)
```

Omit `node` and you get the cluster path, `/cluster/proxmod/<id>/...`.

`request` fills in `params.node` for you when you pass `node`, wraps
`Proxmox.Utils.API2Request`, and supplies a default `failure` that shows the
error rather than swallowing it.

**The callback receives the whole response, not the payload.** What your Perl
method returned is at `response.result.data`. This catches everyone once.

For a grid or a form, use `storeUrl`:

```js
var store = Ext.create('Proxmox.data.UpdateStore', {
    storeid: 'acme-foo-items',
    interval: 3000,
    proxy: {
        type: 'proxmox',
        url: Proxmod.api.storeUrl('acme-foo', 'items', nodename),
    },
});
```

### UI

```js
Proxmod.ui.addNodeTab(spec)         // PVE.node.Config
Proxmod.ui.addQemuTab(spec)         // PVE.qemu.Config
Proxmod.ui.addLxcTab(spec)          // PVE.lxc.Config
Proxmod.ui.addGuestTab(spec)        // both guest types — see below
Proxmod.ui.addDatacenterTab(spec)   // PVE.dc.Config
Proxmod.ui.addTab(target, spec)     // any key of Proxmod.ui.targets

Proxmod.ui.addMenuScreen(spec)      // a node in the config panel's left-hand tree
Proxmod.ui.addMenuSection(spec)     // a section in that node's own card
Proxmod.ui.addMenuItem(spec)        // either, via spec.mode
Proxmod.ui.configureMenu(spec)      // title/icon/layout of the parent node

Proxmod.ui.addStyle(ext, css)
Proxmod.ui.targets                  // the target → class map
Proxmod.ui.registrations()          // what has been registered, for debugging
```

`addGuestTab` is `addQemuTab` + `addLxcTab`. "Add a tab to every VM" means both,
and forgetting the container half is the standard first mistake.

The `spec`:

| Field | | |
|---|---|---|
| `ext` | **required** | Your extension id. Attributes failures and namespaces the `itemId` |
| `xtype` | **required** | The widget alias to instantiate (or set `item.xtype`) |
| `title` | | Tab label. Wrap in `gettext()` |
| `iconCls` | | e.g. `'fa fa-cube'` — Font Awesome ships with PVE |
| `id` | | Suffix for the generated `itemId`, if you add more than one tab |
| `after` | | Sit after an existing tab, by its `itemId` |
| `groups` | | ExtJS tab grouping |
| `item` | | Extra config merged into the instantiated component |

**Do not set `itemId` yourself.** proxmod generates
`proxmod-<ext>[-<id>]`, which is unique by construction. Setting it by hand is
how two extensions collide, and `insertNodes` throws on a duplicate `itemId`
from inside `initComponent` [PVE-F-032] — which would blank the panel.

`addStyle` writes into a `<style>` element keyed by your extension id, so
calling it twice replaces rather than accumulates. Prefix every class with
`proxmod-<yourext>-`.

#### A tab, or a menu item?

Both put a card into the same panel. They differ in where you click to get it:

- a **tab** joins the row across the top — Summary, Notes, Shell, and yours;
- a **menu item** joins the tree down the left, at the bottom, under a shared
  `Proxmod` node.

Add a **tab** when your card is one more view of the object that is already
selected: another statistic about this VM, another list belonging to this node.
It sits among Proxmox's own views because it is one of them.

Add a **menu item** when your extension owns a *place* rather than a view — when
it has several related screens, or one that is not really about this object's
configuration. Grouping them under one node keeps eight extensions from turning
the tab bar into a scrolling strip.

A menu item is either a **screen** (its own node, its own card) or a **section**
(rendered in the parent node's card, alongside every other extension's). Sections
are for a paragraph or a small form; screens are for pages.

```js
// Two screens and a section, from one extension.
Proxmod.ui.addMenuScreen({
    ext: 'acme-foo', targets: ['node', 'storage'],
    id: 'volumes', title: gettext('Volumes'),
    iconCls: 'fa fa-database', xtype: 'acmeFooVolumes',
});
Proxmod.ui.addMenuScreen({
    ext: 'acme-foo', target: 'node',
    id: 'jobs', title: gettext('Jobs'), xtype: 'acmeFooJobs',
});
Proxmod.ui.addMenuSection({
    ext: 'acme-foo', target: 'guest',
    id: 'status', title: gettext('Acme'), xtype: 'acmeFooStatus',
});
```

Targets go well beyond the four tab hosts: `datacenter`, `node`, `qemu`, `lxc`,
`storage`, `pool`, `zone`, `network`, plus the sets `guest` (both guest types)
and `all`. Your card is handed the context under the names PVE's own panels use
— `nodename`, `vmid`, `storage`, `pool`, `zone`, `zoneType` [PVE-F-034] — so
read `this.storage`, never the URL. Fields that do not apply are absent; a pool
has no node.

`standalone: true` gives your extension its own top-level node instead of the
shared one. With a single screen and no sections it *is* that node, unwrapped.
Prefer the shared parent: one `Proxmod` entry is tidier than five, and it is
what an administrator will look under.

See [`js-api.md`](js-api.md) §3 for the full spec and `configureMenu`.

---

## 4. Overriding a component

The `Proxmod.ui` helpers cover tabs, which is most of what people want. When you
need something else, the pattern is:

```js
Ext.define('AcmeFoo.NodeConfigOverride', {
    override: 'PVE.node.Config',

    initComponent: function () {
        var me = this;

        me.callParent();              // FIRST. Always.

        Proxmod.guard('acme-foo node config', function () {
            // ... your optional work, after the component is fully built
        });
    },
});
```

Two rules, and they are not stylistic.

**`callParent` first.** `PVE.panel.Config.initComponent` consumes `me.items`,
deletes it, and builds the tree store. Only after it has run does the component
exist in a form you can manipulate. An override that works *before* the parent
leaves the component half-constructed if it throws — and then Proxmox's own code
runs against the wreckage.

**Your work is optional; the parent's is not.** Wrap yours so an exception
cannot escape.

**Prefer one override per class.** proxmod maintains exactly one override per
target class no matter how many extensions register tabs, deliberately: a chain
of N overrides is N chances for one extension's `callParent` to swallow
another's. If you define your own, you are adding a link to that chain.

### The classes worth knowing

[PVE-F-030]:

| Class | What |
|---|---|
| `PVE.dc.Config` | The datacenter panel |
| `PVE.node.Config` | The per-node panel |
| `PVE.qemu.Config` | The per-VM panel |
| `PVE.lxc.Config` | The per-container panel |
| `PVE.storage.Browser` | The per-storage panel — **not** `PVE.storage.Config`, which does not exist |
| `PVE.pool.Config` | The per-pool panel |
| `PVE.sdn.Browser` | The per-zone panel |
| `PVE.network.Browser` | The per-node network panel |

These are class names in someone else's application. A Proxmox release may
rename one. proxmod probes for the class before defining an override, so an
extension written against a renamed class degrades to a missing tab rather than
to an override left pending in `Ext.Loader` forever — which is a *stuck* UI, not
a degraded one. If you write your own override, probe the same way:

```js
if (!Ext.ClassManager.get('PVE.node.Config')) { return; }
```

---

## 5. Output encoding

**ExtJS does not escape by default.** A `displayfield` renders its value as
HTML, as do `Ext.XTemplate`, grid column renderers and tooltips.

```js
me.down('#message').setValue(Ext.String.htmlEncode(data.message));
```

Encode **everything** that did not come from your own source file: API
responses, guest names, storage ids, notes, hostnames, error strings — and
numbers.

"It is declared as a number in the schema" is a statement about your server. This
code is running in someone else's browser, and the value arrived over the
network. Encode it.

In an `XTemplate`, use the `htmlEncode` filter:

```js
tpl: '<div>{name:htmlEncode}</div>',
```

Guest names, VM notes and storage descriptions are all user-controlled, and a
hypervisor's administrative interface is a high-value place to land a script.

---

## 6. Theming and styling

Scope everything:

```js
Proxmod.ui.addStyle('acme-foo', [
    '.proxmod-acme-foo-status { font-weight: bold; }',
    '.proxmod-acme-foo-status-bad { color: #d9534f; }',
].join('\n'));
```

Never restyle a Proxmox or ExtJS class. There is one selector namespace, your
rule applies everywhere, and the next Proxmox release moves the markup under it.

For colours that must match the surrounding interface, use the widget toolkit's
CSS custom properties (`--pwt-panel-background` and friends) rather than
hardcoding hex values, so dark mode follows. Be aware these are **not a
published interface** — they are internal names that happen to be reachable, and
they may change. Treat any use of them as a workaround with a fallback:

```css
.proxmod-acme-foo-box {
    background: #ffffff;                          /* fallback first */
    background: var(--pwt-panel-background, #ffffff);
}
```

---

## 7. Debugging

`pvemanagerlib.js` is one enormous concatenated file with no source map, so the
console is your only real tool. Some recipes:

```js
// what did proxmod register?
Proxmod.ui.registrations()

// is a class actually there?
Ext.ClassManager.get('PVE.node.Config')

// the live component tree, from an itemId
Ext.ComponentQuery.query('#proxmod-acme-foo')[0]

// what proxmod thinks it loaded
Proxmod.version
```

And in the page source:

```sh
# exactly one loader tag?
curl -sk https://localhost:8006/ | grep -c '/proxmod/loader.js'

# what does the loader think it should load?
curl -sk https://localhost:8006/proxmod/loader.js
```

| Symptom | Likely cause |
|---|---|
| No tag in the page at all | proxmod is not loaded — `proxmod-verify` |
| Tag present, `loader.js` is an inert comment | The loader could not be built; check the journal |
| `loader.js` does not name your asset | Manifest not read: bad JSON, bad `id`, or `enabled: false` |
| Asset named but 404 | The file is not in `/usr/share/proxmod/www/` |
| Asset loads, no tab | Your registration threw — check the console for a `proxmod:` line |
| Tab present, empty | Your `initComponent` or your API call failed |
| Endpoint 501 | The backend half, not this one — see [`backend-extensions.md`](backend-extensions.md) §5 |

Note the deliberate design: a loader that cannot be built returns **HTTP 200
with an inert comment**, not a 500 ([REQ-FE-014]). A 500 puts a red line in every
administrator's console on every page load and changes nothing about the
outcome. So "200 but empty" is a real signal — read the journal:

```sh
journalctl -u pveproxy | grep proxmod
```

---

## 8. Component cookbook

### A status panel that polls

```js
Ext.define('AcmeFoo.Status', {
    extend: 'Proxmox.grid.ObjectGrid',
    alias: 'widget.acmeFooStatus',

    initComponent: function () {
        var me = this;
        if (!me.nodename) { throw 'no node name specified'; }

        me.url = Proxmod.api.storeUrl('acme-foo', 'status', me.nodename);
        me.rows = {
            state:   { header: gettext('State'),  required: true },
            updated: { header: gettext('Updated'), renderer: Proxmox.Utils.render_timestamp },
        };

        me.callParent();
        me.on('activate', me.rstore.startUpdate, me.rstore);
        me.on('deactivate', me.rstore.stopUpdate, me.rstore);
    },
});
```

Start and stop the store on `activate`/`deactivate`. A panel that keeps polling
while hidden multiplies load on `pvedaemon`'s three workers by the number of
open browser tabs.

### A toolbar button that calls an endpoint

```js
tbar: [{
    text: gettext('Refresh'),
    iconCls: 'fa fa-refresh',
    handler: function () {
        Proxmod.api.post('acme-foo', 'refresh', {
            node: me.nodename,
            waitMsgTarget: me,
            success: function () { me.rstore.load(); },
        });
    },
}],
```

### Following a task

If your endpoint returns a UPID, hand it to the task viewer rather than
inventing progress reporting:

```js
success: function (response) {
    var upid = response.result.data;
    Ext.create('Proxmox.window.TaskViewer', { upid: upid }).show();
},
```

---

## 9. Checklist

- [ ] Wrapped in an IIFE, touching one global — and **not** `'use strict'`
- [ ] Guarded by `if (typeof Proxmod === 'undefined' || !Proxmod.ui) { return; }`
- [ ] Every registration carries `ext`
- [ ] No hand-written `itemId`
- [ ] `callParent` first in every override
- [ ] Every rendered value goes through `htmlEncode`
- [ ] No secret, token, hostname or internal path anywhere in the file
- [ ] Every CSS class prefixed `proxmod-<ext>-`
- [ ] Polling stores stop on `deactivate`
- [ ] ES5-compatible; nothing that throws at parse time
- [ ] `node --check acme-foo.js` passes
- [ ] The tab still appears with a second extension installed alongside

---

## Reference

- [`js-api.md`](js-api.md) — every `Proxmod` member, in detail
- [`extension-manifest.md`](extension-manifest.md) — every manifest field
- [`specifications.md`](specifications.md) §7 — the normative requirements (`REQ-FE-*`)
- [`pve-internals.md`](pve-internals.md) §10 — how the interface is built and served
- [`backend-extensions.md`](backend-extensions.md) — the other half
