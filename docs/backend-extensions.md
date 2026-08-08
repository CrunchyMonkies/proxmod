# Writing a backend extension

**Status:** Draft
**Applies to:** proxmod 0.1.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** the worked example in this document is
[`examples/proxmod-example-hello/`](../examples/proxmod-example-hello/), which is
built and exercised by the test suite; Proxmox-internals claims cite
[`pve-facts.md`](pve-facts.md)

A backend extension adds REST endpoints to a Proxmox VE host. It is a Perl
module, a manifest, and a `.deb` with **no maintainer scripts at all**.

Read [`pve-internals.md`](pve-internals.md) first — particularly §3 (the request
lifecycle), §4 (the REST tree) and §6 (permissions). This document assumes it.

---

## 1. Should you write one?

Probably not, and it is worth thirty seconds to be sure. In order of
preference:

| If you want to | Do this instead |
|---|---|
| React to a guest starting or stopping | A **hookscript** — `qm set <vmid> --hookscript` |
| React to backup phases | The **vzdump hook script** |
| Let a service perform an existing operation without `root@pam` | A **custom ACL role** plus an **API token** |
| Add a storage backend | A **`PVE::Storage::Plugin` subclass** |
| Add an identity source | A **`PVE::Auth::Plugin` subclass** |
| Query or drive Proxmox from outside | The **existing REST API** |

All of those are supported interfaces that Proxmox intends you to use. A
proxmod extension is for the case that remains: you need Proxmox itself to
expose something it does not expose, to its own web interface or to its own API
clients, with its own authentication and its own ACLs.

---

## 2. Hello, world

Three files. Nothing else, and no maintainer scripts.

```
/usr/share/perl5/AcmeFoo/API.pm                  the module
/usr/share/proxmod/extensions.d/50-acme-foo.conf the manifest
/usr/share/proxmod/www/acme-foo.js               (optional) the frontend
```

### The manifest

```jsonc
{
    "id": "acme-foo",
    "version": "1.0.0",
    "order": 50,
    "backend": {
        "module": "AcmeFoo::API"
    }
}
```

`id` is an identifier, not a display name: it appears in your URL path, in log
lines and in JavaScript. `enabled` is absent, which means **enabled**. See
[`extension-manifest.md`](extension-manifest.md) for every field.

### The module

```perl
package AcmeFoo::API;

use strict;
use warnings;

use PVE::RESTHandler;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::RESTHandler);

sub proxmod_register {
    my ($api) = @_;

    $api->mount(scope => 'node', subclass => __PACKAGE__);

    $api->add_method(
        class       => __PACKAGE__,
        name        => 'index',
        path        => '',
        method      => 'GET',
        permissions => { user => 'all' },
        description => 'Index of the Acme Foo extension.',
        parameters  => {
            additionalProperties => 0,
            properties => { node => get_standard_option('pve-node') },
        },
        returns => { type => 'array', items => { type => 'object' } },
        code    => sub { return [{ subdir => 'status' }] },
    );

    return;
}

1;
```

That is a working extension. It answers at:

```
GET /api2/json/nodes/pve1/proxmod/acme-foo
```

### `use base qw(PVE::RESTHandler)` is fine

It is a compile-time dependency on Proxmox, and your module is only ever loaded
from inside a running `pvedaemon` or `pveproxy`, where `PVE::RESTHandler` is
already compiled. (proxmod's *own* modules may not do this, because they also
have to load in `proxmod-verify` and under a bare `perl -c`. You have no such
obligation.)

---

## 3. `proxmod_register` — the contract

```perl
sub proxmod_register {
    my ($api) = @_;
    ...
}
```

| | |
|---|---|
| Called | once per wrapped daemon, at daemon start, during `INIT` |
| Argument | a `Proxmod::API` object scoped to your extension |
| Return | ignored |
| If it dies | your extension is skipped, one `proxmod: error:` line is logged, and **every other extension and both daemons are unaffected** |

That last row is a licence to fail loudly. If your prerequisite is missing,
`die` with a message that says so. Do not half-register and hope.

It must be safe to call more than once per process — `mount` and `add_method`
are idempotent, but if you keep your own side-effecting state, guard it.

The `$api` object carries your identity:

```perl
$api->id;      # 'acme-foo' — your extension id from the manifest
$api->daemon;  # 'pvedaemon' or 'pveproxy'
```

`daemon` is occasionally useful — for skipping a `pveproxy`-side setup that only
makes sense as root — but resist branching on it for the *registration itself*.
See §5.

---

## 4. Mounting

```perl
$api->mount(scope => 'node',    subclass => __PACKAGE__);   # default
$api->mount(scope => 'cluster', subclass => __PACKAGE__);
```

| Scope | Your subtree | Parent |
|---|---|---|
| `node` | `/nodes/{node}/proxmod/<id>` | `PVE::API2::Nodes::Nodeinfo` |
| `cluster` | `/cluster/proxmod/<id>` | `PVE::API2::Cluster` |

You do not choose the path. It is derived from your manifest `id`, which is
exactly why two extensions can never collide — and why the `id` regex is strict.

An extension may take both scopes. Node scope is right for anything about *this
machine*; cluster scope for anything about the cluster as a whole. If in doubt,
node.

`mount` is idempotent for the same class, and **dies** if a different class has
already claimed your subtree — before touching PVE's registry, so nothing is
left half-registered. proxmod then probes the mount through `find_handler` and
warns if it did not resolve where it should have, which catches the case where
the mount registered cleanly and is nonetheless unreachable.

---

## 5. Which daemons?

Register in **both**. It is the default, and it is almost always correct.

```jsonc
"backend": {
    "module": "AcmeFoo::API",
    "daemons": ["pvedaemon", "pveproxy"]    // the default; you can omit it
}
```

The reason is the request lifecycle [PVE-F-052]. Every request arrives at
`pveproxy`. `pveproxy` must find your method in *its own* tree before it can
decide whether to proxy it; if the method is `protected`, `pvedaemon` then finds
it again in *its* tree to run it. Load into only one and the other answers **501
Not Implemented**.

The symptom is characteristic and confusing: unprotected endpoints work,
protected ones 501 (registered in `pveproxy` only), or every endpoint 501 while
`journalctl -u pvedaemon` clearly shows your extension registering (registered
in `pvedaemon` only).

Narrow `daemons` only when you have a specific reason — for instance, a module
whose `use` line pulls in something that must not be loaded into the
unprivileged daemon.

---

## 6. Registering a method

```perl
$api->add_method(
    class       => __PACKAGE__,   # required — which class this hangs off
    name        => 'status',      # required — unique within the class
    path        => 'status',      # required — '' for the subtree root
    method      => 'GET',         # GET | POST | PUT | DELETE
    permissions => { ... },       # REQUIRED — see §7
    protected   => 1,             # optional — route to pvedaemon
    proxyto     => 'node',        # optional — route to the right node
    description => '...',
    parameters  => { ... },
    returns     => { ... },
    code        => sub { ... },
);
```

Everything except `class` and `permissions` is passed through to
`PVE::RESTHandler::register_method` unchanged, so the whole of PVE's method
vocabulary is available to you.

What proxmod adds on top:

- **`permissions` must be present** (§7).
- The HTTP verb is checked against the four PVE dispatches.
- A duplicate `(class, method, path)` is a logged no-op rather than a `die`.
  PVE dies on a duplicate [PVE-F-051]; inside `pvedaemon` that is a host with no
  API, and "this extension got listed twice" must not be able to cause it.
- After registration, the route is **replayed** through `find_handler` and the
  returned method info hash is compared **by reference** to the one registered.
  A mismatch is logged naming the method that actually answers. §9 explains why
  comparing class names is not enough.

### Paths

Keep them shallow and boring:

```perl
path => '',            # /nodes/{node}/proxmod/acme-foo
path => 'status',      # /nodes/{node}/proxmod/acme-foo/status
path => 'items',       # .../items
path => '{id}',        # .../{id}     — a parameter
```

Two rules inherited from `PVE::RESTHandler` [PVE-F-051]:

- A level holds **named folders or one `{param}`, never both**. `.../status` and
  `.../{id}` at the same level is `path match error - regex and fixed items`,
  and that is a `die`.
- All `{param}` at one level share **one** name and **one** regex.

Confining you beneath `proxmod/<id>` makes this hard to hit — but a nested
subclass of your own can still reach it.

### The index convention

Give your subtree root a `GET` at `path => ''` that lists its children, with a
`links` block:

```perl
returns => {
    type  => 'array',
    items => {
        type => 'object',
        properties => { subdir => { type => 'string' } },
    },
    links => [{ rel => 'child', href => '{subdir}' }],
},
code => sub { return [{ subdir => 'status' }, { subdir => 'items' }] },
```

This is what makes your extension navigable in the API viewer and in `pvesh ls`,
and it costs four lines.

---

## 7. Permissions — read this one

**Every method must carry a `permissions` key.** `Proxmod::API::add_method`
refuses to register one that does not, and the refusal is the point of the
feature.

A method with no `permissions` key is not an error and is not logged. From the
shipped `check_api2_permissions` [PVE-F-050]:

```perl
return 1 if !$username && $perm->{user} eq 'world';
return 1 if $username eq 'root@pam';
die "missing permissions\n" if !$perm || !$perm->{check};
```

The default is an **absence**. `root@pam` returns early on line two; everyone
else dies on line three with a message that names no method. Your endpoint works
perfectly for you, because you are testing as `root@pam`, and denies every other
user on the host. Nothing warns. This is a mistake it is entirely possible to
ship and not discover for months.

The four things you may write, all explicit:

```perl
# the normal case: a real ACL check, per object
permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },

# any authenticated user
permissions => { user => 'all' },

# root@pam only — PVE's default, chosen deliberately and in writing
permissions => undef,

# NO AUTHENTICATION AT ALL — proxmod registers it and logs a warning
permissions => { user => 'world' },
```

### Choosing a check

`check` is a small expression language:

```perl
['perm', '/nodes/{node}', ['Sys.Audit']]
['perm', '/vms/{vmid}',   ['VM.Monitor']]
['or',  ['perm', '/', ['Sys.Modify']], ['perm', '/nodes/{node}', ['Sys.Modify']]]
['and', ['perm', '/nodes/{node}', ['Sys.Audit']], ['perm', '/storage/{storage}', ['Datastore.Audit']]]
```

Path placeholders are substituted from the request's own parameters *before* the
check runs, so `/nodes/{node}` asks "may this user audit **this** node", not
"some node". That is the whole value of the mechanism — use it rather than
checking `/`.

Rules of thumb:

| Your method | Privilege |
|---|---|
| Reads node-level information | `Sys.Audit` on `/nodes/{node}` |
| Changes node-level state | `Sys.Modify` on `/nodes/{node}` |
| Reads about a guest | `VM.Audit` on `/vms/{vmid}` |
| Changes a guest | `VM.Config.*` or `VM.PowerMgmt` on `/vms/{vmid}` |
| Touches a storage | `Datastore.Audit` / `Datastore.Allocate` on `/storage/{storage}` |

Reuse an existing privilege whose meaning matches. Do not invent a privilege
unless you are also prepared to document it and ship a role that grants it.

### `user => 'world'`

Look again at line one of that source: with `world`, the check returns 1 **with
no username at all**. This is what `/access/ticket` uses. Written on your own
endpoint, it publishes an unauthenticated API on a hypervisor. proxmod registers
it — refusing outright would break the one legitimate use — and logs a warning
naming the method. Treat that warning as an alarm.

---

## 8. `protected`, `proxyto`, and doing work

### `protected => 1` is the bridge to root

`pveproxy` runs as `www-data`. If your code needs to write below `/var/lib`,
read a privileged file, or run a `pve*` command, mark the method `protected` and
`pveproxy` forwards the whole request to `pvedaemon`, which runs it as root
[PVE-F-052].

Nothing less will do — and nothing more is needed. "It works when I run it as
root" almost always means a missing `protected`.

Do **not** mark a method protected when it does not need root. Protected methods
cost a full internal round trip, and they consume one of `pvedaemon`'s three
workers.

### `proxyto => 'node'`

Your method's path contains `{node}`, but the request arrived at whichever node
the browser is connected to. `proxyto => 'node'` makes PVE forward it to the
node named in the path. Without it, `GET /nodes/pve2/proxmod/acme-foo/status`
sent to `pve1` runs on `pve1` and reports `pve1`'s state under `pve2`'s name.

Use `proxyto => 'node'` for anything that reads or writes *this machine*. Omit
it for anything that reads cluster-wide state from `/etc/pve`, which is the same
everywhere.

### Long work: `fork_worker`

Three workers per daemon [PVE-F-053]. A `protected` method that blocks for
thirty seconds removes a third of the host's capacity to run any privileged API
call at all.

```perl
code => sub {
    my ($param) = @_;
    my $rpcenv = PVE::RPCEnvironment::get();
    my $user   = $rpcenv->get_user();

    my $worker = sub {
        print "starting\n";               # goes to the task log
        do_the_slow_thing($param);
        print "done\n";
    };

    return $rpcenv->fork_worker('acmefoo', $param->{node}, $user, $worker);
},
returns => { type => 'string' },          # a UPID
```

Anything the worker prints lands in the task log, and the UPID you return is
what the UI's task viewer follows. The threshold is roughly *a second*: if it
can take longer than that, fork.

---

## 9. Two failure modes that look like success

### Greedy subtrees

Never mount below a path containing a `{param}` you did not register. A subclass
mounted with `fragmentDelimiter => ''` collapses every remaining fragment into
one string [PVE-F-051], so a method registered underneath it is answered by the
`{param}` handler instead.

The live case is storage content:

```
/nodes/{node}/storage/{storage}/content/{volume}
```

Register `.../content/my-thing` and the `{volume}` handler answers with
`volume = "my-thing"`. Note that the **right class** answered — so a check that
compares class names reports success. proxmod compares the method info hash by
reference identity for exactly this reason, and `proxmod-verify --json` will
tell you which method actually answers.

You cannot hit this from your own `proxmod/<id>` subtree. You can hit it the
moment you decide to mount somewhere "more natural".

### Registering twice

PVE dies on a duplicate path, method or name [PVE-F-051], and inside
`pvedaemon`'s startup that is a host with no API. proxmod makes duplicates
harmless, but the underlying rule is still there for anything you register by
hand. Do not call `PVE::RESTHandler->register_method` directly.

---

## 10. Talking to the system safely

### Your parameters are already clean

`PVE::RESTHandler::handle` validates `$param` against your `parameters` schema
and then runs `untaint_recursive` on it before calling your `code`. Declared
parameters can go straight to `open` or `system`.

That applies to **parameters only**. Anything you read yourself — a config file,
`readdir`, `/proc` — is tainted and must be rebuilt from a capture:

```perl
my ($one) = ($line =~ m/\A(\d+\.\d+)\s/);   # match, then use $1
```

Matching without using the capture leaves the value tainted, which is why this
class of bug looks intermittent.

### Running commands

Use `PVE::Tools::run_command`, not backticks:

```perl
use PVE::Tools;

my $out = '';
PVE::Tools::run_command(
    ['/usr/sbin/thing', '--json', $param->{name}],
    outfunc => sub { $out .= "$_[0]\n" },
    errfunc => sub { warn "thing: $_[0]\n" },
    timeout => 30,
);
```

It takes an argument list (no shell, so no quoting bugs), supports a timeout,
and raises a proper error on non-zero exit.

### Where to keep state

| Kind | Where |
|---|---|
| Your own runtime state | `/var/lib/<yourpackage>/`, or `/var/lib/proxmod/` |
| Your own configuration | `/etc/<yourpackage>/` |
| Cluster-wide guest/storage config | read it from `/etc/pve` — do not write your own files there |

**Never keep extension state in `/etc/pve`.** It is a FUSE filesystem, unmounted
during upgrades, replicated to every node, and it holds the cluster's
authentication material. Reading it from a request handler is fine; it is not a
place for your data.

### The environment is empty

`pvedaemon` clears its environment: `/usr/bin/pvedaemon` resets `PATH` and
deletes `IFS`, `CDPATH`, `ENV` and `BASH_ENV`, and systemd supplies nothing
else. Any test override, debug flag or root-path prefix you plumb through an
environment variable is **unreachable in production**.

This is not hypothetical — it is the defect that made one prior extension's
fake-sysfs test harness untestable against the real daemon. Read such settings
from a config file. Honour an environment variable *as well* if you like, for
hand-started daemons, but never only.

---

## 11. Logging

Write to STDERR. systemd routes it to the journal, next to the PVE messages that
explain it.

```perl
warn "acme-foo: could not read the widget table: $err\n";
```

Prefix every line with your extension id, and end with `"\n"` (without it Perl
appends `at ... line N`, which is noise in a log). Then:

```sh
journalctl -u pvedaemon -u pveproxy | grep acme-foo
```

For anything the administrator should act on, prefer failing the request with a
proper HTTP error over logging and returning success:

```perl
use PVE::Exception qw(raise_param_exc raise_perm_exc);

raise_param_exc({ name => 'no such widget' }) if !$widget;
die "the widget service is not running\n";     # becomes a 500
```

---

## 12. Testing

### Without a Proxmox host

Your module should at least compile under taint mode, exactly as the daemon will
load it:

```sh
perl -T -c -I/usr/share/perl5 lib/AcmeFoo/API.pm
```

If you have no PVE libraries locally, stub `PVE::RESTHandler` in a test lib
directory — proxmod's own `t/lib/` shows the pattern.

### On a host

```sh
# 1. is proxmod itself healthy?
proxmod-verify --json | jq

# 2. did the daemons load your extension?
journalctl -u pvedaemon -u pveproxy \
    --since "$(systemctl show -p ExecMainStartTimestamp --value pvedaemon)" \
    | grep proxmod

# 3. does the endpoint answer?
pvesh get /nodes/$(hostname)/proxmod/acme-foo    # note: see below
curl -k -H "Authorization: PVEAPIToken=..." \
    https://localhost:8006/api2/json/nodes/$(hostname)/proxmod/acme-foo
```

**`pvesh` will not see your endpoint.** It builds its own API tree in its own
process from its own `use` statements; it does not load anything a daemon loaded
at runtime. This is expected, not a bug. Test over HTTP.

### The test that actually matters

Test as a **non-root user**. Create one, give it the role your `permissions`
block requires, and call the endpoint:

```sh
pveum user add test@pve --password …
pveum acl modify /nodes/$(hostname) --user test@pve --role PVEAuditor
```

Everything works as `root@pam`. That is precisely the problem (§7).

---

## 13. Packaging

Your `.deb` needs **no maintainer scripts**. Writing into
`/usr/share/proxmod/extensions.d` fires proxmod's dpkg trigger, and
`proxmod-reapply` converges the host.

```
Package: acme-foo
Architecture: all
Depends: proxmod (>= 0.1.0), ${misc:Depends}
Description: Acme Foo for Proxmox VE
```

Do **not**: ship a systemd drop-in for `pvedaemon`/`pveproxy`, call
`proxmod-reapply` or `systemctl restart pveproxy` from a maintainer script, or
write into `/etc/proxmod/`. proxmod does all of that once; doing it twice means
two restarts.

Full detail — including the `dh_fixperms` trap and maintainer-script ordering —
in [`packaging.md`](packaging.md). A complete buildable package is
[`examples/proxmod-example-hello/`](../examples/proxmod-example-hello/).

---

## 14. Checklist

Before you ship:

- [ ] Every method has a `permissions` key, and you have tested as a non-root user
- [ ] `protected => 1` on everything that needs root, and nothing that does not
- [ ] `proxyto => 'node'` on everything that reads or writes this machine
- [ ] `additionalProperties => 0` on every `parameters` block
- [ ] Every parameter and the return value have a `description`
- [ ] `get_standard_option` for `node`, `vmid`, `storage`
- [ ] Anything that can take more than a second goes through `fork_worker`
- [ ] Nothing read off disk reaches `open`/`system` without being untainted
- [ ] No environment variable is load-bearing
- [ ] Nothing writes to `/etc/pve`
- [ ] `perl -T -c` passes
- [ ] The package has no maintainer scripts and depends on `proxmod`
- [ ] `proxmod-verify` exits 0 with the extension installed

---

## Reference

- [`perl-api.md`](perl-api.md) — every `Proxmod::API` method and argument
- [`extension-manifest.md`](extension-manifest.md) — every manifest field
- [`specifications.md`](specifications.md) §6 — the normative requirements (`REQ-BE-*`)
- [`pve-internals.md`](pve-internals.md) — how the machinery underneath works
- [`troubleshooting.md`](troubleshooting.md) — symptom-first debugging
</content>
</invoke>
