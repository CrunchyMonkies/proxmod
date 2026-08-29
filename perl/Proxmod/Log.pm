package Proxmod::Log;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(log_debug log_info log_warn log_error);

our $VERSION = '0.4.0';

# Logging for code running inside pvedaemon and pveproxy.
#
# `journalctl -u pveproxy` is the one place an administrator has to look, and
# there are two different ways of getting there depending on when we are.
#
# BEFORE the daemon detaches — the INIT phase, which is where registration
# happens — systemd still owns the process's stderr, so writing there lands in
# the journal.
#
# AFTER it detaches, it does not. PVE::Daemon reopens STDOUT on /dev/null and
# then STDERR onto STDOUT (`Daemon.pm:313-337`), so both are /dev/null for the
# master and every worker it forks. Anything written to stderr from a request
# handler is discarded — silently, and only in production, because a test
# harness and a CLI both still have a real stderr. That cost pool-quota its
# refusal log: the wrap fired, the caller got a 403, and the journal said
# nothing at all.
#
# So inside a daemon we use syslog, which PVE has already opened for us with the
# right tag and facility (`Daemon.pm:244` calls initlog). Proxmod::Boot sets
# $SYSLOG when it installs; CLI tools never do, and keep their stderr.
#
# Every line is prefixed "proxmod:". That prefix is contract, not decoration —
# proxmod-verify decides whether the live daemon actually loaded us by grepping
# the journal for it since the unit's last start. Do not change it without
# changing bin/proxmod-verify.
#
# This module deliberately has no dependencies beyond core Perl and does not use
# Proxmod::Registry, because everything else logs — including the code that
# reads the registry. It parses the one setting it needs out of proxmod.conf
# itself rather than pulling in a config layer.

our $PREFIX = 'proxmod';

# Overridable so the unit tests can point at a fixture instead of /etc.
our $CONF_FILE = '/etc/proxmod/proxmod.conf';

# Where output goes. Tests localise this to an in-memory handle to capture it,
# and it wins over everything below.
our $FH;

# Set by Proxmod::Boot inside pvedaemon and pveproxy. Off everywhere else, so
# proxmod-verify and proxmodctl still talk to the terminal they were run from.
our $SYSLOG = 0;

my %SYSLOG_LEVEL = (
    debug => 'debug',
    info => 'info',
    warn => 'warning',
    error => 'err',
);

my $debug_cached;

sub _truthy {
    my ($v) = @_;
    return 0 if !defined $v;
    return $v =~ /^\s*(?:1|y|yes|on|true)\s*$/i ? 1 : 0;
}

sub _debug_enabled {
    return $debug_cached if defined $debug_cached;
    $debug_cached = 0;

    # pvedaemon clears its environment before running, so an env var alone is
    # not reachable from a normal systemd start — that is the trap pve-gpu-
    # manager hit with PVE_GPU_SYSFS_ROOT. The config file is the switch that
    # actually works in production; the env var only helps when you run a
    # daemon by hand.
    $debug_cached = 1 if _truthy($ENV{PROXMOD_DEBUG});

    if (open(my $fh, '<', $CONF_FILE)) {
        while (my $line = <$fh>) {
            next if $line =~ /^\s*(?:#|$)/;
            $debug_cached = _truthy($1) if $line =~ /^\s*debug\s*=\s*(\S+)/;
        }
        close($fh);
    }

    return $debug_cached;
}

# Only for the tests: forget what we decided about the debug flag.
sub _reset_cache { $debug_cached = undef; return; }

sub _emit {
    my ($level, @parts) = @_;

    my $msg = join('', map { defined($_) ? $_ : '<undef>' } @parts);

    # A message containing a newline would produce a journal line without our
    # prefix, which proxmod-verify would not see and an administrator would not
    # associate with proxmod. Collapse instead.
    $msg =~ s/\s*\n\s*/ /g;
    $msg =~ s/\s+$//;

    my $line = $level eq 'info' ? "$PREFIX: $msg\n" : "$PREFIX: $level: $msg\n";

    if ($FH) {
        print {$FH} $line;
        return;
    }

    return if $SYSLOG && _syslog($level, $line);

    print {\*STDERR} $line;

    return;
}

# Returns true if the line was handed to syslog.
sub _syslog {
    my ($level, $line) = @_;

    my $priority = $SYSLOG_LEVEL{$level} || 'info';

    chomp(my $msg = $line);

    return eval {
        local $SIG{__DIE__} = 'DEFAULT';

        require PVE::SafeSyslog;

        # '%s' and not $msg: Sys::Syslog treats the second argument as a format
        # string, and these lines carry text an operator typed — a pool comment
        # with a % in it would mangle the entry or worse.
        PVE::SafeSyslog::syslog($priority, '%s', $msg);

        1;
    } ? 1 : 0;
}

sub log_debug { _emit('debug', @_) if _debug_enabled(); return }
sub log_info  { _emit('info',  @_); return }
sub log_warn  { _emit('warn',  @_); return }
sub log_error { _emit('error', @_); return }

1;
