# Security policy

## Supported versions

proxmod is pre-1.0. Only the latest release receives fixes; there are no
maintained stable branches. See [`docs/compatibility.md`](docs/compatibility.md)
for what a version number promises.

## Reporting a vulnerability

**Use GitHub's private vulnerability reporting**, on the
[Security tab](https://github.com/CrunchyMonkies/proxmod/security/advisories/new)
of this repository. That opens a private advisory visible only to the
maintainers; it does not create a public issue.

Please do not open a public issue for anything that is a live exploit path
against a running Proxmox host.

Anything that is *not* exploitable — a missing check with no reachable
consequence, a hardening suggestion, a question about the model — is welcome as
an ordinary issue.

Include, if you have it: the proxmod version (`proxmodctl status`), the
`pve-manager` version, whether any extension packages are installed, and the
smallest thing that reproduces it. `proxmodctl doctor` collects most of this.

## What we are most interested in

proxmod runs as root inside `pvedaemon` and `pveproxy`, under `perl -T`. The
consequences of a failure here are not confined to proxmod. In rough order of
severity:

- **Any way to reach `require`, `eval` or a shell with a string that came from a
  file.** Extension manifests, patch specs and asset names are all read from
  disk and all reach code paths that could compile something. Every one of them
  is supposed to be validated by rebuilding from a strict-pattern capture.
- **Any path where an unprivileged user's input reaches the root daemon without
  a permissions check.** A registered API method with no `permissions` key is
  `root@pam`-only by default [PVE-F-050]; a method that declares one and gets it
  wrong is not.
- **Any way to make the `ExecStart` wrapper inject when it should refuse.**
  `proxmod-exec` checks that nothing it is about to load is writable by a
  non-root user, and execs the daemon unmodified if anything looks wrong. A hole
  in that check is root code execution inside `pvedaemon`.
- **Anything served under `/proxmod/`.** That prefix and `/` are served without
  authentication [PVE-F-023], including to logged-out clients. A secret in an
  asset is a published secret.
- **Anything that makes the managed patch facility write outside its declared
  target, or restore a stale backup over a newer file.**

## What is out of scope

- Findings that require root on the host you are attacking. Root can edit
  `/usr/share/perl5/PVE` directly; proxmod is not a boundary against it.
- Vulnerabilities in Proxmox VE itself. Report those to
  [Proxmox](https://www.proxmox.com/), not here. If proxmod *amplifies* one, we
  want to know.
- The fact that an extension package can run arbitrary code as root. That is
  what an extension is; installing one is a root-level trust decision, the same
  as installing any other Debian package. See
  [`docs/security.md`](docs/security.md) §1.

## Disclosure

We will acknowledge a report within a week, and aim to have a fix or a clear
explanation of why there will not be one within thirty days. We will credit you
in the advisory and the changelog unless you ask us not to.

The full threat model, the trust boundaries and the reasoning behind each rule
above are in [`docs/security.md`](docs/security.md).
