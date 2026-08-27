#!/usr/bin/perl
use strict;
use warnings;

use lib 't/lib';
use lib 'perl';
use Test::More tests => 13;
use ProxmodTest qw(tempdir write_file repo_root);
use File::Path ();

# Two files that had no tests at all, for opposite reasons.
#
# bin/proxmodctl has none because it is "a thin wrapper over something else" and
# a wrapper looks like it cannot be wrong. It was: `list` parsed JSON manifests
# with a sed expression written for INI syntax, matched nothing, and printed an
# empty block on every host for two releases. An always-empty listing is
# indistinguishable from a host with nothing installed, which is why nobody
# reported it.
#
# Proxmod::Log has none because it is four one-line functions. But its output IS
# the contract with proxmod-verify — verify decides whether the live daemon
# loaded proxmod by grepping the journal for the `proxmod:` prefix since the
# unit's last start — so the prefix, the newline collapsing that keeps a line
# from escaping it, and which spellings of `debug = ...` turn debug on are all
# load-bearing and none of them were checked.

my $CTL = repo_root() . '/bin/proxmodctl';
ok(-x $CTL, 'bin/proxmodctl exists and is executable');

# ---------------------------------------------------------------------------
# proxmodctl
# ---------------------------------------------------------------------------

# A tree with stubs where proxmodctl expects programs, plus stubs on PATH for
# the host commands it shells out to. Every stub logs its arguments, because
# what is under test is mostly which program got called with what — the whole
# design claim of this file is that it delegates rather than reimplements.
sub build_tree {
    my (%opt) = @_;
    my $p = tempdir();

    for my $dir (qw(usr/sbin usr/lib/proxmod etc/proxmod bin)) {
        File::Path::make_path("$p/$dir");
    }

    my %progs = (
        "$p/usr/sbin/proxmod-verify"        => $opt{verify_rc}  // 0,
        "$p/usr/lib/proxmod/proxmod-reapply" => $opt{reapply_rc} // 0,
        "$p/usr/lib/proxmod/proxmod-patch"  => $opt{patch_rc}   // 0,
    );
    for my $prog (sort keys %progs) {
        my ($name) = $prog =~ m{([^/]+)\z};
        next if $opt{"no_$name"};
        write_file($prog, "#!/bin/sh\n"
            . "echo \"$name \$*\" >> '$p/calls.log'\n"
            . "echo 'output from $name'\n"
            . "exit $progs{$prog}\n");
        chmod 0755, $prog;
    }

    # journalctl output is what `logs` and `doctor` filter. The default has one
    # proxmod line in it and one line that is not ours, so a test that greps
    # can tell filtering from echoing.
    my $journal = $opt{journal} // "Aug 27 10:00:01 host pveproxy[1]: proxmod: 2 extensions\n"
        . "Aug 27 10:00:02 host pvedaemon[2]: starting server\n";
    write_file("$p/journal.txt", $journal);

    write_file("$p/bin/journalctl", "#!/bin/sh\n"
        . "echo \"journalctl \$*\" >> '$p/calls.log'\ncat '$p/journal.txt'\n");
    write_file("$p/bin/systemctl", "#!/bin/sh\n"
        . "echo \"systemctl \$*\" >> '$p/calls.log'\necho active\n");
    write_file("$p/bin/dpkg-query", "#!/bin/sh\n"
        . "echo \"dpkg-query \$*\" >> '$p/calls.log'\necho 'proxmod 0.2.1'\n");
    chmod 0755, "$p/bin/$_" for qw(journalctl systemctl dpkg-query);

    return $p;
}

sub ctl {
    my ($p, @args) = @_;
    local $ENV{PROXMOD_TEST_PREFIX} = $p;
    local $ENV{PATH}                = "$p/bin:$ENV{PATH}";
    my $out = `'$CTL' @args 2>&1`;
    return ($? >> 8, $out);
}

sub calls {
    my ($p) = @_;
    open my $fh, '<', "$p/calls.log" or return '';
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

subtest 'it says what it does when asked, and when asked nothing' => sub {
    plan tests => 4;
    my $p = build_tree();

    for my $args ([], ['help'], ['--help']) {
        my ($rc, $out) = ctl($p, @$args);
        my $name = @$args ? $args->[0] : '(no arguments)';
        subtest "$name prints usage and succeeds" => sub {
            plan tests => 2;
            is($rc, 0, 'exit 0');
            like($out, qr{^usage: proxmodctl}m, 'usage on stdout');
        };
    }

    my ($rc, $out) = ctl($p, 'frobnicate');
    subtest 'an unknown command is an error that names itself' => sub {
        plan tests => 2;
        is($rc, 1, 'exit 1');
        like($out, qr{unknown command: frobnicate}, 'and says which one');
    };
};

subtest "REGRESSION list-parsed-in-shell: list delegates to the manifest parser" => sub {
    # The defect, exactly: `list` used `sed -n 's/^ *id *= *\(.*\)/\1/p'` over
    # files whose format is JSON. Zero output, every host, no error. The fix is
    # not a better expression — it is that there is only one manifest parser in
    # this project and it is Proxmod::Registry, reached here through
    # proxmod-verify --list.
    plan tests => 4;
    my $p = build_tree();

    my ($rc, $out) = ctl($p, 'list');
    is($rc, 0, 'list succeeds');
    like(calls($p), qr{^proxmod-verify --list$}m, 'by calling proxmod-verify --list');
    like($out, qr{output from proxmod-verify}, 'and prints what it said');

    # The half of the fix that a call assertion cannot see: that nothing came
    # back. A second shell parser would satisfy the test above and reintroduce
    # the bug.
    open my $fh, '<', $CTL or die $!;
    my $src = join '', grep { !/^\s*#/ } <$fh>;   # the comments describe the bug
    close $fh;
    unlike($src, qr{\b(?:sed|awk|jq)\b}, 'and parses no manifest itself');
};

subtest 'a failing verify is an answer, not an error in asking' => sub {
    # `status` is the one command whose non-zero exit is information. proxmod-
    # verify exits 1 for "broken" and 2 for "degraded", and a monitoring system
    # calling `proxmodctl status --json` needs those to arrive unchanged rather
    # than flattened into the shell's own idea of failure.
    plan tests => 4;

    my $p = build_tree(verify_rc => 2);
    my ($rc, $out) = ctl($p, 'status');
    is($rc, 2, "verify's exit code reaches the caller");
    like($out, qr{output from proxmod-verify}, 'and its output does too');

    $p = build_tree(verify_rc => 1);
    ($rc) = ctl($p, 'status', '--json');
    is($rc, 1, 'and again for --json');
    like(calls($p), qr{^proxmod-verify --json$}m, 'with the flag passed through');
};

subtest 'a missing program is reported, not blamed on the host' => sub {
    # On a partially installed or half-removed package, the useful output is
    # the path that is missing. `set -e` plus a bare call would give the
    # administrator "127" and nothing else.
    plan tests => 4;

    my $p = build_tree('no_proxmod-verify' => 1);
    my ($rc, $out) = ctl($p, 'status');
    is($rc, 1, 'status fails');
    like($out, qr{proxmod-verify is not installed}, 'naming the program');

    ($rc, $out) = ctl($p, 'list');
    is($rc, 1, 'and so does list');
    like($out, qr{proxmod-verify is not installed}, 'for the same reason');
};

subtest 'everything that changes the host refuses without root' => sub {
    # The test suite runs unprivileged, which makes this the one property that
    # is easy to check here and expensive to check anywhere else. It matters
    # because the failure it prevents is silent: `disable` without root would
    # otherwise fail partway — after mkdir, before the restart — and leave a
    # host that reports itself enabled and is not.
    plan tests => 4;
    my $p = build_tree();

    for my $cmd (qw(reapply enable disable)) {
        my ($rc, $out) = ctl($p, $cmd);
        subtest "$cmd needs root" => sub {
            plan tests => 3;
            is($rc, 1, 'exit 1');
            like($out, qr{\Q$cmd\E needs root}, 'and says so');
            unlike(calls($p), qr{proxmod-reapply}, 'without having done anything first');
        };
    }

    my ($rc, $out) = ctl($p, 'patch', 'apply', 'some-spec');
    subtest 'patch apply needs root, patch status does not' => sub {
        plan tests => 3;
        is($rc, 1, 'apply refuses');
        like($out, qr{patch apply needs root}, 'naming the subcommand');

        my $q = build_tree();
        my ($rc2) = ctl($q, 'patch', 'status');
        is($rc2, 0, 'status is readable unprivileged');
    };
};

subtest 'patch with no subcommand asks the facility, not this file' => sub {
    # docs and proxmod-patch's own usage are the place patching is explained.
    # proxmodctl deliberately does not summarise it — a summary of how to edit
    # a Proxmox file is worse than no summary.
    plan tests => 2;
    my $p = build_tree();
    my ($rc) = ctl($p, 'patch');
    is($rc, 0, 'it succeeds');
    like(calls($p), qr{^proxmod-patch status$}m, 'by asking proxmod-patch for status');
};

subtest 'logs filters to proxmod, and says so when there is nothing' => sub {
    plan tests => 5;

    my $p = build_tree();
    my ($rc, $out) = ctl($p, 'logs');
    is($rc, 0, 'logs succeeds when there is something to show');
    like($out, qr{proxmod: 2 extensions}, 'showing our line');
    unlike($out, qr{starting server}, 'and not the ones that are not ours');
    like(calls($p), qr{-u pvedaemon -u pveproxy}, 'reading both units interleaved');

    # An empty journal is not an error in the reading — it is the finding, and
    # the message has to say which finding, because "no output" from a log
    # command reads as "no problem".
    $p = build_tree(journal => "Aug 27 10:00:02 host pvedaemon[2]: starting server\n");
    ($rc, $out) = ctl($p, 'logs');
    subtest 'a journal with nothing from proxmod in it' => sub {
        plan tests => 2;
        is($rc, 1, 'exits non-zero');
        like($out, qr{nothing from proxmod in the journal.*proxmodctl status}s,
            'and points at the command that explains why');
    };
};

subtest 'doctor finishes on a host where everything is broken' => sub {
    # doctor is the command for a host that is already broken, so it has to
    # cope with its own programs being missing. Two ways it could fail to: by
    # stopping partway, and by exiting non-zero after a perfectly good report
    # (the last command in the script is a `[ -x ]` test, so its status is
    # doctor's). Both are asserted with every program removed — the report is
    # complete and the exit is 0.
    plan tests => 3;

    my $p = build_tree(
        'no_proxmod-verify' => 1, 'no_proxmod-patch' => 1, 'no_proxmod-reapply' => 1,
    );
    my ($rc, $out) = ctl($p, 'doctor');
    is($rc, 0, 'doctor exits 0 even so');

    my @sections = ('=== proxmod ===', '=== proxmox ===', '=== units ===',
        '=== extensions ===', '=== journal ===', '=== patches ===', '=== verify ===');
    my @missing = grep { index($out, $_) < 0 } @sections;
    is(scalar(@missing), 0, 'and every section is present')
        or diag('missing: ' . join(', ', @missing));

    unlike($out, qr{"version"|"module"}, 'it does not dump third-party manifests');
};

# ---------------------------------------------------------------------------
# Proxmod::Log
# ---------------------------------------------------------------------------

use Proxmod::Log qw(log_debug log_info log_warn log_error);

# Capture what the module printed. $FH exists for exactly this.
sub emitted {
    my ($code) = @_;
    my $buf = '';
    open my $fh, '>', \$buf or die $!;
    local $Proxmod::Log::FH = $fh;
    $code->();
    close $fh;
    return $buf;
}

subtest 'the prefix is the contract, and every line carries it' => sub {
    # proxmod-verify greps the journal for `proxmod:` since the unit's last
    # start to decide whether the running daemon actually loaded us. A line
    # without the prefix is a line verify cannot see — which means proxmod
    # reporting a problem is indistinguishable from proxmod not being loaded.
    plan tests => 5;

    is(emitted(sub { log_info('two extensions') }), "proxmod: two extensions\n",
        'info carries no level word — it is the normal case');
    is(emitted(sub { log_warn('slow') }), "proxmod: warn: slow\n", 'warn names its level');
    is(emitted(sub { log_error('broken') }), "proxmod: error: broken\n", 'so does error');

    is(emitted(sub { log_info('a', 'b', 'c') }), "proxmod: abc\n",
        'parts are concatenated, not joined with spaces');
    is(emitted(sub { log_info('id=', undef) }), "proxmod: id=<undef>\n",
        'an undef part prints as <undef> rather than warning about itself');
};

subtest 'a multi-line message is collapsed, not allowed to escape the prefix' => sub {
    # The failure: Perl error text is multi-line, so `log_error("$@")` would
    # emit a first line with the prefix and the rest without. The unprefixed
    # remainder is invisible to proxmod-verify and, in a journal interleaved
    # with pveproxy's own output, unattributable by a human.
    plan tests => 4;

    is(emitted(sub { log_error("died at foo.pm line 3.\n") }),
        "proxmod: error: died at foo.pm line 3.\n", 'a trailing newline is not a second line');
    is(emitted(sub { log_error("first\nsecond") }),
        "proxmod: error: first second\n", 'an embedded newline becomes a space');
    is(emitted(sub { log_error("first\n   second\n\n  third") }),
        "proxmod: error: first second third\n", 'and so does indentation around it');

    my $out = emitted(sub { log_error("a\nb\nc\nd") });
    is(scalar(() = $out =~ /\n/g), 1, 'whatever went in, one line comes out');
};

subtest 'which spellings of debug turn debug on' => sub {
    # `debug = yes` in a conffile is what an administrator writes; `debug = 1`
    # is what a script writes; `debug = on` is what someone who has used any
    # other daemon writes. All three work and none of them was tested, so any
    # of them could have stopped working in a way that only shows up as "I
    # turned on debug logging and got nothing".
    plan tests => 3;

    my $dir = tempdir();
    local $Proxmod::Log::CONF_FILE = "$dir/proxmod.conf";
    local $ENV{PROXMOD_DEBUG};
    delete $ENV{PROXMOD_DEBUG};

    my $says_debug = sub {
        my ($conf) = @_;
        write_file("$dir/proxmod.conf", $conf);
        Proxmod::Log::_reset_cache();
        return emitted(sub { log_debug('probe') }) eq "proxmod: debug: probe\n" ? 1 : 0;
    };

    subtest 'the spellings that mean yes' => sub {
        my @on = ('1', 'y', 'yes', 'on', 'true', 'YES', 'True', ' yes');
        plan tests => scalar(@on);
        is($says_debug->("debug = $_\n"), 1, "debug = $_") for @on;
    };

    subtest 'the spellings that mean no' => sub {
        my @off = ('0', 'n', 'no', 'off', 'false', 'maybe', '');
        plan tests => scalar(@off) + 2;
        is($says_debug->("debug = $_\n"), 0, "debug = '$_'") for @off;
        is($says_debug->("# debug = yes\n"), 0, 'a commented-out setting is not a setting');
        is($says_debug->("nothing here\n"), 0, 'and neither is a file that never mentions it');
    };

    subtest 'the environment variable, and what it cannot reach' => sub {
        # pvedaemon clears its environment before running, so PROXMOD_DEBUG is
        # unreachable from a normal systemd start — it only helps when you run
        # a daemon by hand. The config file is the switch that works in
        # production, and it is the one that has to win nothing: both are ORed,
        # so neither can turn the other off. That is deliberate; a debug flag
        # you cannot turn on from where you are standing is worse than one that
        # is occasionally on twice.
        plan tests => 3;
        write_file("$dir/proxmod.conf", "");
        local $ENV{PROXMOD_DEBUG} = '1';
        Proxmod::Log::_reset_cache();
        is(emitted(sub { log_debug('probe') }), "proxmod: debug: probe\n",
            'the env var alone enables it');

        Proxmod::Log::_reset_cache();
        {
            local $ENV{PROXMOD_DEBUG} = '0';
            write_file("$dir/proxmod.conf", "debug = yes\n");
            Proxmod::Log::_reset_cache();
            is(emitted(sub { log_debug('probe') }), "proxmod: debug: probe\n",
                'and the config file alone enables it');
        }

        delete $ENV{PROXMOD_DEBUG};
        write_file("$dir/proxmod.conf", "");
        Proxmod::Log::_reset_cache();
        is(emitted(sub { log_debug('probe') }), '', 'with neither, debug says nothing at all');
    };
};

subtest 'the debug decision is made once' => sub {
    # _debug_enabled opens the config file on first use and caches. It is
    # called on every log_debug, and the daemons log a great deal — re-reading
    # /etc/proxmod/proxmod.conf per line would be a syscall per log statement
    # inside pvedaemon's request path.
    plan tests => 2;

    my $dir = tempdir();
    local $Proxmod::Log::CONF_FILE = "$dir/proxmod.conf";
    local $ENV{PROXMOD_DEBUG};
    delete $ENV{PROXMOD_DEBUG};

    write_file("$dir/proxmod.conf", "debug = yes\n");
    Proxmod::Log::_reset_cache();
    is(emitted(sub { log_debug('one') }), "proxmod: debug: one\n", 'debug is on');

    unlink "$dir/proxmod.conf";
    is(emitted(sub { log_debug('two') }), "proxmod: debug: two\n",
        'and stays on for the life of the process, config file or no config file');
};
