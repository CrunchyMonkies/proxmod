#!/usr/bin/perl
use strict;
use warnings;

use lib 't/lib';
use Test::More tests => 26;
use ProxmodTest qw(tempdir write_file repo_root);
use File::Path ();

# exec/proxmod-reapply is the only thing in proxmod that decides when the
# Proxmox daemons get restarted. That makes it the script with the most
# opportunity to be annoying (restarting on every apt run) and the most
# opportunity to be dangerous (leaving a daemon down), so nearly everything
# below asserts on one of those two.
#
# The whole script is driven against a temporary tree via PROXMOD_TEST_PREFIX,
# with a recording `systemctl` stub first on PATH. Every systemctl call the
# script would have made ends up in a log file, so the tests can assert on the
# ABSENCE of a call — which is the interesting half.

my $REAPPLY = repo_root() . '/exec/proxmod-reapply';
ok(-x $REAPPLY, 'exec/proxmod-reapply exists and is executable');

umask 022;

my $SRC = 'usr/share/proxmod/systemd';
my $DST = 'etc/systemd/system';
my @UNITS = qw(pvedaemon.service pveproxy.service);

# A healthy installation: the package-owned drop-ins are present, nothing has
# been converged yet.
sub build_tree {
    my (%opt) = @_;
    my $p = tempdir();

    File::Path::make_path("$p/$DST", "$p/etc/proxmod/extensions.d",
        "$p/var/lib/proxmod", "$p/usr/sbin", "$p/bin");

    my @units = @{ $opt{units} || \@UNITS };
    for my $u (@units) {
        write_file("$p/$SRC/$u.d/10-proxmod.conf",
            "[Service]\nExecStart=\nExecStart=/usr/lib/proxmod/proxmod-exec $u\n");
    }

    # The systemctl stub. `is-active` is what the script uses to decide whether
    # a daemon came back, so it is the knob the self-heal tests turn.
    my $state = $opt{is_active} || 'active';
    write_file("$p/bin/systemctl", <<"EOF");
#!/bin/sh
echo "\$*" >> "$p/systemctl.log"
case "\$1" in is-active) echo '$state' ;; esac
exit 0
EOF
    chmod 0755, "$p/bin/systemctl" or die "chmod: $!";

    # proxmod-verify does not exist yet in the build; when a test wants one it
    # asks for a stub with a fixed exit status.
    if (defined $opt{verify_rc}) {
        write_file("$p/usr/sbin/proxmod-verify", "#!/bin/sh\nexit $opt{verify_rc}\n");
        chmod 0755, "$p/usr/sbin/proxmod-verify" or die "chmod: $!";
    }

    # The managed patch facility, when a test wants one. It is a stub because
    # what is under test here is the contract between the two programs — the
    # one summary line reapply parses, and what it does with it — not the
    # engine, which t/07 covers.
    if (defined $opt{patch}) {
        File::Path::make_path("$p/usr/lib/proxmod");
        my ($changed, $failed, $rc) = @{ $opt{patch} };
        write_file("$p/usr/lib/proxmod/proxmod-patch",
            "#!/bin/sh\necho 'proxmod-patch: changed=$changed failed=$failed'\nexit $rc\n");
        chmod 0755, "$p/usr/lib/proxmod/proxmod-patch" or die "chmod: $!";
    }

    write_file("$p/systemctl.log", '');
    return $p;
}

# Returns ($rc, $stderr, \@systemctl_calls). The script logs everything to
# stderr, which is where the journal would get it.
sub reapply {
    my ($p, @args) = @_;

    write_file("$p/systemctl.log", '');
    my $err = "$p/stderr.$$";

    local $ENV{PROXMOD_TEST_PREFIX} = $p;
    local $ENV{PATH} = "$p/bin:$ENV{PATH}";

    my $rc = system("$REAPPLY " . join(' ', @args) . " 2>$err");
    $rc = $rc == -1 ? -1 : $rc >> 8;

    return ($rc, slurp($err), [ grep { length } split(/\n/, slurp("$p/systemctl.log")) ]);
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return '';
    local $/;
    my $c = <$fh>;
    close($fh);
    return defined $c ? $c : '';
}

sub dropin { my ($p, $u) = @_; return "$p/$DST/$u.d/10-proxmod.conf" }

subtest 'a fresh host is converged and the daemons restarted once' => sub {
    plan tests => 6;
    my $p = build_tree();

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 0, 'exits 0');
    ok(-f dropin($p, 'pvedaemon.service'), 'the pvedaemon drop-in is installed');
    ok(-f dropin($p, 'pveproxy.service'),  'the pveproxy drop-in is installed');

    is(scalar(grep { $_ eq 'daemon-reload' } @$calls), 1, 'daemon-reload exactly once');
    is_deeply(
        [ sort grep { /^try-restart/ } @$calls ],
        [ 'try-restart pvedaemon.service', 'try-restart pveproxy.service' ],
        'each wrapped unit is try-restarted',
    );
    like($err, qr{converged}, 'and it says so');
};

subtest 'a second run does nothing at all' => sub {
    plan tests => 3;
    # This is the anti-pattern the prior art shipped: an APT hook that
    # restarted pveproxy on every apt invocation, whether or not anything
    # relevant had changed. An empty call list is the assertion that matters
    # here — not even a daemon-reload.
    my $p = build_tree();
    reapply($p);

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 0, 'exits 0');
    is_deeply($calls, [], 'not one systemctl call');
    like($err, qr{already converged}, 'and it explains why it did nothing');
};

subtest 'a drop-in edited by hand is put back' => sub {
    plan tests => 3;
    my $p = build_tree();
    reapply($p);
    write_file(dropin($p, 'pveproxy.service'), "[Service]\nExecStart=/bin/false\n");

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 0, 'exits 0');
    like(slurp(dropin($p, 'pveproxy.service')), qr{proxmod-exec}, 'the drop-in is restored');
    ok(scalar(grep { $_ eq 'daemon-reload' } @$calls), 'and systemd is told');
};

subtest 'a drop-in for a unit we no longer wrap is removed' => sub {
    plan tests => 4;
    # The convergence direction that is easy to forget. If a future proxmod
    # stops wrapping pvedaemon, the old drop-in must go, or pvedaemon keeps
    # running through a wrapper nobody maintains any more.
    my $p = build_tree(units => ['pveproxy.service']);
    write_file(dropin($p, 'pvedaemon.service'), "[Service]\nExecStart=/bin/true\n");

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 0, 'exits 0');
    ok(!-e dropin($p, 'pvedaemon.service'), 'the stale drop-in is gone');
    ok(-f dropin($p, 'pveproxy.service'), 'the current one is installed');
    like($err, qr{removed}, 'the removal is reported');
};

subtest 'only proxmod files are touched' => sub {
    plan tests => 3;
    # Another framework's drop-in lives in the same directory. pve-token-copy
    # is the concrete case: it wraps ExecStart the same way we do. Removing it
    # would be exactly the collateral damage this project argues against.
    my $p = build_tree();
    reapply($p);
    my $foreign = "$p/$DST/pveproxy.service.d/20-someone-else.conf";
    write_file($foreign, "[Service]\nEnvironment=X=1\n");

    my ($rc) = reapply($p, '--remove');
    is($rc, 0, 'exits 0');
    ok(!-e dropin($p, 'pveproxy.service'), 'ours is removed');
    ok(-f $foreign, "the other package's drop-in survives");
};

subtest 'the drop-in directory is only removed if we emptied it' => sub {
    plan tests => 2;
    my $p = build_tree();
    reapply($p);
    reapply($p, '--remove');
    ok(!-d "$p/$DST/pveproxy.service.d", 'an empty directory is pruned');

    my $q = build_tree();
    reapply($q);
    write_file("$q/$DST/pveproxy.service.d/20-someone-else.conf", "[Service]\n");
    reapply($q, '--remove');
    ok(-d "$q/$DST/pveproxy.service.d", '...but not one someone else is using');
};

subtest '--remove converges to a stock host' => sub {
    plan tests => 4;
    my $p = build_tree();
    reapply($p);

    my ($rc, $err, $calls) = reapply($p, '--remove');
    is($rc, 0, 'exits 0');
    ok(!-e dropin($p, 'pvedaemon.service'), 'the drop-ins are gone');
    ok(scalar(grep { $_ eq 'daemon-reload' } @$calls), 'systemd is reloaded');
    is(scalar(grep { /^try-restart/ } @$calls), 2, 'both daemons are restarted stock');
};

subtest '--remove on a host that never had them does nothing' => sub {
    plan tests => 3;
    my $p = build_tree();

    my ($rc, $err, $calls) = reapply($p, '--remove');
    is($rc, 0, 'exits 0');
    is_deeply($calls, [], 'no systemctl call');
    like($err, qr{nothing to do}, 'and says so');
};

subtest 'the PVE installer is left alone' => sub {
    plan tests => 4;
    # /proxmox_install_mode exists while the Proxmox installer is building the
    # system. pve-manager's own postinst has the same guard [PVE-F-005].
    # Restarting a daemon in the middle of that is at best pointless.
    my $p = build_tree();
    write_file("$p/proxmox_install_mode", '');

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 0, 'exits 0');
    is_deeply($calls, [], 'no systemctl call');
    ok(!-e dropin($p, 'pveproxy.service'), 'not even the drop-ins are installed');
    like($err, qr{installer is running}, 'and it says why');
};

subtest 'the kill switch converges but never restarts' => sub {
    plan tests => 4;
    # /etc/proxmod/disabled is honoured by proxmod-exec at start time, so the
    # drop-ins stay correct — they simply pass the daemon through unmodified.
    # What reapply must not do is chase the resulting "not loaded" verdict with
    # a restart, forever.
    my $p = build_tree(verify_rc => 1);
    write_file("$p/etc/proxmod/disabled", '');

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 0, 'exits 0');
    ok(-f dropin($p, 'pveproxy.service'), 'the drop-ins are still converged');
    is_deeply([ grep { /restart/ } @$calls ], [], 'nothing is restarted');
    like($err, qr{disabled by}, 'and it names the switch');
};

subtest 'a live daemon that is not loading proxmod is restarted' => sub {
    plan tests => 2;
    # The case that needs proxmod-verify: nothing on disk changed, but the
    # RUNNING daemon does not have proxmod in it. That happens after a plain
    # `systemctl reload`, or after anything that re-execs the daemon from its
    # original argv.
    my $p = build_tree(verify_rc => 1);
    reapply($p);

    my ($rc, $err, $calls) = reapply($p);
    is(scalar(grep { /^try-restart/ } @$calls), 2, 'both daemons are restarted');
    like($err, qr{not loading proxmod}, 'and the reason is in the journal');
};

subtest 'a healthy live daemon is left running' => sub {
    plan tests => 2;
    my $p = build_tree(verify_rc => 0);
    reapply($p);

    my ($rc, $err, $calls) = reapply($p);
    is_deeply($calls, [], 'no systemctl call');
    like($err, qr{already converged}, 'nothing to do');
};

subtest 'a missing proxmod-verify is not treated as a failure' => sub {
    plan tests => 1;
    # If we cannot check, we must not restart. The alternative is restarting
    # the daemons on every trigger on the strength of a check we did not run.
    my $p = build_tree();          # no verify stub at all
    reapply($p);

    my (undef, undef, $calls) = reapply($p);
    is_deeply($calls, [], 'no systemctl call');
};

subtest '--force restarts a converged host' => sub {
    plan tests => 3;
    my $p = build_tree(verify_rc => 0);
    reapply($p);

    my ($rc, $err, $calls) = reapply($p, '--force');
    is($rc, 0, 'exits 0');
    is(scalar(grep { /^try-restart/ } @$calls), 2, 'both daemons are restarted');
    is(scalar(grep { $_ eq 'daemon-reload' } @$calls), 0, 'but systemd is not reloaded for nothing');
};

subtest 'a daemon that does not come back leaves a stock host' => sub {
    plan tests => 6;
    # The prime directive, as a test. A missing extension is acceptable; a dead
    # pveproxy is not. If the daemon will not start with proxmod in it, proxmod
    # takes itself out of the way and starts it without.
    my $p = build_tree(is_active => 'failed');

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 1, 'exits non-zero, so the administrator hears about it');
    ok(!-e dropin($p, 'pveproxy.service'),  'the pveproxy drop-in is removed');
    ok(!-e dropin($p, 'pvedaemon.service'), 'the pvedaemon drop-in is removed');
    is(scalar(grep { $_ eq 'daemon-reload' } @$calls), 2, 'systemd is reloaded again after unwrapping');
    is(scalar(grep { /^restart / } @$calls), 2, 'and both daemons are started stock, not try-restarted');
    like($err, qr{proxmod is now inert}, 'the journal says what happened and how to undo it');
};

subtest 'an inactive daemon is not mistaken for a broken one' => sub {
    plan tests => 2;
    # try-restart on a stopped unit correctly leaves it stopped. Treating that
    # as a failure would make the self-heal fire on any host where an
    # administrator has deliberately stopped pveproxy.
    my $p = build_tree(is_active => 'inactive');

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 0, 'exits 0');
    ok(-f dropin($p, 'pveproxy.service'), 'the drop-in stays');
};

subtest '--trigger never wedges dpkg' => sub {
    plan tests => 2;
    # A non-zero exit from a dpkg trigger leaves proxmod half-configured and
    # can stop an entire `apt dist-upgrade`, including security updates for
    # packages that have nothing to do with us.
    my $p = build_tree(is_active => 'failed');

    my ($rc, $err) = reapply($p, '--trigger');
    is($rc, 0, 'exits 0 even though convergence failed');
    like($err, qr{must not wedge dpkg}, 'and is explicit that it is swallowing a failure');
};

subtest 'without --trigger the same failure is reported' => sub {
    plan tests => 1;
    my $p = build_tree(is_active => 'failed');
    my ($rc) = reapply($p);
    is($rc, 1, 'exits non-zero');
};

subtest 'nothing under /etc/pve is ever touched' => sub {
    # pmxcfs is a FUSE filesystem. It is not mounted early at boot and is
    # routinely unmounted during upgrades — which is exactly when this script
    # runs. A read of /etc/pve at the wrong moment hangs the trigger.
    #
    # The same reasoning covers the maintainer scripts and the boot-time unit:
    # every one of them runs at a moment when pmxcfs may be gone, and none of
    # them has any business reading the cluster's authentication material.
    my @files = grep { -e $_ } map { repo_root() . "/$_" } (
        'exec/proxmod-reapply',
        'debian/proxmod.postinst',
        'debian/proxmod.prerm',
        'debian/proxmod.postrm',
        'systemd/proxmod-verify.service',
    );
    plan tests => scalar(@files) + 2;

    for my $file (@files) {
        my ($name) = $file =~ m{([^/]+)\z};
        unlike(slurp($file), qr{/etc/pve/}, "$name contains no path under /etc/pve");
    }
    is(scalar(@files), 5, 'and all five were actually found to check');

    my $p = build_tree();
    reapply($p);
    ok(!-e "$p/etc/pve", 'a converge run creates nothing there');
};

subtest 'the drop-in is written with sane permissions' => sub {
    plan tests => 2;
    my $p = build_tree();
    reapply($p);
    my $mode = (stat dropin($p, 'pveproxy.service'))[2] & 07777;
    is($mode, 0644, 'mode 0644');
    is_deeply([ glob("$p/$DST/pveproxy.service.d/*proxmod-tmp*") ], [],
        'and no temporary file is left behind');
};

subtest 'an unknown argument is refused rather than guessed at' => sub {
    plan tests => 3;
    my $p = build_tree();
    my ($rc, $err, $calls) = reapply($p, '--restart-everything');
    is($rc, 64, 'exits 64');
    is_deeply($calls, [], 'and does nothing');
    like($err, qr{unknown argument}, 'saying what it did not understand');
};

subtest 'a package with no drop-ins to install says so' => sub {
    plan tests => 3;
    # A truncated or half-unpacked installation. Silently doing nothing here
    # would look identical to a healthy no-op run.
    my $p = build_tree(units => []);

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 0, 'exits 0');
    is_deeply($calls, [], 'no systemctl call');
    like($err, qr{proxmod will not load}, 'but the journal is not silent about it');
};

subtest 'a managed patch that changed a file causes a restart' => sub {
    plan tests => 2;
    # The files a patch edits are Perl modules compiled at daemon start. A
    # patch applied by a dpkg trigger that nothing restarts afterwards is a
    # patch that appears to have worked and has not.
    my $p = build_tree(verify_rc => 0, patch => [ 1, 0, 0 ]);
    reapply($p);                      # first run converges the drop-ins

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 0, 'exits 0');
    ok(scalar(grep { /try-restart/ } @$calls),
        'the daemons are restarted even though the drop-ins did not change');
};

subtest 'a patch facility with nothing to do restarts nothing' => sub {
    plan tests => 2;
    # The default state of every host: specs present, none enabled. This must
    # be indistinguishable from proxmod having no patch facility at all.
    my $p = build_tree(verify_rc => 0, patch => [ 0, 0, 0 ]);
    reapply($p);

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 0, 'exits 0');
    is_deeply($calls, [], 'not one systemctl call');
};

subtest 'a failing patch never tears out the drop-ins' => sub {
    plan tests => 4;
    # The escape hatch must not be able to take the framework down with it. A
    # malformed spec is reported and nothing else: the drop-ins stay, the
    # daemons stay, and proxmod keeps loading.
    my $p = build_tree(verify_rc => 0, patch => [ 0, 1, 1 ]);
    reapply($p);

    my ($rc, $err, $calls) = reapply($p);
    is($rc, 1, 'the failure is visible in the exit status');
    ok(-f "$p/$DST/pveproxy.service.d/10-proxmod.conf", 'the drop-in is still there');
    is_deeply($calls, [], 'and nothing was restarted over it');
    like($err, qr{proxmod itself is unaffected}, 'the journal says which half broke');
};
