#!/usr/bin/perl
use strict;
use warnings;

use lib 't/lib';
use lib 'perl';
use Test::More tests => 6;
use ProxmodTest qw(repo_root);

# Things that are written down twice and have to agree.
#
# Every one of these is deliberate duplication with a stated reason, and the
# reasons are good: the id and asset patterns are re-declared at each taint
# boundary so that no module is trusting another module's validation, and
# proxmod-verify re-implements the frontend predicate because it must answer
# "should this host have a loader tag" without loading Proxmod::Frontend into a
# process that is not a PVE daemon.
#
# What was missing is the other half. A copy that is deliberate is still a copy,
# and the failure mode of a copy is not that someone deletes it — it is that
# someone tightens one of them. Widen $RE_ID in Registry.pm alone and manifests
# start being accepted whose ids Frontend.pm will later refuse, so an extension
# registers and then serves nothing, with no error anywhere that names the
# reason. GH#1 was this shape.
#
# So these are not tests of behaviour. They read the source and assert that text
# which must be identical is identical. When one fails, the fix is usually to
# make the same edit in the other place — and the diag says where.

my $ROOT = repo_root();

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "open $path: $!";
    local $/;
    my $c = <$fh>;
    close($fh);
    return defined($c) ? $c : '';
}

sub rel { my ($p) = @_; $p =~ s{^\Q$ROOT\E/}{}r }

# Pull one `my $NAME = ...;` line out of a module and hand back the right-hand
# side, whitespace-normalised. Deliberately textual: two patterns that differ
# only in spelling are still two patterns to keep in step, and a comparison
# that forgave that would be forgiving the thing being watched for.
sub decl {
    my ($file, $name) = @_;
    my $src = slurp("$ROOT/$file");
    my ($rhs) = $src =~ /^(?:my|our)\s+\Q$name\E\s*=\s*(.+?);\s*$/m
        or return undef;
    $rhs =~ s/\s+/ /g;
    return $rhs;
}

sub body {
    my ($file, $sub) = @_;
    my $src = slurp("$ROOT/$file");
    my ($b) = $src =~ /^sub \Q$sub\E\b.*?\n(.*?)^\}/ms or return undef;
    return $b;
}

subtest 'one file reader, copied three times, identical three times' => sub {
    # Registry, Patch and Frontend each carry their own _read_file. Nine lines
    # is not worth a shared module and a fourth thing for pvedaemon to load —
    # but they diverged anyway: Frontend's returned undef on a zero-byte read
    # where the others return ''. Registry treats an empty manifest as a mask
    # and Frontend's loader_body dies on an empty template, so the two callers
    # took opposite meanings from the same undef, and neither said so.
    my @files = map { "perl/Proxmod/$_.pm" } qw(Registry Patch Frontend);
    plan tests => scalar(@files);

    my $first = body($files[0], '_read_file');
    ok(defined $first, "$files[0] has a _read_file to compare against") or return;

    for my $f (@files[1 .. $#files]) {
        is(body($f, '_read_file'), $first, rel("$ROOT/$f") . ' matches Registry.pm');
    }
};

subtest 'the id pattern is the same at every taint boundary' => sub {
    my @where = (
        ['perl/Proxmod/Registry.pm', '$RE_ID'],
        ['perl/Proxmod/Patch.pm',    '$RE_ID'],
        ['perl/Proxmod/Frontend.pm', '$RE_ID'],
    );
    plan tests => scalar(@where);

    my $want = decl(@{ $where[0] });
    ok(defined $want, "$where[0][0] declares $where[0][1]") or return;

    for my $w (@where[1 .. $#where]) {
        is(decl(@$w), $want, "$w->[0] $w->[1] matches Registry.pm");
    }
};

subtest 'the asset pattern is the same on both sides of the manifest' => sub {
    plan tests => 1;
    # Registry validates it out of the manifest; Frontend validates it again on
    # the way to a URL. If Registry is the looser of the two, an extension
    # installs cleanly and its asset 404s.
    is(decl('perl/Proxmod/Frontend.pm', '$RE_ASSET'),
       decl('perl/Proxmod/Registry.pm', '$RE_ASSET'),
       'Frontend.pm $RE_ASSET matches Registry.pm');
};

subtest 'the package-name pattern is the same in Registry and API' => sub {
    plan tests => 1;
    # Same pattern, two names — Registry calls it $RE_MODULE because a manifest
    # field says `module`, API calls it $RE_PACKAGE because it is about to
    # require() one. The names may differ. The pattern may not: Registry decides
    # what reaches API, and API is where the string becomes code.
    is(decl('perl/Proxmod/API.pm',      '$RE_PACKAGE'),
       decl('perl/Proxmod/Registry.pm', '$RE_MODULE'),
       'API.pm $RE_PACKAGE matches Registry.pm $RE_MODULE');
};

subtest 'proxmod-verify asks the frontend question the way Frontend answers it' =>
sub {
    plan tests => 3;

    # "Does this host want a loader tag" is decided in Frontend::install, and
    # asked again in proxmod-verify::frontend_wanted — which cannot call the
    # first one, because proxmod-verify runs outside pvedaemon and loading
    # Frontend there would pull in PVE::APIServer. The comment in the script
    # says "Keep them in step." This is what keeps them.
    #
    # The consequence of drift is a false alarm on a production host: verify
    # decides the index should carry a tag, the daemon disagreed, and the
    # operator is sent looking for a broken install that is working correctly.
    my $expr = qr/\$_->\{frontend\}\s*&&\s*\@\{\s*\$_->\{frontend\}\{assets\}\s*\|\|\s*\[\]\s*\}/;

    my $install = body('perl/Proxmod/Frontend.pm', 'install');
    ok(defined $install, 'Frontend::install found');
    like($install, $expr, 'Frontend::install greps on frontend.assets being non-empty');

    my $wanted = body('bin/proxmod-verify', 'frontend_wanted');
    like($wanted, $expr, 'proxmod-verify frontend_wanted uses the same predicate');
};

subtest 'the two drop-ins say the same thing about both daemons' => sub {
    plan tests => 3;

    # 10-proxmod.conf exists twice, once per daemon, and the two are the same
    # file with the name changed — plus one paragraph that belongs only to
    # pvedaemon, because only pvedaemon runs protected API methods as root.
    #
    # They are not generated from a template and should not be. An
    # administrator on a host where the web interface is down reads these with
    # `cat`, and the comments are the whole reason the file is worth reading;
    # moving them into the Makefile would make the installed artifact less
    # useful to the one person who ever looks at it. The cost of that decision
    # is that a correction made to one can be missed in the other, and a
    # comment that is right in one file and wrong in the other is worse than
    # the same comment being wrong in both.
    #
    # So: paragraph by paragraph, with the daemon name normalised away.
    my %file = (
        pvedaemon => 'systemd/pvedaemon.service.d/10-proxmod.conf',
        pveproxy  => 'systemd/pveproxy.service.d/10-proxmod.conf',
    );

    my %para;
    for my $d (sort keys %file) {
        my $text = slurp("$ROOT/$file{$d}");
        $text =~ s/\b\Q$d\E\b/DAEMON/g;
        # Paragraphs are separated by a bare `#` in the comment header and by a
        # blank line after it.
        $para{$d} = [ grep { /\S/ } split /^(?:#[ \t]*)?\n/m, $text ];
    }

    is(scalar @{ $para{pvedaemon} }, scalar @{ $para{pveproxy} } + 1,
        'pvedaemon carries exactly one paragraph pveproxy does not');

    # Every pveproxy paragraph appears in pvedaemon's, in order.
    my @extra;
    my @left = @{ $para{pvedaemon} };
    for my $want (@{ $para{pveproxy} }) {
        push @extra, shift @left while @left && $left[0] ne $want;
        if (@left) { shift @left }
        else       { fail("pveproxy paragraph has no match in pvedaemon"); diag($want); return }
    }
    push @extra, @left;

    pass('every pveproxy paragraph appears in pvedaemon, in the same order');
    is(scalar @extra, 1, 'and the leftover is the single pvedaemon-only paragraph')
        or diag(join "\n---\n", @extra);
};
