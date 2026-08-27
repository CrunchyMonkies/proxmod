# Testing

**Status:** Stable
**Applies to:** proxmod 0.2.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** `prove -r t/` on this host; the QEMU suite run against a PVE 9.1 VM built from `proxmox-ve_9.1-1.iso`

---

## 1. Two tiers, and why

proxmod's tests split along a line that is not about speed. It is about what
each kind of test is *able* to prove.

**Unit tests (`t/`, `prove -r t/`)** run anywhere Perl runs. `t/lib/` holds
stubs for the handful of PVE modules proxmod touches, so the real code runs
against a stand-in. They prove the code is correct: that the registry
topologically sorts, that a tainted module name is rejected before `require`
sees it, that the injection puts exactly one tag in the real vendored
`index.html.tpl` and is idempotent, that `proxmod-exec` execs the daemon
unmodified when the shebang is wrong. They are the tests you run while writing
code, and they are the whole of CI.

**Integration tests (`test/integration/`, `make e2e`)** run inside a QEMU VM
with a real Proxmox VE on it. They prove the things no stub can: that a real
`pvedaemon` — root, taint mode, `PERL5LIB` ignored — actually has our module
loaded; that a real `pve-manager` upgrade leaves it that way; that `dpkg -V`
is silent afterwards; that `apt purge` gives the host back.

The split matters because the second tier is the one making proxmod's actual
claims. A unit test can prove the injection function returns the right string.
Only a live host can prove the daemon serving your browser ran it. That
distinction is not academic — it is precisely the gap that let the prior art's
own verification pass while its endpoint had never once loaded.

---

## 2. Running the unit tests

```sh
make test          # prove -r t/
prove -v t/06-frontend.t     # one file, verbosely
```

No Proxmox, no root, no network. If these fail, nothing else is worth running.

`make lint` is part of the same loop: `perl -T -c` on every module (taint mode
is not optional — `/usr/bin/pveproxy` is `#!/usr/bin/perl -T` [PVE-F-002], so
code that only compiles without it fails on a real host and nowhere else),
`shellcheck -x` on every shell file including the maintainer scripts, and
`node --check` on the JavaScript.

### The vendored Proxmox source

proxmod attaches to seams that are not documented API, so a question like "does
`insertNodes` create a group node or not?" has to be answered by reading
Proxmox, not by remembering it. `docs/third_party/` holds eight upstream
repositories as SHA-pinned shallow submodules for exactly that:

```sh
make submodules       # git submodule update --init --depth 1 --recursive
make facts-src        # re-derive docs/facts/pve-src.txt from them
```

They are read-only reference checkouts. Nothing builds against them, `make lint`
cannot reach them, and `debian/source/options` keeps them out of every source
package — check that last one has not regressed with:

```sh
dpkg-deb -c ../proxmod_*_all.deb | grep third_party && echo BROKEN
```

You do not need them to build, test or ship proxmod. You need them to change
anything that cites a `[PVE-F-nnn]` fact. See [`pve-facts.md`](pve-facts.md).

---

## 3. Running the integration tests

### What you need, once

* KVM (`/dev/kvm` readable by you), `qemu-system-x86_64`, `qemu-img`, `socat`,
  `ssh`, and `genisoimage` for the unattended install
* A Proxmox VE 9.x installer ISO
* About 6GB of disk and 40 minutes for the first build

Neither the ISO nor the image is in git. The ISO is Proxmox's to distribute;
the image is large and rebuildable.

```sh
export PROXMOD_PVE_ISO=~/isos/proxmox-ve_9.1-1.iso
test/qemu/vm.sh install        # unattended install → test/qemu/pve-test.qcow2
```

That golden image is built once and then never written to again. Every run
boots a fresh qcow2 overlay on top of it, and `vm.sh stop` deletes the overlay
— so a test that wrecks the host costs one run, not another forty minutes.

### Then

```sh
make e2e                       # build, boot, run everything, tear down
scripts/e2e.sh 03 07           # only those tests
PROXMOD_KEEP_VM=1 make e2e     # leave the VM up afterwards
```

`scripts/e2e.sh` builds both packages, boots the VM, copies the packages and
`test/integration/` in, runs the suite over SSH, pulls the journals and unit
files out to `test/qemu/.run/artifacts/`, and stops the VM. The artifacts are
collected whether the run passed or failed — on a failure the VM is gone by
then, so they are the only remaining record of why.

With `PROXMOD_KEEP_VM=1` you get a live PVE to poke at:

```sh
test/qemu/vm.sh ssh            # a root shell in the VM
test/qemu/vm.sh ssh proxmod-verify
open https://localhost:18006/  # the real web interface, with your extension in it
test/qemu/vm.sh stop
```

---

## 4. What each integration test proves

They run in order and share state through `/var/tmp/proxmod-e2e`. The
numbering is the schedule, not decoration: `00` records the baseline that `02`
and `12` compare against, `01` installs what `12` purges, `04` installs the
extension that `05`–`11` assume is there. A failure in `00` or `01` aborts the
run; everything after that continues, because one run reporting six real
failures is worth more than six runs each reporting the first.

| | Proves |
|---|---|
| `00-baseline` | Refuses to start on a host that already has proxmod on it, and records the sha256 of every dpkg-owned file under Proxmox's directories. Plants a file belonging to a notional third package for `11` to find. |
| `01-install` | Both daemons are **actually running proxmod** — read from the journal of the current process, scoped by `ExecMainStartTimestamp`, not from a fresh `perl -MProxmod -e1`. |
| `02-no-mutation` | **The headline test.** `dpkg -V` silent, every PVE-owned file byte-identical to the baseline, and specifically nothing in `index.html.tpl`, `PVE/API2/`, or `pvemanagerlib.js`. |
| `03-frontend` | Exactly one loader tag, at the right byte offset — after `pvemanagerlib.js`, before `Ext.onReady`. Idempotent across a restart, absent from the novnc and xtermjs bodies, and no path traversal out of `/proxmod/`. |
| `04-backend` | The consumer contract end to end: a package with **no maintainer scripts** drops three files, a dpkg trigger converges, and a tab and an endpoint appear. |
| `05-isolation` | **The most important safety test.** Four broken extensions — a missing module, one that dies at `require`, one that dies during registration behind its own `$SIG{__DIE__}`, and a truncated manifest — and both daemons stay up with the good extension working. |
| `06-killswitch` | `proxmodctl disable` leaves the daemons running exactly as Proxmox ships them, without uninstalling anything or editing a unit file. |
| `07-reload` | `systemctl reload` *and* `deb-systemd-invoke reload-or-try-restart` — PVE's own upgrade path [PVE-F-005] — both keep proxmod loaded. The regression test for the `ExecReload` override. |
| `08-upgrade` | A real `pve-manager` upgrade, using the repository embedded in the installer ISO so it is offline and reproducible. Nothing is reapplied by hand and nothing needs to be. |
| `09-noop-apt` | An apt run that has nothing to do with proxmod does **not** restart the daemons. The regression test for the prior art's APT hook. |
| `10-permissions` | A group-writable module means unauthenticated root inside `pvedaemon`, so the wrapper refuses to inject — the daemon still starts, proxmod does not load, and `proxmod-verify` fails loudly. |
| `11-registry` | Removing an extension takes it out of the *running* daemons, and installing one puts it back — with no `--force` anywhere, because the fingerprint in each daemon's booted line no longer matches the registry on disk. The regression test for a defect that is invisible to `prove` and to every other check here: the host stays healthy, the daemons stay up, and the extension an administrator just removed keeps answering. |
| `12-purge` | The host is indistinguishable from one proxmod was never on: drop-ins gone, `dpkg -V` clean, no orphaned backups, and the planted foreign file untouched. |

---

## 5. Writing a new integration test

Copy the shape of an existing one. `lib.sh` supplies the vocabulary:

```sh
#!/bin/bash
# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "what this section establishes"

assert     "a name for the claim" some-command --that-should-succeed
refute     "a name for the claim" some-command --that-should-fail
assert_eq  "a name" "$expected" "$actual"
assert_contains "a name" "$needle" "$haystack"
skip       "why this could not be checked here"

summary                      # exits non-zero if anything failed
```

Three habits that make these tests worth having:

**Name the claim, not the mechanism.** `"pveproxy went through a real
restart"` tells the next person what broke. `"assert timestamps differ"` does
not.

**Prefer the live system to a proxy for it.** `journalctl` on the running unit
over `perl -c`; a `curl` against `:8006` over reading a file. `pvesh` in
particular cannot see proxmod's endpoints — it builds its own API tree without
`-MProxmod` — so tests go over HTTP with a ticket, the way a browser does.

**Leave the host as you found it.** Anything planted gets cleaned up, and the
runner re-checks that both daemons are active after the whole suite. A suite
that passed while leaving `pvedaemon` dead has not passed.

---

## 6. CI

`.github/workflows/ci.yml` runs on every push: unit tests, lint, both packages
built, `lintian`, and a check that the example extension still ships no
maintainer scripts. All of it on a plain Debian container.

`.github/workflows/e2e.yml` is `workflow_dispatch` on a self-hosted runner
with KVM and a prebuilt image. It is deliberately not on the push path: on a
hosted runner it would mean either a 40-minute unattended install per push or
a TCG-emulated boot slow enough that the harness's timeouts stop meaning
anything — and a job that is usually red for infrastructure reasons trains
people to ignore it.

So the division is: CI proves the code is correct on every push; the QEMU
suite proves it works on a hypervisor when someone asks. Run it before
tagging a release, and after any change to `proxmod-exec`, the drop-ins, the
maintainer scripts, or `proxmod-reapply` — the four places where a defect is
invisible to `prove`.

`release.yml` will not publish a tag whose message lacks an `E2E:` line, which
is how "run it before tagging" stops being a thing to remember. It records the
decision; it cannot verify the run. [`packaging.md`](packaging.md) §10.

`.github/workflows/facts.yml` runs the source fact harvest monthly against
upstream's branch heads and files an issue when a seam a `[PVE-F-nnn]` entry
depends on has moved. It tests nothing — it is the thing that tells you a
document has quietly become false. [`conventions.md`](conventions.md) §8.

## 7. What none of this covers

Worth saying plainly, because a suite this size reads as more complete than it
is:

- **Clusters.** Every integration test is single-node. proxmod holds no
  cluster-wide state, which is why that is defensible rather than merely cheap,
  but "defensible" is not "tested" —
  [`compatibility.md`](compatibility.md) §8 states exactly what is and is not
  claimed, and on what evidence.
- **Proxmox VE 8.** Not supported, not harvested, not probed.
- **Real browsers.** `lint-js` parses the frontend assets and `t/06-frontend.t`
  asserts over what this repo ships; neither loads ExtJS. The 0.2.1 strict-mode
  defect got through both, and what caught it was a person opening the web
  interface.

---

## See also

* [`verification.md`](verification.md) — `proxmod-verify`, which is what you
  run on a production host rather than a test VM
* [`specifications.md`](specifications.md) §16 — the conformance checklist,
  where each item names the test that covers it
* [`conventions.md`](conventions.md) — repository-wide conventions, including
  the ones these tests follow
