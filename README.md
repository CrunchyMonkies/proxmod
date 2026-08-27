# proxmod

A framework for extending **Proxmox VE 9.x** — adding REST API endpoints and web-UI
components to a live host — packaged so that it **survives `apt full-upgrade` with
nothing to reapply**.

proxmod modifies **zero Proxmox-owned files**. No `sed` into `index.html.tpl`, no
`awk` into `PVE/API2/*.pm`, no backup-and-restore dance. After installing proxmod
and any number of extensions, `dpkg -V pve-manager libpve-common-perl
libpve-http-server-perl` still reports a clean tree.

> **Status:** in development, `v0.2.1`. Not affiliated with or endorsed by
> Proxmox Server Solutions GmbH. proxmod attaches at *unofficial* seams; see
> [`docs/pve-facts.md`](docs/pve-facts.md) for exactly which, and what happens
> when one moves.

## How it works

Two mechanisms, both fail-safe:

**Backend.** A systemd `ExecStart` drop-in wraps `pvedaemon` and `pveproxy` so
they start with `-MProxmod`. That single injection point loads every registered
extension, each inside its own `eval`. Perl's taint mode (`-T`, which both
daemons use) ignores `PERL5LIB`, so a command-line `-M` is the only way in.
`ExecReload` is rewritten to a full restart, because PVE's graceful reload
re-`exec`s the original argv and would drop the flag.

**Frontend.** `Proxmod::Frontend` glob-wraps `PVE::Service::pveproxy::get_index`
at `INIT` time to inject **exactly one** `<script>` tag — pointing at
`/proxmod/loader.js`, which is generated per request from the live registry.
Extensions add UI by dropping a `.js` file and a `.conf` file; they never touch
`index.html.tpl`, and a frontend-only extension needs no daemon restart at all.

**Update survival.** Everything proxmod owns lives where Proxmox never writes, so
an upgrade cannot clobber it. A dpkg trigger (the same mechanism pve-manager
itself uses) runs an idempotent convergence script, and pve-manager's own
`postinst` reload path restarts the daemons through our wrapper for us. A
boot-time oneshot is the safety net.

### The prime directive

> **A missing extension is acceptable. A dead `pvedaemon` or `pveproxy` is not.**

Every layer degrades toward "PVE exactly as shipped". A bad shebang, a failed
seam probe, a group-writable module directory, or `/etc/proxmod/disabled` all
cause the wrapper to exec the daemon **unmodified**. Because failure is silent by
design, `proxmod-verify` is not optional — wire it into monitoring.

## Writing an extension

An extension package needs **no maintainer scripts**. It `Depends: proxmod` and
ships three files:

```
/usr/share/perl5/Acme/Widget.pm              # register_method calls
/usr/share/proxmod/extensions.d/50-widget.conf   # the manifest
/usr/share/proxmod/www/widget.js             # Ext.define overrides
```

Writing into those paths fires proxmod's dpkg trigger, and everything converges.
See [`examples/proxmod-example-hello/`](examples/proxmod-example-hello/) for a
complete, buildable worked example.

## Installing

On a **test host** first — this loads into `pvedaemon` and `pveproxy` and
restarts them.

```sh
apt install ./proxmod_*_all.deb
proxmod-verify                                   # exits 0 when healthy
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl   # silent
```

That last line is the claim, and it stays silent after upgrades and after purge.

Off without uninstalling:

```sh
proxmodctl disable      # touch /etc/proxmod/disabled, restart both daemons stock
```

Details in [`docs/install.md`](docs/install.md).

## Documentation

Start at [`docs/README.md`](docs/README.md) for reading orders by audience —
extension author, administrator, someone learning Proxmox internals, or someone
changing proxmod itself.

**Learning how Proxmox works** — useful without proxmod:

| | |
|---|---|
| [`docs/pve-internals.md`](docs/pve-internals.md) | processes, request lifecycle, REST tree, auth, pmxcfs, how the interface is served, and a seam inventory marking what is official |
| [`docs/backend-extensions.md`](docs/backend-extensions.md) | writing a Perl REST endpoint |
| [`docs/frontend-extensions.md`](docs/frontend-extensions.md) | writing an ExtJS interface |
| [`docs/packaging.md`](docs/packaging.md) | shipping it as a `.deb` |
| [`docs/patching.md`](docs/patching.md) | the escape hatch, and a post-mortem of doing it the other way |

**Building an extension:**
[`getting-started.md`](docs/getting-started.md) ·
[`extension-manifest.md`](docs/extension-manifest.md) ·
[`perl-api.md`](docs/perl-api.md) ·
[`js-api.md`](docs/js-api.md)

**Running a host with it installed:**
[`install.md`](docs/install.md) ·
[`verification.md`](docs/verification.md) ·
[`troubleshooting.md`](docs/troubleshooting.md) ·
[`cli.md`](docs/cli.md) ·
[`security.md`](docs/security.md) ·
[`compatibility.md`](docs/compatibility.md)

**Why it is built this way:**
[`specifications.md`](docs/specifications.md) (normative) ·
[`architecture.md`](docs/architecture.md) ·
[`decisions.md`](docs/decisions.md) (ADRs) ·
[`conventions.md`](docs/conventions.md) ·
[`testing.md`](docs/testing.md) ·
[`glossary.md`](docs/glossary.md)

**[`docs/pve-facts.md`](docs/pve-facts.md)** underpins all of it: every claim
about Proxmox internals in this repository cites a `[PVE-F-nnn]` entry naming
the file and lines it was read from. Nothing is asserted from memory.

## Development

```sh
make test                       # unit tests; no Proxmox host needed
make lint                       # perl -T -c + shellcheck
make deb                        # build the package into ../
make e2e                        # full QEMU integration run
make facts ISO=proxmox-ve.iso   # re-derive PVE seam evidence, offline
```

`make test` needs no Proxmox and is the loop you write code in. `make e2e`
boots a real PVE 9.x in QEMU and proves the claims no stub can — that a live
`pvedaemon` is running our module, that a `pve-manager` upgrade leaves it
running, and that `apt purge` gives the host back untouched.
[`docs/testing.md`](docs/testing.md) covers both, including how to build the
VM image the first time.

`scripts/extract-pve-source.sh` reads PVE source straight out of an installer ISO
— no root, no loop mount, no running Proxmox — so every claim in the docs can be
re-checked against a specific `pve-manager` version by anyone. Re-run
`make facts` after each PVE point release and diff `docs/facts/` to see which
assumptions moved.

## Contributing

[`CONTRIBUTING.md`](CONTRIBUTING.md) for how a change gets here, and
[`AGENTS.md`](AGENTS.md) for a cold-start map of the repository — which document
owns which subject, and the hazards worth knowing before the first edit.

Found something exploitable? [`SECURITY.md`](SECURITY.md), not the issue
tracker.

## Licence

AGPL-3.0-or-later, matching Proxmox VE. Full text in [`LICENSE`](LICENSE).
