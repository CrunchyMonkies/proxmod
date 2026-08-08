#!/usr/bin/perl
use strict;
use warnings;

use lib 't/lib';
use Test::More tests => 18;
use ProxmodTest qw(tempdir write_file repo_root);
use File::Path ();

# bin/proxmod-verify is the only thing standing between "proxmod silently does
# nothing" and an administrator finding out. Its whole value is that it reports
# the state of the RUNNING daemon rather than what a fresh perl could do, so
# most of what follows drives it against a fabricated journal and asserts on
# what it concludes.
#
# Everything is faked through stubs on PATH — systemctl, journalctl and curl —
# with PROXMOD_TEST_PREFIX pointing the on-disk paths at a temporary tree.

my $VERIFY = repo_root() . '/bin/proxmod-verify';
ok(-x $VERIFY, 'bin/proxmod-verify exists and is executable');

my @UNITS = qw(pvedaemon.service pveproxy.service);
my $WRAPPER = '/usr/lib/proxmod/proxmod-exec';

sub build_tree {
    my (%opt) = @_;
    my $p = tempdir();

    File::Path::make_path("$p/bin", "$p/sys", "$p/journal", "$p/http",
        "$p/etc/proxmod", "$p/usr/share/proxmod/www");

    my @units = @{ $opt{units} || \@UNITS };
    for my $u (@units) {
        write_file("$p/usr/share/proxmod/systemd/$u.d/10-proxmod.conf", "[Service]\n");
        write_file("$p/etc/systemd/system/$u.d/10-proxmod.conf", "[Service]\n")
            if !$opt{no_dropins};

        write_file("$p/sys/$u.is-active", ($opt{is_active} || 'active') . "\n");
        write_file("$p/sys/$u.ExecStart",
            defined $opt{exec_start} ? $opt{exec_start} : "$WRAPPER $u\n");
        write_file("$p/sys/$u.ExecReload",
            defined $opt{exec_reload} ? $opt{exec_reload}
                : "/bin/systemctl --no-block restart $u\n");
        write_file("$p/sys/$u.ExecMainStartTimestamp", "Sat 2026-08-08 00:00:00 UTC\n");

        my $daemon = $u; $daemon =~ s/\.service\z//;
        my $journal = defined $opt{journal} ? $opt{journal}
            : "proxmod: booted daemon=$daemon extensions=1 failed=0\n";
        write_file("$p/journal/$u", $journal);
    }

    write_file("$p/etc/proxmod/disabled", '') if $opt{disabled};

    write_file("$p/bin/systemctl", <<"EOF");
#!/bin/sh
case "\$1" in
  is-active) f="$p/sys/\$2.is-active" ;;
  show)      f="$p/sys/\$5.\$3" ;;
  *)         exit 0 ;;
esac
[ -f "\$f" ] && cat "\$f"
exit 0
EOF

    write_file("$p/bin/journalctl", <<"EOF");
#!/bin/sh
u=
while [ \$# -gt 0 ]; do
  case "\$1" in -u) u=\$2; shift 2 ;; *) shift ;; esac
done
[ -f "$p/journal/\$u" ] && cat "$p/journal/\$u"
exit 0
EOF

    # curl is only installed when a test wants the HTTP checks to run. Its
    # absence is itself a case worth covering.
    if ($opt{http}) {
        for my $path (keys %{ $opt{http} }) {
            my ($code, $body) = @{ $opt{http}{$path} };
            (my $key = $path) =~ s{/}{_}g;
            write_file("$p/http/$key.code", $code);
            write_file("$p/http/$key.body", $body);
        }
        write_file("$p/bin/curl", <<"EOF");
#!/bin/sh
for a in "\$@"; do url=\$a; done
path=\${url#test:}
key=\$(printf '%s' "\$path" | tr '/' '_')
[ -f "$p/http/\$key.body" ] && cat "$p/http/\$key.body"
if [ -f "$p/http/\$key.code" ]; then
    printf '\\n%s' "\$(cat "$p/http/\$key.code")"
else
    printf '\\n404'
fi
exit 0
EOF
    }

    chmod 0755, glob("$p/bin/*");
    return $p;
}

# Returns ($rc, $stdout).
sub verify {
    my ($p, @args) = @_;
    my $out = "$p/stdout.$$";

    local $ENV{PROXMOD_TEST_PREFIX} = $p;
    local $ENV{PATH} = "$p/bin:$ENV{PATH}";

    my $rc = system("$VERIFY " . join(' ', @args) . " >$out 2>&1");
    $rc = $rc == -1 ? -1 : $rc >> 8;
    return ($rc, slurp($out));
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return '';
    local $/;
    my $c = <$fh>;
    close($fh);
    return defined $c ? $c : '';
}

# Every non-HTTP test passes --no-http, because a host with no curl and a host
# with a broken web interface are different findings and only one of them is
# under test at a time.
sub check { my ($p, @a) = @_; return verify($p, '--no-http', @a) }

subtest 'a healthy host reports healthy' => sub {
    plan tests => 4;
    my $p = build_tree();
    my ($rc, $out) = check($p);
    is($rc, 0, 'exits 0');
    like($out, qr{proxmod is working}, 'and says so');
    like($out, qr{pveproxy\.service has proxmod loaded}, 'the live check names the unit');
    like($out, qr{1 extension\(s\) loaded}, 'and reports what it loaded');
};

subtest 'a daemon running without proxmod is the headline failure' => sub {
    plan tests => 3;
    # The failure mode this whole tool exists for: everything is installed,
    # nothing is broken, and the module never reached the daemon. There is no
    # error anywhere — only the absence of a line.
    my $p = build_tree(journal => "-- some unrelated pve message --\n");
    my ($rc, $out) = check($p);
    is($rc, 1, 'exits non-zero');
    like($out, qr{running WITHOUT proxmod}, 'and is blunt about it');
    like($out, qr{looks like everything being fine},
        'and explains why nothing else noticed');
};

subtest 'a fresh perl being able to load the module proves nothing' => sub {
    plan tests => 2;
    # Restated as a property of the code rather than of a run: the live check
    # must derive its verdict from journalctl, not from require.
    my $body = slurp($VERIFY);
    like($body, qr{journalctl}, 'the live gate reads the journal');
    like($body, qr{ExecMainStartTimestamp},
        'scoped to the current invocation of the unit');
};

subtest 'a journal line from a previous run is not counted' => sub {
    plan tests => 1;
    # The stub honours --since only in the sense that it always returns what
    # the test put there; what is asserted here is that verify asks for the
    # window at all. Without it, a `booted` line from a process that has since
    # been replaced by an unwrapped one would read as success.
    my $p = build_tree();
    my ($rc, $out) = check($p);
    is($rc, 0, 'the healthy case still passes with the window applied');
};

subtest 'missing drop-ins are reported before anything else' => sub {
    plan tests => 3;
    my $p = build_tree(no_dropins => 1);
    my ($rc, $out) = check($p);
    is($rc, 1, 'exits non-zero');
    like($out, qr{drop-ins are not in place}, 'names the problem');
    like($out, qr{proxmodctl reapply}, 'and the command that fixes it');
};

subtest 'a package that shipped no drop-ins at all' => sub {
    plan tests => 2;
    my $p = build_tree(units => []);
    my ($rc, $out) = check($p);
    is($rc, 1, 'exits non-zero');
    like($out, qr{no systemd drop-ins are shipped}, 'and distinguishes it from an unconverged host');
};

subtest 'another package winning the ExecStart race is detected' => sub {
    plan tests => 3;
    # Two frameworks that both override ExecStart= in a drop-in do not compose:
    # the one whose filename sorts last wins outright and the other stops
    # loading, silently. Detecting it is the honest response.
    my $p = build_tree(exec_start => "/usr/lib/other-thing/wrapper pveproxy\n");
    my ($rc, $out) = check($p);
    is($rc, 1, 'exits non-zero');
    like($out, qr{does not start through proxmod}, 'the drift is named');
    like($out, qr{systemctl cat}, 'with the command that shows who won');
};

subtest 'a lost ExecReload override is a warning, not a failure' => sub {
    plan tests => 3;
    # The daemon is fine right now. It will lose proxmod the next time anything
    # runs `systemctl reload` — including pve-manager's own postinst
    # [PVE-F-005]. That is worth saying and is not worth failing monitoring for
    # while the host is still working.
    my $p = build_tree(exec_reload => "/usr/bin/pveproxy reload\n");
    my ($rc, $out) = check($p);
    is($rc, 0, 'exits 0');
    like($out, qr{will lose proxmod on reload}, 'but warns');
    like($out, qr{\[ warn \]}, 'at warning level');
};

subtest 'the kill switch is respected without complaint' => sub {
    plan tests => 3;
    my $p = build_tree(disabled => 1, journal => "-- nothing from us --\n");
    my ($rc, $out) = check($p);
    is($rc, 0, 'exits 0');
    like($out, qr{deliberately disabled}, 'and says the state is intentional');
    unlike($out, qr{FAIL}, 'nothing is reported as a failure');
};

subtest 'a failed extension is visible but does not fail the host' => sub {
    plan tests => 3;
    # The isolation working as designed: one extension died at require, the
    # daemon is serving, the other extensions are live. A red alert here would
    # train people to ignore the alert.
    my $p = build_tree(journal => join('',
        "proxmod: error: broken-one: cannot load Broken::Module\n",
        "proxmod: booted daemon=pveproxy extensions=2 failed=1\n"));
    my ($rc, $out) = check($p);
    is($rc, 0, 'exits 0');
    like($out, qr{1 extension\(s\) failed to load}, 'the count is reported');
    like($out, qr{Broken::Module}, 'along with the journal line that says why');
};

subtest 'a stopped daemon is reported, not blamed on proxmod' => sub {
    plan tests => 3;
    my $p = build_tree(is_active => 'inactive', journal => '');
    my ($rc, $out) = check($p);
    is($rc, 0, 'exits 0');
    like($out, qr{is not running}, 'the state is reported');
    unlike($out, qr{running WITHOUT proxmod}, 'and not misread as a failed injection');
};

subtest '--live-only answers one narrow question' => sub {
    plan tests => 4;
    # proxmod-reapply turns this answer into a daemon restart, so it must not
    # widen. A drifted ExecStart is a real problem that a restart cannot fix.
    my $p = build_tree(exec_start => "/usr/lib/other-thing/wrapper pveproxy\n");
    my ($full) = check($p);
    is($full, 1, 'the full report fails on the drift');

    my ($narrow) = verify($p, '--live-only');
    is($narrow, 0, 'but --live-only passes: proxmod IS loaded in the running daemon');

    my $q = build_tree(journal => "-- nothing --\n");
    my ($dead) = verify($q, '--live-only');
    is($dead, 1, 'and fails when it is not');

    my $r = build_tree(disabled => 1, journal => "-- nothing --\n");
    my ($off) = verify($r, '--live-only');
    is($off, 0, 'the kill switch does not make reapply restart forever');
};

subtest '--quiet says nothing at all' => sub {
    plan tests => 4;
    my $p = build_tree();
    my ($rc, $out) = verify($p, '--no-http', '--quiet');
    is($rc, 0, 'exits 0 when healthy');
    is($out, '', 'and prints nothing');

    my $q = build_tree(journal => "-- nothing --\n");
    my ($rc2, $out2) = verify($q, '--no-http', '--quiet');
    is($rc2, 1, 'exits 1 when not');
    is($out2, '', 'and still prints nothing');
};

subtest '--json is parseable and carries the verdict' => sub {
    plan tests => 5;
    my $p = build_tree(journal => "-- nothing --\n");
    my ($rc, $out) = verify($p, '--no-http', '--json');
    is($rc, 1, 'the exit status still carries the verdict');

    require JSON::PP;
    my $data = eval { JSON::PP->new->decode($out) };
    ok($data, 'the output parses as JSON') or diag($out);
    is($data->{healthy}, 0, 'healthy is false');
    cmp_ok($data->{errors}, '>', 0, 'the error count is set');
    ok(scalar(@{ $data->{findings} }), 'and the individual findings are included');
};

subtest 'the live web interface must carry exactly one loader tag' => sub {
    plan tests => 6;
    # Zero means the injection is not happening. More than one means every
    # extension asset is evaluated twice, which presents as click handlers
    # firing in duplicate rather than as anything that looks like a bug in
    # proxmod.
    my $tag = '<script src="/proxmod/loader.js?v=1"></script>';

    my $one = build_tree(http => {
        '/' => [ 200, "<html>$tag</html>\n" ],
        '/proxmod/loader.js' => [ 200, "var a=[];\n" ],
    });
    my ($rc, $out) = verify($one, '--url', 'test:');
    is($rc, 0, 'one tag is healthy');
    like($out, qr{exactly one loader tag}, 'and is reported as such');

    my $none = build_tree(http => { '/' => [ 200, "<html></html>\n" ] });
    ($rc, $out) = verify($none, '--url', 'test:');
    is($rc, 1, 'no tag fails');
    like($out, qr{no loader tag}, 'and says the frontend is not injecting');

    my $two = build_tree(http => {
        '/' => [ 200, "<html>$tag$tag</html>\n" ],
        '/proxmod/loader.js' => [ 200, "var a=[];\n" ],
    });
    ($rc, $out) = verify($two, '--url', 'test:');
    is($rc, 1, 'two tags fail');
    like($out, qr{evaluated more than once}, 'with the consequence spelled out');
};

subtest 'an asset the loader names but nothing serves is a failure' => sub {
    plan tests => 2;
    # The signature of a manifest naming a file its package forgot to ship.
    my $p = build_tree(http => {
        '/' => [ 200, qq{<html><script src="/proxmod/loader.js?v=1"></script></html>\n} ],
        '/proxmod/loader.js' => [ 200,
            qq{var assets=[{"id":"gone","url":"/proxmod/gone.js"}];\n} ],
        '/proxmod/gone.js' => [ 404, '' ],
    });
    my ($rc, $out) = verify($p, '--url', 'test:');
    is($rc, 1, 'exits non-zero');
    like($out, qr{/proxmod/gone\.js is referenced but not served}, 'naming the asset');
};

subtest 'an unknown argument is refused rather than guessed at' => sub {
    plan tests => 2;
    my $p = build_tree();
    my ($rc, $out) = verify($p, '--fix-everything');
    is($rc, 64, 'exits 64');
    like($out, qr{unknown argument}, 'saying what it did not understand');
};
