# ADR 0012 — A wrap declares its posture, and there is no default

**Status:** Accepted
**Date:** 2026-08-28
**Applies to:** proxmod 0.4.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1
**Verification method:** implemented in
[`perl/Proxmod/API.pm`](../../perl/Proxmod/API.pm) `wrap_method` / `wrap_sub`;
both postures exercised in `t/04-api.t`, and the `open` posture's behaviour is
pinned end to end by `t/06-frontend.t`

---

## Context

[ADR 0001](0001-runtime-injection-over-file-patching.md) chose runtime injection
over patching Proxmox's files, and [`conventions.md`](../conventions.md) §3
states the rule that follows from it: *"Probe before you wrap … A seam that moved
should produce a missing feature and a log line, never a stuck interface."*

That was prose with no code behind it. `Proxmod::Frontend::_wrap` was the only
implementation, private and specific to two seams, and the first backend
extension to enforce anything — `proxmod-pool-quota`, wrapping eleven seams —
wrote the whole thing again: the probe, the `eval`, the log-once rule,
idempotency, and a bookkeeping ledger so it could report what was live.

Making that shared raised a question the two consumers answer in opposite ways.

**The frontend fails open.** If the injection hook dies, the browser must still
get the page Proxmox built. *Our half is optional; theirs is not.*

**Enforcement fails closed.** If the quota hook dies, the guest must not be
created. A refusal that gets swallowed is a quota that does not exist.

Both are correct. Neither is a safe thing to assume on an author's behalf.

## Decision

`posture` is a **required** argument to `wrap_method` and `wrap_sub`, taking
`closed` or `open`. There is no default, and omitting it is an error naming both
values and what each one does.

## Why

**A silent default here has the same shape as the one ADR 0006 exists to
prevent.** A method registered with no `permissions` key is not an error to
Proxmox — it is a working endpoint only `root@pam` can call, with nothing said
anywhere. [ADR 0006](0006-permissions-are-mandatory.md) made the argument that
the failure is invisible and the cost of being wrong is high, so the choice must
be written down. This is the same argument about a different field: a wrap whose
posture was guessed would either swallow a refusal that mattered or propagate an
exception into a page render, and in both cases the author would find out from
somebody else's incident.

**The two failures are asymmetric in the worst way.** Guessing `open` on an
enforcement seam is silent — the quota simply does not hold, and nothing logs
that it was supposed to. Guessing `closed` on a presentation seam is loud, but it
takes out the web interface. Neither direction is a safe default even before
asking which is more common.

**"More common" is not a tiebreak worth having.** proxmod has two consumers and
they split one apiece. Any default would be a coin toss dressed as a
convention.

**It costs one word.** The argument against mandatory fields is friction, and
`posture => 'closed'` is not friction — it is the one thing about a wrap that a
reader most needs to know, sitting where they will read it.

## Consequences

- Every call site states, at the call site, whether a hook failure is survivable.
  That is legible to a reviewer in a way a framework default never is.
- `Proxmod::Frontend` now says `posture => 'open'` out loud, where before the
  behaviour was a comment above a hand-written `eval`.
- One more thing to get wrong at first use, mitigated by the error message
  naming both values and their consequences rather than saying "invalid posture".
- The ledger records the posture per seam, so `proxmod-verify` can report not
  only which seams are wrapped but which of them would refuse a call.

## Alternatives considered

**Default to `open`**, matching proxmod's existing behaviour and its general
stance that extensions are optional. Rejected: it makes the dangerous case the
quiet one. An enforcement author who forgets the argument ships a quota that
reports and never refuses, and no test they are likely to write would catch it.

**Default to `closed`**, on the grounds that a wrap author who did not think
about failure should get the loud version. Rejected: applied to the frontend it
turns a bad tab into an unusable hypervisor interface, which is precisely the
outcome [`frontend-extensions.md`](../frontend-extensions.md)'s prime directive
forbids.

**Two differently named methods** — `wrap_method` and `try_wrap_method`.
Rejected as the same decision spelled less clearly: the distinction ends up in a
prefix a reader has to already know, rather than in a word that says what it
means.

---

## Reference

- [ADR 0001](0001-runtime-injection-over-file-patching.md) — why there is a wrap at all
- [ADR 0006](0006-permissions-are-mandatory.md) — the same argument about `permissions`
- [`perl-api.md`](../perl-api.md) §2 — the two methods
- [`pve-facts.md`](../pve-facts.md) — `[PVE-F-054]`, the seam `wrap_method` uses
