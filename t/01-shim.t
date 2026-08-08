#!/usr/bin/perl -T

use strict;
use warnings;

use lib 't/lib';

use Test::More tests => 18;
use File::Copy ();
use ProxmodTest qw(tempdir write_file perl_bin);

# The fail-safe contract, tested the only way that means anything: by actually
# starting a Perl process the way the ExecStart wrapper starts pveproxy, with a
# deliberately broken Proxmod::Boot, and checking the process still runs.
#
# "The daemon survives" is proxmod's prime directive. If this file fails,
# nothing else about the framework matters.

my $perl = perl_bin();

# Each scenario gets its own @INC root containing a verbatim copy of the real
# shim plus whichever Proxmod::Boot we want to inflict on it. Copying rather
# than adding perl/ to @INC means the "Boot.pm is missing entirely" case is
# genuinely missing, not merely shadowed.
sub scenario {
    my ($boot_source) = @_;

    my $root = tempdir();
    mkdir "$root/Proxmod" or die "mkdir: $!";
    File::Copy::copy('perl/Proxmod.pm', "$root/Proxmod.pm")
        or die "cannot copy the shim: $!";
    write_file("$root/Proxmod/Boot.pm", $boot_source) if defined $boot_source;

    my $errfile = "$root/stderr";
    my $stdout  = qx{$perl -T -I$root -MProxmod -e 'print "ALIVE\n"' 2>$errfile};
    my $status  = $?;

    open(my $fh, '<', $errfile) or die "cannot read captured stderr: $!";
    my $stderr = do { local $/; <$fh> };
    close($fh);

    return ($stdout, $stderr, $status);
}

sub survives_ok {
    my ($name, $boot_source, $stderr_check) = @_;

    my ($stdout, $stderr, $status) = scenario($boot_source);

    is($status, 0, "$name: process exits 0");
    is($stdout, "ALIVE\n", "$name: the host program still ran");
    $stderr_check->($stderr, $name);

    return;
}

my $BOOT_OK = <<'PERL';
package Proxmod::Boot;
use strict; use warnings;
sub boot { print STDERR "proxmod: booted daemon=test extensions=0 failed=0\n"; return }
1;
PERL

survives_ok('healthy boot', $BOOT_OK, sub {
    my ($stderr, $name) = @_;
    like($stderr, qr/^proxmod: booted /m, "$name: the booted marker is emitted");
    unlike($stderr, qr/disabled/, "$name: nothing reports a failure");
});

survives_ok('boot() dies', <<'PERL', sub {
package Proxmod::Boot;
use strict; use warnings;
sub boot { die "kaboom\n" }
1;
PERL
    my ($stderr, $name) = @_;
    like($stderr, qr/^proxmod: error: disabled, startup failed: kaboom$/m,
        "$name: reports the failure on one prefixed line");
    unlike($stderr, qr/^proxmod: booted /m, "$name: does not claim to have booted");
});

survives_ok('Boot.pm does not compile', <<'PERL', sub {
package Proxmod::Boot;
this is not perl (((
PERL
    my ($stderr, $name) = @_;
    like($stderr, qr/^proxmod: error: disabled, startup failed: /m,
        "$name: reports the compile failure");
});

survives_ok('Boot.pm is missing entirely', undef, sub {
    my ($stderr, $name) = @_;
    like($stderr, qr/^proxmod: error: disabled, startup failed: .*Boot\.pm/m,
        "$name: names the module it could not find");
});

# A die() with embedded newlines must not produce journal lines lacking the
# "proxmod:" prefix — proxmod-verify greps for that prefix, and an unprefixed
# line is one an administrator would never connect to proxmod.
survives_ok('boot() dies with a multi-line message', <<'PERL', sub {
package Proxmod::Boot;
use strict; use warnings;
sub boot { die "first line\nsecond line\nthird line\n" }
1;
PERL
    my ($stderr, $name) = @_;
    my @lines = grep { /\S/ } split /\n/, $stderr;
    is(scalar(@lines), 1, "$name: collapses to a single journal line");
    like($lines[0] // '', qr/^proxmod: error: .*first line second line third line/,
        "$name: keeps the whole message on that line");
});
