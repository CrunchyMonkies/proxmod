package Proxmod;

use strict;
use warnings;

our $VERSION = '0.2.1';

# The entry point, loaded by `perl -MProxmod` from the ExecStart drop-in that
# /usr/lib/proxmod/proxmod-exec installs for pvedaemon and pveproxy.
#
# Keep this file trivial and dependency-free. It is the single piece of proxmod
# that the daemons cannot start without: if it fails to compile, pvedaemon and
# pveproxy fail to start, and the host loses its API and its web interface. It
# must therefore compile under any Perl those daemons might run, using nothing
# but core, and it must not do any work of its own.
#
# All the work is in Proxmod::Boot, loaded at runtime inside an eval so that a
# broken, half-upgraded, or deleted Boot.pm costs an extension and not a host.
#
# WHY -M AND NOT PERL5LIB: both daemons are `#!/usr/bin/perl -T`. Taint mode
# ignores PERL5LIB and PERL5OPT, so the only way into a tainted daemon is a
# command-line -M, and this module has to live in a default @INC directory
# (/usr/share/perl5 on Debian).

INIT {
    # INIT, not compile time and not run time.
    #
    # `use Proxmod` is compiled first, before the daemon's own source, so at
    # compile time PVE::Service::pveproxy does not exist yet and there is
    # nothing to attach to. All INIT blocks then run after the whole program is
    # compiled but before the first statement executes — which is precisely the
    # window we need: PVE's classes are defined, but init() and run() have not
    # been called, so wrapping them still takes effect.
    local $@;

    my $ok = eval {
        require Proxmod::Boot;
        Proxmod::Boot::boot();
        1;
    };

    if (!$ok) {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+$//;
        $err =~ s/\s*\n\s*/ /g;

        # STDERR is the journal for these units. Report and carry on: dying
        # here would take the daemon with us, which is the one outcome proxmod
        # exists to avoid.
        print STDERR "proxmod: error: disabled, startup failed: $err\n";
    }
}

1;
