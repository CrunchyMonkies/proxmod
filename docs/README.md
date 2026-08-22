# proxmod documentation

**Status:** Draft
**Applies to:** proxmod 0.2.1, Proxmox VE 9.x
**Last verified against:** pve-manager 9.1.1 (2026-08-08)
**Verification method:** each document below carries its own verification line

Two things live here: **how to extend Proxmox VE**, which is useful whether or
not you use proxmod, and **how proxmod does it**.

Start with the reading order that matches why you are here.

---

## Reading orders

### I want to add something to Proxmox

Twenty minutes to a working tab and endpoint, then depth as you need it.

1. [`getting-started.md`](getting-started.md) — build and install the example, then make it yours
2. [`extension-manifest.md`](extension-manifest.md) — the manifest, field by field
3. [`backend-extensions.md`](backend-extensions.md) — the REST endpoint
4. [`frontend-extensions.md`](frontend-extensions.md) — the ExtJS interface
5. [`packaging.md`](packaging.md) — the `.deb`
6. [`perl-api.md`](perl-api.md) and [`js-api.md`](js-api.md) — reference, when you need a signature

Read [`security.md`](security.md) §8 before you ship. Your code runs as root
inside `pvedaemon`, and your JavaScript renders in an administrator's browser.

### I run Proxmox and something installed this

1. [`install.md`](install.md) — what it put on your system, and how to remove it
2. [`verification.md`](verification.md) — how to know it is working, and **the monitoring obligation**
3. [`troubleshooting.md`](troubleshooting.md) — symptom first
4. [`cli.md`](cli.md) — `proxmodctl` and `proxmod-verify`
5. [`security.md`](security.md) — what it added to your attack surface, stated honestly

If something is on fire: `touch /etc/proxmod/disabled && systemctl restart
pvedaemon pveproxy` starts both daemons exactly as Proxmox ships them.

### I want to understand how Proxmox works

The teaching material. Useful on its own — none of it requires proxmod.

1. [`pve-internals.md`](pve-internals.md) — processes, request lifecycle, the REST tree, auth, pmxcfs, how the interface is built and served, and a **seam inventory** marking what is official and what is not
2. [`backend-extensions.md`](backend-extensions.md) — the Perl side in practice
3. [`frontend-extensions.md`](frontend-extensions.md) — the ExtJS side in practice
4. [`pve-facts.md`](pve-facts.md) — every internals claim in this documentation, with the file and lines it was read from
5. [`patching.md`](patching.md) §2 — a post-mortem of doing this the other way

### I want to know why proxmod is built like this

1. [`architecture.md`](architecture.md) — the narrative
2. [`decisions.md`](decisions.md) — the ADRs, each with its costs and rejected alternatives
3. [`specifications.md`](specifications.md) — the normative version, with requirement IDs
4. [`compatibility.md`](compatibility.md) — what happens on a Proxmox proxmod has not seen

### I am changing proxmod itself

1. [`conventions.md`](conventions.md) — the rules, and which are enforced by tests
2. [`architecture.md`](architecture.md) §9 — where things are in the source
3. [`testing.md`](testing.md) — the two test tiers, and which claims each one can make
4. [`decisions.md`](decisions.md) — before revisiting a decision, read why it was made
5. [`pve-facts.md`](pve-facts.md) — before writing a new claim about Proxmox

---

## Everything, by kind

**Teaching**

| | |
|---|---|
| [`pve-internals.md`](pve-internals.md) | how Proxmox VE works inside |
| [`backend-extensions.md`](backend-extensions.md) | writing a Perl REST endpoint |
| [`frontend-extensions.md`](frontend-extensions.md) | writing an ExtJS interface |
| [`packaging.md`](packaging.md) | building the Debian package |
| [`patching.md`](patching.md) | the escape hatch, and why it is one |
| [`getting-started.md`](getting-started.md) | the twenty-minute path |

**Reference**

| | |
|---|---|
| [`specifications.md`](specifications.md) | normative, with `[REQ-*]` ids |
| [`extension-manifest.md`](extension-manifest.md) | every manifest field |
| [`perl-api.md`](perl-api.md) | `Proxmod::API` |
| [`js-api.md`](js-api.md) | the `Proxmod` JS global |
| [`cli.md`](cli.md) | `proxmodctl`, `proxmod-verify` |
| [`glossary.md`](glossary.md) | the vocabulary |
| [`pve-facts.md`](pve-facts.md) | the fact ledger |

**Operating**

| | |
|---|---|
| [`install.md`](install.md) | install, configure, remove |
| [`verification.md`](verification.md) | knowing it works |
| [`troubleshooting.md`](troubleshooting.md) | when it does not |
| [`compatibility.md`](compatibility.md) | across Proxmox versions |
| [`security.md`](security.md) | trust boundaries and obligations |

**Design**

| | |
|---|---|
| [`architecture.md`](architecture.md) | how it fits together |
| [`decisions.md`](decisions.md) | the decision log |
| [`adr/`](adr) | the ADRs themselves |
| [`conventions.md`](conventions.md) | how this project writes things |
| [`testing.md`](testing.md) | how it is tested, and how to add a test |

---

## Two conventions worth knowing before you read

**Every claim about Proxmox internals cites a `[PVE-F-nnn]` entry** in
[`pve-facts.md`](pve-facts.md), which names the file and lines it was read from.
Nothing here is asserted from memory. The ledger is regenerable offline:

```sh
make facts ISO=/path/to/proxmox-ve_9.1-1.iso
git diff docs/facts/
```

A diff means a seam moved, and tells you exactly which sentences to re-read.

The same evidence can be re-derived with no ISO at all. `docs/third_party/`
holds the eight upstream Proxmox repositories as SHA-pinned shallow submodules,
so the source behind every fact is readable in place:

```sh
make submodules       # populate docs/third_party/
make facts-src        # re-derive docs/facts/pve-src.txt from it
```

They are reference material only: nothing builds against them, and
`debian/source/options` keeps them out of every package.

**Every document states what it costs.** proxmod attaches to interfaces Proxmox
never published; the limitations are in the documents, not omitted from them.
[`compatibility.md`](compatibility.md) §3 lists what breaks when each seam moves,
[`architecture.md`](architecture.md) §8 lists what proxmod cannot do, and
[`verification.md`](verification.md) §6 lists what verification cannot tell you.
