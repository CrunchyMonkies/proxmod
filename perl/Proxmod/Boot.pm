package Proxmod::Boot;

use strict;
use warnings;

use Proxmod::Log qw(log_debug log_info log_warn log_error);
use Proxmod::Registry;

our $VERSION = '0.2.0';

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

sub _run_stage {
    my ($name, $code) = @_;

    my $result;
    my $ok = eval {
        local $SIG{__DIE__} = 'DEFAULT';
        $result = $code->();
        1;
    };
    if (!$ok) {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+$//;
        log_error("$name failed, continuing without it: $err");
        return { loaded => 0, failed => 1 };
    }

    return ref($result) eq 'HASH' ? $result : { loaded => 0, failed => 0 };
}

# The optional argument names the daemon to pretend we are running inside; it
# exists so the unit tests can exercise every branch without a live PVE, and is
# not passed by Proxmod.pm.
sub boot {
    my ($daemon) = @_;

    if ($booted) {
        log_debug('boot() called twice, ignoring the second call');
        return;
    }
    $booted = 1;

    if (-e $DISABLED_FILE) {
        log_info("disabled by $DISABLED_FILE, loading nothing");
        return;
    }

    $daemon = daemon_name() if !defined $daemon;
    if (!Proxmod::Registry::is_known_daemon($daemon)) {
        # pvesh builds its own API tree, and a developer may well run
        # `perl -MProxmod` by hand. Neither is a context an extension author
        # tested against, so proxmod does nothing at all there.
        log_debug('not running inside a daemon proxmod extends ('
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

    my ($loaded, $failed) = (0, 0);

    # The frontend is pveproxy's business: it serves the UI. pvedaemon never
    # renders a page, so wrapping it there would be pure risk for no gain.
    if ($daemon eq 'pveproxy') {
        my $r = _run_stage('frontend injection', sub {
            require Proxmod::Frontend;
            return Proxmod::Frontend::install($exts);
        });
        $loaded += $r->{loaded};
        $failed += $r->{failed};
    }

    my @backend = grep { $_->{backend} && $_->{backend}{daemons}{$daemon} } @$exts;
    if (@backend) {
        my $r = _run_stage('backend registration', sub {
            require Proxmod::Backend;
            return Proxmod::Backend::install($daemon, \@backend);
        });
        $loaded += $r->{loaded};
        $failed += $r->{failed};
    }

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
