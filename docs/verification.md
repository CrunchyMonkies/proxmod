# Verification

**Status:** Draft
**Applies to:** proxmod 0.1.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** every check id, level and message below was read out of
[`bin/proxmod-verify`](../bin/proxmod-verify); its behaviour is unit-tested in
`t/10-verify.t`

**proxmod fails quietly on purpose.** A broken extension does not stop a daemon.
A failed dpkg trigger does not stop `apt`. A seam that moved disables one
feature and leaves the rest running. That is the right behaviour for something
attached to a hypervisor's control plane — and it means **nothing will tell you
when proxmod stops working.** You have to ask.

Asking is one command.

```sh
proxmod-verify            # 0 healthy, 1 a check failed, 64 bad usage
proxmod-verify --json     # for monitoring
```

---

## 1. The obligation

Two things, and they are the price of the fail-safe design:

1. **Wire `proxmod-verify --json` into monitoring.** Alert on `healthy: false`.
2. **Run it after every `pve-manager` upgrade.** That is when a seam moves.

Everything else in this document is detail for when it says something is wrong.

---

## 2. The primary gate is the running daemon

`proxmod-verify` asks, of each wrapped unit:

```sh
journalctl -u <unit> --since "$(systemctl show -p ExecMainStartTimestamp --value <unit>)"
```

— does the journal, **since this process started**, contain proxmod's boot line?

It deliberately does **not** run a fresh `perl -MProxmod -e1`. A fresh `perl`
proves the module compiles on this host today. It proves nothing about the
process currently serving your API, which started earlier, possibly with a
different command line, possibly before an upgrade replaced something
underneath it.

That distinction is the whole design. It is exactly the class of check that
would have caught `pve-token-copy`'s taint-mode bug, where its own verify passed
while the endpoint had never once loaded — the module compiled fine outside the
daemon and `-T` refused it inside.

**Rule for anything you write:** verify the running system, not a fresh process
that resembles it.

---

## 3. The checks

### `installed`

Are the drop-in sources shipped, and are they in place under
`/etc/systemd/system/`?

- **error — "no systemd drop-ins are shipped"** — the package is damaged.
  Reinstall.
- **error — "the systemd drop-ins are not in place"** — `postinst` did not run
  or something removed them. `proxmodctl reapply`.

### `disabled`

- **info — "proxmod is disabled by the kill switch"** — `/etc/proxmod/disabled`
  exists. Everything downstream is expected to be absent. `proxmodctl enable`.

### `drift.<unit>`

Does the **live** unit's `ExecStart` resolve to proxmod's wrapper?

- **error — "`<unit>` does not start through proxmod"** — the drop-in is absent,
  or **another package's drop-in won the `ExecStart=` race**. Only one drop-in
  can set it; the last one alphabetically wins. If another framework wraps the
  same daemon, they conflict. See §6.

### `reload.<unit>`

- **warn — "`<unit>` will lose proxmod on reload"** — the `ExecReload` override
  is missing. The next `systemctl reload pveproxy`, or the next `pve-manager`
  upgrade running `reload-or-try-restart` [PVE-F-005], will silently unload
  proxmod and leave a healthy-looking daemon serving no extensions.
  `proxmodctl reapply`.

This is the most likely thing to be wrong after an upgrade, and the reason to
run `proxmod-verify` after one.

### `live.<unit>`

- **error — "`<unit>` is running WITHOUT proxmod"** — the drop-in may be
  correct, but the process serving requests right now was started without it, or
  the wrapper fell back. `journalctl -u <unit>` for the wrapper's reason;
  usually the kill switch, a permissions refusal (§5), or an unrecognised
  shebang after a Proxmox change.
- **ok — "`<unit>` is running without proxmod, as configured"** — the kill
  switch is set. Not a failure.
- **warn — "cannot read the journal"** — persistent journald is off, or the
  check is not running as root. Verification is degraded, not failing.

### `extensions.<unit>`

- **warn — "N extension(s) failed to load in `<unit>`"** — proxmod is working;
  an extension is not. This is a warning, not an error, because the isolation is
  designed behaviour. `proxmodctl logs` says which and why.

### `http.index`

What counts as correct here depends on whether any extension actually wants a
frontend. `Proxmod::Frontend` leaves the index completely alone when none does,
so on a **backend-only host the absence of a loader tag is the design working**
— see "A host with no frontend extension" below.

- **ok — "exactly one loader tag"** — what you want, on a host with a frontend
  extension.
- **ok — "no loader tag, and no extension asks for one"** — backend-only host.
  Nothing is wrong; proxmod's zero-footprint promise means there is nothing to
  see.
- **ok — "no loader tag, as configured"** — the kill switch is set.
- **error — "no loader tag"** — an extension declares a frontend asset and the
  tag is missing anyway. The injection did not happen; the seam probe likely
  failed. Check the journal for a warning from `Proxmod::Frontend`.
- **error — "N loader tags"** — two things are injecting. Usually a patch spec
  doing by hand what proxmod already does at runtime. `proxmodctl patch status`.
- **warn — "N loader tag(s) but no extension declares a frontend asset"** —
  proxmod did not put that there. Either a stale tag from an extension that has
  since been removed without a daemon restart, or something has patched
  `index.html.tpl`.
- **warn — "disabled but the index still has a loader tag"** — the kill switch
  is set but the daemon has not been restarted since.
- **warn — "could not fetch the web interface index"** — `GET /` did not answer
  200. That is a `pveproxy` problem, not a proxmod one, so it does not fail the
  run; the rest of the HTTP checks are skipped.

### `http.loader`

- **error — "`/proxmod/loader.js` is not being served"** — the `init` wrap did
  not register the route. Journal.
- **info — "skipped the `/proxmod/loader.js` checks"** — no extension declares a
  frontend asset, so proxmod deliberately registers no route. Not a failure, and
  reported explicitly rather than silently dropped: a check that vanishes reads
  exactly like a check that passed.

Note on what a *served* loader can contain: once the route exists, a loader
proxmod could not *build* returns **HTTP 200 with an inert comment**, not a 500 —
a 500 would put a red line in every administrator's console on every page load
and change nothing. So "served, but empty" is a real state; the journal is where
the reason is.

That only holds once the route exists. Before it does — on a backend-only host,
where the `init` wrap never ran — `/proxmod/loader.js` matches nothing in
`{pages}` or `{dirs}` [PVE-F-024] and `pveproxy`'s static fall-through answers
**500**. That is why this check is skipped rather than made lenient: a 500 there
is normal, and a 500 anywhere else is not.

### `http.asset/proxmod/<file>.js`

One finding per distinct asset the loader references; the asset's own path is
part of the finding id, so monitoring can tell which file moved.

- **error — "`<asset>` is referenced but not served"** — a manifest names an
  asset that is not in `/usr/share/proxmod/www/`. The extension package is
  broken, or half-installed.

### `structure`

Loads the extension registry in a fresh `perl` and reports which backend
extensions it finds. This is a sanity check on the registry, not a replay of the
API tree, and it is deliberately never fatal — `check_live` is what is
authoritative about whether anything is actually running.

- **info — "N backend extension(s) in the registry"** — normal.
- **info — "no backend extensions are registered"** — normal on a
  frontend-only host.
- **warn — "could not load proxmod to replay the API tree"** — this check needs
  PVE modules present; it is skipped rather than failed when they are not.
- **warn — "could not read the extension registry"** — a manifest is malformed.
  `proxmodctl list` for which.

### Levels

Only **error** sets the exit status. **warn** is reported and does not fail:
proxmod degrading *is* the designed behaviour, and an administrator who disabled
an extension should not get a red alert for it.

That said — read the warnings. `reload.<unit>` is a warning and it means proxmod
will disappear at the next upgrade.

### A host with no frontend extension

A host whose extensions are all backend-only — a CSI driver, a metrics
collector, anything that adds API endpoints and no UI — is a **fully healthy
host**, and `proxmod-verify` exits 0 on it.

This is worth stating because the evidence looks alarming if you go looking by
hand:

| What you see | Why |
|---|---|
| no `/proxmod/loader.js` tag in the index | `Proxmod::Frontend::install` returns immediately when no extension declares an asset; `get_index` is never wrapped |
| `GET /proxmod/loader.js` → **500** | the `init` wrap never ran either, so `/proxmod/` is not in `{pages}` or `{dirs}` [PVE-F-024] and `pveproxy` falls through to its static handler |
| nothing in the journal about it | the no-op is logged at debug level, because on a backend-only host it would otherwise be printed on every daemon start forever |

All three are the zero-footprint promise being kept: proxmod does not touch the
web interface unless something asked it to. `proxmod-verify` reads the registry
to tell this state apart from a genuinely broken injection, reports `http.index`
as **ok** and `http.loader` as **info — skipped**, and exits 0.

If you want to confirm it rather than infer it:

```sh
proxmod-verify --json | jq -r '.findings[] | select(.id | startswith("http.")) | "\(.level)\t\(.id)\t\(.title)"'
```

---

## 4. `--live-only`

The narrow question `proxmod-reapply` asks before deciding whether to restart:
are the running daemons loaded?

**It must not be widened.** A failing HTTP check is not a reason to bounce
`pvedaemon` — a 404 on one asset would become a hypervisor API interruption, and
a restart would not fix it anyway.

---

## 5. Checks that run before proxmod loads

`proxmod-exec` refuses to inject — and starts the daemon **unmodified** — when
any of `/usr/share/perl5/Proxmod*`, `/usr/share/proxmod/extensions.d` or
`/etc/proxmod` is non-root-owned or group/world-writable.

Everything in those paths is executed as root inside `pvedaemon`. A
group-writable entry is unauthenticated root RCE on the hypervisor, so refusing
is correct, and it presents as `live.<unit>` failing while `drift.<unit>` passes.
Fix the mode, do not work around the check:

```sh
find /usr/share/perl5/Proxmod* /usr/share/proxmod/extensions.d /etc/proxmod \
     \( ! -user root -o -perm /022 \) -print
```

See [`security.md`](security.md).

---

## 6. What verification cannot tell you

Say so plainly:

- **Another framework's drop-in winning the `ExecStart=` race** is *detected*
  (`drift.<unit>`) but not *resolved*. Two packages wrapping the same daemon
  conflict. The mitigation is that proxmod can inject a list of modules, so
  another wrapper's module can become a proxmod extension instead of a
  competing drop-in.
- **Whether an extension is correct.** proxmod verifies that it loaded and that
  its routes resolve. What it does is between it and you.
- **Whether an endpoint's permissions are right.** `add_method` forces you to
  make the choice explicit; it cannot tell you that you chose well. Test as a
  non-root user with a real ACL.
- **A Proxmox change that alters behaviour without moving a seam.** The
  probes ask "does this exist" and "does this resolve", not "does this still
  mean what it meant".

For the last one, the fact ledger is the tool:

```sh
make facts ISO=/path/to/proxmox-ve_X.Y-Z.iso
git diff docs/facts/
```

Every Proxmox-internals claim in the documentation cites a `[PVE-F-nnn]` entry
harvested by that script. A diff in the harvest is the signal to re-read the
claims that cite it. See [`pve-facts.md`](pve-facts.md).

---

## 7. Recipes

```sh
# Routine
proxmod-verify

# Monitoring
proxmod-verify --json | jq -e '.healthy'

# After a Proxmox upgrade
proxmod-verify && echo ok

# The headline claim, checked
dpkg -V pve-manager libpve-common-perl libpve-http-server-perl

# Everything, for a bug report
proxmodctl doctor

# Why did an extension not load?
proxmodctl logs | grep -i 'fail\|error\|warn'
```

---

## Reference

- [`cli.md`](cli.md) — every flag
- [`troubleshooting.md`](troubleshooting.md) — symptom-first
- [`specifications.md`](specifications.md) §15 — normative observability requirements
- [`pve-facts.md`](pve-facts.md) — the fact ledger and how to regenerate it
- [`security.md`](security.md) — the refusals in §5
- [`testing.md`](testing.md) — the test suites, which check the same claims on a
  VM rather than on your host
