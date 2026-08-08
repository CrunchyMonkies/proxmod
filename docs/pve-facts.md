# The fact ledger

**Status:** Living
**Applies to:** Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** read directly out of `proxmox-ve_9.1-1.iso` with
`scripts/extract-pve-source.sh`; raw evidence in [`facts/pve-9.1.1.txt`](facts/pve-9.1.1.txt)

proxmod attaches to Proxmox VE at seams that are not documented API. Anything
this project claims about Proxmox internals is recorded here as a numbered fact
with the evidence attached, and cited by number from the code and the other
documents — `[PVE-F-020]` rather than a restatement that can quietly drift out
of date.

Re-derive the evidence for a new point release with:

```sh
make facts ISO=/path/to/proxmox-ve_9.x-1.iso
git diff docs/facts/
```

That diff is the list of assumptions that moved. It needs no PVE host, no root,
and no loop mount — the script streams files out of the `.deb`s inside the ISO.

**How to read a status:**

| Status | Meaning |
|---|---|
| `Verified` | Read out of the shipped source for the stated version |
| `Observed` | Seen on a running host, not provable from source alone |
| `Assumed` | Believed, not yet checked — never load-bearing without a fallback |

Nothing marked `Assumed` may be the only thing standing between a user and a
dead daemon.

---

## Runtime and process model

### [PVE-F-002] `pveproxy` and `pvedaemon` run under Perl taint mode

**Status:** Verified (9.1.1)

```
pveproxy:  #!/usr/bin/perl -T
pvedaemon: #!/usr/bin/perl -T
pvestatd:  #!/usr/bin/perl
```

**Consequence.** Taint mode ignores `PERL5LIB` and `PERL5OPT`, so neither can be
used to load code into these daemons. A command-line `-M` is the only route in,
which is why proxmod needs an `ExecStart` wrapper rather than an environment
drop-in. It also means every value proxmod reads off disk is tainted; see
`[PVE-F-040]` and `[PVE-F-042]`.

Note that `pvestatd` is *not* tainted. proxmod does not extend it — it serves no
REST API — but the asymmetry is worth knowing before assuming all three behave
alike.

### [PVE-F-003] `/usr/share/perl5` is in Perl's default `@INC`

**Status:** Verified (Debian perl 5.38, and the same on PVE 9's trixie base)

**Consequence.** A module placed there is loadable by `-M` under taint without
any path configuration. proxmod installs `Proxmod.pm` and `Proxmod/*.pm` there.
This is a Debian-wide vendor directory, not a Proxmox-owned one, so a
`pve-manager` upgrade never touches it.

### [PVE-F-005] `pve-manager`'s own `postinst` reloads the daemons

**Status:** Verified (9.1.1) — `control.tar`, `postinst:144-160`

```sh
triggered)
  test -f /etc/pve/local/pve-ssl.pem || exit 0;
  test -e /proxmox_install_mode && exit 0;
  deb-systemd-invoke reload-or-try-restart pvedaemon.service || true
  deb-systemd-invoke reload-or-try-restart pvestatd.service || true
  deb-systemd-invoke reload-or-try-restart pveproxy.service || true
  deb-systemd-invoke reload-or-try-restart spiceproxy.service || true
  deb-systemd-invoke reload-or-try-restart pvescheduler.service || true
```

**Consequence, two of them.** First, Proxmox's own upgrade path restarts the
daemons, so proxmod is re-injected after an upgrade without proxmod having to
arrange it. Second — and this is why the `ExecReload` override is mandatory —
`reload-or-try-restart` prefers *reload*, and PVE's graceful reload re-`exec`s
the daemon's original `argv`, which does not contain our `-M`. Without rewriting
`ExecReload` to a full restart, every upgrade would silently unload proxmod.

The two guards are worth copying: `pve-ssl.pem` stands in for "is `/etc/pve`
mounted", and `/proxmox_install_mode` for "are we inside the installer". proxmod
mirrors both in `proxmod-reapply`.

### [PVE-F-010] `pve-manager` ships dpkg triggers

**Status:** Verified (9.1.1) — `control.tar`, `triggers`

```
interest-noawait pve-api-updates
interest-noawait /usr/share/perl5/PVE
```

**Consequence.** File triggers are the mechanism Proxmox itself uses to notice
that the API surface changed. proxmod using the same mechanism is idiomatic
rather than novel — and unlike an APT `DPkg::Post-Invoke` hook it fires on a
plain `dpkg -i`, runs once per batch rather than once per apt invocation, and is
ordered with respect to unpacking.

---

## The web interface

### [PVE-F-020] `get_index` is a named sub, reachable for wrapping

**Status:** Verified (9.1.1) — `PVE/Service/pveproxy.pm`

```perl
123:  pages => {
124:      '/' => sub { get_index($self->{nodename}, @_) },
206:  sub get_index {
304:      $template->process("$dir/index.html.tpl", $vars, \$page) || die $template->error(), "\n";
307:      my $resp = HTTP::Response->new(200, "OK", $headers, $page);
```

**Consequence.** This single fact is what makes proxmod's zero-mutation frontend
possible. The dispatch table holds a closure that calls a *named* sub by name at
request time, so reassigning `*PVE::Service::pveproxy::get_index` takes effect
for every subsequent request. Had line 124 inlined the body, or captured a code
reference at build time, the only way to add a `<script>` tag would have been to
edit `index.html.tpl` on disk — which is precisely the approach proxmod exists
to avoid.

**If this breaks,** `Proxmod::Frontend` probes for the sub with `can()` before
wrapping and does nothing if it is absent. The UI extension disappears; the web
interface keeps working.

### [PVE-F-021] The script order in `index.html.tpl`

**Status:** Verified (9.1.1) — `/usr/share/pve-manager/index.html.tpl`

```
51:  <script ... src="/proxmoxlib.js?ver=[% wtversion %]"></script>
52:  <script ... src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>
53:  <script ... src="/pve2/ext6/locale/locale-[% lang %].js?ver=7.0.0"></script>
55:  <script type="text/javascript">
       ... Ext.onReady(function() { Ext.create('PVE.StdWorkspace');});
61:  </head>
```

**Consequence.** proxmod injects its one `<script>` tag after the locale on
line 53 and before the inline block on line 55. At that point every `PVE.*`
class exists and the translations are loaded, but no ready handler has been
registered — so an extension can install `Ext.define({override: ...})` and have
it apply to components that have not been constructed yet.

The ExtJS version is pinned at 7.0.0 in the template.

### [PVE-F-022] `get_index` renders one of four different pages

**Status:** Verified (9.1.1) — `PVE/Service/pveproxy.pm:206-307`

The same sub serves the manager UI, the noVNC console, the xterm.js console and
the mobile interface, choosing a template directory from the request's
`console`, `novnc`, `xtermjs` and `mobile` parameters and the `User-Agent`.

**Consequence.** A wrapper on `get_index` sees all four. Only the manager
template loads `pvemanagerlib.js`, so anchoring the injection on that specific
`<script>` tag makes the other three no-ops by construction, with no need to
sniff which page is being rendered.

### [PVE-F-023] `/` is served without authentication

**Status:** Verified (9.1.1) — comment above the `pages` table in
`PVE/Service/pveproxy.pm`: *"Requests to those pages are not authenticated"*

**Consequence.** The index, and therefore anything proxmod injects into it or
serves under `/proxmod/`, is reachable by anyone who can reach port 8006. No
secret, hostname, token or internal path may appear in a frontend asset or in
the generated loader. Access control belongs on the API endpoints, which *are*
authenticated.

### [PVE-F-024] `server_config` holds the two routing tables

**Status:** Verified (9.1.1) — `PVE/Service/pveproxy.pm:122-136`,
`PVE/APIServer/AnyEvent.pm:1231-1258`

```perl
# pveproxy.pm, inside init()
pages => { '/' => sub { ... }, '/favicon.ico' => { file => ... }, ... },
dirs  => $dirs,

# AnyEvent.pm, per request
if ($self->{pages} && ($method eq 'GET') && (my $handler = $self->{pages}->{$path})) { ... }
if ($self->{dirs} && ($method eq 'GET')) {
    if ($path =~ m!^(/\S+/)([a-zA-Z0-9\-\_\.]+)$!) { ... }
}
```

**Consequence.** Adding a URL to the running `pveproxy` is two hash-store
operations on `$self->{server_config}` after `init()` has run, and needs no file
on disk and no change to Proxmox. `Proxmod::Frontend` adds `dirs{'/proxmod/'}`
for extension assets and `pages{'/proxmod/loader.js'}` for the generated loader.

Two details are load-bearing. `pages` is consulted *before* `dirs` and matched on
the exact path, so the dynamic loader wins over any file of the same name. And
the `dirs` pattern matches one path component with no slash in it, so
`/proxmod/` serves a flat directory only — which is why extension assets are
bare filenames.

### [PVE-F-025] `add_dirs` walks the tree with `File::Find`

**Status:** Verified (9.1.1) — `PVE/APIServer/AnyEvent.pm:2240-2253`

```perl
sub add_dirs {
    my ($result_hash, $alias, $subdir) = @_;
    $result_hash->{$alias} = $subdir;
    my $wanted = sub {
        my $dir = $File::Find::dir;
        if ($dir =~ m!^$subdir(.*)$!) { $result_hash->{"$alias$1/"} = "$dir/"; }
    };
    find({ wanted => $wanted, follow => 0, no_chdir => 1 }, $subdir);
}
```

**Consequence.** The helper registers every subdirectory as its own alias, and
every path it produces came from the filesystem and is therefore tainted
`[PVE-F-041]`. `Proxmod::Frontend` deliberately does **not** call it: a literal
`$cfg->{dirs}{'/proxmod/'} = '/usr/share/proxmod/www/'` registers the one flat
directory proxmod serves and cannot be tainted by construction. The cost is that
extensions may not use subdirectories, which the manifest schema enforces
anyway.

### [PVE-F-026] `Content-Length` is recomputed from the response body

**Status:** Verified (9.1.1) — `PVE/APIServer/AnyEvent.pm:342-360`

```perl
my $content = $resp->content;
$content_length = length($content);
...
$resp->header("Content-Length" => $content_length);
```

**Consequence.** A wrapper that rewrites `$resp->content` has no header to fix
up; `response()` measures whatever it is handed, after any compression. This is
why the injection in `Proxmod::Frontend` is a plain `substr` on the body and
nothing else.

### [PVE-F-030] The ExtJS classes worth overriding

**Status:** Verified (9.1.1) — `/usr/share/pve-manager/js/pvemanagerlib.js`

```
Ext.define('PVE.dc.Config'
Ext.define('PVE.lxc.Config'
Ext.define('PVE.node.Config'
Ext.define('PVE.qemu.Config'
```

**Consequence.** These are the hook hosts for adding a tab at the datacenter,
container, node and virtual-machine levels respectively. `PVE.storage.Config`
does not exist under that name; storage panels are built differently.

### [PVE-F-031] `insertNodes` is the tab-insertion entry point

**Status:** Verified (9.1.1) — `pvemanagerlib.js`, `insertNodes: function`

**Consequence.** `Proxmod.ui.addNodeTab` and friends are built on it. Its
signature is not API and may change; the JS helper is written to fail into a
missing tab rather than a blank page.

The call order in an override is the part everyone gets wrong.
`PVE.panel.Config.initComponent` consumes `me.items`, deletes it, and builds the
tree store — so `insertNodes` only exists to be called *after* `me.callParent()`
has returned, not before.

### [PVE-F-032] `insertNodes` throws on a duplicate `itemId`, and mutates its argument

**Status:** Verified (9.1.1) — `pvemanagerlib.js`, `insertNodes: function (items)`

```js
if (me.savedItems[item.itemId] !== undefined) { throw 'itemId already exists, please use another'; }
...
while (item.groups && item.groups.length) { let groupId = item.groups.shift(); ... }
...
var node = curnode.findChild('id', item.itemId);
if (node === null) { curnode.appendChild(treeitem); } else { throw 'id already exists'; }
```

**Consequence.** Two things follow, and both are why extensions do not call this
directly.

A duplicate `itemId` throws from inside `initComponent`, which blanks the panel
— so two extensions choosing the same tab name take out the whole node view, not
just their own tabs. `Proxmod.ui` derives every `itemId` from the extension id
(`proxmod-<ext>`) and checks `savedItems` before calling, so a collision costs a
console warning and one missing tab.

`item.groups` is `shift()`ed empty, and `item` is retained in `savedItems`. A
registration object reused across panel instances therefore works exactly once
and then lands in the wrong place. `Proxmod.ui` rebuilds the item per instance
and copies `groups`.

Nodes are always `appendChild`ed; there is no positional argument. Ordering a
tab relative to an existing one means moving the node afterwards, which
`Proxmod.ui` does on a best-effort basis for `after:`.

---

## Perl behaviour that bites inside these daemons

These are facts about Perl, not about Proxmox, but they only cause trouble under
`-T`, which is exactly where proxmod lives.

### [PVE-F-040] An `:encoding()` layer cannot open a tainted path under `-T`

**Status:** Verified (perl 5.38; reproduced in `t/02-registry.t`)

```perl
open(my $fh, '<:encoding(UTF-8)', $tainted_path);
# Insecure dependency in require while running with -T switch
```

A raw `open(my $fh, '<', $tainted_path)` on the same path succeeds. The encoding
layer loads `PerlIO::encoding` lazily, and perl treats that implicit `require`
as insecure when the filename is tainted. Preloading `PerlIO::encoding` does not
help.

**Consequence.** Every path proxmod reads comes from `readdir` and is therefore
tainted, always. This fails *only* under taint, so it works perfectly on a
developer's laptop and then, inside `pvedaemon`, throws on the first manifest —
disabling every extension while the daemon itself starts happily and says
nothing. Read bytes and decode explicitly instead: `Proxmod::Registry` opens raw
and lets `JSON::PP->utf8` do the decoding.

### [PVE-F-041] `glob()` and `readdir` return tainted strings

**Status:** Verified (perl 5.38)

**Consequence.** Filenames discovered on disk cannot be passed to `require`,
`unlink`, `system`, or a subprocess without being matched against a pattern and
rebuilt from the capture. This is why `Proxmod::Registry` untaints every
manifest field it will use, and why the unit tests untaint their own `glob`
results before spawning a compiler.

### [PVE-F-042] `require` of a tainted string dies

**Status:** Verified (perl documentation and behaviour)

**Consequence.** An extension's Perl module name arrives from a JSON manifest
read off disk, so it is tainted. `Proxmod::Registry` matches it against a strict
package-name pattern and keeps the capture; a name that does not match is
rejected, and its extension does not load. Nothing else in proxmod may pass a
manifest value to `require`.

---

## The REST API tree

### [PVE-F-050] A method with no `permissions` key is `root@pam`-only

**Status:** Verified

**Evidence.** `PVE::RPCEnvironment::check_api2_permissions`, shipped by
`libpve-access-control`, in full:

```perl
sub check_api2_permissions {
    my ($self, $perm, $username, $param) = @_;

    return 1 if !$username && $perm->{user} && $perm->{user} eq 'world';
    raise_perm_exc("user != null") if !$username;
    return 1 if $username eq 'root@pam';
    raise_perm_exc('user != root@pam') if !$perm;
    return 1 if $perm->{user} && $perm->{user} eq 'all';
    return $self->exec_api2_perm_check($perm->{check}, $username, $param)
        if $perm->{check};
    raise_perm_exc();
}
```

**Consequence.** The defaulting is in the *absence* of a branch: with no `perm`,
every caller who is not `root@pam` is refused, and `root@pam` is returned early
before `perm` is ever looked at. So a method registered without a `permissions`
key is not unprotected and is not broken — it works perfectly for its author,
who is logged in as `root@pam`, and denies everyone else with a message that
names no method. Nothing is logged and nothing warns.

This is the single most expensive mistake available to an extension author, and
it is why `Proxmod::API::add_method` refuses to register a method that has no
`permissions` key at all. `permissions => undef` gets PVE's root-only default,
deliberately and in writing.

`user => 'world'` is the first line: it means the endpoint is answered with no
login. `Proxmod::API` logs a warning when an extension asks for it.

### [PVE-F-051] `register_method`'s path rules, and greedy subtrees

**Status:** Verified

**Evidence.** `PVE::RESTHandler`, shipped by `libpve-common-perl`:

```perl
die "duplicate path '$realpath'" if $index->{$fullpath};            # :108
die "$errprefix path match error - regex and fixed items\n"          # :284, :292
die "$errprefix duplicate method definition\n"                       # :299
die "$errprefix duplicate method definition SUBCLASS and $m\n"       # :304
die "$errprefix method name already defined\n"                       # :315

my $fd = $info->{fragmentDelimiter};                                 # :395
if (defined($fd)) {
    # we only support the empty string '' (match whole URI)
    die "unsupported fragmentDelimiter '$fd'" if $fd ne '';
    $stack = [join('/', @$stack)] if scalar(@$stack) > 1;            # :402
}
```

**Consequence, in four parts.**

1. **Registration dies, it does not warn.** A duplicate path, a duplicate
   method, or a duplicate method *name* on the same class is a `die` — and
   inside `pvedaemon` that happens while the API tree is being built, so it is
   a daemon that does not start. Two extensions choosing the same path must not
   be able to do that, which is why `Proxmod::API` owns one namespace segment
   and hands each extension its own registry-unique id beneath it, and why
   `mount`/`add_method` are idempotent rather than trusting callers not to
   repeat themselves.

2. **A path level holds either named folders or one `{param}` regex, never
   both.** Registering `foo` at a level that already has `{vmid}` — or the
   reverse — dies with *"path match error - regex and fixed items"*. This is
   the rule that decides where an extension may mount at all.

3. **All `{param}` registrations at one level share a single regex.** A second
   registration with a different parameter name or a different regex at the same
   level dies. A level's parameter is effectively global to that level.

4. **`fragmentDelimiter => ''` swallows the rest of the URI.** `$stack` is
   collapsed to one joined string, so everything below that subtree is handed to
   the subclass as a single fragment. `/nodes/{node}/storage/{storage}/content`
   is the live example. A method registered underneath such a subtree registers
   without complaint and then never resolves — or resolves to the *right class*
   and the *wrong method*, which is why `Proxmod::API`'s post-check compares the
   method info hash by reference identity and not the class name.

---

### [PVE-F-052] The request lifecycle: permissions, then `proxyto`, then `protected`

**Status:** Verified

**Evidence.** `PVE::HTTPServer::rest_handler`, shipped by `pve-manager`, is the
sub both daemons run for every `/api2/` request. Line numbers are relative to
the start of the sub:

```perl
my $resp = {
    status  => HTTP_NOT_IMPLEMENTED,                                     # :7
    message => "Method '$method $rel_uri' not implemented",              # :8
};
...
($handler, $info) = PVE::API2->find_handler($method, $rel_uri, $uri_param);  # :15
...
$rpcenv->check_api2_permissions($info->{permissions}, $auth->{userid}, $uri_param);  # :32
...
if ($info->{proxyto} || $info->{proxyto_callback}) { ... }                # :34
...
my $euid = $>;                                                           # :50
if ($info->{protected} && ($euid != 0)) {                                # :51
    $resp = { proxy => 'localhost', proxy_params => $params };           # :52
}
```

**Consequence, in three parts.**

1. **An unregistered path answers `501 Not Implemented`, not `404`.** The
   default response is built before `find_handler` runs and is returned
   unchanged when nothing matches. When an endpoint is missing, that is the
   status to look for — a 404 means something else entirely.

2. **Permissions are checked before any proxying, in whichever daemon received
   the request.** For a `protected` method that is `pveproxy`, running as
   `www-data`. So a method's `permissions` block is enforced by the unprivileged
   daemon, and `pvedaemon` executes what it is handed — which is why
   [PVE-F-050]'s silent `root@pam` default is a real access-control decision and
   not an internal detail.

3. **`protected => 1` proxies to `localhost` only when the effective uid is not
   0.** Inside `pvedaemon` (`$> == 0`) the same code runs the handler directly.
   Both daemons therefore need the method registered: `pveproxy` to find it and
   decide to proxy, `pvedaemon` to find it again and run it. An extension loaded
   into only one of them answers 501 from the other. This is what
   `[REQ-BE-004]` is protecting against.

---

### [PVE-F-053] Where each daemon listens, and as whom

**Status:** Verified

**Evidence.** `PVE::Service::pvedaemon` and `PVE::Service::pveproxy`, both from
`pve-manager`:

```perl
# pvedaemon
max_workers => 3,                                   # may be overridden in init
my $socket = $self->create_reusable_socket(85, '127.0.0.1');
trusted_env => 1,

# pveproxy
max_workers => 3,                                   # may be overridden in init
setuid => 'www-data',
setgid => 'www-data',
my $socket = $self->create_reusable_socket(8006, $listen_ip);
trusted_env => 0, # not trusted, anyone can connect
```

**Consequence.** `pvedaemon` is root, bound to loopback only, and marks its
environment trusted; `pveproxy` drops to `www-data`, is bound to the world on
:8006, and marks its environment untrusted. Both default to **three** worker
processes. Three is a small number: a `protected` method that blocks for thirty
seconds occupies a third of the host's capacity to execute *any* privileged API
call for that whole time, which is why `[REQ-BE-018]` requires long work to go
through `fork_worker` rather than treating it as a style preference. Both values
are overridable via `MAX_WORKERS` in `/etc/default/pveproxy`, so an extension
must not assume any particular figure — only that it is small.

---

## Not yet verified

These are settled on a live host during integration testing (`test/qemu/`), not
from the ISO, and are marked in the code where they matter.

| Fact | Why it is not verified yet |
|---|---|
| `-MProxmod` plus `INIT` fires inside the real tainted daemon | Needs a running `pveproxy` |
| `ExecReload` override behaviour under `deb-systemd-invoke` | Needs systemd and the real unit |
| Whether `pvesh` can see proxmod endpoints | `pvesh` builds its own tree without `-M`; expected to be **no** |
| Another package winning the `ExecStart=` drop-in race | Needs a second such package installed |
