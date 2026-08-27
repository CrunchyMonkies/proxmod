#!/usr/bin/perl

use strict;
use warnings;

use lib 't/lib';

use Test::More tests => 120;
use ProxmodTest qw(tempdir write_file repo_root);

use File::Path ();

# exec/proxmod-exec decides, at daemon start, whether -MProxmod gets added to
# pveproxy's and pvedaemon's command line. Every branch in it that is not the
# happy path exists to start the daemon EXACTLY as Proxmox ships it, so most of
# what follows asserts on the fail-safe rather than on the feature.
#
# The script is driven in --dry-run mode: instead of exec()ing the command it
# has assembled, it prints it. That single seam is what makes a shell script
# whose entire job is to exec something testable without a Proxmox host.
#
# PROXMOD_TEST_PREFIX relocates every absolute path the script knows about into
# a temporary tree. The script honours it only when it is not running as root,
# so it is inert under systemd.

my $EXEC = repo_root() . '/exec/proxmod-exec';
ok(-x $EXEC, 'exec/proxmod-exec exists and is executable');

# A group-writable file anywhere in the guarded set is meant to block injection.
# If the developer's umask is 002 the fixtures would trip that guard and every
# happy-path test would fail for the wrong reason.
umask 022;

# Build a complete, healthy fake installation. Individual tests then break
# exactly one thing about it, which keeps each failure attributable.
sub build_tree {
    my (%opt) = @_;

    my $p = tempdir();

    File::Path::make_path(
        "$p/usr/bin",
        "$p/usr/lib/proxmod",
        "$p/usr/lib/systemd/system",
        "$p/usr/share/perl5/Proxmod",
        "$p/usr/share/proxmod/www",
        "$p/usr/share/proxmod/extensions.d",
        "$p/usr/share/proxmod/patches",
        "$p/etc/proxmod/extensions.d",
        "$p/etc/proxmod/patches",
    );

    # A patch spec names a Proxmox file to rewrite and the text to write into
    # it, which makes a spec anyone can edit worth exactly as much to an
    # attacker as a registry anyone can edit. Both directories get a file so
    # the guard is exercised on the specs and not only on the directories.
    for my $d ("$p/usr/share/proxmod/patches", "$p/etc/proxmod/patches") {
        write_file("$d/50-demo.conf", qq({ "id": "demo", "enabled": false }\n));
    }

    # The real shim, not a stand-in: the load probe in the wrapper has to be
    # exercised against the module that will actually be injected.
    my $root = repo_root();
    write_file("$p/usr/share/perl5/Proxmod.pm", slurp("$root/perl/Proxmod.pm"));
    for my $m (glob("$root/perl/Proxmod/*.pm")) {
        my ($base) = $m =~ m{([^/]+)\z};
        write_file("$p/usr/share/perl5/Proxmod/$base", slurp($m));
    }

    my $shebang = defined $opt{shebang} ? $opt{shebang} : '#!/usr/bin/perl -T';
    write_file("$p/usr/bin/pveproxy",  "$shebang\nprint \"pveproxy\\n\";\n");
    write_file("$p/usr/bin/pvedaemon", "$shebang\nprint \"pvedaemon\\n\";\n");
    chmod 0755, "$p/usr/bin/pveproxy", "$p/usr/bin/pvedaemon";

    for my $svc (qw(pveproxy pvedaemon)) {
        my $exec_start = defined $opt{exec_start}
            ? $opt{exec_start}
            : "ExecStart=$p/usr/bin/$svc start";
        $exec_start =~ s/\@PREFIX\@/$p/g;
        write_file(
            "$p/usr/lib/systemd/system/$svc.service",
            "[Unit]\nDescription=fake $svc\n\n[Service]\nType=forking\n$exec_start\n",
        );
    }

    return $p;
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!";
    local $/;
    my $c = <$fh>;
    close($fh);
    return $c;
}

# Returns (stdout, stderr, exit_code). stdout is the command the wrapper would
# have become; stderr is what an administrator would find in the journal.
sub run_exec {
    my ($prefix, @args) = @_;

    my $err = "$prefix/stderr.txt";
    my $cmd = sprintf(
        "PROXMOD_TEST_PREFIX=%s /bin/sh %s --dry-run %s 2>%s",
        shq($prefix), shq($EXEC), join(' ', map { shq($_) } @args), shq($err),
    );

    my $out = `$cmd`;
    my $code = $? >> 8;

    $out = '' if !defined $out;
    chomp $out;

    return ($out, -e $err ? slurp($err) : '', $code);
}

sub shq {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# ---------------------------------------------------------------------------
# The happy path
# ---------------------------------------------------------------------------

{
    my $p = build_tree();
    my ($out, $err, $code) = run_exec($p, 'pveproxy');

    is($code, 0, 'healthy tree: exits 0');
    like($out, qr{\A\S*perl\b},           'healthy tree: runs the interpreter from the shebang');
    like($out, qr{\s-T\b},                'healthy tree: keeps the -T flag from the shebang');
    like($out, qr{\s-MProxmod\b},         'healthy tree: injects -MProxmod');
    like($out, qr{\Q$p/usr/bin/pveproxy\E\s+start\z},
        'healthy tree: ends with the real command and its arguments');
    is($err, '', 'healthy tree: says nothing to the journal');

    # -MProxmod must come before the script, or perl would treat it as one of
    # the daemon's own arguments.
    my $mod_at = index($out, '-MProxmod');
    my $scr_at = index($out, "$p/usr/bin/pveproxy");
    ok($mod_at >= 0 && $mod_at < $scr_at, 'healthy tree: -MProxmod precedes the script');
}

{
    my $p = build_tree();
    my ($out, $err, $code) = run_exec($p, 'pvedaemon');
    is($code, 0, 'pvedaemon: exits 0');
    like($out, qr{\s-MProxmod\s.*\Q$p/usr/bin/pvedaemon\E\s+start\z},
        'pvedaemon: injected the same way as pveproxy');
}

{
    # Whatever Proxmox decides to pass its daemons has to survive untouched.
    my $p = build_tree(exec_start => 'ExecStart=@PREFIX@/usr/bin/pveproxy start --debug 3');
    my ($out, undef, $code) = run_exec($p, 'pveproxy');
    is($code, 0, 'extra arguments: exits 0');
    like($out, qr{\Q$p/usr/bin/pveproxy\E\s+start\s+--debug\s+3\z},
        'extra arguments: passed through in order');
}

{
    # systemd's rule: a bare ExecStart= resets the list, so the last assignment
    # is the one that runs. Reading the first would inject into the wrong thing.
    my $p = build_tree(exec_start =>
        "ExecStart=\@PREFIX\@/usr/bin/pvedaemon start\nExecStart=\nExecStart=\@PREFIX\@/usr/bin/pveproxy start");
    my ($out, undef, $code) = run_exec($p, 'pveproxy');
    is($code, 0, 'multiple ExecStart: exits 0');
    like($out, qr{\Q$p/usr/bin/pveproxy\E\s+start\z}, 'multiple ExecStart: the last one wins');
    unlike($out, qr{pvedaemon}, 'multiple ExecStart: the reset earlier line is ignored');
}

{
    # '-' means "failure of this command is not a failure of the unit"; it is a
    # systemd prefix, not part of the path.
    my $p = build_tree(exec_start => 'ExecStart=-@PREFIX@/usr/bin/pveproxy start');
    my ($out, undef, $code) = run_exec($p, 'pveproxy');
    is($code, 0, 'prefixed ExecStart: exits 0');
    like($out, qr{\s-MProxmod\s+\Q$p/usr/bin/pveproxy\E\s+start\z},
        'prefixed ExecStart: the - prefix is stripped, not treated as part of the path');
}

{
    # pvestatd is not tainted [PVE-F-002]; a future daemon might not be either.
    my $p = build_tree(shebang => '#!/usr/bin/perl');
    my ($out, undef, $code) = run_exec($p, 'pveproxy');
    is($code, 0, 'untainted shebang: exits 0');
    like($out, qr{\s-MProxmod\s}, 'untainted shebang: still injects');
    unlike($out, qr{\s-T\b},      'untainted shebang: does not invent a -T flag');
}

# ---------------------------------------------------------------------------
# Fail-safe: the daemon starts unmodified
# ---------------------------------------------------------------------------

# Every case below must produce the daemon's own command with no -M anywhere in
# it. That is the prime directive: a missing extension is acceptable, a dead
# pvedaemon is not.
sub assert_unmodified {
    my ($out, $code, $expect, $label) = @_;
    is($code, 0, "$label: exits 0");
    is($out, $expect, "$label: starts the daemon exactly as shipped");
    # Anchored on a space so a temporary directory that happens to contain the
    # letters "-M" cannot pass or fail this by accident.
    unlike($out, qr{\s-M}, "$label: nothing injected");
}

{
    my $p = build_tree();
    write_file("$p/etc/proxmod/disabled", "");
    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", 'kill switch');
    like($err, qr{disabled by \Q$p/etc/proxmod/disabled\E}, 'kill switch: says why, and names the file');
}

{
    my $p = build_tree(shebang => '#!/bin/sh');
    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", 'non-perl daemon');
    like($err, qr{not a perl script}, 'non-perl daemon: says why');
}

{
    my $p = build_tree(shebang => '#!/nonexistent/perl -T');
    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", 'missing interpreter');
    like($err, qr{interpreter /nonexistent/perl .*not executable}, 'missing interpreter: names it');
}

{
    # An interrupted upgrade can leave the module truncated. Injecting a module
    # that will not compile turns a cosmetic problem into an outage.
    my $p = build_tree();
    write_file("$p/usr/share/perl5/Proxmod.pm", "package Proxmod;\nthis is not perl\n");
    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", 'module will not compile');
    like($err, qr{Proxmod will not load}, 'module will not compile: says why');
}

{
    my $p = build_tree();
    unlink "$p/usr/share/perl5/Proxmod.pm";
    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", 'module missing');
    like($err, qr{Proxmod will not load}, 'module missing: says why');
}

# ---------------------------------------------------------------------------
# Fail-safe: the permissions guard
# ---------------------------------------------------------------------------

# Everything guarded here is loaded, or names something loaded, as root inside
# pvedaemon. A non-root user who can write to any of it has unauthenticated root
# code execution on the host, so the wrapper must refuse to inject rather than
# carry on.

for my $case (
    ['usr/share/perl5/Proxmod.pm',      0664, 'group-writable module'],
    ['usr/share/perl5/Proxmod.pm',      0666, 'world-writable module'],
    ['usr/share/perl5/Proxmod/Boot.pm', 0664, 'group-writable submodule'],
    ['usr/share/perl5/Proxmod',         0775, 'group-writable module directory'],
    ['usr/share/proxmod/extensions.d',  0777, 'world-writable extension registry'],
    ['etc/proxmod',                     0775, 'group-writable configuration directory'],
    ['usr/lib/proxmod',                 0777, 'world-writable helper directory'],
    # The specs, not just the directories holding them. find runs -maxdepth 1,
    # so these pass only because both patch directories are named in
    # GUARDED_PATHS in their own right.
    ['usr/share/proxmod/patches/50-demo.conf', 0664, 'group-writable packaged patch spec'],
    ['etc/proxmod/patches/50-demo.conf',       0666, 'world-writable admin patch spec'],
) {
    my ($rel, $mode, $label) = @$case;

    my $p = build_tree();
    chmod $mode, "$p/$rel" or die "chmod $p/$rel: $!";

    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", $label);
    like($err, qr{refusing to inject}, "$label: refuses loudly");
    like($err, qr{\Q$p/$rel\E}, "$label: names the offending path");
}

# ---------------------------------------------------------------------------
# Fail-safe: the unit file cannot be understood
# ---------------------------------------------------------------------------

# Here the wrapper does not know the daemon's real command, so it falls back to
# the invocation PVE has used for several major versions. That is a guess, and
# proxmod-verify reports when the live ExecStart is not what we expect.

{
    my $p = build_tree();
    unlink "$p/usr/lib/systemd/system/pveproxy.service";
    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", 'unit file missing');
    like($err, qr{cannot find the unit file}, 'unit file missing: says why');
}

{
    my $p = build_tree(exec_start => '# no ExecStart at all');
    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", 'no ExecStart');
    like($err, qr{no ExecStart}, 'no ExecStart: says why');
}

{
    # The wrapper word-splits the command, so anything needing real parsing has
    # to be refused rather than mangled into a different command.
    my $p = build_tree(exec_start => 'ExecStart=@PREFIX@/usr/bin/pveproxy start "a b"');
    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", 'quoted ExecStart');
    like($err, qr{quoting or specifiers}, 'quoted ExecStart: says why');
}

{
    my $p = build_tree(exec_start => 'ExecStart=@PREFIX@/usr/bin/pveproxy start %i');
    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", 'ExecStart with a % specifier');
    like($err, qr{quoting or specifiers}, 'ExecStart with a % specifier: says why');
}

{
    my $p = build_tree();
    chmod 0644, "$p/usr/bin/pveproxy";
    my ($out, $err, $code) = run_exec($p, 'pveproxy');
    assert_unmodified($out, $code, "$p/usr/bin/pveproxy start", 'daemon not executable');
    like($err, qr{not executable}, 'daemon not executable: says why');
}

# The base unit is read directly and never the merged configuration, because the
# merged ExecStart is our own drop-in: following that would recurse.
{
    my $p = build_tree();
    File::Path::make_path("$p/usr/lib/systemd/system/pveproxy.service.d");
    write_file(
        "$p/usr/lib/systemd/system/pveproxy.service.d/10-proxmod.conf",
        "[Service]\nExecStart=\nExecStart=$p/usr/lib/proxmod/proxmod-exec pveproxy\n",
    );
    my ($out, undef, $code) = run_exec($p, 'pveproxy');
    is($code, 0, 'drop-in present: exits 0');
    unlike($out, qr{proxmod-exec}, 'drop-in present: does not re-enter itself');
    like($out, qr{\Q$p/usr/bin/pveproxy\E\s+start\z}, 'drop-in present: still finds the real command');
}

# ---------------------------------------------------------------------------
# Refusing outright
# ---------------------------------------------------------------------------

# The one case that is not fail-safe, because there is nothing safe to fall back
# to: if the drop-in names a daemon we do not wrap, there is no daemon for this
# wrapper to start. Failing here is a packaging bug, and it should be loud.

for my $bad ('pvestatd', 'bash', '../../bin/sh', '') {
    my $p = build_tree();
    my ($out, $err, $code) = run_exec($p, $bad);
    is($code, 64, "refuses '$bad': exits 64");
    is($out, '', "refuses '$bad': starts nothing at all");
    like($err, qr{is not a daemon proxmod wraps}, "refuses '$bad': says why");
}
