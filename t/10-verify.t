#!/usr/bin/perl
use strict;
use warnings;

use lib 't/lib';
use lib 'perl';
use Test::More tests => 26;
use ProxmodTest qw(tempdir write_file repo_root);
use File::Path ();

# The same module proxmod-verify and Proxmod::Boot use to fingerprint the
# registry. The tests compute the expected value with it rather than hard-coding
# a digest, so a deliberate change to what the fingerprint covers does not have
# to be re-typed here in hex.
use Proxmod::Registry;

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

# What verify() puts in PERL5LIB. Package-scoped rather than lexical so one
# test can localise it, to prove that a registry proxmod-verify cannot read
# falls back to the strict behaviour.
our $PERL5LIB = repo_root() . '/perl';

sub build_tree {
    my (%opt) = @_;
    my $p = tempdir();

    File::Path::make_path("$p/bin", "$p/sys", "$p/journal", "$p/http",
        "$p/etc/proxmod", "$p/etc/proxmod/extensions.d",
        "$p/usr/share/proxmod/www", "$p/usr/share/proxmod/extensions.d");

    # The registry decides whether a missing loader tag is a failure or the
    # zero-footprint design working, so the HTTP tests have to say which kind
    # of host they are describing. Written to the package-owned directory,
    # which is where an extension's .deb drops its manifest.
    my $order = 50;
    for my $m (@{ $opt{manifests} || [] }) {
        my %ext = (version => '1.0.0', %$m);
        require JSON::PP;
        write_file("$p/usr/share/proxmod/extensions.d/"
                . sprintf('%02d-%s.conf', $order++, $ext{id}),
            JSON::PP->new->canonical->encode(\%ext));
    }

    # What proxmod-verify will compute from that registry, and so what a daemon
    # running it would have logged. A test that wants a stale daemon overrides
    # the journal with a different one, or with none at all.
    my $fp = fingerprint_of($p);

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
            : "proxmod: booted daemon=$daemon extensions=1 failed=0 registry=$fp\n";
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

sub fingerprint_of {
    my ($p) = @_;
    my $exts = Proxmod::Registry::load(dirs => [
        "$p/usr/share/proxmod/extensions.d",
        "$p/etc/proxmod/extensions.d",
    ]);
    return Proxmod::Registry::fingerprint($exts);
}

# Returns ($rc, $stdout).
sub verify {
    my ($p, @args) = @_;
    my $out = "$p/stdout.$$";

    local $ENV{PROXMOD_TEST_PREFIX} = $p;
    local $ENV{PATH} = "$p/bin:$ENV{PATH}";
    # proxmod-verify reads the registry to tell a backend-only host apart from
    # a broken injection. It is not under -T, so PERL5LIB reaches it — which is
    # the only reason that branch is testable at all. One test points this
    # somewhere empty on purpose, to prove the strict path is still there.
    local $ENV{PERL5LIB} = $PERL5LIB;

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

# A host with something that actually wants a frontend, which is the only kind
# of host on which a missing loader tag is a defect.
my @WITH_FRONTEND = ({
    id => 'has-ui',
    backend  => { module => 'ProxmodExample::Hello' },
    frontend => { assets => ['proxmod-has-ui.js'] },
});

# ...and one that does not: the case in issue #1.
my @BACKEND_ONLY = ({
    id      => 'csi-storage',
    backend => { module => 'ProxmodExt::CSIStorage' },
});

subtest 'the live web interface must carry exactly one loader tag' => sub {
    plan tests => 6;
    # Zero means the injection is not happening. More than one means every
    # extension asset is evaluated twice, which presents as click handlers
    # firing in duplicate rather than as anything that looks like a bug in
    # proxmod.
    my $tag = '<script src="/proxmod/loader.js?v=1"></script>';

    my $one = build_tree(manifests => \@WITH_FRONTEND, http => {
        '/' => [ 200, "<html>$tag</html>\n" ],
        '/proxmod/loader.js' => [ 200, "var a=[];\n" ],
    });
    my ($rc, $out) = verify($one, '--url', 'test:');
    is($rc, 0, 'one tag is healthy');
    like($out, qr{exactly one loader tag}, 'and is reported as such');

    my $none = build_tree(manifests => \@WITH_FRONTEND,
        http => { '/' => [ 200, "<html></html>\n" ] });
    ($rc, $out) = verify($none, '--url', 'test:');
    is($rc, 1, 'no tag fails');
    like($out, qr{no loader tag}, 'and says the frontend is not injecting');

    my $two = build_tree(manifests => \@WITH_FRONTEND, http => {
        '/' => [ 200, "<html>$tag$tag</html>\n" ],
        '/proxmod/loader.js' => [ 200, "var a=[];\n" ],
    });
    ($rc, $out) = verify($two, '--url', 'test:');
    is($rc, 1, 'two tags fail');
    like($out, qr{evaluated more than once}, 'with the consequence spelled out');
};

subtest 'a backend-only host is healthy with no loader tag at all' => sub {
    plan tests => 6;
    # Issue #1, reproduced. proxmod::Frontend leaves the index alone when no
    # extension declares an asset, so there is no tag AND no /proxmod/ route —
    # pveproxy's static fall-through answers the loader with a 500. Both are
    # the zero-footprint promise being kept, and reading either as a defect
    # made a correct host report "proxmod is NOT working correctly".
    my $p = build_tree(manifests => \@BACKEND_ONLY, http => {
        '/' => [ 200, "<html><script src=\"/pve2/js/pvemanagerlib.js\"></script></html>\n" ],
        '/proxmod/loader.js' => [ 500, '' ],
    });
    my ($rc, $out) = verify($p, '--url', 'test:');
    is($rc, 0, 'exits 0');
    like($out, qr{proxmod is working}, 'and reports the host as working');
    unlike($out, qr{FAIL}, 'with nothing reported as a failure');
    like($out, qr{no extension asks for one}, 'the index check says why zero is correct');
    like($out, qr{skipped the /proxmod/loader\.js checks},
        'and the loader probe is skipped, not silently dropped');
    unlike($out, qr{is not being served},
        'so the 500 from the static fall-through is never reported');
};

subtest 'a loader tag with nothing asking for one is a warning' => sub {
    plan tests => 3;
    # Backend-only, but the index has a tag anyway: either a stale tag from an
    # extension removed without a daemon restart, or something has patched
    # index.html.tpl. Worth saying, not worth failing — the host still works.
    my $p = build_tree(manifests => \@BACKEND_ONLY, http => {
        '/' => [ 200, qq{<html><script src="/proxmod/loader.js?v=1"></script></html>\n} ],
        '/proxmod/loader.js' => [ 200, "var a=[];\n" ],
    });
    my ($rc, $out) = verify($p, '--url', 'test:');
    is($rc, 0, 'exits 0');
    like($out, qr{\[ warn \]}, 'at warning level');
    like($out, qr{no extension declares a frontend asset}, 'saying what does not add up');
};

subtest 'a registry that cannot be read keeps the strict behaviour' => sub {
    plan tests => 2;
    # The skip must never become the default. When the registry cannot be read
    # at all, "no tag" has to stay a failure — otherwise a host where proxmod
    # is half-installed reports clean, which is the exact failure mode this
    # whole tool exists to prevent. Unknown is not the same as none.
    my $p = build_tree(manifests => \@BACKEND_ONLY,
        http => { '/' => [ 200, "<html></html>\n" ] });
    local $PERL5LIB = '/nonexistent';
    my ($rc, $out) = verify($p, '--url', 'test:');
    is($rc, 1, 'exits 1 even though the host is in fact backend-only');
    like($out, qr{no loader tag}, 'and still names the missing tag');
};

subtest 'an asset the loader names but nothing serves is a failure' => sub {
    plan tests => 2;
    # The signature of a manifest naming a file its package forgot to ship.
    my $p = build_tree(manifests => \@WITH_FRONTEND, http => {
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

# --- the registry fingerprint ---------------------------------------------
#
# check_live answers "is proxmod running". These answer the question directly
# after it, and the one a dpkg trigger actually needs: an extension package
# installs cleanly, the daemons keep serving the registry they read at startup,
# and every other check on this host reports it perfectly healthy.

subtest 'a daemon running an older registry is reported and not fatal' => sub {
    plan tests => 5;
    my $p = build_tree(
        manifests => [ { id => 'hello', backend => { module => 'A::Hello' } } ],
        journal   => "proxmod: booted daemon=x extensions=1 failed=0 registry=deadbeefcafe\n",
    );
    my ($rc, $out) = check($p);

    is($rc, 0, 'exits 0: a restart away from correct is not a failed host');
    like($out, qr{\[ warn \].*running an older extension registry}, 'but it is a warning');
    like($out, qr{deadbeefcafe}, 'naming what the daemon loaded');
    like($out, qr{\Q@{[ fingerprint_of($p) ]}\E}, 'and what is on disk');
    like($out, qr{proxmodctl reapply}, 'and what to do about it');
};

subtest 'a daemon from before fingerprinting is treated as out of date' => sub {
    plan tests => 3;
    # How a host upgrading onto a fingerprint-aware proxmod converges by
    # itself: the daemons still running the old modules cannot say what they
    # loaded, so they are assumed not to have loaded this.
    my $p = build_tree(
        journal => "proxmod: booted daemon=x extensions=1 failed=0\n",
    );
    my ($rc, $out) = check($p);

    is($rc, 0, 'exits 0');
    like($out, qr{predates registry fingerprinting}, 'and says what it cannot tell');
    like($out, qr{A restart resolves this permanently}, 'and that it is self-correcting');
};

subtest '--registry-only is the narrow question reapply asks' => sub {
    plan tests => 7;

    my $current = build_tree(
        manifests => [ { id => 'hello', backend => { module => 'A::Hello' } } ],
    );
    my ($rc, $out) = verify($current, '--registry-only');
    is($rc, 0, 'a daemon on the current registry exits 0');
    like($out, qr{\A\Q@{[ fingerprint_of($current) ]}\E\n\z},
        'and the fingerprint on disk is all it prints');

    my $stale = build_tree(
        manifests => [ { id => 'hello', backend => { module => 'A::Hello' } } ],
        journal   => "proxmod: booted daemon=x extensions=1 failed=0 registry=deadbeefcafe\n",
    );
    ($rc, $out) = verify($stale, '--registry-only');
    is($rc, 1, 'a daemon on an older registry exits 1');
    like($out, qr{\A\Q@{[ fingerprint_of($stale) ]}\E\n\z}, 'and still prints the current one');

    # The kill switch means nothing is loaded, so nothing can be out of date.
    # Without this, reapply would restart the daemons forever chasing a state
    # the administrator asked for.
    my $off = build_tree(disabled => 1, journal => "-- nothing --\n");
    ($rc) = verify($off, '--registry-only');
    is($rc, 0, 'a disabled host is never stale');

    # An unreadable registry is "could not tell", which reapply must not treat
    # as a reason to restart anything.
    {
        local our $PERL5LIB = "$current/nowhere";
        ($rc) = verify($current, '--registry-only');
        is($rc, 2, 'a registry we cannot read exits 2');
    }

    ($rc, $out) = verify($current, '--quiet', '--registry-only');
    is($out, '', '--quiet still says nothing at all');
};

subtest 'REGRESSION list-printed-nothing' => sub {
    plan tests => 7;

    # `proxmodctl list` ran a sed expression looking for `id = value` against
    # files whose format is JSON. It matched nothing, so list — and doctor's
    # extensions section — printed manifest paths and not one field from any of
    # them, on every host, for every release. An always-empty listing is
    # indistinguishable from a host with nothing installed, which is why it
    # survived. proxmodctl now delegates here, to the parser the daemons use,
    # so what is listed and what is loaded cannot disagree.
    my $p = build_tree(manifests => [
        { id => 'alpha',
          backend  => { module => 'Alpha::Ext', daemons => ['pvedaemon'] },
          frontend => { assets => ['alpha.js'] } },
        { id => 'beta', enabled => \0, backend => { module => 'Beta::Ext' } },
    ]);

    my ($rc, $out) = verify($p, '--list');
    is($rc, 0, 'exits 0: a listing is not a verdict');
    like($out, qr{^alpha 1\.0\.0 \[effective\]}m,
        'names the extension, its version and its state');
    like($out, qr{Alpha::Ext in pvedaemon}, 'and the module it loads, and where');
    like($out, qr{^beta 1\.0\.0 \[disabled\]}m,
        'including one load() drops — which is the one an administrator is looking for');
    like($out, qr{alpha\.js \(MISSING}, 'and a declared asset that is not on disk');

    write_file("$p/usr/share/proxmod/www/alpha.js", "// present\n");
    (undef, $out) = verify($p, '--list');
    unlike($out, qr{MISSING}, 'and does not once the asset is there');

    (undef, $out) = verify(build_tree(), '--list');
    like($out, qr{no extensions installed},
        'a host with none says so, rather than printing nothing at all');
};

subtest 'the structural replay actually replays' => sub {
    plan tests => 7;

    # check_structure carried a ten-line banner promising to catch an endpoint
    # that registered successfully and is nonetheless unreachable — a failure
    # with no log line at all — and then counted the extensions in the registry
    # and returned. It never resolved a path, and Proxmod::API::assert_route,
    # written for it, was called from nothing but t/04. This asserts the replay
    # happens: both that a good route is reported as resolving, and that a
    # shadowed one is reported as an error rather than counted as healthy.
    my $lib = tempdir();
    File::Path::make_path("$lib/Demo");
    write_file("$lib/Demo/Ext.pm", <<'PM');
package Demo::Ext;
use strict;
use warnings;
# An extension may depend on PVE at compile time; it is only ever loaded where
# PVE is present. See the note in examples/proxmod-example-hello.
use PVE::RESTHandler;
use PVE::API2;
use base qw(PVE::RESTHandler);

# The real PVE::API2 builds its tree while it compiles. The stub under t/lib
# builds it on request instead, because registration is process-global and the
# tests reset it between groups — so here, where nothing else will, the fixture
# asks for it.
BEGIN { PVE::API2::_build_tree() if PVE::API2->can('_build_tree') }
sub proxmod_register {
    my ($api) = @_;
    $api->mount(scope => 'node', subclass => __PACKAGE__);
    $api->add_method(
        class => __PACKAGE__,
        name => 'index',
        path => '',
        method => 'GET',
        permissions => { user => 'all' },
        parameters => { additionalProperties => 0, properties => {} },
        returns => { type => 'null' },
        code => sub { return },
    );
    return;
}
1;
PM

    my $p = build_tree(manifests => [
        { id => 'demo', backend => { module => 'Demo::Ext' } },
    ]);

    local $PERL5LIB = join(':', $lib, repo_root() . '/t/lib', repo_root() . '/perl');
    my ($rc, $out) = check($p);
    is($rc, 0, 'a route that resolves does not fail the run');
    like($out, qr{registered route\(s\) replayed},
        'and the replay reports what it replayed');
    like($out, qr{GET /nodes/proxmod-probe/proxmod/demo},
        'naming the path a request would take, not just a count of extensions');

    # An extension whose module is not installed where a fresh perl can see it
    # is the caveat in the banner, not a failure: check_live is the authority
    # on what the daemons loaded.
    my $q = build_tree(manifests => [
        { id => 'ghost', backend => { module => 'Nowhere::Ext' } },
    ]);
    ($rc, $out) = check($q);
    is($rc, 0, 'an extension this perl cannot load is a warning, not an error');
    like($out, qr{could not be loaded here}, 'and says so, rather than silently replaying nothing');

    # And the case the banner is actually about: a route that registered
    # without complaint and is nonetheless unreachable. Simulated by re-shaping
    # the API tree after registration, which is what a pve-manager upgrade does
    # to a host — the registration succeeded, the ledger still names the path,
    # and nothing answers it.
    write_file("$lib/Demo/Wiped.pm", <<'PM');
package Demo::Wiped;
use strict;
use warnings;
use PVE::RESTHandler;
use PVE::API2;
use base qw(PVE::RESTHandler);
BEGIN { PVE::API2::_build_tree() if PVE::API2->can('_build_tree') }
sub proxmod_register {
    my ($api) = @_;
    $api->mount(scope => 'node', subclass => __PACKAGE__);
    $api->add_method(
        class => __PACKAGE__,
        name => 'index',
        path => '',
        method => 'GET',
        permissions => { user => 'all' },
        parameters => { additionalProperties => 0, properties => {} },
        returns => { type => 'null' },
        code => sub { return },
    );
    # Something else re-shapes the tree afterwards.
    PVE::API2::_build_tree() if PVE::API2->can('_build_tree');
    return;
}
1;
PM

    my $r = build_tree(manifests => [
        { id => 'wiped', backend => { module => 'Demo::Wiped' } },
    ]);
    ($rc, $out) = check($r);
    is($rc, 1, 'a route that no longer resolves fails the run');
    like($out, qr{registered but is not reachable},
        'and is reported as unreachable, not counted as an extension and called healthy');
};
