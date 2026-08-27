# ADR 0004 — One frontend injection point feeding a generated loader

**Status:** Accepted
**Date:** 2026-08-08
**Applies to:** proxmod 0.2.2, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** implemented in
[`perl/Proxmod/Frontend.pm`](../../perl/Proxmod/Frontend.pm); tested in
`t/05-frontend.t` against the real `index.html.tpl` vendored from the 9.1.1 ISO

---

## Context

Every frontend extension needs its JavaScript to run in the Proxmox interface,
after `pvemanagerlib.js` has defined the `PVE.*` classes and before
`Ext.onReady` fires [PVE-F-021].

The obvious design is one `<script>` tag per extension. That is what patching
`index.html.tpl` naturally produces, and it is what `pmxxpuiov` does.

## Decision

**Exactly one `<script src="/proxmod/loader.js">` tag, ever**, regardless of how
many extensions are installed. `loader.js` is generated per request from the
live registry and loads each extension's asset in declared order.

## Why

**N tags is N races.** Two packages each inserting a tag into the same response
have no ordering relationship, no way to express a dependency, and no way to
remove one without knowing about the other. One tag makes ordering a property of
the registry — where `requires` and `order` already live — instead of a property
of string insertion.

**Idempotency becomes checkable.** "Exactly one loader tag" is a thing
`proxmod-verify` can assert and a QEMU test can count. "The right set of tags in
the right order" is not.

**A frontend-only extension needs no daemon restart.** The loader is built per
request, so installing an extension that ships only a `.js` file and a manifest
takes effect on the next page load. With static tags this would require
re-injecting, which means restarting `pveproxy`.

**Failure has somewhere to go.** A loader proxmod cannot build returns **HTTP
200 with an inert comment**, not a 500 ([REQ-FE-014]). A 500 would put a red
line in every administrator's console on every page load and change nothing. A
missing asset costs one extension, not the interface.

**The injection itself stays trivially auditable.** One byte-level, ASCII-only,
idempotent insertion at a single anchor, in one function, with one unit test
against the real template. Everything variable moved into generated content.

`get_index` renders four different bodies [PVE-F-022] — the main interface,
novnc, xtermjs and mobile. Injection is a no-op on the other three; a loader in
the noVNC console body would run ExtJS overrides against classes that are not
there.

## Consequences

- Extension load order is proxmod's to define, which means it must be defined:
  `requires` is topologically sorted, ties broken by `order` then filename.
- The loader is a per-request generation on an unauthenticated URL. It contains
  only asset names, which is why those names are pattern-restricted to
  `[A-Za-z0-9][A-Za-z0-9._-]*\.js` — they are path components in a URL served to
  anyone who can reach port 8006 [PVE-F-023].
- Assets are fetched as separate requests rather than concatenated. On a LAN-
  local hypervisor interface with a handful of extensions this does not matter,
  and concatenation would trade a real caching story for a marginal one.
- One extension's asset failing to parse does not stop the others, because they
  are separate script elements — a property concatenation would lose.

## Alternatives considered

**One tag per extension, injected at runtime** — keeps zero-mutation but brings
back the ordering and idempotency problems for no gain.

**Concatenate all assets into one generated bundle** — one request, and one
parse error takes out every extension. Rejected on the isolation ground alone.

**Have extensions register into an existing PVE bundle** — would require
modifying `pvemanagerlib.js`, which is exactly the file mutation ADR 0001 exists
to avoid.
