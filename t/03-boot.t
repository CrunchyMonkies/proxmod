#!/usr/bin/perl -T

use strict;
use warnings;

use lib 't/lib';
use lib 'perl';

use Test::More tests => 44;
use ProxmodTest qw(tempdir write_file capture_log);

use Proxmod::Boot;
use Proxmod::Registry;

# Boot is the piece that decides what happens inside a running pvedaemon or
# pveproxy. Its whole job is to contain damage, so most of what follows is about
# what it does when something is broken.

# Proxmod::Frontend and Proxmod::Backend are stubbed through %INC. Boot reaches
# them with `require`, which is a no-op once %INC has the key, so this keeps the
# test focused on Boot's own control flow — and keeps working unchanged once the
# real modules exist.
my (@frontend_calls, @backend_calls);
my ($frontend_result, $backend_result);

BEGIN {
    $INC{'Proxmod/Frontend.pm'} = __FILE__;
    $INC{'Proxmod/Backend.pm'}  = __FILE__;
}

sub Proxmod::Frontend::install {
    push @frontend_calls, [@_];
    return ref($frontend_result) eq 'CODE' ? $frontend_result->(@_) : $frontend_result;
}

sub Proxmod::Backend::install {
    push @backend_calls, [@_];
    return ref($backend_result) eq 'CODE' ? $backend_result->(@_) : $backend_result;
}

# The real stages answer with the ids of the extensions they brought up, so the
# stubs have to as well: a fixed answer would not exercise the union boot() does
# and would hide the case this whole file is careful about, an extension that is
# in both answers at once.
sub frontend_loads_everything {
    my ($exts) = @_;
    my @wanted = grep { $_->{frontend} && @{ $_->{frontend}{assets} || [] } } @$exts;
    return { loaded => [ map { $_->{id} } @wanted ], failed => [] };
}

sub backend_loads_everything {
    my ($daemon, $exts) = @_;
    return { loaded => [ map { $_->{id} } @$exts ], failed => [] };
}

my $root = tempdir();

# Run boot() in a controlled world: a fresh boot guard, an extension registry we
# supply, and a kill-switch path that does not exist unless a test creates it.
# What boot() left $Proxmod::Log::SYSLOG at, for the block at the end.
my $syslog_after;

sub run_boot {
    my ($daemon, %opt) = @_;

    @frontend_calls = @backend_calls = ();
    $frontend_result = $opt{frontend_result} // \&frontend_loads_everything;
    $backend_result  = $opt{backend_result}  // \&backend_loads_everything;

    my $dir = "$root/ext-" . (($opt{tag} // 'x'));
    mkdir $dir;
    for my $name (sort keys %{ $opt{manifests} || {} }) {
        write_file("$dir/$name", $opt{manifests}{$name});
    }

    Proxmod::Boot::_reset();

    # boot() sets $Proxmod::Log::SYSLOG as a side effect and does not localise
    # it, so the harness has to, or one case's answer becomes the next one's
    # starting point.
    local $Proxmod::Log::SYSLOG = 0;

    my (undef, $log) = capture_log(sub {
        local $Proxmod::Boot::DISABLED_FILE = $opt{disabled_file} // "$root/no-such-kill-switch";
        local @Proxmod::Registry::EXT_DIRS = ($dir);
        Proxmod::Boot::boot($daemon);
        return 1;
    });

    $syslog_after = $Proxmod::Log::SYSLOG;

    return $log;
}

my $HELLO = '{"id":"hello","backend":{"module":"Acme::Hello"},"frontend":{"assets":["hello.js"]}}';

# --- which daemon are we in? ---------------------------------------------

is(Proxmod::Boot::daemon_name('/usr/bin/pveproxy'), 'pveproxy', 'daemon name from an absolute path');
is(Proxmod::Boot::daemon_name('pvedaemon'), 'pvedaemon', 'daemon name from a bare name');
is(Proxmod::Boot::daemon_name('/usr/bin/pvestatd'), 'pvestatd', 'daemon name for an unsupported daemon');
is(Proxmod::Boot::daemon_name('/usr/bin/PVEProxy'), undef, 'a name outside the expected shape is refused');
is(Proxmod::Boot::daemon_name('/usr/bin/pve proxy'), undef, 'a name with a space is refused');
is(Proxmod::Boot::daemon_name(''), undef, 'an empty $0 is refused');

# --- the happy path -------------------------------------------------------

{
    my $log = run_boot('pveproxy', tag => 'happy', manifests => { '50-hello.conf' => $HELLO });

    # The field is named extensions=, and hello is one extension. It declares
    # both a frontend and a backend half and pveproxy runs both of them, which
    # is precisely the case that used to be reported as two.
    like($log, qr/^proxmod: booted daemon=pveproxy extensions=1 failed=0 registry=[0-9a-f]{12}$/m,
        'an extension running both of its halves is counted once, not once per stage');
    is(scalar(@frontend_calls), 1, 'the frontend is installed in pveproxy');
    is(scalar(@backend_calls), 1, 'the backend is installed in pveproxy');
    is(scalar(@{ $backend_calls[0][1] }), 1, 'the matching extension is passed to the backend');
    is($backend_calls[0][0], 'pveproxy', 'the backend is told which daemon it is in');
}

{
    my $log = run_boot('pvedaemon', tag => 'daemon', manifests => { '50-hello.conf' => $HELLO });

    like($log, qr/^proxmod: booted daemon=pvedaemon extensions=1 failed=0 registry=[0-9a-f]{12}$/m,
        'and pvedaemon, running only its backend half, reports the same one');
    # pvedaemon never renders a page. Wrapping the UI seam there would be pure
    # risk for no benefit.
    is(scalar(@frontend_calls), 0, 'the frontend is not installed in pvedaemon');
    is(scalar(@backend_calls), 1, 'the backend is installed in pvedaemon');
}

# An extension that names only one daemon must not be handed to the other.
{
    my $log = run_boot('pveproxy', tag => 'picky', manifests => {
        '50-picky.conf' => '{"id":"picky","backend":{"module":"A::P","daemons":["pvedaemon"]}}',
    });
    is(scalar(@backend_calls), 0, 'an extension scoped to pvedaemon is skipped in pveproxy');
    like($log, qr/^proxmod: booted daemon=pveproxy /m, 'and boot still completes');
}

# A frontend-only extension needs no backend stage at all — which is what makes
# it installable without restarting anything.
{
    run_boot('pveproxy', tag => 'feonly', manifests => {
        '50-fe.conf' => '{"id":"fe","frontend":{"assets":["fe.js"]}}',
    });
    is(scalar(@backend_calls), 0, 'a frontend-only extension does not invoke the backend stage');
    is(scalar(@frontend_calls), 1, 'but it is passed to the frontend stage');
}

# The two numbers are a partition: every extension this daemon is responsible
# for lands in exactly one of them, so extensions= + failed= is the count of
# extensions applicable here. Two extensions, one declaring both halves and one
# backend-only, and the backend-only one fails to register.
{
    my $log = run_boot('pveproxy', tag => 'mixed',
        manifests => {
            '50-hello.conf' => $HELLO,
            '51-beonly.conf' => '{"id":"beonly","backend":{"module":"Acme::Be"}}',
        },
        backend_result => sub {
            my ($daemon, $exts) = @_;
            my @ids = map { $_->{id} } @$exts;
            return {
                loaded => [ grep { $_ ne 'beonly' } @ids ],
                failed => [ grep { $_ eq 'beonly' } @ids ],
            };
        },
    );

    like($log, qr/^proxmod: booted daemon=pveproxy extensions=1 failed=1 registry=[0-9a-f]{12}$/m,
        'two extensions, one of them broken, are reported as one and one');
}

# --- the kill switch ------------------------------------------------------

{
    my $kill = write_file("$root/disabled", '');
    my $log = run_boot('pveproxy', tag => 'kill', disabled_file => $kill,
        manifests => { '50-hello.conf' => $HELLO });

    like($log, qr/disabled by \Q$kill\E, loading nothing/, 'the kill switch is reported');
    unlike($log, qr/booted/, 'and nothing claims to have booted');
    is(scalar(@frontend_calls) + scalar(@backend_calls), 0, 'and no stage runs');
}

# --- containment ----------------------------------------------------------

# The property the whole design rests on: a stage that dies costs that stage.
{
    my $log = run_boot('pveproxy', tag => 'febang',
        manifests      => { '50-hello.conf' => $HELLO },
        frontend_result => sub { die "frontend exploded\n" },
    );

    like($log, qr/^proxmod: error: frontend injection failed, continuing without it: frontend exploded$/m,
        'a frontend failure is reported');
    # The backend half did register — @backend_calls below says so — but hello
    # is one extension and half of it is missing. Reporting it as both loaded
    # and failed is what summing the stages did; the administrator reading this
    # is asking whether anything needs looking at, and the answer is yes.
    like($log, qr/^proxmod: booted daemon=pveproxy extensions=0 failed=1 registry=[0-9a-f]{12}$/m,
        'an extension that lost one half is counted once, as failed');
    is(scalar(@backend_calls), 1, 'the backend stage still ran');
}

{
    my $log = run_boot('pvedaemon', tag => 'bebang',
        manifests     => { '50-hello.conf' => $HELLO },
        backend_result => sub { die "backend exploded\n" },
    );
    like($log, qr/^proxmod: error: backend registration failed, continuing without it: backend exploded$/m,
        'a backend failure is reported');
    like($log, qr/^proxmod: booted daemon=pvedaemon extensions=0 failed=1 registry=[0-9a-f]{12}$/m,
        'and boot still completes');
}

# An unrecognised host — pvesh, or a developer running perl -MProxmod by hand —
# gets nothing. Extensions declare the daemons they support; guessing on their
# behalf would run them somewhere nobody tested.
{
    my $log = run_boot('bash', tag => 'unknown', manifests => { '50-hello.conf' => $HELLO });
    unlike($log, qr/booted/, 'an unrecognised host boots nothing');
    is(scalar(@frontend_calls) + scalar(@backend_calls), 0, 'and runs no stage');
}

# If the registry itself cannot be read there is nothing to load, but the daemon
# must still come up.
{
    Proxmod::Boot::_reset();
    my (undef, $log) = capture_log(sub {
        local $Proxmod::Boot::DISABLED_FILE = "$root/no-such-kill-switch";
        no warnings 'redefine';
        local *Proxmod::Registry::load = sub { die "registry on fire\n" };
        Proxmod::Boot::boot('pveproxy');
        return 1;
    });
    like($log, qr/^proxmod: error: could not read the extension registry, loading nothing: registry on fire$/m,
        'a broken registry is reported');
    unlike($log, qr/booted/, 'and boot stops there');
}

# --- booting twice --------------------------------------------------------

# dpkg triggers and systemd reloads both make a double load plausible, and a
# second registration pass would hit PVE::RESTHandler's die-on-duplicate-path.
{
    Proxmod::Boot::_reset();
    @frontend_calls = @backend_calls = ();
    $frontend_result = \&frontend_loads_everything;
    $backend_result  = \&backend_loads_everything;

    my $dir = "$root/ext-twice";
    mkdir $dir;
    write_file("$dir/50-hello.conf", $HELLO);

    my (undef, $log) = capture_log(sub {
        local $Proxmod::Boot::DISABLED_FILE = "$root/no-such-kill-switch";
        local @Proxmod::Registry::EXT_DIRS = ($dir);
        Proxmod::Boot::boot('pveproxy');
        Proxmod::Boot::boot('pveproxy');
        return 1;
    });

    my @booted = ($log =~ /^proxmod: booted /mg);
    is(scalar(@booted), 1, 'boot() runs its work exactly once');
    is(scalar(@frontend_calls), 1, 'the frontend is not installed twice');
    is(scalar(@backend_calls), 1, 'the backend is not registered twice');
}

# --- the command-line tools -----------------------------------------------

# A CLI dispatches to the same PVE::API2 classes a daemon does, in its own
# process, so an extension that wraps an API method has the same seam there —
# and a `qm create` from a root shell goes through the same code a create from
# the web interface does. What differs is that proxmod only reaches a CLI
# because an operator enabled a patch (ADR 0013), so nothing loads there unless
# the extension asked for it by name.

my $CLI_EXT = '{"id":"cli","backend":{"module":"Acme::Hello",'
    . '"daemons":["pvedaemon","qm"]},"frontend":{"assets":["hello.js"]}}';

{
    my $log = run_boot('qm', tag => 'cli', manifests => { '50-cli.conf' => $CLI_EXT });

    like($log, qr/^proxmod: booted daemon=qm extensions=1 failed=0 registry=[0-9a-f]{12}$/m,
        'proxmod loads inside a command-line tool that an extension named');
    is(scalar(@backend_calls), 1, 'the backend stage runs there');
    is($backend_calls[0][0], 'qm', 'and is told which host it is in');

    # A CLI renders no pages. Running the UI seam there would be pure risk for
    # no gain, exactly as in pvedaemon.
    is(scalar(@frontend_calls), 0, 'the frontend stage does not');
}

{
    # The default has to hold: $HELLO names no daemons, so it must not appear
    # in a CLI even though it would in both daemons.
    my $log = run_boot('qm', tag => 'cli-default', manifests => { '50-hello.conf' => $HELLO });

    like($log, qr/^proxmod: booted daemon=qm extensions=0 failed=0 registry=[0-9a-f]{12}$/m,
        'an extension that did not name a CLI is not loaded into one');
}

{
    my $log = run_boot('rsync', tag => 'stranger', manifests => { '50-cli.conf' => $CLI_EXT });

    # Asserted by what did not happen rather than by the log line, which is a
    # debug one: proxmod ran no stage at all, which is the property that
    # matters to a program that merely happened to load us.
    is(scalar(@backend_calls) + scalar(@frontend_calls), 0,
        'a program that merely loaded us gets nothing at all');
    unlike($log, qr/booted/, 'and does not even report having booted');
}

# --- where log output goes ------------------------------------------------

# PVE::Daemon reopens stderr on /dev/null once it detaches (Daemon.pm:313-337),
# so a daemon's output has to go to syslog or it goes nowhere. A CLI has a real
# terminal and its output belongs there — and since proxmod is only in a CLI
# because somebody patched it in, taking over `qm`'s stderr would be a rude way
# to repay that.
{
    run_boot('pvedaemon', tag => 'sl-daemon', manifests => { '50-hello.conf' => $HELLO });
    is($syslog_after, 1, 'pvedaemon logs to syslog');

    run_boot('qm', tag => 'sl-cli', manifests => { '50-cli.conf' => $CLI_EXT });
    is($syslog_after, 0, 'a CLI keeps the terminal it was run from');

    run_boot('rsync', tag => 'sl-stranger');
    is($syslog_after, 0, 'and so does anything else that loaded us');
}
