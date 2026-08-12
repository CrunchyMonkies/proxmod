# proxmox-csi-storage

**Status:** Living
**Applies to:** Proxmox VE 9.x, proxmod >= 0.1.0

A proxmod extension that gives [proxmox-csi-plugin](https://github.com/sergelogvinov/proxmox-csi-plugin)
two token-authorised operations it currently needs `root@pam` for. It adds:

- `GET /nodes/{node}/proxmod/csi-storage` — an index
- `POST /nodes/{node}/proxmod/csi-storage/copy` — cross-storage volume copy,
  used by the migration controller and by volume snapshots
- `POST /nodes/{node}/proxmod/csi-storage/reassign` — reassign a disk's
  owning VM ID, wrapping PVE's built-in `move_disk` `target-vmid`

Both endpoints are `protected => 1` (bridged to root inside `pvedaemon`) but
gated by an explicit ACL `check` instead of PVE's usual root@pam-only
default, so a scoped API token can call them.

## Relationship to `hack/pve-token-copy`

`proxmox-csi-plugin` ships a hand-rolled version of the `copy` endpoint at
`hack/pve-token-copy/`, built before proxmod existed. It works by injecting
a `-MPVECSICopy` module load onto the `pvedaemon`/`pveproxy` systemd
`ExecStart` line, to route around `perl -T` taint mode ignoring
`PERL5LIB`/`PERL5OPT`. This extension supersedes that workaround: proxmod's
own `-MProxmod` injection and manifest-driven `require` make the systemd
wrapper unnecessary, and the endpoint moves off `/nodes/{node}/storage/{storage}/csi-copy`
(a sibling to PVE's own `content/{volume}`, chosen specifically to dodge that
route's greedy `{volume}` param) onto proxmod's isolated
`/nodes/{node}/proxmod/csi-storage` subtree, where a routing collision with
any PVE-owned tree is structurally impossible.

`hack/pve-token-copy/` is not removed by shipping this — see that hack's own
docs for its deprecation status in `proxmox-csi-plugin`.

## Caveats — read before deploying

- **`reassign`'s target PVE method name is a best guess.** `PVE::API2::Qemu`
  is part of `pve-manager`, not vendored anywhere either repo can inspect
  offline, so `_reassign_code` in `CSIStorage.pm` tries a short list of
  candidate registered method names (`move_vm_disk`, `move_disk`,
  `moveDisk`) via `map_method_by_name` and dies with a clear error if none
  resolve. Validate against the actual PVE version on the target node
  before relying on this in production.
- **Whether this endpoint is even necessary is unconfirmed.** It's possible
  vanilla PVE already permits a `VM.Config.Disk`-scoped token to pass
  `target-vmid` to the built-in `move_disk` call without needing a
  root-bridging wrapper at all. Check this on a live cluster first.
- **`move_disk`'s `target-vmid` renames the underlying volume** on storage
  backends that encode the owning VM ID in the volume name (LVM, ZFS,
  directory). Callers that track a volume by its pre-reassignment name
  (as `proxmox-csi-plugin`'s CSI `VolumeID` does) need their own plan for
  that; see `proxmox-csi-plugin`'s `docs/reassign-volume-on-attach.md`.

## Read it in this order

1. `conf/50-proxmox-csi-storage.conf` — the manifest
2. `perl/ProxmodExt/CSIStorage.pm` — `proxmod_register()`, the ACL model for
   each endpoint, and the caveats above in code-comment form
3. `Makefile` and `debian/` — packaging, same shape as
   `examples/proxmod-example-hello/`

No frontend asset: this extension is backend-only, nothing renders in the
web UI.
