#!/usr/bin/perl -T

use strict;
use warnings;

use lib 't/lib';
use lib 'perl';

use Test::More;
use ProxmodTest qw(perl_bin);

# Every module has to compile under `perl -T`, because pvedaemon and pveproxy
# are `#!/usr/bin/perl -T` and a compile failure inside them is not a broken
# extension, it is a host with no API and no web interface.

# glob() reads the filesystem, so its results are tainted and cannot be passed
# to a subprocess. Untaint them the same way Proxmod::Registry untaints module
# names: match a strict pattern and keep the capture.
my @modules = map { m{\A([\w./-]+\.pm)\z} ? $1 : () } sort glob('perl/Proxmod/*.pm');
plan skip_all => 'run from the repository root' if !@modules;
plan tests => 2 * (@modules + 1) + 3 + 3 + 4 + 1;

my $perl = perl_bin();

sub compiles_ok {
    my ($file, @inc) = @_;
    my $out = qx{$perl -T @{[ map { "-I$_" } @inc ]} -c $file 2>&1};
    my $rc  = $?;
    is($rc, 0, "$file compiles under -T");
    like($out, qr/syntax OK/, "$file reports syntax OK")
        or diag($out);
    return;
}

# The shim is compiled with no -I at all. That is the real assertion here: it
# must have no compile-time dependency on anything outside core Perl, because
# it is the one file whose failure to compile stops the daemons from starting.
compiles_ok('perl/Proxmod.pm');

compiles_ok($_, 'perl', 't/lib') for @modules;

# `perl -c` runs BEGIN but not INIT, so the check above never executed boot().
# Confirm that, otherwise the assertion above is weaker than it looks.
{
    my $out = qx{$perl -c -e 'INIT { print "init-ran" } 1;' 2>&1};
    unlike($out, qr/init-ran/, 'perl -c does not run INIT blocks');
}

# Loading the modules for real, in-process, catches the runtime half: a `use` of
# something that is not installed, or a syntax error behind a conditional.
require_ok('Proxmod::Log');
require_ok('Proxmod::Registry');

# --- static invariants -------------------------------------------------------
#
# Three things must not appear anywhere in the code that runs inside a daemon.
# Each of them is a documented requirement whose violation is invisible at
# runtime until the exact circumstance that breaks it, so it is checked here
# rather than left to review.
#
# Comments are stripped before matching, because every one of these patterns is
# named in a comment explaining why it is absent - which is precisely the kind
# of note a later reader needs, and would otherwise fail its own test. The strip
# is naive (a `#` inside a string or regex truncates the line), so it can hide a
# violation on such a line; it cannot invent one.

sub code_lines {
    my ($file) = @_;
    open(my $fh, '<', $file) or return ();
    my @out;
    my $n = 0;
    while (defined(my $line = <$fh>)) {
        $n++;
        $line =~ s/#.*//;
        push(@out, [$n, $line]) if $line =~ /\S/;
    }
    close($fh);
    return @out;
}

my @sources = ('perl/Proxmod.pm', @modules);

sub forbidden_ok {
    my ($re, $why) = @_;
    my @hits;
    for my $file (@sources) {
        push(@hits, "$file:$_->[0]") for grep { $_->[1] =~ $re } code_lines($file);
    }
    is(scalar(@hits), 0, $why) or diag("found at: @hits");
    return;
}

# [REQ-FW-021] / [REQ-SEC-008]: a module name read off disk must never reach the
# compiler. Proxmod::Backend converts it to a path and requires that instead.
forbidden_ok(qr/eval\s*["']/, 'no eval of a string anywhere in the daemon code');

# [REQ-FE-010]: add_dirs walks the tree with File::Find, and under -T every path
# it produces is tainted. The static route is assigned as a literal instead.
forbidden_ok(qr/\badd_dirs\b/, 'the static route is never registered via add_dirs');

# [REQ-MF-016] / [PVE-F-040]: perl loads PerlIO::encoding lazily and treats that
# require as insecure under -T, so an :encoding layer cannot open a tainted path.
forbidden_ok(qr/:encoding\(/, 'no :encoding layer on a path that came from disk');

# [REQ-FW-031]: every entry point PVE calls into is wrapped in an eval whose
# __DIE__ handler is localised to DEFAULT, so that a PVE or extension handler
# cannot turn proxmod's contained failure into an uncontained one.
for my $file (qw(Boot Backend Frontend API)) {
    my @hits = grep { $_->[1] =~ /local\s+\$SIG\{__DIE__\}\s*=\s*'DEFAULT'/ }
        code_lines("perl/Proxmod/$file.pm");
    ok(scalar(@hits) > 0, "Proxmod::$file localises \$SIG{__DIE__} around its eval");
}

subtest 'inside a daemon a log line goes to syslog, not to a dead stderr' => sub {
    plan tests => 5;

    require PVE::SafeSyslog;
    require Proxmod::Log;

    PVE::SafeSyslog::_reset();

    # PVE::Daemon reopens STDOUT on /dev/null and STDERR onto STDOUT once the
    # daemon detaches (Daemon.pm:313-337), so stderr from a request handler is
    # discarded. proxmod logged there anyway, which cost pool-quota every
    # refusal line in production while the suite and the CLI both looked fine.
    my $stderr = '';
    {
        local $Proxmod::Log::SYSLOG = 1;
        local $Proxmod::Log::FH;                 # no capture handle: the real path
        local *STDERR;
        open(STDERR, '>', \$stderr) or die;
        Proxmod::Log::log_warn('a refusal nobody would have seen');
    }

    is(scalar @PVE::SafeSyslog::CALLS, 1, 'the line went to syslog');
    is($stderr, '', 'and not to the stderr that is /dev/null in production');

    my $call = $PVE::SafeSyslog::CALLS[0];
    is($call->{priority}, 'warning', 'at a priority syslog understands');
    like($call->{rendered}, qr/\Aproxmod: warn: a refusal nobody/,
        'keeping the prefix proxmod-verify greps for');

    # Sys::Syslog treats its second argument as a format string, and these lines
    # carry text an operator typed — a pool comment with a % in it would mangle
    # the entry or worse.
    PVE::SafeSyslog::_reset();
    {
        local $Proxmod::Log::SYSLOG = 1;
        local $Proxmod::Log::FH;
        Proxmod::Log::log_warn('pool comment: 100%s of nothing %n');
    }
    is($PVE::SafeSyslog::CALLS[0]->{format}, '%s',
        'the message is an argument, never the format');
};
