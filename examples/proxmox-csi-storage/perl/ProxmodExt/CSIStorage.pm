package ProxmodExt::CSIStorage;

use strict;
use warnings;

use PVE::RESTHandler;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::RESTHandler);

# Token-authorised replacement for hack/pve-token-copy in proxmox-csi-plugin.
# Two endpoints, both `protected => 1` (bridged to root inside pvedaemon),
# both gated by an explicit ACL check instead of PVE's root@pam-only default:
#
#   POST /nodes/{node}/proxmod/csi-storage/copy      - cross-storage volume copy
#   POST /nodes/{node}/proxmod/csi-storage/reassign   - reassign a disk's owning vmid
#
# Mounted entirely under proxmod's own /nodes/{node}/proxmod/csi-storage
# subtree (see Proxmod::API - THE NAMESPACE RULE), so neither endpoint
# collides with or is shadowed by PVE::API2::Storage::Content's greedy
# {volume} path or PVE::API2::Qemu's {vmid} tree. That collision risk is
# exactly what forced hack/pve-token-copy's csi-copy method to live at the
# storage level instead of under content/ - moot here, since proxmod never
# nests inside either subtree.
#
# `copy` is a close port of hack/pve-token-copy/perl/PVECSICopy/Impl.pm:
# same ACL model (Datastore.Audit + check_volume_access on the source,
# Datastore.AllocateSpace on the target), same volume-name allow-list, same
# advisory no-clobber check, same storage_migrate worker. See that file's
# history/README for the reasoning; only the registration mechanism changes
# (proxmod's $api->add_method instead of a raw register_method behind a
# `-MPVECSICopy` daemon command-line hack).
#
# `reassign` is new: it authorises `move_disk`'s `target-vmid` parameter
# (Proxmox's own "reassign disk owner" primitive) for a scoped, non-root
# token. Rather than reimplementing PVE's disk-move internals (locking,
# config rewrite on both VMs, snapshot handling), it looks up and invokes
# PVE::API2::Qemu's already-registered move-disk method in-process - this
# extension's job is the ACL bridge, not a reimplementation of vetted PVE
# logic. NOTE: whether vanilla PVE already permits a VM.Config.Disk-scoped
# token to pass target-vmid (i.e. whether this endpoint is even necessary)
# is unconfirmed as of writing; validate against a live cluster before
# relying on this in production - see ../README.md "Caveats".

our $VERSION = '0.1.0';

my $RE_VOLNAME = qr/^[A-Za-z0-9][A-Za-z0-9._\-]*$/;
my $RE_DISK_KEY = qr/^(?:ide|sata|scsi|virtio|efidisk|tpmstate|unused)\d+$/;

# Candidate registered method names for PVE::API2::Qemu's move_disk handler.
# 'move_vm_disk' matches PVE's naming convention for this API
# (resize_vm, migrate_vm, clone_vm, ...) and is the expected match; the list
# exists so a naming difference on an untested PVE release fails loudly
# (a clear die) rather than by guessing wrong silently.
my @MOVE_DISK_METHOD_NAMES = ('move_vm_disk', 'move_disk', 'moveDisk');

sub proxmod_register {
    my ($api) = @_;

    $api->mount(scope => 'node', subclass => __PACKAGE__);

    _register_index($api);
    _register_copy($api);
    _register_reassign($api);

    return;
}

sub _register_index {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'index',
        path => '',
        method => 'GET',
        permissions => { user => 'all' },
        description => 'Index of the proxmox-csi-storage extension.',
        parameters => {
            additionalProperties => 0,
            properties => {
                node => get_standard_option('pve-node'),
            },
        },
        returns => {
            type => 'array',
            items => {
                type => 'object',
                properties => { subdir => { type => 'string' } },
            },
            links => [{ rel => 'child', href => '{subdir}' }],
        },
        code => sub {
            return [{ subdir => 'copy' }, { subdir => 'reassign' }];
        },
    );

    return;
}

sub _register_copy {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'copy',
        path => 'copy',
        method => 'POST',
        protected => 1,
        permissions => {
            description => 'Datastore.Audit on the SOURCE storage (a copy is a read); '
                . 'the specific source volume is additionally checked with '
                . 'check_volume_access, and Datastore.AllocateSpace on the TARGET '
                . 'storage is checked in code.',
            check => ['perm', '/storage/{storage}', ['Datastore.Audit']],
        },
        description => 'Copy a volume to another storage. Token-authorised sibling '
            . "of PVE's root-only built-in content 'copy' method.",
        parameters => {
            additionalProperties => 0,
            properties => {
                node => get_standard_option('pve-node'),
                storage => get_standard_option('pve-storage-id'),
                volume => {
                    description => 'Source volume name within {storage} (block volname).',
                    type => 'string',
                    pattern => $RE_VOLNAME,
                    maxLength => 128,
                },
                target => {
                    description => "Target volume id, 'storage:volname'.",
                    type => 'string',
                    maxLength => 160,
                },
                target_node => get_standard_option('pve-node', {
                    description => 'Target node (defaults to the request node).',
                    optional => 1,
                }),
            },
        },
        returns => { type => 'string' },
        code => \&_copy_code,
    );

    return;
}

sub _copy_code {
    my ($param) = @_;

    require PVE::JSONSchema;
    require PVE::RPCEnvironment;
    require PVE::Storage;
    require PVE::SSHInfo;
    require PVE::INotify;

    my $rpcenv = PVE::RPCEnvironment::get();
    my $authuser = $rpcenv->get_user();
    my $cfg = PVE::Storage::config();

    # --- source (a READ) --------------------------------------------------
    my $src_volid = "$param->{storage}:$param->{volume}";
    my ($src_sid, undef) = PVE::Storage::parse_volume_id($src_volid);
    die "internal: source storage mismatch\n" if $src_sid ne $param->{storage};

    # Datastore.Audit on the storage (declared in `permissions`) is coarse;
    # enforce access to THIS volume so a token can't copy another owner's
    # disk merely because it can create volumes on the same storage.
    my $ownervm;
    eval { (undef, undef, $ownervm) = PVE::Storage::parse_volname($cfg, $src_volid); };
    PVE::Storage::check_volume_access($rpcenv, $authuser, $cfg, $ownervm, $src_volid);

    my $src_size = eval { PVE::Storage::volume_size_info($cfg, $src_volid) };
    die "source volume '$src_volid' not found\n" if !$src_size;

    # --- target (a WRITE) --------------------------------------------------
    my ($dst_sid, $dst_volname) = PVE::Storage::parse_volume_id($param->{target});
    die "invalid target volume name\n"
        unless $dst_volname =~ $RE_VOLNAME && length($dst_volname) <= 128;
    my $dst_volid = "$dst_sid:$dst_volname";
    $rpcenv->check($authuser, "/storage/$dst_sid", ['Datastore.AllocateSpace']);

    PVE::Storage::storage_config($cfg, $src_sid);
    PVE::Storage::storage_config($cfg, $dst_sid);

    # Advisory no-clobber (best-effort; see hack/pve-token-copy's Impl.pm for
    # why the real guarantee is the target plugin's exclusive alloc).
    my $dst_exists = eval { PVE::Storage::volume_size_info($cfg, $dst_volid) };
    die "target volume '$dst_volid' already exists, refusing to overwrite\n"
        if $dst_exists;

    my $target_node = $param->{target_node} || PVE::INotify::nodename();

    my $worker = sub {
        my $sshinfo = PVE::SSHInfo::get_ssh_info($target_node);
        PVE::Storage::storage_migrate(
            $cfg, $src_volid, $sshinfo, $dst_sid,
            { target_volname => $dst_volname },
        );
        return;
    };

    return $rpcenv->fork_worker('imgcopy', undef, $authuser, $worker);
}

sub _register_reassign {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'reassign',
        path => 'reassign',
        method => 'POST',
        protected => 1,
        permissions => {
            description => 'VM.Config.Disk on both the current owning VM and the '
                . 'target VM.',
            check => [
                'and',
                ['perm', '/vms/{vmid}', ['VM.Config.Disk']],
                ['perm', '/vms/{target-vmid}', ['VM.Config.Disk']],
            ],
        },
        description => "Reassign a disk's owning VM ID (proxies PVE's own "
            . "move_disk target-vmid) for a scoped, non-root token.",
        parameters => {
            additionalProperties => 0,
            properties => {
                node => get_standard_option('pve-node'),
                vmid => get_standard_option('pve-vmid', {
                    description => 'The VM the disk currently belongs to.',
                }),
                disk => {
                    description => "The disk key to move (e.g. 'scsi0').",
                    type => 'string',
                    pattern => $RE_DISK_KEY,
                },
                'target-vmid' => get_standard_option('pve-vmid', {
                    description => 'The VM to reassign the disk to.',
                }),
                storage => get_standard_option('pve-storage-id', { optional => 1 }),
                bwlimit => {
                    description => 'Override I/O bandwidth limit (KiB/s).',
                    type => 'number',
                    optional => 1,
                    minimum => 0,
                },
            },
        },
        returns => { type => 'string' },
        code => \&_reassign_code,
    );

    return;
}

sub _reassign_code {
    my ($param) = @_;

    die "vmid and target-vmid must differ\n"
        if $param->{vmid} == $param->{'target-vmid'};

    require PVE::API2::Qemu;

    my $method;
    for my $name (@MOVE_DISK_METHOD_NAMES) {
        $method = eval { PVE::API2::Qemu->map_method_by_name($name) };
        last if $method;
    }
    die "internal: could not locate PVE::API2::Qemu's move_disk handler "
        . '(tried: ' . join(', ', @MOVE_DISK_METHOD_NAMES) . '); '
        . "PVE::API2::Qemu's API may have changed on this version - see "
        . "../README.md \"Caveats\"\n"
        if !$method;

    # Our `permissions` check above has already authorised this call; PVE's
    # own handler is invoked directly (not re-dispatched through RPCEnvironment)
    # so its declared `permissions` are not re-evaluated here - the token
    # never needed to satisfy those in the first place, only ours.
    return $method->{code}->($param);
}

1;
