package PVE::SafeSyslog;

use strict;
use warnings;

# STUB. Enough of PVE's syslog wrapper to prove where a log line goes.
#
# The real one calls Sys::Syslog::syslog and swallows errors, against a syslog
# PVE::Daemon has already opened (Daemon.pm:244, initlog). What matters here is
# the call shape: syslog($priority, $format, @args), where the SECOND argument
# is a format string — which is why Proxmod::Log passes '%s' and the message
# separately rather than interpolating.

our @CALLS;

sub _reset { @CALLS = (); return }

sub syslog {
    my ($priority, $format, @args) = @_;

    push @CALLS, {
        priority => $priority,
        format => $format,
        args => [@args],
        rendered => sprintf($format, @args),
    };

    return;
}

1;
