# ADR 0006 — `permissions` is a mandatory argument to `add_method`

**Status:** Accepted
**Date:** 2026-08-08
**Applies to:** proxmod 0.2.0, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** enforced in
[`perl/Proxmod/API.pm`](../../perl/Proxmod/API.pm); tested in `t/04-api.t`;
the PVE behaviour is `[PVE-F-050]`

---

## Context

`PVE::RESTHandler::register_method` accepts a `permissions` key and does not
require it. Omitting it is not an error — `check_api2_permissions` treats a
method with no `permissions` as **`root@pam` only**, silently [PVE-F-050].

The consequence: the endpoint works perfectly while you develop it as root, and
returns 403 for every real caller, with nothing in the journal, nothing in the
API documentation and nothing in the code saying why.

That is the exact trap that made `pve-token-copy` necessary in the first place —
and it is a security problem in *both* directions, because the workaround people
reach for is handing out `root@pam` credentials to a service that needed one
narrow capability.

## Decision

`Proxmod::API::add_method` **dies** if the caller did not pass `permissions`.
There is no default. Passing `permissions => undef` is accepted, and means
"`root@pam` only, deliberately".

`{ user => 'world' }` — no authentication at all — is accepted and **logs a
warning naming the method**, so an administrator can find it in the journal.

## Why

The failure being prevented is not "the author chose wrong". It is "the author
never made a choice, and nothing said so". A required argument converts a silent
runtime behaviour into a compile-time-ish error the author hits on their first
run.

`undef` is allowed because root-only is sometimes right. What is not allowed is
arriving at root-only by omission.

The `world` warning exists because that value is correct for exactly one class
of endpoint — PVE uses it for the ticket endpoint — and catastrophic everywhere
else. A warning is the right level: proxmod cannot know it is wrong, and an
administrator grepping the journal can.

## Consequences

- Every proxmod extension has an explicit, greppable permission declaration.
  `grep -r permissions` over an extension is a complete audit of its access
  control surface.
- `add_method` is not a drop-in replacement for `register_method`. That is
  intended; an author who wants the raw call can still make it, and gives up the
  idempotency and route post-check as well.
- proxmod forces the choice to be explicit. It **cannot tell you the choice was
  good.** Testing as root proves nothing about permissions — the documentation
  says so in [`security.md`](../security.md) §6 and
  [`perl-api.md`](../perl-api.md) §3, and `proxmod-verify` says so in
  [`verification.md`](../verification.md) §6.

## Alternatives considered

**Default to `{ user => 'all' }`** — a sane-looking default that silently grants
every authenticated user access to an endpoint the author never thought about.
Strictly worse than root-only-by-omission, because it fails open.

**Default to `undef` and warn** — a warning in a journal that nobody reads until
something breaks. The 403 arrives long before the warning is found.

**Lint it in the build instead** — catches it only for extensions built with
proxmod's tooling, and not at all for one written by hand.
