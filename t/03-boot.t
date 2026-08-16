#!/usr/bin/perl -T

use strict;
use warnings;

use lib 't/lib';
use lib 'perl';

use Test::More tests => 33;
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
    return ref($frontend_result) eq 'CODE' ? $frontend_result->() : $frontend_result;
}

sub Proxmod::Backend::install {
    push @backend_calls, [@_];
    return ref($backend_result) eq 'CODE' ? $backend_result->() : $backend_result;
}

my $root = tempdir();

# Run boot() in a controlled world: a fresh boot guard, an extension registry we
# supply, and a kill-switch path that does not exist unless a test creates it.
sub run_boot {
    my ($daemon, %opt) = @_;

    @frontend_calls = @backend_calls = ();
    $frontend_result = $opt{frontend_result} // { loaded => 1, failed => 0 };
    $backend_result  = $opt{backend_result}  // { loaded => 1, failed => 0 };

    my $dir = "$root/ext-" . (($opt{tag} // 'x'));
    mkdir $dir;
    for my $name (sort keys %{ $opt{manifests} || {} }) {
        write_file("$dir/$name", $opt{manifests}{$name});
    }

    Proxmod::Boot::_reset();

    my (undef, $log) = capture_log(sub {
        local $Proxmod::Boot::DISABLED_FILE = $opt{disabled_file} // "$root/no-such-kill-switch";
        local @Proxmod::Registry::EXT_DIRS = ($dir);
        Proxmod::Boot::boot($daemon);
        return 1;
    });

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

    like($log, qr/^proxmod: booted daemon=pveproxy extensions=2 failed=0 registry=[0-9a-f]{12}$/m,
        'pveproxy reports both stages loaded');
    is(scalar(@frontend_calls), 1, 'the frontend is installed in pveproxy');
    is(scalar(@backend_calls), 1, 'the backend is installed in pveproxy');
    is(scalar(@{ $backend_calls[0][1] }), 1, 'the matching extension is passed to the backend');
    is($backend_calls[0][0], 'pveproxy', 'the backend is told which daemon it is in');
}

{
    my $log = run_boot('pvedaemon', tag => 'daemon', manifests => { '50-hello.conf' => $HELLO });

    like($log, qr/^proxmod: booted daemon=pvedaemon extensions=1 failed=0 registry=[0-9a-f]{12}$/m,
        'pvedaemon reports one stage loaded');
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
    like($log, qr/^proxmod: booted daemon=pveproxy extensions=1 failed=1 registry=[0-9a-f]{12}$/m,
        'the backend still loads and the failure is counted');
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
    $frontend_result = $backend_result = { loaded => 1, failed => 0 };

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
