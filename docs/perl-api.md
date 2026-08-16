# The Perl API

**Status:** Draft
**Applies to:** proxmod 0.1.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** signatures, defaults and every `die` message below were
read out of [`perl/Proxmod/API.pm`](../perl/Proxmod/API.pm) and
[`perl/Proxmod/Backend.pm`](../perl/Proxmod/Backend.pm); behaviour is
unit-tested in `t/04-api.t`

Reference for the surface a backend extension codes against. For the guided
introduction, read [`backend-extensions.md`](backend-extensions.md) first.

---

## 1. The entry point

proxmod `require`s your module and calls one sub:

```perl
package Acme::Foo;
use strict;
use warnings;
use base qw(PVE::RESTHandler);

sub proxmod_register {
    my ($api) = @_;
    ...
}

1;
```

- Called **once per daemon**, so twice on a default manifest — once inside
  `pvedaemon` and once inside `pveproxy`. Use `$api->daemon` if you need to
  tell them apart; usually you do not.
- Called inside `eval` with `$SIG{__DIE__}` localised. **Dying here disables
  your extension and nothing else.** Every other extension still loads, and both
  daemons still start.
- Called during `INIT`, before the daemon binds its socket. Do not do slow work,
  do not open network connections, do not fork.

A module that does not define `proxmod_register` is reported and skipped.

### How the module is loaded, and why it matters

The module name comes from a manifest read off disk, so under `-T` it is
tainted, and **`require` of a tainted string dies** [PVE-F-042] — inside the
daemon, at startup. `Proxmod::Registry` rebuilds it from a strict package-name
capture, and `Proxmod::Backend` checks it again, because the cost of being wrong
is arbitrary code execution as root inside `pvedaemon` and the check costs one
regex.

Note the deliberate absence of `eval "require $module"`. The name is converted
to a relative path and *that* is required, keeping a string that came from disk
out of the Perl compiler entirely. Do not reintroduce the string form in your
own code either.

---

## 2. `Proxmod::API`

The object handed to `proxmod_register`. You never construct it.

### `$api->id`

Your extension id, from the manifest. The API path segment, and the string that
prefixes every log line proxmod writes on your behalf.

### `$api->daemon`

`'pvedaemon'` or `'pveproxy'` — which daemon this call is happening inside.

### `$api->mount(%args)`

Attach a `PVE::RESTHandler` subclass into PVE's tree under your extension's own
path. Returns the mounted path.

| Argument | | |
|---|---|---|
| `subclass` | **required** | Your loaded `PVE::RESTHandler` subclass |
| `scope` | default `'node'` | `'node'` or `'cluster'` |

```perl
my $path = $api->mount(scope => 'node', subclass => __PACKAGE__);
# /nodes/{node}/proxmod/acme-foo
```

| Scope | Mounts under | Parent |
|---|---|---|
| `node` | `/nodes/{node}/proxmod/<id>` | `PVE::API2::Nodes::Nodeinfo` |
| `cluster` | `/cluster/proxmod/<id>` | `PVE::API2::Cluster` |

Pick `node` if the answer differs per host — hardware, local services, anything
under `/sys` or `/proc`. Pick `cluster` if it does not.

**Idempotent for the same subclass**, so a module loaded twice under different
names is harmless. **Dies on a conflict**: a different subclass already mounted
at your path. That die is caught, and the *right* outcome — proxmod cannot
silently give two extensions the same API path, and dying disables only yours.

Dies also on an unknown scope, a name that is not a valid package name, or a
class that is not loaded / is not a `PVE::RESTHandler` subclass. All three are
programming errors, and all three are caught.

### `$api->add_method(%args)`

Register one endpoint. Takes `PVE::RESTHandler::register_method`'s info hash
plus a `class`. Returns the full path it resolved to.

| Argument | | |
|---|---|---|
| `class` | **required** | The handler class this method belongs to |
| `name` | **required** | Unique method name within the class |
| `path` | **required** | `''` for the subtree root, otherwise a path fragment |
| `code` | **required** | `sub { my ($param) = @_; ... }` |
| `permissions` | **required** | See §3 — no default, deliberately |
| `method` | default `'GET'` | `GET`, `POST`, `PUT` or `DELETE` |
| `parameters` | | JSON Schema for the input |
| `returns` | | JSON Schema for the output |
| `protected` | | `1` to run as root inside `pvedaemon` |
| `proxyto` | | `'node'` to proxy to the node named in `{node}` |
| `description` | | Shown by `pvesh` and the API viewer |

Everything not listed is passed through to `register_method` untouched.

```perl
$api->add_method(
    class => __PACKAGE__,
    name => 'status',
    path => 'status',
    method => 'GET',
    description => 'Current widget status.',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'object',
        properties => { state => { type => 'string' } },
    },
    code => sub {
        my ($param) = @_;
        return { state => 'ok' };
    },
);
```

**Idempotent** on `(class, method, path)`: registering the same endpoint twice
logs at debug and returns, rather than dying. `register_method` itself *dies* on
a duplicate path [PVE-F-051], and an extension listed twice must not be able to
take `pvedaemon` down over it.

**The post-check.** After registering, `add_method` pushes a synthetic request
through `find_handler` and asks what it actually resolves to. Registration
succeeding and the endpoint being reachable are different questions — a path
behind a greedy `fragmentDelimiter => ''` subtree registers perfectly and then
never resolves [PVE-F-051]. Three distinct warnings come out of this:

```
... but a request to it does not resolve to any handler; the endpoint is unreachable
... but a request to it resolves to PVE::API2::Something; the endpoint is shadowed
... but a request to it is answered by 'other-name' on the same class; the endpoint is shadowed
```

None of them are fatal, and all of them mean your endpoint does not work. Grep
for them after installing.

If the class was not mounted by proxmod, the check is skipped and says so —
rather than pretending the route was verified.

### `$api->assert_route($method, $path, $expect)`

Returns `($ok, $message)`. Would a request to `$path` reach `$expect`?

```perl
my ($ok, $why) = $api->assert_route('GET', '/nodes/n1/proxmod/acme-foo/status',
                                    'Acme::Foo');
```

Exposed because an extension that mounts something itself, or nests subclasses,
can check its own work — and because `proxmod-verify` replays the same question
against a live daemon.

### `Proxmod::API::registrations()`

Everything registered so far, as an arrayref of
`{ scope, id, subclass, path }`. Used by the root index and `proxmod-verify`.
Read-only; nothing else should call it.

---

## 3. `permissions` is required

`add_method` **dies** if you omit the key:

```
add_method: every method must carry a 'permissions' key. Pass
`permissions => undef` for root@pam-only, `{ user => 'all' }` for any
authenticated user, or `{ check => [...] }` for an ACL check.
```

To Proxmox, a method with no `permissions` key is not an error. It is a working
endpoint that **only `root@pam` may call**, with nothing said about it anywhere
[PVE-F-050]. That silence is the exact trap that made `pve-token-copy` necessary
in the first place: an endpoint that works perfectly in testing as root and
returns 403 for every real caller, with no message explaining why.

proxmod makes the choice explicit. There is no default.

| Value | Who can call it |
|---|---|
| `undef` | `root@pam` only — PVE's default, chosen deliberately |
| `{ user => 'all' }` | Any authenticated user |
| `{ user => 'world' }` | **Anyone. No authentication at all.** |
| `{ check => [...] }` | An ACL check — what you almost always want |

`{ user => 'world' }` is what PVE uses for the ticket endpoint. An extension
almost never wants it, and proxmod **logs a warning naming your method** when
you use it, so an administrator can find out from the journal.

Validation: `permissions` must be a hashref or `undef`; it must have a `user` or
a `check`; `user` must be `all` or `world`. Anything else dies, and the die
disables your extension rather than the daemon.

### `check` expressions

Passed to PVE unchanged, so PVE's grammar applies:

```perl
permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
permissions => { check => ['perm', '/vms/{vmid}', ['VM.Config.Options']] },
permissions => { check => ['or',
    ['perm', '/nodes/{node}', ['Sys.Modify']],
    ['userid-param', 'self'],
] },
```

`{node}` and `{vmid}` interpolate from the request's parameters. Use the
narrowest privilege that does the job: `Sys.Audit` to read, `Sys.Modify` to
change. Do not ask for `Sys.Modify` on a read-only endpoint because it is
easier to reason about — you are widening who is locked out and narrowing who
can be given access.

Permissions are enforced by `pveproxy`, as `www-data`, **before** anything is
proxied to `pvedaemon` [PVE-F-052]. They are a real boundary, not advisory.

---

## 4. `protected`, `proxyto`, and workers

**`protected => 1`** makes the method run inside `pvedaemon` as root. Anything
that reads a root-only file, writes system configuration or runs a privileged
command needs it. Do not set it on a read-only method that does not: it costs a
round trip and it puts your code in the root process.

**`proxyto => 'node'`** makes a request that arrives at node A for node B get
proxied to B. Any node-scoped method whose answer is about the local machine
should set it, or a request to the wrong node quietly answers about the wrong
machine.

**Long-running work goes through `fork_worker`** and returns a UPID, rather than
blocking:

```perl
my $rpcenv = PVE::RPCEnvironment::get();
my $user = $rpcenv->get_user();
return $rpcenv->fork_worker('acmefoo', $param->{node}, $user, sub {
    ...
});
```

`fork_worker` is defined in `PVE::RESTEnvironment` and inherited by
`PVE::RPCEnvironment`. `pvedaemon` runs **three** worker processes [PVE-F-053]:
a `protected` method that blocks for thirty seconds removes a third of the
host's capacity to execute any privileged API call at all, for that whole time.
Return the UPID and let the frontend's task viewer follow it.

---

## 5. Taint, and reading from the system

The daemons run under `perl -T` [PVE-F-002]. `PVE::RESTHandler::handle`
validates against your `parameters` schema and then runs `untaint_recursive`, so
**declared parameters arrive clean**. Anything you read off disk or out of a
command does not.

Untaint by matching a strict pattern and rebuilding from the capture. Never with
`=~ /(.*)/s`, which launders without checking:

```perl
open(my $fh, '<', '/proc/loadavg') or die "cannot read loadavg: $!\n";
my $line = <$fh>;
close($fh);
my ($one) = ($line =~ /\A(\d+\.\d+)\s/)
    or die "unexpected /proc/loadavg format\n";
return { loadavg => 0 + $one };
```

Two more rules from [`pve-internals.md`](pve-internals.md) §9:

- **`readdir` and `glob` return tainted strings** [PVE-F-041].
- **`open` with an `:encoding()` layer cannot open a tainted path** [PVE-F-040].
  It works on a laptop and fails inside `pvedaemon`. Read bytes; decode after.

### Running commands

Use `PVE::Tools::run_command` with a **list**, never a string through the shell:

```perl
use PVE::Tools;
my $out = '';
PVE::Tools::run_command(['/usr/sbin/smartctl', '-i', $dev],
    outfunc => sub { $out .= "$_[0]\n" });
```

`$dev` here must have come from a schema-validated parameter or a pattern you
matched yourself. A device path assembled from an unvalidated parameter and
passed to a shell is a root command injection.

**`pvedaemon` clears the environment.** An extension that changes behaviour
based on an environment variable — a test override pointing at a fake `/sys`,
say — will find that variable absent inside the daemon. Provide a config-file
fallback, or the override silently does nothing on a real host.

---

## 6. Logging

```perl
use Proxmod::Log qw(log_info log_warn log_error log_debug);

log_info("acme-foo: scanned $n devices");
log_warn("acme-foo: device $dev did not respond");
```

Output goes to the daemon's journal, prefixed, so `journalctl -u pvedaemon |
grep proxmod` finds it. `log_debug` is quiet unless debug logging is enabled in
`/etc/proxmod/proxmod.conf`.

**Never log a ticket, a password, a token or a private key.** The journal is
readable by more people than the API is.

---

## 7. What kills what

| You do | Result |
|---|---|
| `die` in `proxmod_register` | Your extension is disabled. Everything else loads. |
| `die` in a method's `code` | That request gets a 500. Nothing else is affected. |
| Mount a path another extension has | Your extension is disabled, with a message naming the other one. |
| Register the same method twice | Debug line, no-op. |
| Omit `permissions` | Your extension is disabled, with a message telling you what to pass. |
| Infinite-loop in `proxmod_register` | **The daemon does not start.** proxmod cannot protect you from this. |
| Block for 30s in a `protected` method | A third of the host's privileged API capacity is gone for 30s. |

The first five are proxmod working. The last two are the two ways to hurt the
host from inside an extension, and neither is something a wrapper can catch.

---

## Reference

- [`backend-extensions.md`](backend-extensions.md) — the guided version, with a worked example
- [`examples/proxmod-example-hello/perl/ProxmodExample/Hello.pm`](../examples/proxmod-example-hello/perl/ProxmodExample/Hello.pm) — the reference extension
- [`specifications.md`](specifications.md) §6 — normative requirements (`REQ-BE-*`)
- [`pve-internals.md`](pve-internals.md) — `RESTHandler`, the request lifecycle, taint
- [`extension-manifest.md`](extension-manifest.md) — how your module gets named
