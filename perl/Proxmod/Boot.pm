package Proxmod::Boot;

use strict;
use warnings;

use Proxmod::Log qw(log_debug log_info log_warn log_error);
use Proxmod::Registry;

our $VERSION = '0.4.0';

# Everything proxmod does at daemon startup, in one place.
#
# Called from Proxmod.pm's INIT block, which the ExecStart wrapper arranges by
# starting pvedaemon/pveproxy with `-MProxmod`. By the time we run, the daemon's
# own modules are compiled — so PVE::Service::pveproxy exists and can be wrapped
# — but its init() and run() have not been called yet.
#
# THE PRIME DIRECTIVE: a missing extension is acceptable, a dead pvedaemon or
# pveproxy is not. Nothing in this file, or anything it calls, may propagate an
# exception. Each stage and each individual extension runs inside its own eval,
# so one broken extension costs exactly itself.

# Presence of this file stops proxmod loading anything. proxmod-exec checks it
# too and skips the injection entirely; this second check covers the case where
# the module was loaded some other way.
our $DISABLED_FILE = '/etc/proxmod/disabled';

# The one line proxmod-verify greps the journal for. Changing it is a contract
# change — see bin/proxmod-verify.
our $BOOTED_MARKER = 'booted';

my $booted = 0;

# Which daemon are we inside? $0 is tainted under -T; we never use it as a path,
# but matching it to a capture keeps that true by construction if someone later
# does. An unrecognised host (pvesh, a developer's one-off perl -MProxmod) loads
# nothing: extensions declare the daemons they support, and guessing on their
# behalf is how you get a surprise in a context nobody tested.
sub daemon_name {
    my ($argv0) = @_;
    $argv0 = $0 if !defined $argv0;

    my ($base) = ($argv0 =~ m{([^/]+)\z});
    return undef if !defined $base;

    my ($clean) = ($base =~ m{\A([a-z][a-z0-9_-]{0,31})\z});
    return $clean;
}

# Runs one stage, contains what it does to itself, and answers in the vocabulary
# boot() counts in: which extensions came up, and which did not.
#
# @applicable is what this stage was responsible for. It is used only when the
# stage does not answer — because it died, or because it answered in a shape
# this does not recognise. Neither case leaves anything running, and neither
# leaves boot() any other way to find out which extensions were affected.
sub _run_stage {
    my ($name, $applicable, $code) = @_;

    my $result;
    my $ok = eval {
        local $SIG{__DIE__} = 'DEFAULT';
        $result = $code->();
        1;
    };

    my @ids = map { defined $_->{id} ? $_->{id} : '<unnamed>' } @$applicable;

    if (!$ok) {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+$//;
        log_error("$name failed, continuing without it: $err");
        return { loaded => [], failed => \@ids };
    }

    if (   ref($result) ne 'HASH'
        || ref($result->{loaded}) ne 'ARRAY'
        || ref($result->{failed}) ne 'ARRAY')
    {
        log_error("$name returned nothing usable, counting its extensions as"
            . ' not loaded');
        return { loaded => [], failed => \@ids };
    }

    return $result;
}

# The optional argument names the daemon to pretend we are running inside; it
# exists so the unit tests can exercise every branch without a live PVE, and is
# not passed by Proxmod.pm.
sub boot {
    my ($daemon) = @_;

    $daemon = daemon_name() if !defined $daemon;

    # Syslog if and only if this is a DETACHING DAEMON, and the distinction is
    # load-bearing in both directions.
    #
    # PVE::Daemon reopens stderr on /dev/null once it detaches
    # (Daemon.pm:313-337), so anything a daemon logs after boot goes nowhere
    # unless it goes to syslog. A command-line tool has a real terminal and its
    # output belongs on it — and since a CLI only loads proxmod when an operator
    # patched it in, hijacking `qm`'s stderr would be a rude way to repay that.
    # Somebody running `perl -MProxmod -e1` by hand is in the same position.
    $Proxmod::Log::SYSLOG = 1 if Proxmod::Registry::is_known_daemon($daemon);

    if ($booted) {
        log_debug('boot() called twice, ignoring the second call');
        return;
    }
    $booted = 1;

    if (-e $DISABLED_FILE) {
        log_info("disabled by $DISABLED_FILE, loading nothing");
        return;
    }

    if (!Proxmod::Registry::is_known_host($daemon)) {
        # A developer running `perl -MProxmod` by hand, or any program that
        # happens to load us. Not a context an extension author tested against,
        # so proxmod does nothing at all there.
        log_debug('not running inside a host proxmod extends ('
            . ($daemon // 'unknown') . '), loading nothing');
        return;
    }

    my $exts = [];
    my $ok = eval {
        local $SIG{__DIE__} = 'DEFAULT';
        $exts = Proxmod::Registry::load();
        1;
    };
    if (!$ok) {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+$//;
        log_error("could not read the extension registry, loading nothing: $err");
        return;
    }

    # Counted per extension, never per stage. An extension declaring both a
    # frontend and a backend half is one extension, and pveproxy runs both of
    # its halves — summing the two stages reported it twice, and the field is
    # named extensions=. %applicable is every extension this daemon was
    # responsible for; %failed is those that did not fully come up.
    my (%applicable, %failed);
    my $account = sub {
        my ($r) = @_;
        $applicable{$_} = 1 for @{ $r->{loaded} }, @{ $r->{failed} };
        $failed{$_}     = 1 for @{ $r->{failed} };
        return;
    };

    # The frontend is pveproxy's business: it serves the UI. pvedaemon never
    # renders a page and neither does a command-line tool, so wrapping either
    # would be pure risk for no gain.
    if ($daemon eq 'pveproxy') {
        # The same predicate Frontend::install greps on, carried here rather
        # than asked of it. The one case that needs this list is the case where
        # Proxmod::Frontend could not be loaded at all, so it cannot be the
        # thing that answers. t/13-invariants.t keeps the copies in step.
        my @frontend = grep { $_->{frontend} && @{ $_->{frontend}{assets} || [] } } @$exts;
        $account->(_run_stage('frontend injection', \@frontend, sub {
            require Proxmod::Frontend;
            return Proxmod::Frontend::install($exts);
        }));
    }

    my @backend = grep { $_->{backend} && $_->{backend}{daemons}{$daemon} } @$exts;
    if (@backend) {
        $account->(_run_stage('backend registration', \@backend, sub {
            require Proxmod::Backend;
            return Proxmod::Backend::install($daemon, \@backend);
        }));
    }

    # An extension is loaded only if every stage it was applicable to brought it
    # up. Half an extension is not a working extension, and the administrator
    # reading failed= is asking whether anything needs looking at.
    my $failed = scalar keys %failed;
    my $loaded = scalar grep { !$failed{$_} } keys %applicable;

    # The fingerprint of the registry this process actually loaded. It is what
    # lets proxmod-verify tell "running" from "running the current registry",
    # and so what lets proxmod-reapply know an installed extension has not gone
    # live yet. Appended to the end of the line, never inserted: the existing
    # extensions=/failed= parsing has to keep working against a daemon that has
    # been up since before this field existed.
    #
    # Guarded, and last: a fingerprint we could not compute is worth losing.
    # Killing a hypervisor daemon over a digest is not.
    my $fp = eval {
        local $SIG{__DIE__} = 'DEFAULT';
        Proxmod::Registry::fingerprint($exts);
    };
    if (!defined $fp) {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+$//;
        log_warn("could not compute the registry fingerprint: $err");
    }

    # This line is the signal. proxmod-verify treats the *live* journal since
    # the unit's last start as the source of truth about whether proxmod is
    # actually running, rather than asking a fresh perl whether it could — the
    # distinction is exactly the one that let a comparable tool ship a verify
    # that passed while its endpoint had never loaded.
    log_info("$BOOTED_MARKER daemon=$daemon extensions=$loaded failed=$failed"
        . (defined $fp ? " registry=$fp" : ''));

    return;
}

# Only for the tests.
sub _reset { $booted = 0; return }

1;
