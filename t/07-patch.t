#!/usr/bin/perl

use strict;
use warnings;

use lib 't/lib', 'perl';

use Test::More tests => 26;
use ProxmodTest qw(tempdir write_file capture_log repo_root);
use File::Path ();
use JSON::PP ();
use Digest::SHA ();

# Loaded at compile time as well as through use_ok, because use_ok runs at
# runtime and the package variables build_host() sets below would otherwise not
# be declared yet when this file is compiled — every one of them would draw a
# "used only once" warning.
use Proxmod::Patch ();

use_ok('Proxmod::Patch');

# The managed patch facility. Three of the subtests below are named for defects
# that exist, today, in ~/dev/pmxxpuiov — the package that motivated this
# project. They are the reason this module has the shape it has, and they are
# the tests to read first:
#
#   stale-backup-restored-over-newer-file
#   revert-on-upgrade
#   leaked-backup
#
# Everything runs against a temporary tree owned by whoever is running the
# tests, so $OWNER_UID is localised to $>. That is the only production check
# these tests relax; the group/world-writable check is left live, and is
# exercised for real below.

my $SPEC_SEQ = 0;

# The roots a real host uses, captured before any test relocates them.
my $PROD_ROOTS = [ @Proxmod::Patch::PATCH_ROOTS ];

# A host: allowed patch roots, spec directories, state file and backup dir, all
# under one temporary tree. Returns a hashref of paths plus a `spec` closure for
# dropping specs in and a `target` closure for reading files back.
sub build_host {
    my (%opt) = @_;

    my $root = tempdir();
    my $pve  = "$root/usr/share/perl5/PVE";
    my $mgr  = "$root/usr/share/pve-manager";
    File::Path::make_path($pve, $mgr, "$root/usr/share/proxmod/patches",
        "$root/etc/proxmod/patches", "$root/var/lib/proxmod");

    my $h = {
        root       => $root,
        pve        => $pve,
        mgr        => $mgr,
        pkg_specs  => "$root/usr/share/proxmod/patches",
        adm_specs  => "$root/etc/proxmod/patches",
        state      => "$root/var/lib/proxmod/patches.state",
        backups    => "$root/var/lib/proxmod/backups",
    };

    $Proxmod::Patch::STATE_FILE = $h->{state};
    $Proxmod::Patch::BACKUP_DIR = $h->{backups};
    @Proxmod::Patch::SPEC_DIRS  = ($h->{pkg_specs}, $h->{adm_specs});
    @Proxmod::Patch::PATCH_ROOTS = ($mgr, $pve, "$root/usr/share/javascript/proxmox-widget-toolkit");
    @Proxmod::Patch::NEVER      = ("$root/etc/pve");
    $Proxmod::Patch::OWNER_UID  = $>;

    return $h;
}

sub drop_spec {
    my ($h, %fields) = @_;
    my $dir = delete($fields{_dir}) || $h->{pkg_specs};
    my $name = delete($fields{_name}) || sprintf('%02d-%s.conf', ++$SPEC_SEQ, $fields{id});
    write_file("$dir/$name", JSON::PP->new->canonical->encode(\%fields));
    return "$dir/$name";
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    binmode($fh);
    local $/;
    my $c = <$fh>;
    close($fh);
    return $c;
}

# A stand-in for a Proxmox Perl module, with a line worth anchoring to.
my $STOCK = <<'PERL';
package PVE::API2::Hardware;

use strict;

__PACKAGE__->register_method({
    name => 'index',
});

1;
PERL

sub stock_spec {
    my ($h, %over) = @_;
    return (
        id       => 'demo',
        enabled  => 1,
        target   => "$h->{pve}/Demo.pm",
        anchor   => "use strict;\n",
        position => 'after',
        text     => "use PVE::API2::Demo;",
        %over,
    );
}

# ---------------------------------------------------------------------------

subtest 'everything proxmod ships is disabled' => sub {
    plan tests => 4;

    my @specs = glob(repo_root() . '/patches/*.conf');
    ok(scalar(@specs), 'the package ships at least one example spec');

    my $enabled = 0;
    for my $path (@specs) {
        my $raw = JSON::PP->new->relaxed->decode(slurp($path));
        $enabled++ if $raw->{enabled};
    }
    is($enabled, 0, 'not one of them is enabled');

    # The stronger claim, and the one that survives someone adding a spec
    # without reading this file: installing proxmod changes no Proxmox file.
    my $h = build_host();
    for my $path (@specs) {
        my $name = (split m{/}, $path)[-1];
        write_file("$h->{pkg_specs}/$name", slurp($path));
    }
    my ($out) = capture_log(sub { Proxmod::Patch::converge() });
    is_deeply($out->{results}, [], 'converging a stock install does nothing at all');

    # Disabled is not the same as unread. Every shipped spec is also checked
    # against the production allowlist, because a spec that is only ever
    # skipped is a spec whose target nobody has validated — and the first
    # person to enable one will be someone in a hurry.
    my $h2 = build_host();
    @Proxmod::Patch::PATCH_ROOTS = @{ $PROD_ROOTS };
    @Proxmod::Patch::NEVER = ('/etc/pve');
    for my $path (@specs) {
        my $name = (split m{/}, $path)[-1];
        my $raw = JSON::PP->new->relaxed->decode(slurp($path));
        write_file("$h2->{pkg_specs}/$name",
            JSON::PP->new->encode({ %$raw, enabled => 1 }));
    }
    my ($loaded, $log) = capture_log(sub { Proxmod::Patch::load_specs() });
    is(scalar(@$loaded), scalar(@specs),
        'every shipped spec is well-formed and names a patchable file')
        or diag($log);
};

subtest 'apply inserts exactly one delimited block' => sub {
    plan tests => 6;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    my %spec = stock_spec($h);
    drop_spec($h, %spec);

    my ($out) = capture_log(sub { Proxmod::Patch::converge() });
    is($out->{failed}, 0, 'no failures');
    is($out->{results}[0]{status}, 'applied', 'applied');

    my $after = slurp("$h->{pve}/Demo.pm");
    like($after, qr/proxmod:begin demo/, 'opening marker present');
    like($after, qr/proxmod:end demo/, 'closing marker present');
    like($after, qr/use strict;\n# proxmod:begin demo\nuse PVE::API2::Demo;\n/,
        'inserted immediately after the anchor, in Perl comment syntax');
    is(scalar(() = $after =~ /proxmod:begin/g), 1, 'exactly one block');
};

subtest 'apply is idempotent and does not rewrite the file' => sub {
    plan tests => 3;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    drop_spec($h, stock_spec($h));
    capture_log(sub { Proxmod::Patch::converge() });

    my $first = slurp("$h->{pve}/Demo.pm");
    my $mtime = (stat("$h->{pve}/Demo.pm"))[9];

    my ($out) = capture_log(sub { Proxmod::Patch::converge() });
    is($out->{results}[0]{status}, 'already', 'second run reports already');
    is(slurp("$h->{pve}/Demo.pm"), $first, 'byte-identical');
    is((stat("$h->{pve}/Demo.pm"))[9], $mtime,
        'not even rewritten with the same content — an apt run must not churn mtimes');
};

subtest 'revert restores the file byte for byte' => sub {
    plan tests => 3;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    drop_spec($h, stock_spec($h));
    capture_log(sub { Proxmod::Patch::converge() });
    isnt(slurp("$h->{pve}/Demo.pm"), $STOCK, 'patched');

    my ($r) = capture_log(sub { Proxmod::Patch::revert('demo') });
    is($r->{status}, 'reverted', 'reverted');
    is(slurp("$h->{pve}/Demo.pm"), $STOCK, 'exactly as it was');
};

subtest 'REGRESSION stale-backup-restored-over-newer-file' => sub {
    plan tests => 6;

    # pve-gpu-manager's backup_if_needed() skipped taking a backup when one
    # already existed. So: patch, upgrade PVE (the file is replaced), patch
    # again — and the backup still held the file from before the upgrade.
    # Reverting then wrote a pre-upgrade Proxmox file over the new one, at the
    # moment of uninstall, with nothing said about it.
    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    drop_spec($h, stock_spec($h));
    capture_log(sub { Proxmod::Patch::converge() });

    # pve-manager 9.1.2 lands and replaces the file.
    my $NEWER = $STOCK . "\n# added by a later Proxmox release\n";
    write_file("$h->{pve}/Demo.pm", $NEWER);

    my ($out) = capture_log(sub { Proxmod::Patch::converge() });
    is($out->{results}[0]{status}, 'applied', 'the trigger reapplies after the upgrade');

    # The backup must now hold the NEW pristine file, not the old one.
    my $backup = slurp("$h->{backups}/demo.bak");
    is($backup, $NEWER, 'the backup was re-taken from the upgraded file');

    my ($r) = capture_log(sub { Proxmod::Patch::revert('demo') });
    is($r->{status}, 'reverted', 'reverted');
    is(slurp("$h->{pve}/Demo.pm"), $NEWER, 'the newer Proxmox file survived intact');
    unlike(slurp("$h->{pve}/Demo.pm"), qr/proxmod/, 'and carries nothing of ours');

    # And the other half of the same defect: if the file changes without us
    # noticing at all, revert must refuse the backup outright rather than
    # restore it.
    my $h2 = build_host();
    write_file("$h2->{pve}/Demo.pm", $STOCK);
    drop_spec($h2, stock_spec($h2));
    capture_log(sub { Proxmod::Patch::converge() });

    my $patched = slurp("$h2->{pve}/Demo.pm");
    my $edited = $patched . "\n# an administrator was here\n";
    write_file("$h2->{pve}/Demo.pm", $edited);

    my ($r2, $log) = capture_log(sub { Proxmod::Patch::revert('demo') });
    is_deeply(
        [ $r2->{status}, (slurp("$h2->{pve}/Demo.pm") =~ /administrator was here/ ? 1 : 0),
          (slurp("$h2->{pve}/Demo.pm") =~ /proxmod:begin/ ? 1 : 0),
          ($log =~ /would have reinstated an older file/ ? 1 : 0) ],
        [ 'unpatched', 1, 0, 1 ],
        'our block removed surgically, their edit kept, and the reason logged'
    );
};

subtest 'REGRESSION revert-on-upgrade' => sub {
    plan tests => 4;

    # The maintainer-script half of the same story. pve-gpu-manager reverted
    # its patches from prerm on every invocation, including `upgrade`, so an
    # upgrade restored a stale file over the one dpkg had just unpacked.
    my $prerm = slurp(repo_root() . '/debian/proxmod.prerm');
    ok(defined $prerm, 'prerm exists');

    my ($remove_branch) = ($prerm =~ /remove\|deconfigure\)(.*?)\n\s+upgrade\|/s);
    my ($upgrade_branch) = ($prerm =~ /\n(\s+upgrade\|failed-upgrade\).*?)\n\s+\*\)/s);

    like($remove_branch, qr/proxmod-patch|\$PATCH.*revert-all/s,
        'remove reverts the patches');
    unlike($upgrade_branch, qr/revert|PATCH/,
        'upgrade does not — this is the defect, and it is asserted, not assumed');

    # It is not enough that prerm behaves; converge must not quietly revert on
    # its own during an upgrade either. Reapplying is right; reverting is not.
    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    drop_spec($h, stock_spec($h));
    capture_log(sub { Proxmod::Patch::converge() });
    write_file("$h->{pve}/Demo.pm", $STOCK . "# newer\n");
    capture_log(sub { Proxmod::Patch::converge() });
    like(slurp("$h->{pve}/Demo.pm"), qr/# newer/,
        'converge after an upgrade reapplies without reverting to the old file');
};

subtest 'REGRESSION leaked-backup' => sub {
    plan tests => 5;

    # pve-gpu-manager wrote its backup as Hardware.pm.pre-gpu, next to the
    # original, inside a Proxmox-owned directory — and never removed it. The
    # file outlived the package.
    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    drop_spec($h, stock_spec($h));
    capture_log(sub { Proxmod::Patch::converge() });

    my @strays = grep { !m{/Demo\.pm\z} } glob("$h->{pve}/*");
    is_deeply(\@strays, [], 'nothing was left beside the file we patched');
    ok(-f "$h->{backups}/demo.bak", 'the backup lives in proxmod\'s own state directory');

    capture_log(sub { Proxmod::Patch::revert('demo') });
    ok(!-e "$h->{backups}/demo.bak", 'and is deleted with the record that named it');
    ok(!-d $h->{backups}, 'the directory goes too once it is empty');

    my $state = JSON::PP->new->decode(slurp($h->{state}));
    is_deeply($state->{patches}, {}, 'no record left behind');
};

subtest 'purge clears backups it could not revert' => sub {
    plan tests => 2;

    # postrm's backstop, for the case where prerm could not finish. Asserted
    # against the shipped script rather than reimplemented here, because the
    # defect being guarded against was a maintainer script that did not do it.
    my $postrm = slurp(repo_root() . '/debian/proxmod.postrm');
    like($postrm, qr{rm -f /var/lib/proxmod/backups/\*\.bak},
        'purge sweeps the backup directory');
    # Comment lines stripped first: the header explains the rule by naming the
    # thing it forbids, and matching that would make the test pass or fail on
    # the prose rather than on the code.
    my $code = join("\n", grep { !/^\s*#/ } split(/\n/, $postrm));
    unlike($code, qr{rm -rf}, 'and never with rm -rf');
};

subtest 'the anchor must appear exactly once' => sub {
    plan tests => 4;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", "use strict;\nuse strict;\n");
    drop_spec($h, stock_spec($h));

    my ($out, $log) = capture_log(sub { Proxmod::Patch::converge() });
    is($out->{results}[0]{status}, 'error', 'ambiguous anchor is refused');
    like($out->{results}[0]{message}, qr/more than once/, 'and says why');
    unlike(slurp("$h->{pve}/Demo.pm"), qr/proxmod/, 'the file is untouched');

    # And the far more common case after an upgrade: the anchor is gone.
    write_file("$h->{pve}/Demo.pm", "# a completely rewritten module\n");
    my ($out2) = capture_log(sub { Proxmod::Patch::converge() });
    like($out2->{results}[0]{message}, qr/almost certainly changed/,
        'a missing anchor is reported as "the file changed", which is what it means');
};

subtest 'a target outside the allowed roots is refused' => sub {
    plan tests => 3;

    my $h = build_host();
    write_file("$h->{root}/etc/shadow", "root:x:\n");
    my ($specs, $log) = capture_log(sub {
        drop_spec($h, stock_spec($h, id => 'escape', target => "$h->{root}/etc/shadow"));
        return Proxmod::Patch::load_specs();
    });
    is_deeply($specs, [], 'the spec is rejected at parse time');
    like($log, qr/outside every directory proxmod is allowed to patch/, 'and says why');
    is(slurp("$h->{root}/etc/shadow"), "root:x:\n", 'the file is untouched');
};

subtest '/etc/pve is refused even if someone widens the allowlist' => sub {
    plan tests => 2;

    my $h = build_host();
    # The mistake this guards against: an edit that adds /etc/pve, or a parent
    # of it, to @PATCH_ROOTS. /etc/pve is pmxcfs — a FUSE mount of replicated
    # cluster state that is not mounted early at boot and is unmounted during
    # parts of an upgrade. Writing to it from a trigger is how a cluster
    # database gets corrupted.
    push @Proxmod::Patch::PATCH_ROOTS, "$h->{root}/etc";
    File::Path::make_path("$h->{root}/etc/pve");
    write_file("$h->{root}/etc/pve/datacenter.cfg", "keyboard: en-us\n");

    my ($specs, $log) = capture_log(sub {
        drop_spec($h, stock_spec($h, id => 'cluster',
            target => "$h->{root}/etc/pve/datacenter.cfg",
            anchor => "keyboard: en-us\n", comment => 'perl'));
        return Proxmod::Patch::load_specs();
    });
    is_deeply($specs, [], 'still refused');
    like($log, qr/cluster filesystem, not program code/, 'for the right reason');
};

subtest 'path traversal and symlinks are refused' => sub {
    plan tests => 3;

    my $h = build_host();
    my ($specs, $log) = capture_log(sub {
        drop_spec($h, stock_spec($h, id => 'traverse',
            target => "$h->{pve}/../../../../etc/passwd"));
        return Proxmod::Patch::load_specs();
    });
    is_deeply($specs, [], "'..' in a target is refused");

    SKIP: {
        skip 'no symlink support', 2 if !eval { symlink('', ''); 1 };

        my $h2 = build_host();
        write_file("$h2->{root}/elsewhere", "secret\n");
        symlink("$h2->{root}/elsewhere", "$h2->{pve}/Demo.pm")
            or skip 'cannot create symlink', 2;
        drop_spec($h2, stock_spec($h2));

        my ($out) = capture_log(sub { Proxmod::Patch::converge() });
        like($out->{results}[0]{message}, qr/symlink/,
            'a symlinked target is refused — following it would bypass the allowlist');
        is(slurp("$h2->{root}/elsewhere"), "secret\n", 'the destination is untouched');
    }
};

subtest 'a writable target is refused' => sub {
    plan tests => 2;

    # This check is not relaxed for the tests. A file that pvedaemon compiles
    # as root and that a non-root user can rewrite is a root escalation with or
    # without proxmod; patching it would make proxmod part of the problem.
    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    chmod(0666, "$h->{pve}/Demo.pm");
    drop_spec($h, stock_spec($h));

    my ($out) = capture_log(sub { Proxmod::Patch::converge() });
    like($out->{results}[0]{message}, qr/group- or world-writable/, 'refused');
    is(slurp("$h->{pve}/Demo.pm"), $STOCK, 'untouched');
};

subtest 'enabled must be set explicitly' => sub {
    plan tests => 3;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    my %spec = stock_spec($h);
    delete $spec{enabled};
    drop_spec($h, %spec);

    my $specs = Proxmod::Patch::load_specs();
    is(scalar(@$specs), 1, 'the spec loads');
    is($specs->[0]{enabled}, 0, 'but omitting enabled means disabled, not enabled');

    my ($out) = capture_log(sub { Proxmod::Patch::converge() });
    is(slurp("$h->{pve}/Demo.pm"), $STOCK, 'so nothing is patched');
};

subtest 'disabling a spec undoes the patch' => sub {
    plan tests => 3;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    my $path = drop_spec($h, stock_spec($h));
    capture_log(sub { Proxmod::Patch::converge() });
    like(slurp("$h->{pve}/Demo.pm"), qr/proxmod:begin/, 'patched');

    write_file($path, JSON::PP->new->encode({ stock_spec($h), enabled => 0 }));
    my ($out) = capture_log(sub { Proxmod::Patch::converge() });
    is($out->{results}[0]{status}, 'reverted', 'converge notices and reverts');
    is(slurp("$h->{pve}/Demo.pm"), $STOCK, 'stock again');
};

subtest 'deleting a spec entirely undoes the patch' => sub {
    plan tests => 2;

    # An extension package that shipped a spec gets removed. The spec file
    # disappears, and the edit it described must not outlive it.
    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    my $path = drop_spec($h, stock_spec($h));
    capture_log(sub { Proxmod::Patch::converge() });

    unlink($path);
    my ($out) = capture_log(sub { Proxmod::Patch::converge() });
    is($out->{results}[0]{status}, 'reverted', 'reverted');
    is(slurp("$h->{pve}/Demo.pm"), $STOCK, 'stock again');
};

subtest 'the /etc overlay masks a packaged spec' => sub {
    plan tests => 2;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    drop_spec($h, stock_spec($h), _name => '50-demo.conf');
    write_file("$h->{adm_specs}/50-demo.conf", '');

    my $specs = Proxmod::Patch::load_specs();
    is_deeply($specs, [], 'an empty file at the same basename masks it');

    capture_log(sub { Proxmod::Patch::converge() });
    is(slurp("$h->{pve}/Demo.pm"), $STOCK, 'and nothing is patched');
};

subtest 'two patches to one file are independent' => sub {
    plan tests => 4;

    # The pmxxpuiov race: two packages both sed-ing index.html.tpl, neither
    # aware of the other. Markers naming the patch id make each block findable
    # and removable on its own.
    my $h = build_host();
    write_file("$h->{mgr}/index.html.tpl", "<head>\n<body>\n");
    drop_spec($h, id => 'one', enabled => 1, target => "$h->{mgr}/index.html.tpl",
        anchor => "<head>\n", position => 'after', text => '<!-- one -->');
    drop_spec($h, id => 'two', enabled => 1, target => "$h->{mgr}/index.html.tpl",
        anchor => "<body>\n", position => 'after', text => '<!-- two -->');

    capture_log(sub { Proxmod::Patch::converge() });
    my $both = slurp("$h->{mgr}/index.html.tpl");
    like($both, qr/proxmod:begin one/, 'first applied');
    like($both, qr/proxmod:begin two/, 'second applied');

    capture_log(sub { Proxmod::Patch::revert('one') });
    my $left = slurp("$h->{mgr}/index.html.tpl");
    unlike($left, qr/proxmod:begin one/, 'removing one takes only its own block');
    like($left, qr/proxmod:begin two/, 'the other package\'s patch is untouched');
};

subtest 'position before and replace' => sub {
    plan tests => 4;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    drop_spec($h, stock_spec($h, id => 'pre', position => 'before'));
    capture_log(sub { Proxmod::Patch::converge() });
    like(slurp("$h->{pve}/Demo.pm"), qr/proxmod:end pre\nuse strict;/,
        'before puts the block ahead of the anchor');

    my $h2 = build_host();
    write_file("$h2->{pve}/Demo.pm", $STOCK);
    drop_spec($h2, stock_spec($h2, id => 'rep', position => 'replace',
        text => 'use warnings;'));
    capture_log(sub { Proxmod::Patch::converge() });
    my $after = slurp("$h2->{pve}/Demo.pm");
    unlike($after, qr/use strict;/, 'replace consumed the anchor');
    like($after, qr/use warnings;/, 'and left the replacement');

    # Reverting a `replace` has to put the anchor back, which is why the state
    # database records it alongside the hashes.
    write_file("$h2->{pve}/Demo.pm", $after . "# changed elsewhere\n");
    capture_log(sub { Proxmod::Patch::revert('rep') });
    like(slurp("$h2->{pve}/Demo.pm"), qr/use strict;.*# changed elsewhere/s,
        'a surgical un-patch restores the anchor it replaced');
};

subtest 'an unknown comment style is a rejected spec, not a guess' => sub {
    plan tests => 2;

    my $h = build_host();
    write_file("$h->{mgr}/something.cfg", "a\n");
    my ($specs, $log) = capture_log(sub {
        drop_spec($h, stock_spec($h, id => 'odd',
            target => "$h->{mgr}/something.cfg", anchor => "a\n"));
        return Proxmod::Patch::load_specs();
    });
    is_deeply($specs, [], 'rejected');
    like($log, qr/cannot tell what a comment looks like/,
        'guessing would corrupt the file the next time something parsed it');
};

subtest 'a malformed spec never costs the others' => sub {
    plan tests => 3;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    write_file("$h->{pkg_specs}/10-broken.conf", '{ this is not json');
    drop_spec($h, stock_spec($h), _name => '20-demo.conf');

    my ($out, $log) = capture_log(sub { Proxmod::Patch::converge() });
    like($log, qr/patch spec invalid, ignoring/, 'the broken one is reported');
    is($out->{failed}, 0, 'and is not counted as a patch failure');
    like(slurp("$h->{pve}/Demo.pm"), qr/proxmod:begin demo/, 'the good one applied');
};

subtest 'writes are atomic and preserve the mode' => sub {
    plan tests => 3;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    chmod(0640, "$h->{pve}/Demo.pm");
    drop_spec($h, stock_spec($h));
    capture_log(sub { Proxmod::Patch::converge() });

    is((stat("$h->{pve}/Demo.pm"))[2] & 07777, 0640, 'mode preserved');
    my @tmp = grep { /proxmod-tmp/ } glob("$h->{pve}/*");
    is_deeply(\@tmp, [], 'no temporary file left behind');

    # The backup holds the original and nothing else can read it: it is a
    # verbatim copy of a file from another package, taken so it can be put
    # back, not published.
    is((stat("$h->{backups}/demo.bak"))[2] & 07777, 0600, 'the backup is 0600');
};

subtest 'status reports drift, orphans and unapplied specs' => sub {
    plan tests => 4;

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    drop_spec($h, stock_spec($h));

    my $before = Proxmod::Patch::status();
    is_deeply([ $before->[0]{enabled}, $before->[0]{applied} ], [ 1, 0 ],
        'enabled but not yet applied');

    capture_log(sub { Proxmod::Patch::converge() });
    my $after = Proxmod::Patch::status();
    is_deeply([ $after->[0]{enabled}, $after->[0]{applied}, $after->[0]{drifted} ],
        [ 1, 1, 0 ], 'applied and clean');

    write_file("$h->{pve}/Demo.pm", slurp("$h->{pve}/Demo.pm") . "# later\n");
    is(Proxmod::Patch::status()->[0]{drifted}, 1, 'drift is visible');

    # A record whose spec has vanished is the state an administrator most needs
    # told about: the host still carries an edit and nothing describes it.
    unlink(glob("$h->{pkg_specs}/*.conf"));
    my $orphan = Proxmod::Patch::status();
    is_deeply([ $orphan->[0]{id}, $orphan->[0]{orphaned} ], [ 'demo', 1 ],
        'orphaned patches are reported');
};

subtest 'nothing in Proxmod::Boot loads the patch engine' => sub {
    plan tests => 2;

    # Patching runs from a dpkg trigger, as root, with nothing else happening.
    # It must never run inside pvedaemon: a daemon starting up is the worst
    # possible moment to rewrite a file another process may be reading, and a
    # patch failure there would be a failure in the daemon's startup path.
    my $boot = slurp(repo_root() . '/perl/Proxmod/Boot.pm');
    unlike($boot, qr/Proxmod::Patch/, 'Boot does not mention it');

    my @loaders = grep { !m{/Patch\.pm\z} }
        glob(repo_root() . '/perl/Proxmod/*.pm'), repo_root() . '/perl/Proxmod.pm';
    my @refs = grep { (slurp($_) // '') =~ /Proxmod::Patch/ } @loaders;
    is_deeply(\@refs, [], 'and neither does anything else that runs in a daemon');
};

subtest 'the CLI, and the one line proxmod-reapply parses' => sub {
    plan tests => 6;

    # exec/proxmod-patch is what actually runs on a host, and proxmod-reapply
    # decides whether to restart the hypervisor's daemons by reading one line
    # of its output. t/09 stubs that line; this asserts the real program emits
    # it, so the two tests cannot agree with each other and both be wrong.
    my $cli = repo_root() . '/exec/proxmod-patch';
    ok(-x $cli, 'proxmod-patch is executable');

    my $h = build_host();
    write_file("$h->{pve}/Demo.pm", $STOCK);
    drop_spec($h, stock_spec($h));

    my $run = sub {
        local $ENV{PROXMOD_TEST_PREFIX} = $h->{root};
        local $ENV{PERL5LIB} = repo_root() . '/perl';
        my $out = `$cli @_ 2>&1`;
        return ($? >> 8, $out);
    };

    my ($rc, $out) = $run->('converge');
    is($rc, 0, 'converge exits 0');
    like($out, qr/^proxmod-patch: changed=1 failed=0$/m,
        'and reports that a file changed, in the shape reapply greps for');

    (undef, $out) = $run->('converge');
    like($out, qr/^proxmod-patch: changed=0 failed=0$/m,
        'a second run reports no change, which is what keeps apt runs quiet');

    ($rc, $out) = $run->('revert-all');
    is($rc, 0, 'revert-all exits 0');
    is(slurp("$h->{pve}/Demo.pm"), $STOCK, 'and the host is stock again');
};
