# ADR 0011 — Fingerprint the registry a daemon loaded

**Status:** Accepted
**Date:** 2026-08-16
**Applies to:** proxmod 0.2.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** implemented in
[`perl/Proxmod/Registry.pm`](../../perl/Proxmod/Registry.pm),
[`perl/Proxmod/Boot.pm`](../../perl/Proxmod/Boot.pm),
[`bin/proxmod-verify`](../../bin/proxmod-verify) and
[`exec/proxmod-reapply`](../../exec/proxmod-reapply); tested in
`t/02-registry.t`, `t/09-reapply.t`, `t/10-verify.t` and
`test/integration/11-registry.sh`

---

## Context

[ADR 0009](0009-verify-the-running-daemon.md) settled that the primary gate is
the running daemon: does its journal, since *this process* started, contain
proxmod's boot line? `proxmod-reapply` turns that answer into a restart
decision, and restarts when the drop-ins changed, a managed patch changed a
file, or the daemons are not loading proxmod.

That set has a hole in it, and the hole is the ordinary case.

An extension package installs three files, ships no maintainer scripts, and
fires our dpkg trigger. The drop-ins are already converged. Nothing is patched.
Both daemons are perfectly healthy and have proxmod loaded. So every gate says
"already converged; not restarting", and the extension the administrator just
installed does nothing at all until somebody restarts `pvedaemon` by hand.

Removing an extension is the same defect wearing the other face: the manifest
is gone and the daemon keeps serving the endpoint out of the registry it read
at startup. Upgrading proxmod itself is the third: the new modules land on disk
and the old ones stay resident.

This was found on a live five-node cluster, not in a test. Every check on every
node reported a healthy host.

## Decision

Each daemon logs a short fingerprint of the registry it loaded, in the same
`booted` line ADR 0009 made the source of truth:

```
proxmod: booted daemon=pveproxy extensions=3 failed=0 registry=8c1f0ab27d3e
```

`Proxmod::Registry::fingerprint($exts)` computes it — a truncated SHA-256 over
proxmod's own version plus, for each effective extension in resolved order, the
fields that change what runs: id, basename, version, order, backend module and
daemon set, frontend assets.

`proxmod-verify` recomputes it from disk and compares, reporting
`registry.<unit>` in the ordinary report and answering the narrow question on
`--registry-only` (exit 0 up to date, 1 out of date, 2 could not tell, with the
current fingerprint on stdout). `proxmod-reapply` gains one more reason to
restart, asked last, behind a loop-breaker.

## Why

**One function, called from both sides.** `Proxmod::Boot` and `proxmod-verify`
call the same code, so they agree by construction rather than by two
implementations being kept in step. The failure mode of the alternative is a
verify tool that reports drift where there is none, which is worse than no
check: it teaches people to ignore the check.

**Not a count of extensions.** The obvious cheap version — compare
`extensions=N` against what is on disk — does not work, and does not work
quietly. `pveproxy` runs the frontend stage and `pvedaemon` does not, so on one
registry they legitimately report different numbers. Any comparison built on
what each daemon *loaded* has to know which daemon is asking. A digest of the
registry itself does not.

**proxmod's own version is in it.** That is what makes `dpkg -i proxmod`
restart the daemons onto the new modules. It is read from `Proxmod::Registry`'s
`$VERSION` rather than `Proxmod.pm`'s, because `Proxmod.pm` is an `INIT` block
that boots proxmod into whatever process loads it — `proxmod-verify` must never
require it.

**A warning, not an error.** In the ordinary case the dpkg trigger is
converging this a moment later. A tool that went red for those seconds would be
red often enough to be ignored, and the thing it must never be is ignored.

**A separate flag, not a wider `--live-only`.** ADR 0009 says `--live-only`
must stay narrow because `proxmod-reapply` turns it into a daemon restart. The
same argument applies to its replacement, so this is a second narrow question
rather than a broader one: widening either cannot silently widen the other.

**Asked last.** A daemon that is not running proxmod at all and a daemon
running an old registry are both true at once on a freshly broken host. The
more serious one has to be the message in the journal, or it sends the
administrator after the wrong problem.

**A missing fingerprint counts as stale.** A daemon that has been up since
before 0.2.0 cannot say what it loaded. Assuming the worst is what makes the
first upgrade onto a fingerprint-aware proxmod converge by itself, with no
release note telling anyone to restart anything.

## Consequences

- **One more restart trigger, and restarts are the expensive thing proxmod
  does.** It fires only when the registry genuinely moved, which is exactly when
  a restart was needed and was previously not happening. `09-noop-apt` remains
  the standing proof that an unrelated apt run still restarts nothing.
- **A loop-breaker, and its cost.** `proxmod-reapply` records the fingerprint it
  restarted for in `/var/lib/proxmod/registry.stamp`. If the daemons come back
  still not running it, it says so once and stops — restarting on every trigger
  is the prior art's behaviour this project exists to not repeat. The cost is
  real: a host whose daemons genuinely cannot load the new registry converges
  once, warns once, and then stays quiet about it until something else changes.
  `proxmod-verify` keeps reporting it on every run, which is where that state is
  meant to be seen.
- **The fingerprint is a cluster tool by accident.** Nodes with the same
  extensions print the same value, so `proxmod-verify --registry-only` across a
  cluster is an honest answer to "are these nodes actually running the same
  thing". [`cli.md`](../cli.md) §2 has the loop.
- **Changing what the fingerprint covers changes every fingerprint**, so the
  first reapply after such an upgrade restarts the daemons once. That is
  correct — proxmod's version is in the digest precisely so an upgrade counts —
  but it means the covered field list is not somewhere to add speculative
  entries.
- **It cannot see a change that is not in the registry.** An extension whose
  Perl module was replaced on disk with the same manifest has the same
  fingerprint. The trigger on `/usr/share/perl5/PVE` and the `changed` gate
  cover the cases proxmod owns; an extension package that ships a module without
  touching its manifest is relying on dpkg's trigger firing for the directory,
  which it does.

## Alternatives considered

**Compare `extensions=N` to a count from disk.** Cheapest, and wrong: the two
daemons legitimately disagree on the count for one registry. It would report
permanent drift on every host with a frontend extension.

**Restart on every trigger.** What the prior art's APT hook effectively did.
Correct in the narrow sense and unacceptable in practice — an apt run that has
nothing to do with proxmod would interrupt the hypervisor's API.

**Timestamp the extension directories and compare against the unit's start
time.** No new field in the journal, but it says "something was written",
not "what runs is different". Touching a manifest, reinstalling the same
package, or a config-management tool rewriting an identical file would each cost
a restart. It also cannot express "proxmod itself was upgraded".

**A state file written at boot.** ADR 0009 already rejected this for the live
gate, for the reason that applies here too: it can be stale in exactly the case
that matters — written by a process that has since died, still present, still
saying the right thing.
