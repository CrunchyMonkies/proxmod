package Proxmod::Registry;

use strict;
use warnings;

use Proxmod::Log qw(log_debug log_warn);

# Loaded at compile time, not with a runtime require, so that a missing or
# broken JSON::PP surfaces while Proxmod::Boot is loading us inside its eval
# rather than part-way through reading the registry.
use JSON::PP ();

our $VERSION = '0.2.2';

# The extension registry: which extensions exist, and in what order they load.
#
# Manifests are drop-in files, read from two directories:
#
#   /usr/share/proxmod/extensions.d/   package-owned; an extension .deb writes here
#   /etc/proxmod/extensions.d/         admin-owned; overrides the above
#
# Later directories win *by basename*, the same rule systemd uses for units. An
# administrator disables a packaged extension by masking it — an empty file, or
# a symlink to /dev/null, at the same basename under /etc — which survives
# reinstalling the extension package, unlike editing the packaged file.
#
# The content is JSON (see docs/extension-manifest.md and the schema in
# specifications.md appendix B). The .conf suffix is the drop-in convention;
# the format inside is JSON because manifests need arrays and nesting.
#
# TAINT. pvedaemon and pveproxy run under `perl -T`. Everything read off disk
# here is tainted, and `require` of a tainted string dies — which, since it
# would happen inside the daemon at startup, is a dead daemon. Every field that
# can reach `require`, a filesystem path, or generated JavaScript is therefore
# untainted the only way Perl allows: matched against a strict pattern and
# rebuilt from the capture. Never pass a manifest value through unmatched.

our @EXT_DIRS = (
    '/usr/share/proxmod/extensions.d',
    '/etc/proxmod/extensions.d',
);

# Daemons a backend extension may ask to load into. pvestatd is deliberately
# absent: it does not run under taint mode and serves no REST API, so there is
# nothing for an extension to attach to there.
my %KNOWN_DAEMONS = map { $_ => 1 } qw(pvedaemon pveproxy);

sub known_daemons { return sort keys %KNOWN_DAEMONS }

sub is_known_daemon {
    my ($name) = @_;
    return (defined($name) && $KNOWN_DAEMONS{$name}) ? 1 : 0;
}

my $RE_ID     = qr/\A([a-z0-9][a-z0-9_-]{0,63})\z/;
my $RE_MODULE = qr/\A([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*)\z/;
my $RE_ASSET  = qr/\A([A-Za-z0-9][A-Za-z0-9._-]{0,127}\.js)\z/;
my $RE_ORDER  = qr/\A([0-9]{1,4})\z/;

# Read a manifest as raw bytes. The decoding is left to JSON::PP's ->utf8, for
# a reason that is not stylistic:
#
#   open($fh, '<:encoding(UTF-8)', $tainted_path)
#
# dies under -T with "Insecure dependency in require". The encoding layer loads
# PerlIO::encoding lazily, and perl treats that require as insecure when the
# open's filename is tainted. Every path here comes from readdir and so is
# always tainted. It works fine on a laptop and fails inside pvedaemon, where
# the result would be that no extension ever loads and nothing says why.
# See [PVE-F-040] in docs/pve-facts.md. Do not reintroduce an encoding layer.
sub _read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    binmode($fh);
    local $/;
    my $content = <$fh>;
    close($fh);
    return defined($content) ? $content : '';
}

# Parse and validate one manifest, logging why if it is rejected. Returns a
# manifest hashref, a {masked=>1} marker, or undef. One malformed manifest must
# never cost us the others, so nothing in here is allowed to be fatal.
sub _parse_manifest {
    my ($path, $basename) = @_;

    my $text = _read_file($path);
    if (!defined $text) {
        log_warn("manifest unreadable, ignoring: $path: $!");
        return undef;
    }

    # An empty file is a mask, not an error — that is how an admin disables a
    # packaged extension. Same for a symlink to /dev/null.
    if ($text !~ /\S/) {
        log_debug("manifest masked (empty): $path");
        return { masked => 1, basename => $basename, source => $path };
    }

    my $raw;
    my $ok = eval {
        # ->utf8 because _read_file deliberately hands us bytes; ->relaxed so a
        # trailing comma, or a # or // comment, in a hand-edited /etc manifest
        # is a forgivable mistake rather than a silently missing extension.
        $raw = JSON::PP->new->utf8->relaxed->decode($text);
        1;
    };
    if (!$ok || ref($raw) ne 'HASH') {
        my $err = $ok ? 'top level is not a JSON object' : ($@ || 'parse failed');
        $err =~ s/\s+$//;
        log_warn("manifest invalid, ignoring: $path: $err");
        return undef;
    }

    my ($id) = (($raw->{id} // '') =~ $RE_ID);
    if (!defined $id) {
        log_warn("manifest invalid, ignoring: $path: bad or missing 'id'"
            . " (want lowercase letters, digits, '-' and '_')");
        return undef;
    }

    my $ext = {
        id       => $id,
        source   => $path,
        basename => $basename,
        version  => ($raw->{version} // '0'),
        enabled  => exists($raw->{enabled}) ? ($raw->{enabled} ? 1 : 0) : 1,
        order    => 50,
        requires => [],
        backend  => undef,
        frontend => undef,
    };

    if (defined $raw->{order}) {
        my ($order) = ("$raw->{order}" =~ $RE_ORDER);
        if (!defined $order) {
            log_warn("$id: bad 'order' (want 0-9999), using default 50");
        } else {
            $ext->{order} = 0 + $order;
        }
    }

    for my $dep (@{ _as_list($raw->{requires}) }) {
        my ($clean) = (($dep // '') =~ $RE_ID);
        if (!defined $clean) {
            log_warn("$id: ignoring malformed entry in 'requires'");
            next;
        }
        push @{ $ext->{requires} }, $clean;
    }

    if (defined(my $be = $raw->{backend})) {
        if (ref($be) ne 'HASH') {
            log_warn("$id: 'backend' is not an object, ignoring it");
        } else {
            # The untainting that matters most: this string reaches require().
            my ($module) = (($be->{module} // '') =~ $RE_MODULE);
            if (!defined $module) {
                log_warn("$id: bad or missing 'backend.module', skipping backend");
            } else {
                my %daemons;
                my $wanted = _as_list($be->{daemons});
                $wanted = [ sort keys %KNOWN_DAEMONS ] if !@$wanted;
                for my $d (@$wanted) {
                    if (!defined($d) || !$KNOWN_DAEMONS{$d}) {
                        log_warn("$id: unknown daemon '" . ($d // 'undef')
                            . "' in 'backend.daemons', ignoring it");
                        next;
                    }
                    $daemons{$d} = 1;
                }
                if (!%daemons) {
                    log_warn("$id: 'backend.daemons' left no usable daemon, skipping backend");
                } else {
                    $ext->{backend} = { module => $module, daemons => \%daemons };
                }
            }
        }
    }

    if (defined(my $fe = $raw->{frontend})) {
        if (ref($fe) ne 'HASH') {
            log_warn("$id: 'frontend' is not an object, ignoring it");
        } else {
            my @assets;
            for my $a (@{ _as_list($fe->{assets}) }) {
                # Assets are bare filenames under /usr/share/proxmod/www. No
                # slashes, so no traversal: this name is interpolated into a
                # URL that pveproxy serves to unauthenticated clients.
                my ($clean) = (($a // '') =~ $RE_ASSET);
                if (!defined $clean) {
                    log_warn("$id: ignoring bad asset name '" . ($a // 'undef')
                        . "' (want a plain *.js filename, no directories)");
                    next;
                }
                push @assets, $clean;
            }
            $ext->{frontend} = { assets => \@assets } if @assets;
        }
    }

    if (!$ext->{backend} && !$ext->{frontend}) {
        log_warn("$id: manifest declares neither a usable backend nor frontend, ignoring: $path");
        return undef;
    }

    return $ext;
}

# JSON gives us a scalar where a list was meant often enough that accepting
# both costs one function and saves every extension author a support round.
sub _as_list {
    my ($v) = @_;
    return [] if !defined $v;
    return [ @$v ] if ref($v) eq 'ARRAY';
    return [] if ref($v);
    return [ $v ];
}

sub _scan_dir {
    my ($dir, $by_basename) = @_;

    opendir(my $dh, $dir) or do {
        log_debug("no extension directory at $dir");
        return;
    };
    my @names = sort grep { /\.conf\z/ && !/\A\./ } readdir($dh);
    closedir($dh);

    for my $name (@names) {
        my $path = "$dir/$name";
        next if !-f $path && !-l $path;

        my $ext;
        my $ok = eval { $ext = _parse_manifest($path, $name); 1 };
        if (!$ok) {
            my $err = $@ || 'unknown error';
            $err =~ s/\s+$//;
            log_warn("manifest threw while parsing, ignoring: $path: $err");
            next;
        }
        next if !defined $ext;

        # Same basename in a later directory replaces the earlier one outright,
        # including replacing it with a mask.
        $by_basename->{$name} = $ext;
    }

    return;
}

# Order extensions by 'requires', keeping declared order where dependencies
# allow it. Anything whose dependency is missing or circular is dropped, along
# with whatever depended on it: an extension whose prerequisite never loaded is
# more likely to misbehave than to degrade gracefully.
sub _resolve_order {
    my ($exts) = @_;

    my %by_id;
    my @ordered;
    for my $e (@$exts) {
        if (my $prev = $by_id{ $e->{id} }) {
            log_warn("duplicate extension id '$e->{id}': $e->{source} shadows"
                . " $prev->{source}, ignoring the later one");
            next;
        }
        $by_id{ $e->{id} } = $e;
        push @ordered, $e;
    }

    my (@result, %done);
    my $progress = 1;
    while ($progress) {
        $progress = 0;
        my @remaining;
        for my $e (@ordered) {
            my $ready = 1;
            for my $dep (@{ $e->{requires} }) {
                next if $done{$dep};
                $ready = 0;
                last;
            }
            if ($ready) {
                push @result, $e;
                $done{ $e->{id} } = 1;
                $progress = 1;
            } else {
                push @remaining, $e;
            }
        }
        @ordered = @remaining;
    }

    for my $e (@ordered) {
        my @missing = grep { !$done{$_} } @{ $e->{requires} };
        my @absent  = grep { !$by_id{$_} } @missing;
        my $why = @absent
            ? "requires missing extension(s): " . join(', ', @absent)
            : "is part of a dependency cycle with: " . join(', ', @missing);
        log_warn("$e->{id}: not loading, $why");
    }

    return \@result;
}

# Returns an arrayref of enabled extension manifests, in load order.
sub load {
    my (%opt) = @_;

    my $dirs = $opt{dirs} || \@EXT_DIRS;

    my %by_basename;
    _scan_dir($_, \%by_basename) for @$dirs;

    return _effective(\%by_basename);
}

# The filter and the ordering load() applies to a scanned set, split out so that
# inventory() can reach the same verdict from the same scan. Two scans would
# mean two passes of log_warn over every malformed manifest, and an inventory
# that disagreed with load() if a file changed between them.
sub _effective {
    my ($by_basename) = @_;

    my @candidates;
    for my $name (sort keys %$by_basename) {
        my $e = $by_basename->{$name};
        if ($e->{masked}) {
            log_debug("$name: masked by $e->{source}");
            next;
        }
        if (!$e->{enabled}) {
            log_debug("$e->{id}: disabled by its manifest");
            next;
        }
        push @candidates, $e;
    }

    # Declared order first, basename as the tie-break so the result does not
    # depend on readdir order.
    @candidates = sort {
        $a->{order} <=> $b->{order} || $a->{basename} cmp $b->{basename}
    } @candidates;

    return _resolve_order(\@candidates);
}

# Everything on disk, including what load() drops.
#
# load() answers the only question the daemons have: what will be loaded. An
# administrator running `proxmodctl list` has a different one, and an extension
# that is masked, disabled by its manifest, or dropped for a missing dependency
# is precisely what they are looking for — load() omitting it is
# indistinguishable from it not being installed at all.
#
# Each entry is a manifest hashref with one extra field, `state`:
#
#   effective   it is in load()'s result; the daemons will load it
#   disabled    "enabled": false in its own manifest
#   masked      an empty file or /dev/null symlink shadows it from /etc
#   unresolved  parsed and enabled, but dropped for a missing or circular
#               'requires' — the case that otherwise has no visible symptom
#
# A manifest too broken to parse is deliberately absent: _parse_manifest has
# already logged why, and an entry for it would need an id we do not have.
sub inventory {
    my (%opt) = @_;

    my $dirs = $opt{dirs} || \@EXT_DIRS;

    my %by_basename;
    _scan_dir($_, \%by_basename) for @$dirs;

    my %effective = map { $_->{id} => 1 } @{ _effective(\%by_basename) };

    my @out;
    for my $name (sort keys %by_basename) {
        my $e = $by_basename{$name};
        my $state = $e->{masked}            ? 'masked'
                  : !$e->{enabled}          ? 'disabled'
                  : $effective{ $e->{id} }  ? 'effective'
                  :                           'unresolved';
        push @out, { %$e, state => $state };
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# A short digest of "what proxmod would load right now".
#
# The daemons log it at startup (Proxmod::Boot) and proxmod-verify recomputes it
# from disk, so `installed an extension but never restarted` becomes a visible
# difference rather than an invisible one. Both sides call this function, so
# they agree by construction rather than by two implementations staying in step.
#
# It is a pure function of the *effective* extension list, deliberately:
#
#  * counting extensions instead would not work. pveproxy runs the frontend
#    stage and pvedaemon does not, so the two daemons legitimately report
#    different counts for one registry. A digest of the list itself does not
#    care which daemon is asking.
#  * proxmod's own version is folded in, so upgrading proxmod is itself a
#    change. That is what makes `dpkg -i proxmod` restart the daemons onto the
#    new modules instead of leaving the old ones resident. It is read from this
#    module rather than from Proxmod.pm on purpose: Proxmod.pm's INIT block
#    boots proxmod into whatever process loads it, so proxmod-verify must never
#    require it. Every module in the distribution carries the same $VERSION, and
#    docs/conventions.md is where that is enforced.
#  * a masked or disabled manifest contributes nothing, because it contributes
#    nothing to what runs.
#
# Serialised by hand rather than through JSON or Data::Dumper: this value has to
# be stable across Perl versions and hash orderings for as long as a daemon
# stays up, and neither of those promises that.
sub fingerprint {
    my ($exts) = @_;
    $exts ||= [];

    require Digest::SHA;

    my $canon = "proxmod\0" . ($VERSION // '?') . "\n";
    for my $e (@$exts) {
        my @f = (
            $e->{id}       // '',
            $e->{basename} // '',
            $e->{version}  // '',
            defined $e->{order} ? $e->{order} : '',
        );

        if (my $be = $e->{backend}) {
            push @f, 'backend', ($be->{module} // ''),
                join(',', sort keys %{ $be->{daemons} || {} });
        }
        if (my $fe = $e->{frontend}) {
            push @f, 'frontend', join(',', @{ $fe->{assets} || [] });
        }

        $canon .= join("\0", @f) . "\n";
    }

    return substr(Digest::SHA::sha256_hex($canon), 0, 12);
}

1;
