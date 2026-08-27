#!/usr/bin/perl
use strict;
use warnings;

use lib 't/lib';
use lib 'perl';
use Test::More tests => 8;
use ProxmodTest qw(repo_root);
use File::Find ();

# docs/conventions.md is project law that until now nothing enforced. Every rule
# in it was satisfied by hand, which works exactly as long as one person is
# committing and remembers all of it — and stops working silently, some months
# after it stops working.
#
# What is checked here is only the mechanical half. "Say what it costs" and
# "name a regression test after the defect it prevents" are judgements and stay
# judgements; a status block either has four lines or it does not, a
# [PVE-F-nnn] citation either resolves or it does not, and $VERSION either
# agrees with itself across eleven files or it does not. Those are the ones that
# rot quietly, because nothing about the repository looks wrong when they break.

my $ROOT = repo_root();

# Every markdown file the repository owns. docs/third_party/ is eight vendored
# upstream checkouts — somebody else's documentation, held to somebody else's
# conventions — and .git/ is not ours either.
sub docs_files {
    my @found;
    File::Find::find({
        no_chdir => 1,
        wanted   => sub {
            return if $File::Find::name =~ m{/third_party/};
            push @found, $File::Find::name if $File::Find::name =~ m{\.md\z};
        },
    }, "$ROOT/docs");
    return sort @found;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub rel { my ($p) = @_; $p =~ s{\A\Q$ROOT\E/}{}r }

my @DOCS = docs_files();
ok(scalar(@DOCS) >= 30, 'there are documents to check (' . scalar(@DOCS) . ' of them)');

# ---------------------------------------------------------------------------

subtest 'every document opens with the four-line status block' => sub {
    # docs/conventions.md §1. The block is what tells a reader whether the page
    # in front of them was checked against a running Proxmox or written from
    # memory — and "Last verified against" is the only thing in the repository
    # that dates a claim. A document without one is not a document with a
    # missing header, it is a document making unattributed assertions.
    plan tests => scalar(@DOCS);

    my @fields = ('Status', 'Applies to', 'Last verified against', 'Verification method');
    for my $doc (@DOCS) {
        my $head = join '', (split /\n/, slurp($doc), 20)[0 .. 14];
        my @missing = grep { $head !~ /\*\*\Q$_\E:\*\*/ } @fields;
        is(scalar(@missing), 0, rel($doc) . ' has all four header fields')
            or diag('missing: ' . join(', ', @missing));
    }
};

subtest 'nothing leaves Draft carrying an UNVERIFIED marker' => sub {
    # docs/conventions.md §5: "No document leaves Draft while it contains an
    # UNVERIFIED marker. Mark what you have not checked rather than writing
    # around it." The marker is the honest option and costs nothing while a
    # document is Draft; promoting the document is the moment it becomes a lie.
    #
    # Only two files mention the marker outside that use — conventions.md and
    # specifications.md, both stating the rule — and both are Draft, so they
    # need no exception here. If one is ever promoted, the fix is to reword the
    # rule rather than to add a name to a skip list.
    my @promoted = grep { slurp($_) !~ /^\*\*Status:\*\* Draft\s*$/m } @DOCS;
    plan tests => scalar(@promoted) + 1;

    ok(scalar(@promoted) > 0, 'some documents have left Draft (' . scalar(@promoted) . ')');
    for my $doc (@promoted) {
        unlike(slurp($doc), qr/UNVERIFIED/, rel($doc) . ' has left Draft and carries no UNVERIFIED');
    }
};

# ---------------------------------------------------------------------------

subtest 'every [PVE-F-nnn] citation resolves to a ledger entry' => sub {
    # docs/conventions.md §4: cite the ledger rather than restating the fact,
    # "so a claim about Proxmox that turns out to be wrong is wrong in one
    # place". That only holds while the citations point at something. A
    # dangling [PVE-F-051] reads exactly like a sound one — the reader takes the
    # sentence on trust and there is nothing to correct when the seam moves.
    my $ledger = slurp("$ROOT/docs/pve-facts.md");
    my %defined = map { $_ => 1 } ($ledger =~ /^### \[PVE-F-(\d+)\]/gm);

    # Citations live in the source too: the modules and scripts cite facts in
    # comments for the same reason the documents do.
    my @sources = (@DOCS, glob("$ROOT/perl/Proxmod/*.pm"), "$ROOT/perl/Proxmod.pm",
        glob("$ROOT/bin/*"), glob("$ROOT/exec/*"), glob("$ROOT/t/*.t"));

    my %cited;
    for my $file (@sources) {
        next if !-f $file;
        my $text = slurp($file);
        $cited{$_}{ rel($file) } = 1 for ($text =~ /\[PVE-F-(\d+)\]/g);
    }

    plan tests => 3;
    ok(scalar(keys %defined) > 15, 'the ledger has entries (' . scalar(keys %defined) . ')');

    my @dangling = sort grep { !$defined{$_} } keys %cited;
    is(scalar(@dangling), 0, 'every citation resolves to a ledger entry')
        or diag(join "\n", map { "[PVE-F-$_] cited by " . join(', ', sort keys %{ $cited{$_} }) } @dangling);

    # §8: "A fact nothing cites should not be in the ledger." The ledger is not
    # a reference manual for Proxmox — it is the set of assumptions proxmod
    # actually rests on, and an uncited entry is either a claim that lost its
    # consumer or research that belongs in pve-internals.md.
    my @orphans = sort grep {
        my $id = $_;
        my @from = grep { $_ ne 'docs/pve-facts.md' } keys %{ $cited{$id} || {} };
        !@from;
    } keys %defined;
    is(scalar(@orphans), 0, 'every ledger entry is cited by something outside the ledger')
        or diag('uncited: ' . join(', ', map { "[PVE-F-$_]" } @orphans));
};

# ---------------------------------------------------------------------------

subtest 'one version, agreed on by everything that states it' => sub {
    # Release commit e6a23e9 describes this fan-out as a ritual: bump $VERSION
    # in every module and script, Proxmod.version in the JS, the "Applies to"
    # header in every doc, the man pages, and debian/changelog. Nothing checked
    # it, and the failure is not cosmetic — Frontend serves the asset as
    # /proxmod/proxmod-ui.js?v=$VERSION, so a JS file whose version lags the
    # Perl one is served to browsers under a cache key that never changes. That
    # is how a fixed bug stays visible to everyone who already loaded the page.
    my %seen;   # version => { source => 1 }

    my @perl = (glob("$ROOT/perl/Proxmod/*.pm"), "$ROOT/perl/Proxmod.pm",
        glob("$ROOT/bin/*"), glob("$ROOT/exec/*"));
    for my $file (@perl) {
        next if !-f $file;
        my ($v) = slurp($file) =~ /^our \$VERSION\s*=\s*'([^']+)'/m or next;
        $seen{$v}{ rel($file) } = 1;
    }

    my ($js) = slurp("$ROOT/www/proxmod-ui.js") =~ /Proxmod\.version\s*=\s*'([^']+)'/;
    $seen{ $js // 'none' }{'www/proxmod-ui.js'} = 1;

    for my $man (glob("$ROOT/man/*.8")) {
        my ($v) = slurp($man) =~ /^\.TH\s+\S+\s+\d+\s+"[^"]*"\s+"proxmod ([^"]+)"/m;
        $seen{ $v // 'none' }{ rel($man) } = 1;
    }

    # A document may say `0.2.x` instead of `0.2.1` when what it describes is
    # true for the whole minor series rather than for one release — testing.md
    # does, and re-stamping it every patch release would be a lie in the other
    # direction. The series still has to be the current one, so the form buys
    # accuracy without buying an exemption from the check.
    my %series;
    for my $doc (@DOCS) {
        my ($v) = slurp($doc) =~ /^\*\*Applies to:\*\* proxmod ([0-9][^,\n]*)/m or next;
        if ($v =~ /\A(\d+\.\d+)\.x\z/) { $series{$1}{ rel($doc) } = 1; next }
        $seen{$v}{ rel($doc) } = 1;
    }

    my ($changelog) = slurp("$ROOT/debian/changelog") =~ /\A\S+ \(([^)]+)\)/;
    $seen{ $changelog // 'none' }{'debian/changelog'} = 1;

    plan tests => 4;
    ok(defined $changelog, "debian/changelog states a version ($changelog)");
    ok(scalar(keys %{ $seen{$changelog} || {} }) > 20,
        'and most of the tree agrees with it (' . scalar(keys %{ $seen{$changelog} || {} }) . ' places)');
    is(scalar(keys %seen), 1, 'exactly one version is stated anywhere')
        or diag(join "\n", map { "$_: " . join(', ', sort keys %{ $seen{$_} }) } sort keys %seen);

    my ($minor) = ($changelog // '') =~ /\A(\d+\.\d+)\./;
    my @wrong_series = sort grep { $_ ne ($minor // '') } keys %series;
    is(scalar(@wrong_series), 0, "every X.Y.x header names the current series ($minor)")
        or diag(join "\n", map { "$_.x: " . join(', ', sort keys %{ $series{$_} }) } @wrong_series);
};

# ---------------------------------------------------------------------------

subtest 'install instructions name no version they will outlive' => sub {
    # Borrowed from pve-microvm, which asserts the same thing about its own
    # README. An install line that names proxmod_0.2.1_all.deb is correct for
    # one release and wrong, silently, for every release after it — and the
    # person it is wrong for is a first-time reader following instructions
    # literally, who has no way to know the number is stale rather than
    # required. A glob is right forever and costs a reader nothing.
    #
    # The registry channel has the same problem in a different shape. A `.deb`
    # can be globbed; an OCI tag cannot, and there is deliberately no `latest`
    # to point at — so the honest spelling is a placeholder the reader has to
    # fill in, and a concrete `:0.2.1` here would be the stale number all over
    # again with no glob available to save it.
    my @install = ("$ROOT/README.md", "$ROOT/docs/install.md",
        "$ROOT/docs/getting-started.md");
    plan tests => scalar(@install);

    for my $file (@install) {
        my @pinned = grep {
            /^\s*(?:apt|dpkg)[^\n]*\b\w[\w.+-]*_\d+\.\d+[\w.+-]*\.deb/
                || /\boras\s+pull\b[^\n]*:\d+\.\d+/
        } split /\n/, slurp($file);
        is(scalar(@pinned), 0, rel($file) . ' installs by glob or placeholder, not by pinned version')
            or diag(join "\n", @pinned);
    }
};

# ---------------------------------------------------------------------------

subtest 'every document links to files that exist' => sub {
    # A broken relative link is the same class of defect as a dangling
    # citation, and the docs are dense with them — docs/README.md alone is
    # almost nothing else. Only repo-relative links are checked; external URLs
    # are somebody else's uptime.
    plan tests => scalar(@DOCS);

    for my $doc (@DOCS) {
        my $dir = $doc;
        $dir =~ s{/[^/]+\z}{};
        my @broken;

        # Code first, then links. `Proxmod.api['delete'](…)` in a sentence is
        # indistinguishable from a markdown link to a regex, and the docs are
        # full of that shape.
        my $text = slurp($doc);
        $text =~ s/^```.*?^```//gms;
        $text =~ s/`[^`\n]*`//g;

        for my $target ($text =~ /\]\(([^)\s#]+)(?:#[^)]*)?\)/g) {
            next if $target =~ m{\A(?:https?:|mailto:|#)};
            my $path = $target =~ m{\A/} ? "$ROOT$target" : "$dir/$target";
            push @broken, $target if !-e $path;
        }
        is(scalar(@broken), 0, rel($doc) . ' has no broken relative links')
            or diag('broken: ' . join(', ', @broken));
    }
};

# ---------------------------------------------------------------------------

subtest 'the rules this file enforces are the rules that are written down' => sub {
    # The failure mode a conventions test has that other tests do not: it can
    # drift from the document it enforces and then quietly enforce a private
    # opinion. These are the sentences the assertions above were read off. If
    # one of them is reworded, this subtest fails and whoever reworded it has to
    # come and look at what the change did to the checks — which is the point.
    plan tests => 4;

    my $conv = slurp("$ROOT/docs/conventions.md");
    like($conv, qr/No document leaves Draft while it contains an `UNVERIFIED` marker/,
        'the UNVERIFIED rule still reads as this file assumes');
    like($conv, qr/A fact nothing cites should not be in the ledger/,
        'the uncited-fact rule still reads as this file assumes');
    like($conv, qr/Conventional Commits/,
        'the commit convention is written down at all');

    my $facts = slurp("$ROOT/docs/pve-facts.md");
    like($facts, qr/^### \[PVE-F-\d+\]/m,
        'the ledger still uses the heading shape this file parses');
};
