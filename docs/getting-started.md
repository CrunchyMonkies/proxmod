# Getting started

**Status:** Draft
**Applies to:** proxmod 0.2.1, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** every command below is run by the example package's
`Makefile` or by the QEMU integration suite; the example source is
[`examples/proxmod-example-hello/`](../examples/proxmod-example-hello)

Build and install an extension that adds a tab to the node view and an API
endpoint behind it. About twenty minutes.

**You need a test host.** This installs into `pvedaemon` and `pveproxy` and
restarts them. Not on production, not the first time.

---

## 1. Install proxmod

```sh
apt install ./proxmod_*_all.deb
proxmod-verify
```

Expect exit 0 and a list of `ok` lines. If not, [`install.md`](install.md) §9.

Then the claim worth checking once, so you believe it later:

```sh
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl
```

Silence. proxmod is loaded into both daemons and has not touched a single
Proxmox file.

## 2. Build the example

```sh
cd examples/proxmod-example-hello
dpkg-buildpackage -us -uc -b
apt install ../proxmod-example-hello_*.deb
```

Reload the Proxmox web interface, select a node, and there is a **Hello** tab.
Click it: the panel calls `/nodes/{node}/proxmod/example-hello/greet` and shows
what came back.

Nothing in that package ran a maintainer script. It wrote three files into
directories proxmod watches, a dpkg trigger fired, and `proxmod-reapply`
converged. That is the entire contract.

## 3. What the three files are

```
/usr/share/perl5/ProxmodExample/Hello.pm                        the backend
/usr/share/proxmod/www/proxmod-example-hello.js                 the frontend
/usr/share/proxmod/extensions.d/50-proxmod-example-hello.conf   the manifest
```

**The manifest** names the id, the Perl module, and the JS assets. It is the
only thing proxmod reads at boot; everything else follows from it.

```json
{
  "id": "example-hello",
  "version": "0.2.1",
  "order": 50,
  "backend": { "module": "ProxmodExample::Hello",
               "daemons": ["pvedaemon", "pveproxy"] },
  "frontend": { "assets": ["proxmod-example-hello.js"] }
}
```

Full field reference: [`extension-manifest.md`](extension-manifest.md).

**The backend** is a package with one sub. proxmod calls it once per daemon.

```perl
sub proxmod_register {
    my ($api) = @_;

    $api->mount(scope => 'node', subclass => __PACKAGE__);

    $api->add_method(
        class       => __PACKAGE__,
        name        => 'greet',
        path        => 'greet',
        method      => 'GET',
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
        parameters  => { ... },
        returns     => { ... },
        code        => sub { return { message => 'hello from proxmod' } },
    );
}
```

`permissions` is **mandatory**. There is no default, on purpose — to Proxmox, a
method with no `permissions` key is a working endpoint that only `root@pam` may
call, silently [PVE-F-050]. See [ADR 0006](adr/0006-permissions-are-mandatory.md).

**The frontend** is plain JavaScript in one global scope — no modules, no
bundler, no build step.

```js
Proxmod.ui.addNodeTab({
    ext:     'example-hello',
    title:   'Hello',
    xtype:   'proxmodExampleHello',
    iconCls: 'fa fa-comment',
});
```

`addNodeTab` maintains a **single** override chain per host class and guards
every callback, so a mistake here costs your tab and not the interface.

## 4. Make it yours

Copy the example directory, then rename in five places:

```sh
cp -r examples/proxmod-example-hello ~/my-extension
cd ~/my-extension
```

| | from | to |
|---|---|---|
| the id | `example-hello` | `my-thing` |
| the Perl package | `Proxmod::Example::Hello` | `Acme::MyThing` |
| the manifest | `50-proxmod-example-hello.conf` | `50-proxmod-my-thing.conf` |
| the asset | `example-hello.js` | `my-thing.js` |
| the ExtJS xtype | `proxmodExampleHelloPanel` | `proxmodMyThingPanel` |

Your Perl module does **not** have to be under `Proxmod::` — that namespace is
proxmod's own. Use one you own.

Then:

```sh
make deb && apt install ../*.deb && proxmod-verify
```

## 5. The edit-test loop

**Changed only JavaScript?** Nothing to restart. `loader.js` is generated per
request from the live registry — copy the file into
`/usr/share/proxmod/www/` and reload the page with the cache disabled.

**Changed Perl or the manifest?**

```sh
systemctl restart pvedaemon pveproxy
proxmodctl logs
```

**Check it registered:**

```sh
proxmodctl list      # is your extension there, and did it load?
proxmodctl status    # is proxmod itself healthy?
```

## 6. When it does not work

Three commands, in order:

```sh
proxmod-verify        # is proxmod itself healthy?
proxmodctl list       # did your extension load?
proxmodctl logs       # why not?
```

The most common four:

| Symptom | Usually |
|---|---|
| Extension not in `proxmodctl list` | the manifest is malformed, or its `id` is invalid — `proxmodctl logs` names the file |
| Loaded, but no tab | the asset is missing from `/usr/share/proxmod/www/`, or the JS threw — check the browser console |
| Endpoint returns **501** | you registered in `pvedaemon` only. Every request reaches `pveproxy` first, and it must find the method in its own tree before it can proxy [PVE-F-052]. Register in both, which is the default |
| Endpoint returns **403** | your `permissions` check does not match the calling user. Test as a non-root user with a real ACL — testing as root proves nothing |

`pvesh` will **not** see your endpoint. It builds its own API tree in a process
that was not started through proxmod's wrapper. Use the browser, or curl over
HTTPS with a ticket.

Symptom-first: [`troubleshooting.md`](troubleshooting.md).

## 7. Before you ship it

- `permissions` on every method, checked as a non-root user with a real ACL
- Every value rendered in the interface passed through `Ext.String.htmlEncode`
  — ExtJS does not escape by default, and guest names are user-controlled
- No secrets in the JS asset — it is served **unauthenticated** [PVE-F-023]
- `run_command(['prog', $arg])`, never `system("prog $arg")`
- Everything namespaced under your id: Perl package, API path, CSS prefix,
  ExtJS `itemId`, `xtype`
- `dpkg -V pve-manager` still silent
- `apt purge` leaves the daemons running and Proxmox pristine

Full lists: [`packaging.md`](packaging.md) §9,
[`frontend-extensions.md`](frontend-extensions.md) §9,
[`security.md`](security.md) §8.

---

## Where to go next

| | |
|---|---|
| Writing the backend | [`backend-extensions.md`](backend-extensions.md) |
| Writing the frontend | [`frontend-extensions.md`](frontend-extensions.md) |
| The manifest, field by field | [`extension-manifest.md`](extension-manifest.md) |
| The Perl API | [`perl-api.md`](perl-api.md) |
| The JS API | [`js-api.md`](js-api.md) |
| Building the `.deb` | [`packaging.md`](packaging.md) |
| How Proxmox itself works | [`pve-internals.md`](pve-internals.md) |
| How proxmod works | [`architecture.md`](architecture.md) |
