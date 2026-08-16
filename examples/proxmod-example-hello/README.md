# proxmod-example-hello

**Status:** Living
**Applies to:** Proxmox VE 9.x, proxmod >= 0.2.0

The reference proxmod extension, and the executable form of the extension
contract. It adds:

- `GET /nodes/{node}/proxmod/example-hello` — an index
- `GET /nodes/{node}/proxmod/example-hello/greet` — an ACL-checked read
- `POST /nodes/{node}/proxmod/example-hello/note` — a `protected` write, run as
  root by `pvedaemon`
- a **Hello** tab in the node view of the web interface

## The contract, in full

An extension package ships **three files** and declares one dependency. It has
**no maintainer scripts at all** — no `postinst`, no `prerm`, no `postrm`.

| File | Purpose |
|---|---|
| `/usr/share/perl5/ProxmodExample/Hello.pm` | the backend, in the extension's own namespace |
| `/usr/share/proxmod/extensions.d/50-proxmod-example-hello.conf` | the manifest — what to load, and where |
| `/usr/share/proxmod/www/proxmod-example-hello.js` | the frontend asset |

Writing into `/usr/share/proxmod/extensions.d` activates proxmod's dpkg trigger,
and `proxmod-reapply` converges from there. Nothing in this package knows how
the daemons are started, that they are restarted at all, or that Proxmox exists
beyond `PVE::RESTHandler`.

Every path above is owned by Debian or by proxmod. No Proxmox-owned file is read
at build time, written at install time, or patched ever. That is the property
that makes `dpkg -V pve-manager` come back clean after installing this, and
after removing it.

## Read it in this order

1. `conf/50-proxmod-example-hello.conf` — the manifest, and what each field
   costs if you get it wrong
2. `perl/ProxmodExample/Hello.pm` — `proxmod_register()`, permissions,
   `protected => 1`
3. `www/proxmod-example-hello.js` — the one-global rule, and why the file is
   readable by anyone who can reach port 8006
4. `Makefile` and `debian/` — how little there is of it

## The frontend surface this example uses

`proxmod-ui.js` is loaded before any extension asset, so `Proxmod` is already
there. The example touches four things:

| Call | What it does |
|---|---|
| `Proxmod.api.get(ext, path, opts)` | `GET /api2/json/nodes/<node>/proxmod/<ext>/<path>` through `Proxmox.Utils.API2Request`. `post`/`put`/`delete` are the same shape. `opts` takes `node`, `params`, `success`, `failure`, `waitMsgTarget` |
| `Proxmod.api.url(ext, path, node)` | the same path without the `/api2/json` prefix — for a store's `url`, use `Proxmod.api.storeUrl` |
| `Proxmod.ui.addNodeTab(spec)` | inserts a tab into `PVE.node.Config`. `addQemuTab`, `addLxcTab`, `addGuestTab` (both guest types at once) and `addDatacenterTab` are the rest |
| `Proxmod.ui.addStyle(ext, css)` | injects a stylesheet, once per extension id |

The `spec` handed to a tab helper needs `ext` and `xtype`; `title`, `iconCls`,
`groups` and `after` are optional. **`itemId` is not yours to set** — it is
always `proxmod-<ext>`, which is what makes two extensions unable to collide.
`after` names an existing PVE tab (`'system'` here) rather than an index,
because an index moves every time Proxmox adds a tab of its own.

Every one of these swallows its own exceptions and reports through
`Proxmod.log`, so a mistake here costs a missing tab rather than a blank
interface. That protection stops at the boundary: code inside your component's
own callbacks — `initComponent`, a store's `load`, an event handler — runs
inside ExtJS, not inside proxmod. Wrap anything risky in `Proxmod.guard`.

The full reference is [`docs/js-api.md`](../../docs/js-api.md).

## Build and install

```sh
cd examples/proxmod-example-hello
dpkg-buildpackage -us -uc -b
apt install ../proxmod-example-hello_0.2.0_all.deb
```

Then, on the host:

```sh
proxmod-verify                      # exits 0, lists example-hello as loaded
pvesh get /nodes/$(hostname)/proxmod/example-hello/greet
```

`pvesh` is worth a caveat: it builds its own API tree in a fresh `perl` without
`-MProxmod`, so it may not see proxmod endpoints at all. The authoritative check
is an HTTP request to the running `pveproxy`, which is what `proxmod-verify`
does.

## Things this example deliberately does not do

- **It does not omit `permissions`.** A method without that key is silently
  `root@pam`-only [PVE-F-050]. proxmod refuses to register one, so the choice is
  always visible in the source.
- **It does not touch `/etc/pve`.** That is a FUSE filesystem which is routinely
  unmounted during upgrades. Extension state goes under `/var/lib/proxmod`.
- **It does not pick its own API path.** The path is
  `/nodes/{node}/proxmod/<id>`, derived from the manifest id, which is what
  makes a collision with another extension structurally impossible rather than a
  matter of good manners.
- **It does not patch anything.** See [`docs/patching.md`](../../docs/patching.md)
  for when that is unavoidable, and what it costs.
