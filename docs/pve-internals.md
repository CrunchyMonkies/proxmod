# How Proxmox VE works, from the inside

**Status:** Draft
**Applies to:** Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** read directly out of `proxmox-ve_9.1-1.iso` with
`scripts/extract-pve-source.sh`; the load-bearing claims are entries in
[`pve-facts.md`](pve-facts.md), with raw evidence in
[`facts/pve-9.1.1.txt`](facts/pve-9.1.1.txt)

This is the document that did not exist when two separate projects in this
author's own tree each reverse-engineered the same seams and each got them wrong
in a different way. It explains how a Proxmox VE host is actually put together:
what runs, what talks to what, where the boundaries are, and — the part that
costs people weeks — which of the obvious-looking ways to extend it silently do
not work.

You do not need a Proxmox host to check any of it. Everything below was read out
of an installer ISO:

```sh
./scripts/extract-pve-source.sh --iso proxmox-ve_9.1-1.iso --list
./scripts/extract-pve-source.sh --iso proxmox-ve_9.1-1.iso \
    --cat pve-manager ./usr/share/perl5/PVE/HTTPServer.pm
```

**Read this before writing any extension.** Then
[`backend-extensions.md`](backend-extensions.md) or
[`frontend-extensions.md`](frontend-extensions.md) for how to actually do it.

---

## 1. The shape of the thing

Proxmox VE is a Debian system with a Perl application on top. There is no
application server, no ORM and no framework in the modern sense. There is:

- a set of **long-running Perl daemons**, each a `PVE::Daemon` subclass;
- a **REST API** built by registering methods into a class tree at process
  start, described by JSON Schema;
- a **cluster filesystem** (`/etc/pve`) that is a FUSE mount backed by a
  replicated SQLite database;
- a **single-page ExtJS application** served as one concatenated JavaScript
  file, with no bundler and no module system.

Almost everything surprising about extending it follows from one of those four
facts.

---

## 2. The processes

| Process | User | Listens | Purpose |
|---|---|---|---|
| `pveproxy` | `www-data` | `:8006` (TLS) | The API and web interface everyone talks to |
| `pvedaemon` | root | `127.0.0.1:85` | Executes anything that needs root |
| `pvestatd` | root | — | Polls guests, storages and nodes for status; writes to pmxcfs |
| `pve-cluster` | root | — | `pmxcfs`, the FUSE filesystem at `/etc/pve` |
| `pvescheduler` | root | — | Replication and scheduled jobs |
| `spiceproxy` | `www-data` | `:3128` | SPICE console proxying |

Verified from the shipped service modules [PVE-F-053]:

```perl
# PVE::Service::pvedaemon
max_workers => 3,                                   # may be overridden in init
my $socket = $self->create_reusable_socket(85, '127.0.0.1');
trusted_env => 1,

# PVE::Service::pveproxy
max_workers => 3,
setuid => 'www-data',
setgid => 'www-data',
my $socket = $self->create_reusable_socket(8006, $listen_ip);
trusted_env => 0, # not trusted, anyone can connect
```

Three things in there matter more than they look.

**`pveproxy` is not root.** It drops to `www-data` after binding. It can read
the API tree, validate a request and check an ACL, but it cannot start a VM.
That is the entire reason `pvedaemon` exists.

**`pvedaemon` is bound to loopback.** It is not reachable from the network.
Its only client is `pveproxy` (and `pvesh`, and the CLI tools).

**Three workers.** Both daemons fork three worker processes by default,
overridable with `MAX_WORKERS` in `/etc/default/pveproxy`. Three is a *small*
number. An API method that blocks for thirty seconds inside `pvedaemon` takes
out a third of the host's ability to perform any privileged operation at all for
that whole time. §7 is about what to do instead.

Both daemons run under **Perl taint mode** — `#!/usr/bin/perl -T` [PVE-F-002].
§9 is about what that costs you.

---

## 3. The life of a request

Trace `GET /api2/json/nodes/pve1/status` from the browser:

```
browser
  │  TLS
  ▼
pveproxy (www-data)
  │  1. AnyEvent HTTP server accepts, parses
  │  2. is the path in {pages}? in {dirs}?        ← §10; NO AUTH YET
  │  3. /api2/... → auth_handler: cookie or API token
  │  4. rest_handler:
  │       PVE::API2->find_handler(GET, /nodes/pve1/status)
  │       → ($handler, $info), or 501 if nothing matches
  │       check_api2_permissions($info->{permissions}, …)
  │       proxyto?   → forward to the right node over :8006
  │       protected? → forward to pvedaemon, because $> != 0
  │  5. otherwise: $handler->handle($info, $param)
  ▼
pvedaemon (root), only for protected methods
       find_handler again — in its own tree
       $> == 0, so no further proxying
       $handler->handle($info, $param)
         → JSONSchema::validate($param, $info->{parameters})
         → untaint_recursive($param)
         → $info->{code}->($param)          ← your code runs here
```

The exact source, from `PVE::HTTPServer::rest_handler` [PVE-F-052]:

```perl
my $resp = {
    status  => HTTP_NOT_IMPLEMENTED,
    message => "Method '$method $rel_uri' not implemented",
};
...
($handler, $info) = PVE::API2->find_handler($method, $rel_uri, $uri_param);
...
$rpcenv->check_api2_permissions($info->{permissions}, $auth->{userid}, $uri_param);
...
if ($info->{proxyto} || $info->{proxyto_callback}) { ... }
...
my $euid = $>;
if ($info->{protected} && ($euid != 0)) {
    $resp = { proxy => 'localhost', proxy_params => $params };
}
```

Four consequences worth memorising:

1. **A missing endpoint answers `501 Not Implemented`, not `404`.** The default
   response is constructed before the lookup and returned unchanged when nothing
   matches. If you are debugging a missing endpoint and seeing 404, you have a
   different problem — probably a URL prefix, not a registration.

2. **Permissions are checked by `pveproxy`**, as `www-data`, *before* any
   proxying — including for `protected` methods. `pvedaemon` largely executes
   what it is handed. Your `permissions` block is the access control, not a
   formality.

3. **`protected` proxies only when `$> != 0`.** Inside `pvedaemon` the same code
   path runs the handler directly. Both daemons therefore need the method
   registered — `pveproxy` to find it and decide to proxy, `pvedaemon` to find it
   again and run it. **An extension loaded into only one daemon answers 501 from
   the other**, and this is the single most common way a new endpoint appears to
   half-work.

4. **Your parameters arrive validated and untainted.** `handle()` runs
   `PVE::JSONSchema::validate` and then `untaint_recursive` before calling your
   `code`. Under `-T` that is a genuine gift: you can pass a parameter straight
   to `open` or `system`. It applies to *parameters only* — anything you read
   off disk yourself is still tainted (§9).

---

## 4. The REST tree

There is no router table and no path-to-controller map. `PVE::API2` is a class,
and the tree is built by classes registering into each other at process start.

```perl
package PVE::API2::Nodes::Nodeinfo;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Qemu",
    path     => '{node}/qemu',
});

__PACKAGE__->register_method({
    name        => 'status',
    path        => 'status',
    method      => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    protected   => 1,
    proxyto     => 'node',
    parameters  => { ... },
    returns     => { type => 'object' },
    code        => sub { my ($param) = @_; ... },
});
```

Two kinds of registration: a **subclass mount** (`subclass` + `path`) grafts
another class's whole tree at a point, and a **method** (`name`, `path`,
`method`, `code`) adds one endpoint. `find_handler` walks the tree segment by
segment at request time.

### The registration rules that `die`

`register_method` validates as it goes, and every failure is a `die` — at
**process start**, inside a daemon that is trying to boot. There is no warning
level. From the shipped source [PVE-F-051]:

| Rule | Message |
|---|---|
| One method per path + verb | `duplicate method definition` |
| One name per class | `method name already defined` |
| One subclass per path | `duplicate path` |
| A level holds named folders **or** one `{param}`, never both | `path match error - regex and fixed items` |
| All `{param}` at one level share one name and one regex | `found changed regex match name` / `found changed regex` |

A `die` in `pvedaemon`'s startup is a host with no working API. This is why
`Proxmod::API` re-implements every one of these checks *before* calling
`register_method`, and turns the recoverable ones into logged no-ops.

### The greedy-subtree trap

`{param}` normally matches one path segment. But a subclass mount may set
`fragmentDelimiter => ''`, and then [PVE-F-051]:

```perl
$stack = [join('/', @$stack)] if scalar(@$stack) > 1;
```

Every remaining fragment collapses into a single string, and the `{param}`
swallows the rest of the URI. The live example is storage content:

```
/nodes/{node}/storage/{storage}/content/{volume}
                                        ^^^^^^^^ fragmentDelimiter => ''
```

A volume id contains slashes, so this is correct behaviour for storage. But if
you register `.../content/my-thing`, your method is never reached: the
`{volume}` handler answers, with `volume = "my-thing"`. The class that answers is
the *right* class — so a sanity check that compares class names reports success
while the endpoint is unreachable. That is why `Proxmod::API` compares the
returned method info hash by **reference identity**.

The rule for extension authors is short: never mount below a path that already
contains a `{param}` you did not register yourself.

### `pvesh` and the CLI build their own tree

`pvesh`, `qm`, `pct` and friends build the API tree in their own process from
their own `use` statements. They do not go through `pveproxy`, and they do not
load anything a daemon loaded at runtime. An endpoint that works over HTTP and
is invisible to `pvesh` is not broken — it is a different process with a
different tree.

---

## 5. The JSON Schema layer

Every method describes its parameters and its return value as JSON Schema, and
`PVE::JSONSchema` enforces the parameters before your code runs.

```perl
parameters => {
    additionalProperties => 0,
    properties => {
        node    => get_standard_option('pve-node'),
        vmid    => get_standard_option('pve-vmid'),
        verbose => {
            type => 'boolean', optional => 1, default => 0,
            description => 'Include the slow checks too.',
        },
    },
},
returns => { type => 'object' },
```

Points that matter in practice:

- **`additionalProperties => 0` is not the default.** Set it. Without it a typo
  in a caller's parameter name is silently accepted and silently ignored.
- **`get_standard_option`** (`pve-node`, `pve-vmid`, `pve-storage-id`, …) gives
  you the same validation, description and CLI completion the built-in endpoints
  get. Use it rather than re-describing a node name.
- **`description` is mandatory in spirit**: it is what appears in the API
  viewer, in `pvesh` help, and in the generated documentation. An endpoint
  without descriptions is an endpoint nobody else can use.
- **Return validation is off by default** and the source says why: *"return
  validation is rather lose-lose, as it can require quite a bit of time and lead
  to false-positive errors"*. Declare `returns` anyway — it is documentation
  and it is what the API viewer shows.

---

## 6. Authentication and access control

**Authentication** happens in `PVE::HTTPServer::auth_handler`: a
`PVEAuthCookie` ticket, or an API token in the `Authorization` header. Ticket
auth additionally requires a **CSRF token** header on anything that is not a
`GET`. API tokens skip CSRF (they are stateless by design) but are refused
outright on any method that does not set `allowtoken` — which defaults to 1.

**Authorization** is `$rpcenv->check_api2_permissions($info->{permissions}, …)`,
driven entirely by the `permissions` key on the method.

Forms you will use:

```perl
permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
permissions => { check => ['perm', '/vms/{vmid}', ['VM.Monitor']] },
permissions => { user => 'all' },       # any authenticated user
permissions => { user => 'world' },     # NO AUTHENTICATION AT ALL
permissions => undef,                   # root@pam only, deliberately
```

`check` takes a small expression language — `['perm', path, privs]`, and
`['or', …]` / `['and', …]` to combine. Path placeholders like `{node}` and
`{vmid}` are substituted from the request's own parameters, so the check is
per-object, not per-endpoint.

### The trap: omitting `permissions` entirely

This is the single most expensive mistake in the whole document, because it does
not look like a mistake. From `check_api2_permissions` [PVE-F-050]:

```perl
sub check_api2_permissions {
    my ($self, $perm, $username, $param) = @_;

    return 1 if !$username && $perm->{user} eq 'world';

    return 1 if $username eq 'root@pam';

    die "missing permissions\n" if !$perm || !$perm->{check};
    ...
```

The default is expressed as an **absence**: with no `perm`, `root@pam` returns
early on the line before, and everyone else hits `die "missing permissions"`.

So an endpoint with no `permissions` key:

- works perfectly for its author, who is testing as `root@pam`;
- fails for every other user with a message that names no method;
- logs nothing and warns about nothing.

It is entirely possible to ship this, use it for months, and only discover it
when someone tries to use a non-root account. `Proxmod::API::add_method`
therefore refuses to register a method whose `permissions` key is **absent** —
`undef` is accepted, because writing `undef` is a decision.

### `user => 'world'` means no login

Note the first line: with `$perm->{user} eq 'world'` the check returns 1 with no
username at all. This is what `/access/ticket` uses. If you write it on your own
endpoint, you have published an unauthenticated API on a hypervisor. proxmod
registers it and logs a warning naming the method, because refusing it outright
would break the one legitimate use — but you should treat that warning as an
alarm.

---

## 7. Tasks and UPIDs

An API method that runs long must not run inline. The pattern is
`$rpcenv->fork_worker` (defined in `PVE::RESTEnvironment`, inherited by
`PVE::RPCEnvironment`):

```perl
my ($self, $dtype, $id, $user, $function, $background) = @_;
```

Used from a method's `code`:

```perl
code => sub {
    my ($param) = @_;
    my $rpcenv = PVE::RPCEnvironment::get();
    my $user   = $rpcenv->get_user();

    my $worker = sub {
        print "starting the slow thing\n";   # goes to the task log
        do_the_slow_thing($param);
        print "done\n";
    };

    return $rpcenv->fork_worker('acmefoo', $param->{node}, $user, $worker);
},
returns => { type => 'string' },   # a UPID
```

The return value is a **UPID**, a colon-delimited string [`PVE::UPID::encode`]:

```
UPID:%s:%08X:%08X:%08X:%s:%s:%s:
     node  pid  pstart start  type id user
```

It is the handle for everything else: the task log lives under
`/var/log/pve/tasks/`, the UI's task viewer polls
`/nodes/{node}/tasks/{upid}/status` and `/log`, and anything your frontend does
with a long operation should hand the UPID to `Proxmox.Utils.API2Request`'s task
helpers rather than inventing progress reporting.

Whatever the worker prints on stdout and stderr goes into the task log. That is
the intended way to report progress.

---

## 8. `/etc/pve` — the cluster filesystem

`/etc/pve` is **not a directory**. It is a FUSE mount provided by `pmxcfs`
(`pve-cluster`), backed by a SQLite database that is replicated across the
cluster with Corosync. Writing a file there writes it on every node.

`PVE::Cluster` keeps a list of *observed* files it can fetch over IPC and cache:
`storage.cfg`, `datacenter.cfg`, `user.cfg`, `domains.cfg`, `jobs.cfg`,
`replication.cfg`, `notifications.cfg`, `status.cfg` and others, plus the
per-node trees under `/etc/pve/nodes/<node>/`.

What you need to know as an extension author:

- **It is not always mounted.** It is not there early in boot, and it is
  routinely unmounted during package upgrades. `PVE::Cluster` itself says
  *"pmxcfs isn't mounted (/etc/pve), chickening out.."* and gives up.
- **Therefore: never touch `/etc/pve` from a maintainer script, from a systemd
  unit that runs at boot, or from anything on a daemon's startup path.** Reading
  it at the wrong moment hangs, and hanging in a dpkg trigger wedges the
  upgrade. Proxmox's own `postinst` guards with
  `test -f /etc/pve/local/pve-ssl.pem || exit 0` [PVE-F-005] — copy that
  discipline.
- Reading it from inside a **request handler** is completely normal. By then the
  daemon is up and pmxcfs is mounted.
- It holds the cluster's authentication material (`/etc/pve/priv/`). Treat every
  read as sensitive.
- Locking is `PVE::Cluster::cfs_lock_file`, not `flock` on a path under
  `/etc/pve`.
- A single node still runs pmxcfs. "No cluster" does not mean "no
  `/etc/pve`".

---

## 9. Perl under `-T`, and what it costs you

Both daemons run `#!/usr/bin/perl -T` [PVE-F-002]. Taint mode marks every value
that came from outside the program as untrusted, and refuses to let it reach
anything dangerous. Three consequences dominate:

**`PERL5LIB` and `PERL5OPT` are ignored.** Completely, silently. Any plan that
loads code into these daemons via an environment variable does not work, and
does not announce that it does not work: the daemon starts perfectly and your
module is simply absent. Code must live in a **default `@INC`** directory —
`/usr/share/perl5` on Debian [PVE-F-003] — and be loaded with a command-line
`-M`.

**`require` of a tainted string dies** [PVE-F-042]. Since `readdir` and `glob`
return tainted strings [PVE-F-041], any scheme that discovers plugin modules by
listing a directory must untaint the name through a strict capture regex first:

```perl
my ($safe) = $name =~ /\A([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*)\z/
    or next;                          # rebuilt from the capture, not the original
```

Note the shape: match, then use `$1`. Matching without using the capture leaves
the value tainted, which is the mistake that makes this look intermittent.

**An `:encoding()` layer cannot open a tainted path** [PVE-F-040]. Perl loads
`PerlIO::encoding` lazily, and under `-T` treats that lazy `require` as
insecure. So this dies:

```perl
open(my $fh, '<:encoding(UTF-8)', $path_from_readdir);   # Insecure dependency
```

and this works:

```perl
open(my $fh, '<', $path_from_readdir);                   # bytes; decode after
```

There is a fourth, smaller one: `pvedaemon` starts with a **cleared
environment**. `/usr/bin/pvedaemon` resets `PATH` and deletes `IFS`, `CDPATH`,
`ENV` and `BASH_ENV`, and systemd gives it nothing else. Any test override,
debug switch or path prefix plumbed through an environment variable is
unreachable in production. Use a config file; honour the environment variable
too if you like, but never *only*.

---

## 10. How the web interface is built and served

### The build

`pve-manager` concatenates its entire JavaScript source into **one file**,
`/usr/share/pve-manager/js/pvemanagerlib.js`, shipped pre-built in the `.deb`.
There is no module system, no bundler, no `import`, and no source map. Every
class is defined into one global `Ext` class registry, and everything Proxmox
writes lives under the `PVE.*` namespace.

The page itself comes from a Template Toolkit template,
`/usr/share/pve-manager/index.html.tpl`, whose script order is
[PVE-F-021]:

```
proxmoxlib.js          ← the shared widget toolkit
pvemanagerlib.js       ← every PVE.* class
<inline> Ext.onReady(…) ← builds the workspace
```

That order is the whole opportunity: after `pvemanagerlib.js` and before the
inline block, every `PVE.*` class exists and no ready handler has run yet.

### The serving

`pveproxy` is an `AnyEvent` HTTP server. Its routing is two hashes in
`$self->{server_config}` [PVE-F-024]:

| Table | Match | Checked |
|---|---|---|
| `pages` | **exact** path → a code ref | first |
| `dirs` | path prefix → a filesystem directory | second |

`pveproxy` registers `pages{'/'} => sub { get_index($self->{nodename}, @_) }`
and a set of `dirs` for `/pve2/`, `/novnc/`, `/pve-docs/` and friends.

Two things follow.

**`/` is served without authentication** [PVE-F-023]. So is everything in
`dirs`. The login screen has to be reachable by a logged-out browser, and the
`pages`/`dirs` lookup happens before the auth handler runs. Never put anything
sensitive in a served directory, and never register a `pages` handler that
reads host state.

**`get_index` is a named sub** [PVE-F-020], not an anonymous closure — which
means it can be replaced through the symbol table at runtime, and the `pages`
entry (which calls it by name) picks up the replacement. This is the seam the
entire zero-file-mutation frontend rests on.

`get_index` renders one of **four** different pages [PVE-F-022] — the manager
index, the noVNC console, the xterm.js console, and a mobile page — so anything
wrapping it must key on something that appears only in the page it means to
change, not simply mutate whatever it is handed.

Finally, `PVE::APIServer::AnyEvent::response` **recomputes `Content-Length`**
from the response content [PVE-F-026]. If you change the body, do not touch the
header; setting it yourself is how you get a truncated page.

### `add_dirs` is a trap under `-T`

`PVE::APIServer::AnyEvent::add_dirs` looks like the right way to register a
static directory. It walks the tree with `File::Find` and registers every
subdirectory as its own alias [PVE-F-025] — and under taint mode every path it
produces is tainted. Assign a **string literal** into `dirs` instead, and keep
the directory flat:

```perl
$cfg->{dirs}{'/myprefix/'} = '/usr/share/mything/www/';   # literal: untaintable
```

### The ExtJS side

The classes worth knowing [PVE-F-030]:

| Class | What it is |
|---|---|
| `PVE.node.Config` | The per-node tab panel |
| `PVE.qemu.Config` | The per-VM tab panel |
| `PVE.lxc.Config` | The per-container tab panel |
| `PVE.dc.Config` | The datacenter tab panel |

You add a tab by overriding the class's `initComponent` and calling
`insertNodes` [PVE-F-031]. Two hazards, both confirmed in the shipped source
[PVE-F-032]: `insertNodes` **throws on a duplicate `itemId`**, and it calls
`shift()` on `item.groups` — so a `groups` array shared between two insertions
is consumed by the first and behaves differently for the second. Give every tab
a globally-unique namespaced `itemId`, and never hand it an array you did not
build fresh.

And the universal ExtJS rule: in an override, **call `callParent` first**, then
do your work. An override that works before the parent has run leaves the
component half-constructed if it throws.

---

## 11. The on-disk map

| Path | Owner | What |
|---|---|---|
| `/usr/share/perl5/PVE/` | several `libpve-*` packages | The Perl libraries and the API2 tree |
| `/usr/share/perl5/PVE/API2/` | `pve-manager`, `libpve-*` | The API endpoint classes |
| `/usr/share/perl5/PVE/Service/` | `pve-manager` | The daemon classes |
| `/usr/share/pve-manager/` | `pve-manager` | `index.html.tpl`, images, css |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | `pve-manager` | The whole UI, concatenated |
| `/usr/share/javascript/proxmox-widget-toolkit/` | `proxmox-widget-toolkit` | `proxmoxlib.js`, shared with PBS/PMG |
| `/usr/share/novnc-pve/`, `/usr/share/pve-xtermjs/` | their packages | Console assets |
| `/usr/bin/{pveproxy,pvedaemon,pvestatd,pvesh,qm,pct}` | `pve-manager`, `qemu-server`, `pve-container` | Entry points |
| `/etc/pve/` | **pmxcfs** — no package owns it | Cluster configuration (§8) |
| `/etc/default/pveproxy` | admin | `MAX_WORKERS`, listen address, ciphers |
| `/var/log/pve/tasks/` | runtime | Task logs, indexed by UPID |
| `/var/lib/pve-cluster/config.db` | `pve-cluster` | The SQLite behind `/etc/pve` |

Everything in the first block is owned by a Debian package. `dpkg -V pve-manager`
tells you whether anything has modified it — which is the test proxmod is built
to pass.

---

## 12. Seam inventory: what is supported and what is not

The most important table in this document. Proxmox supports several genuine
extension points. If one of them fits your problem, **use it** — nothing in
proxmod is as stable as a documented plugin interface.

### Officially supported

| Seam | Use it for | Where |
|---|---|---|
| Storage plugins | A new storage backend | `PVE::Storage::Plugin` subclass |
| Authentication realms | A new identity source | `PVE::Auth::Plugin` subclass |
| Hookscripts | Reacting to guest lifecycle events | `qm set <vmid> --hookscript` |
| Backup hook script | Reacting to backup phases | `vzdump.conf` |
| Notification targets | Sending alerts elsewhere | `notifications.cfg` |
| The REST API itself | Anything a client can do from outside | `/api2/json` |
| `pvesh`, `qm`, `pct` | Scripting from the host | CLI |
| ACL roles and privileges | Delegating existing operations | `/access/roles` |

If your goal is "run something when a VM starts", that is a hookscript, not an
extension framework. If your goal is "let a service call one privileged
operation without `root@pam`", that is a custom role plus an API token, and you
only need a custom endpoint if no existing endpoint does the job.

### Community mechanisms — not supported, may break at any release

| Seam | What it gets you | Stability |
|---|---|---|
| `-M` injection via a systemd `ExecStart` drop-in | Loading code into a running daemon | Depends on `ExecStart` and on `-T` semantics; probe at start |
| Glob-wrapping `PVE::Service::pveproxy::get_index` | One `<script>` tag in the index | Depends on `get_index` staying a named sub [PVE-F-020] |
| Assigning into `server_config->{dirs}` / `{pages}` | Serving your own assets and dynamic pages | Depends on the two-table routing [PVE-F-024] |
| `register_method` into `PVE::API2::*` from outside | Your own REST endpoints | The mechanism is stable; the tree's *shape* is not |
| `Ext.define({override: 'PVE.node.Config'})` | UI components | Depends on the class names [PVE-F-030] |
| Editing `index.html.tpl` or a `PVE/*.pm` file | Anything | **Overwritten by the next upgrade.** See [`patching.md`](patching.md) |

proxmod uses rows 1–5 and refuses row 6 except through the deliberately
unattractive facility in [`patching.md`](patching.md). Every one of rows 1–5 is
probed at startup, and a missing seam disables the feature that needed it rather
than the daemon.

---

## 13. The danger zone

Things that look like they work.

**Setting `PERL5LIB` in a systemd drop-in.** The daemon starts, the unit is
green, your module never loads. Taint mode ignores it [PVE-F-002]. There is no
error anywhere.

**Registering a method with no `permissions` key.** Works for you, denies
everyone else, logs nothing (§6).

**Verifying with a fresh `perl -M... -e1`.** It proves the module is
*loadable*. It proves nothing about whether the *running daemon* loaded it — and
those two answers come apart in exactly the case you are trying to detect. Read
the running process's journal since `ExecMainStartTimestamp` instead.

**`systemctl reload pveproxy` after injecting `-M`.** PVE's graceful reload
`exec()`s the original `argv`, which does not contain your `-M`. The daemon comes
back healthy and unextended. And `pve-manager`'s own `postinst` runs
`deb-systemd-invoke reload-or-try-restart` on every upgrade [PVE-F-005], so this
fires whether or not you ever type it. Override `ExecReload` to a full restart.

**Mounting an endpoint under `content/`** or any other subtree with a greedy
`{param}`. It registers cleanly and is never reached (§4).

**Comparing class names to check a route resolved.** Inside a greedy subtree the
right class answers with the wrong method. Compare the method info hash by
reference.

**`add_dirs` for static files.** Tainted paths under `-T` [PVE-F-025].

**`open($fh, '<:encoding(UTF-8)', $path)`** where `$path` came from `readdir`.
Dies under `-T` [PVE-F-040].

**Reading `/etc/pve` from a maintainer script or a boot-time unit.** It may not
be mounted, and hanging in a dpkg trigger wedges the whole upgrade (§8).

**Editing `index.html.tpl` with `sed` and reapplying after upgrades.** Two
packages doing this race; the reapply logic drifts from what the installer
actually patched; the backup goes stale and a later revert *downgrades* the host.
All four of those are documented failures of real code, in
[`patching.md`](patching.md).

**Assuming `pvesh` sees your endpoint.** It builds its own tree in its own
process (§4).

**Blocking in a `protected` method.** Three workers (§2).

---

## 14. Re-deriving this yourself

Nothing here should be taken on trust, including from this document. For a new
Proxmox point release:

```sh
# what is in the ISO
./scripts/extract-pve-source.sh --iso proxmox-ve_9.x-1.iso --list

# any file out of any package, without installing anything
./scripts/extract-pve-source.sh --iso proxmox-ve_9.x-1.iso \
    --cat libpve-common-perl ./usr/share/perl5/PVE/RESTHandler.pm

# maintainer scripts and triggers
./scripts/extract-pve-source.sh --iso proxmox-ve_9.x-1.iso \
    --control pve-manager triggers

# regenerate every piece of evidence behind the fact ledger
make facts ISO=proxmox-ve_9.x-1.iso
git diff docs/facts/
```

That last diff is the list of assumptions that moved. Anything that changed
invalidates the fact that cited it — and every requirement in
[`specifications.md`](specifications.md) that cited *that*.

---

## Where to go next

| You want to | Read |
|---|---|
| Add a REST endpoint | [`backend-extensions.md`](backend-extensions.md) |
| Add something to the web interface | [`frontend-extensions.md`](frontend-extensions.md) |
| Ship it as a `.deb` | [`packaging.md`](packaging.md) |
| Modify a Proxmox file anyway | [`patching.md`](patching.md), then reconsider |
| Know exactly what proxmod promises | [`specifications.md`](specifications.md) |
| Check a claim made here | [`pve-facts.md`](pve-facts.md) |
</content>
</invoke>
