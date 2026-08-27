# Troubleshooting

**Status:** Draft
**Applies to:** proxmod 0.2.2, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** each symptom maps to a check or a code path that
produces it; check ids are from [`bin/proxmod-verify`](../bin/proxmod-verify)

Symptom first. If you do not know what is wrong yet, start with §0.

---

## 0. Emergency: the web interface is down

```sh
touch /etc/proxmod/disabled
systemctl restart pvedaemon pveproxy
```

Both daemons now start **exactly as Proxmox ships them**. The kill switch is
checked by the `ExecStart` wrapper before any proxmod code is loaded, so it works
even when proxmod itself is broken.

Still down? It is not proxmod. `systemctl status pveproxy`,
`journalctl -u pveproxy -n 100`.

To go further, remove the drop-ins entirely:

```sh
rm -f /etc/systemd/system/{pvedaemon,pveproxy}.service.d/10-proxmod.conf
systemctl daemon-reload
systemctl restart pvedaemon pveproxy
```

`proxmod-reapply` does this itself if a daemon fails to come back after a
proxmod restart — self-healing to stock is built in. This is the manual version.

Then, before doing anything else:

```sh
proxmodctl doctor > /tmp/proxmod-doctor.txt
```

---

## 1. First three commands

```sh
proxmodctl status      # what is wrong, by check id
proxmodctl logs        # what proxmod said
proxmodctl doctor      # everything, for a bug report
```

Every check id below is what `status` prints. [`verification.md`](verification.md)
describes each one in full.

---

## 2. Nothing from proxmod at all

### The index has no loader tag; no proxmod lines in the journal

```sh
proxmodctl status
```

| It says | Meaning | Fix |
|---|---|---|
| `disabled` (info) | The kill switch is set | `proxmodctl enable` |
| `installed` (error) | Drop-ins are not in place | `proxmodctl reapply` |
| `drift.<unit>` (error) | The unit does not start through proxmod | §3 |
| `live.<unit>` (error) | Drop-in is right, the process is not loaded | §4 |

### `drift.<unit>`: the unit does not start through proxmod

```sh
systemctl show -p ExecStart --value pveproxy.service
ls /etc/systemd/system/pveproxy.service.d/
```

Expected: `/usr/lib/proxmod/proxmod-exec pveproxy`.

- **Nothing there** — `proxmodctl reapply`.
- **Another package's wrapper** — only one drop-in can set `ExecStart=`, and the
  last one alphabetically wins. Two frameworks wrapping the same daemon
  conflict; proxmod detects it and cannot resolve it. The way out is for the
  other module to become a proxmod extension rather than a competing drop-in.

### `live.<unit>`: the drop-in is right but the daemon is not loaded

The wrapper ran and chose to start the daemon unmodified. It always says why:

```sh
journalctl -u pveproxy | grep proxmod
```

| Reason | Fix |
|---|---|
| Kill switch | `proxmodctl enable` |
| **Refusing: unsafe permissions** | §7 — fix the mode, do not bypass |
| Unrecognised shebang | Proxmox changed the daemon's invocation. File an issue with `doctor` output |
| `systemctl show` failed | Systemd or the base unit is in a strange state |

If the journal says nothing at all, the daemon may have started before proxmod
was installed:

```sh
systemctl show -p ExecMainStartTimestamp --value pveproxy.service
proxmodctl reapply --force
```

---

## 3. Extension-shaped problems

### I installed (or removed) an extension and nothing happened

`proxmodctl list` shows it, `proxmod-verify` exits 0, and the extension still
does nothing — or the one you removed still answers. A running daemon reads the
registry once, at startup, so a registry change only takes effect when the
daemons restart.

```sh
proxmod-verify | grep registry     # `registry.<unit>` warns if they are stale
proxmodctl reapply                 # converge, which restarts them if they are
```

Normally the dpkg trigger has already done this. If it did not, the reapply run
says why:

| `proxmodctl logs` says | Cause |
|---|---|
| `still not running registry <fp> after a restart for it` | The daemons restarted and came back on the same old registry. Something is stopping the new one loading — read `journalctl -u pvedaemon -u pveproxy \| grep proxmod:`. proxmod deliberately stops retrying at this point rather than restarting on every apt run |
| nothing at all | The trigger never fired. `dpkg-trigger --by-package proxmod proxmod-reapply` |
| `proxmod is disabled` | The kill switch at `/etc/proxmod/disabled`. `proxmodctl enable` |

`proxmod-verify --registry-only` answers just this question: exit 0 up to date,
1 out of date, 2 could not tell, with the fingerprint on stdout. The same
fingerprint on two nodes means the same registry, which makes it the honest way
to ask whether a cluster agrees — see [`cli.md`](cli.md) §2.

### One extension is missing; others work

Working as designed — extensions are isolated. Find out why:

```sh
proxmodctl logs | grep '<your-ext-id>'
```

| Journal says | Cause |
|---|---|
| `Can't locate Acme/Foo.pm` | The module is not in `/usr/share/perl5` |
| `does not define proxmod_register()` | Wrong sub name, or not exported from the package |
| `every method must carry a 'permissions' key` | Add one; see [`perl-api.md`](perl-api.md) §3 |
| `mount: ... already mounted by` | Two extensions claim the same `id` |
| `requires missing extension(s)` | Its prerequisite did not load — fix that one first |
| `is part of a dependency cycle` | Two extensions `require` each other |
| Nothing at all | The manifest was never read — §5 |

### Nothing in the journal for my extension

The manifest was rejected before the id was known, or masked.

```sh
proxmodctl list                                    # is it listed?
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' \
    /usr/share/proxmod/extensions.d/50-acme-foo.conf   # valid strict JSON?
ls -l /etc/proxmod/extensions.d/                   # masked by an /etc override?
```

Remember `/etc` wins over `/usr/share` **by basename**, and an empty file or a
symlink to `/dev/null` there is a deliberate mask.

Common rejections — every one is logged, but with the path rather than an id:
invalid JSON, bad `id` pattern, `backend.module` that is not a valid package
name, an asset name with a slash in it or without a `.js` suffix. See
[`extension-manifest.md`](extension-manifest.md) §4.

---

## 4. Frontend-shaped problems

### The tab does not appear

```sh
curl -sk https://localhost:8006/ | grep -c '/proxmod/loader.js'   # want 1
curl -sk https://localhost:8006/proxmod/loader.js                 # names your asset?
```

| State | Cause | Fix |
|---|---|---|
| 0 tags | proxmod is not loaded, or the injection seam failed | §2 |
| 2+ tags | Something else is injecting too — probably a patch | `proxmodctl patch status` |
| Loader is an inert comment | proxmod could not build it | `proxmodctl logs` |
| Loader does not name your asset | Manifest not read, or `enabled: false` | §3 |
| Asset named but 404 | Not in `/usr/share/proxmod/www/` | Reinstall the extension |

Asset loads and still no tab — open the browser console:

```js
Proxmod.ui.registrations()          // did your registration land?
Ext.ClassManager.get('PVE.node.Config')   // does the target class exist?
```

| Console shows | Cause |
|---|---|
| `proxmod: tab acme-foo/... failed` | Your registration threw |
| `cannot add tabs to PVE.node.Config: the class does not exist` | Proxmox renamed it — [`compatibility.md`](compatibility.md) |
| `tab itemId "..." already exists` | Two registrations, one id. Do not set `itemId` by hand |
| `addTab needs an xtype` / `needs the registering extension id` | Fix the spec |
| Nothing at all | Your file threw at parse time — check the Network tab, then `node --check` it |

### The menu or panel breaks with `Cannot read properties of null`

```
Uncaught TypeError: Cannot read properties of null (reading 'apply')
    at constructor.callParent (ext-all.js)
    at constructor.initComponent (<your asset>.js)
```

`'use strict'` in the file holding that `initComponent`. ExtJS resolves
`callParent` through `Function.caller`, and V8 hands out `null` for it whenever
the caller is a strict-mode function, so the parent method is never found and
the panel never builds. Drop the directive from the file — strictness is
inherited by every nested function, so there is no narrower fix. proxmod's own
`proxmod-ui.js` carried the directive through 0.2.0 and broke every panel an
extension touched; 0.2.1 removes it. Upgrade past it, and make the same edit in
any extension asset of your own.

### The tab appears but is empty

Your `initComponent` ran and the API call failed. Console + Network tab.

- **501** — the backend is registered in only one daemon. §5.
- **403** — permissions. Test as the user who is actually failing, not as root.
- **500** — your `code` sub died. `proxmodctl logs`.

### A hard reload fixes it

Browser cache. `Ctrl-Shift-R`. The loader tag carries a version query string, so
this should be rare; if it is not, the version did not change when the asset
did.

---

## 5. Backend-shaped problems

### 501 Not Implemented

**Not 404.** `PVE::HTTPServer::rest_handler` builds its default response as
`HTTP_NOT_IMPLEMENTED` before `find_handler` runs [PVE-F-052], so 501 is what an
unregistered path returns.

Almost always: the extension is registered in one daemon and the request landed
on the other. Every request reaches `pveproxy` first, and it must find the
method in its own tree before it can decide to proxy it. Set
`"daemons": ["pvedaemon", "pveproxy"]`, or omit the key — both is the default.

Otherwise, the route is registered but shadowed. `proxmodctl logs` and look for:

```
... but a request to it does not resolve to any handler; the endpoint is unreachable
... but a request to it resolves to PVE::API2::Something; the endpoint is shadowed
```

That is `add_method`'s post-check telling you registration succeeded and
reachability did not — usually a greedy `fragmentDelimiter => ''` subtree
[PVE-F-051].

### 403 for everyone except root

You omitted `permissions`, or passed `undef`. A method with no `permissions` key
is a working endpoint that only `root@pam` may call, with nothing said anywhere
[PVE-F-050]. proxmod refuses to let you omit the key; `undef` is the explicit
version of the same thing.

Fix: `permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] }`.

**Test as a non-root user with a real ACL.** Testing as root proves nothing
about permissions.

### 500 from my endpoint

```sh
proxmodctl logs
```

Under `-T`, three specific causes are worth checking first:

- **`Insecure dependency in require`** — a tainted string reached `require`
  [PVE-F-042].
- **`Insecure dependency in open`** — you opened a path that came from `readdir`
  or `glob` [PVE-F-041], or used an `:encoding()` layer on one [PVE-F-040].
- **`Insecure $ENV{PATH}`** — you ran a command without an absolute path.

See [`perl-api.md`](perl-api.md) §5.

### It works from the shell but not in the daemon

Three usual suspects:

1. **Taint.** Your test ran without `-T`. Try `perl -T`.
2. **The environment is cleared.** `pvedaemon` gets no environment from systemd,
   so a variable-based override — a test fixture pointing at a fake `/sys`, say
   — is simply absent. Provide a config-file fallback.
3. **`pvesh` has its own tree.** `pvesh` builds the API tree in its own process,
   which was not started through proxmod's wrapper. **`pvesh` will not see your
   endpoint** and that is not a bug. Test over HTTP.

### The endpoint is slow and the whole host feels slow

`pvedaemon` runs **three** worker processes [PVE-F-053]. A `protected` method
that blocks for thirty seconds removes a third of the host's capacity to execute
*any* privileged API call for that whole time.

Move the work into `$rpcenv->fork_worker` and return a UPID.

---

## 6. Upgrade-shaped problems

### proxmod vanished after a Proxmox upgrade

```sh
proxmod-verify
```

`reload.<unit>` warning → the `ExecReload` override is missing, so
`reload-or-try-restart` [PVE-F-005] reloaded rather than restarted, and PVE's
in-process `exec()` of the original `argv` dropped `-MProxmod`.

```sh
proxmodctl reapply
```

### `dpkg -V pve-manager` now reports a file

Something patched Proxmox. If you enabled a proxmod patch spec, that is it:

```sh
proxmodctl patch status
proxmodctl patch revert <id>
```

If you did not, another package on this host is patching Proxmox files. See
[`patching.md`](patching.md) §2 for what that costs you.

### apt is wedged mid-upgrade

Not proxmod: its trigger path always exits 0, precisely so that a proxmod
failure cannot stop an unrelated `apt dist-upgrade`. `dpkg --configure -a` and
look at what actually failed.

---

## 7. Permission-shaped problems

### `live.<unit>` fails, `drift.<unit>` passes, journal says proxmod refused

`proxmod-exec` refuses to inject when any of `/usr/share/perl5/Proxmod*`,
`/usr/share/proxmod/extensions.d` or `/etc/proxmod` is non-root-owned or
group/world-writable.

Everything there executes as root inside `pvedaemon`. A writable entry is
unauthenticated root RCE on the hypervisor.

```sh
find /usr/share/perl5/Proxmod* /usr/share/proxmod/extensions.d /etc/proxmod \
     \( ! -user root -o -perm /022 \) -print
chown -R root:root /usr/share/proxmod /etc/proxmod
chmod -R go-w /usr/share/proxmod /etc/proxmod
```

**Do not work around this check.** Find out what made those files writable — a
config management tool running as a non-root user, an rsync with the wrong
flags, a tarball extracted with a bad umask — because whatever it was can do it
again.

### A daemon will not start at all, systemd mentions permissions

`dh_fixperms` reset `/usr/lib/proxmod/proxmod-exec` to `0644`. That is a
packaging bug in a locally built `.deb`:

```sh
chmod 0755 /usr/lib/proxmod/proxmod-exec
systemctl restart pvedaemon pveproxy
```

Then fix `debian/rules` — [`packaging.md`](packaging.md) §3.

---

## 8. Filing a bug

```sh
proxmodctl doctor > /tmp/proxmod-doctor.txt
```

Include it. It has package versions, both units' live `ExecStart`/`ExecReload`,
the extension list, 200 lines of proxmod journal, the patch state and a full
`proxmod-verify` run. It deliberately does not dump extension manifests — those
are third-party files whose contents proxmod makes no promises about.

Also say: what you expected, what happened, whether `dpkg -V pve-manager` is
silent, and whether `proxmodctl disable` changes the symptom.

---

## Reference

- [`verification.md`](verification.md) — every check in full
- [`cli.md`](cli.md) — every command and flag
- [`compatibility.md`](compatibility.md) — when Proxmox moved a seam
- [`perl-api.md`](perl-api.md), [`js-api.md`](js-api.md) — the two API surfaces
- [`pve-internals.md`](pve-internals.md) §13 — things that look like they work and do not
