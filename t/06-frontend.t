#!/usr/bin/perl -T

use strict;
use warnings;

use lib 't/lib';
use lib 'perl';

use Test::More tests => 16;
use ProxmodTest qw(tempdir write_file capture_log capture_debug_log is_tainted repo_root);

use JSON::PP ();

use PVE::Service::pveproxy;
use Proxmod::Frontend;

# The zero-file-mutation frontend. Everything below is about one property: the
# only thing that changes on a Proxmox host is what pveproxy holds in memory.
#
# The index bodies come from t/fixtures/, extracted from the real 9.1.1 ISO by
# scripts/extract-pve-source.sh. Asserting that the anchor exists in a fixture
# we wrote ourselves would prove nothing; asserting it against Proxmox's own
# template is the point of vendoring them.

# ---------------------------------------------------------------------------
# Fixtures and scaffolding
# ---------------------------------------------------------------------------

# The vendored files are Template Toolkit sources, and get_index returns them
# rendered. Stripping the [% ... %] directives and keeping everything between
# them is not a renderer — it leaves BOTH arms of every conditional in place.
# That is deliberate: the result has more <script> tags than any real page, so
# an anchor that survives it is not relying on there being exactly one
# candidate.
sub rendered {
    my ($name) = @_;

    my $path = repo_root() . "/t/fixtures/index.html.tpl.$name.9.1.1";
    open(my $fh, '<', $path) or die "cannot read fixture $path: $!";
    binmode($fh);
    local $/;
    my $body = <$fh>;
    close($fh);

    $body =~ s/\[%.*?%\]//gs;

    return $body;
}

my $INDEX = rendered('pve-manager');

# A tree that looks like an installed proxmod, built from the files this repo
# actually ships so that a change to www/ that breaks the loader is caught here
# rather than on a host.
my $ROOT = tempdir();
my $WWW = "$ROOT/usr/share/proxmod/www";

sub install_tree {
    my $root = repo_root();

    for my $file (qw(proxmod-ui.js)) {
        write_file("$WWW/$file", slurp("$root/www/$file"));
    }
    write_file("$ROOT/usr/share/proxmod/loader-runtime.js",
        slurp("$root/www/loader-runtime.js"));

    return;
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!";
    binmode($fh);
    local $/;
    my $c = <$fh>;
    close($fh);
    return $c;
}

install_tree();

$Proxmod::Frontend::WWW_DIR = $WWW;
$Proxmod::Frontend::RUNTIME_FILE = "$ROOT/usr/share/proxmod/loader-runtime.js";

# Wrapping replaces a glob, and a glob stays replaced. Every group of
# assertions starts from Proxmox's own subs.
my $ORIG_INIT = \&PVE::Service::pveproxy::init;
my $ORIG_INDEX = \&PVE::Service::pveproxy::get_index;

sub reset_all {
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    no warnings 'redefine'; ## no critic (ProhibitNoWarnings)
    *PVE::Service::pveproxy::init = $ORIG_INIT;
    *PVE::Service::pveproxy::get_index = $ORIG_INDEX;
    Proxmod::Frontend::_reset();
    $PVE::Service::pveproxy::BODY = $INDEX;
    return;
}

sub ext {
    my (%override) = @_;
    return {
        id => 'hello',
        version => '1.0',
        frontend => { assets => ['hello.js'] },
        %override,
    };
}

# What a browser would receive for GET /.
sub serve_index {
    my $resp = PVE::Service::pveproxy::get_index('n1', undef, undef, {});
    return $resp->content;
}

sub tag_count {
    my ($body) = @_;
    my $n = () = ($body =~ m{src="/proxmod/loader\.js}g);
    return $n;
}

write_file("$WWW/hello.js", "/* hello */\n");

# ---------------------------------------------------------------------------

subtest 'with no frontend extension, nothing is wrapped at all' => sub {
    plan tests => 5;

    reset_all();

    # The strongest form of "survives updates": on a host where no extension
    # wants a frontend, proxmod is not in the request path at any point.
    my ($result) = capture_debug_log(sub { Proxmod::Frontend::install([]) });

    is($result->{loaded}, 0, 'nothing loaded');
    is($result->{failed}, 0, 'nothing failed');
    is(\&PVE::Service::pveproxy::get_index, $ORIG_INDEX, 'get_index is untouched');
    is(\&PVE::Service::pveproxy::init, $ORIG_INIT, 'init is untouched');
    is(serve_index(), $INDEX, 'the index is byte-for-byte what Proxmox rendered');
};

subtest 'a backend-only extension does not drag in the frontend' => sub {
    plan tests => 2;

    reset_all();

    my ($result) = capture_log(sub {
        Proxmod::Frontend::install([{ id => 'be', backend => { module => 'X' } }]);
    });

    is($result->{loaded}, 0, 'it is not counted as a frontend extension');
    is(serve_index(), $INDEX, 'and the index is untouched');
};

subtest 'the happy path injects exactly one tag' => sub {
    plan tests => 6;

    reset_all();

    my ($result, $log) = capture_log(sub { Proxmod::Frontend::install([ext()]) });

    is($result->{loaded}, 1, 'the extension is loaded');
    is($result->{failed}, 0, 'nothing failed');
    like($log, qr{frontend ready}, 'the journal says so');

    my $body = serve_index();
    is(tag_count($body), 1, 'exactly one loader tag');
    like($body, qr{<script type="text/javascript" src="/proxmod/loader\.js\?v=[\w.-]+"></script>},
        'and it is a well-formed script tag');

    my $stripped = $body;
    $stripped =~ s{<script type="text/javascript" src="/proxmod/loader\.js[^"]*"></script>\n}{};
    is($stripped, $INDEX, 'the tag is the only difference from the original page');
};

subtest 'the tag lands between pvemanagerlib and Ext.onReady' => sub {
    plan tests => 3;

    reset_all();

    # This is the whole reason the injection point was chosen. Earlier and the
    # PVE.* classes an extension overrides do not exist yet; later and
    # PVE.StdWorkspace has already been created.
    capture_log(sub { Proxmod::Frontend::install([ext()]) });
    my $body = serve_index();

    my $lib = index($body, 'pvemanagerlib.js');
    my $ours = index($body, '/proxmod/loader.js');
    my $ready = index($body, 'Ext.onReady');

    cmp_ok($lib, '>', -1, 'the page loads pvemanagerlib.js');
    cmp_ok($ours, '>', $lib, 'our tag comes after it');
    cmp_ok($ours, '<', $ready, '...and before Ext.onReady');
};

subtest 'injection is idempotent' => sub {
    plan tests => 3;

    reset_all();

    capture_log(sub { Proxmod::Frontend::install([ext()]) });

    my $first = serve_index();
    my $second = serve_index();
    is($second, $first, 'serving the page twice gives the same bytes');
    is(tag_count($second), 1, 'still exactly one tag');

    # A second install — which is what a reload that re-ran INIT would do —
    # must not stack a second wrapper's worth of tags.
    capture_log(sub { Proxmod::Frontend::install([ext()]) });
    is(tag_count(serve_index()), 1, 'and one after a second install');
};

subtest 'the other pages get_index serves are left alone' => sub {
    plan tests => 4;

    reset_all();
    capture_log(sub { Proxmod::Frontend::install([ext()]) });

    # get_index renders four different templates depending on the request
    # [PVE-F-025]. Injecting into the noVNC or xterm.js page would put our
    # loader into a document with no ExtJS in it at all.
    for my $name (qw(novnc-pve pve-xtermjs)) {
        my $body = rendered($name);
        $PVE::Service::pveproxy::BODY = $body;
        is(serve_index(), $body, "the $name page is untouched");
        is(tag_count(serve_index()), 0, "...with no tag in it");
    }
};

subtest 'init adds the routes without disturbing Proxmox own' => sub {
    plan tests => 6;

    reset_all();
    capture_debug_log(sub { Proxmod::Frontend::install([ext()]) });

    my $self = PVE::Service::pveproxy->new;
    my $ret = $self->init;

    is($ret, $self, 'the original return value is passed through');
    is($self->{init_called}, 1, 'the original init ran exactly once');

    my $cfg = $self->{server_config};
    is($cfg->{dirs}{'/proxmod/'}, "$WWW/", 'our static directory is registered');
    is($cfg->{dirs}{'/pve2/css/'}, '/usr/share/pve-manager/css/',
        'and Proxmox own directories survive');
    is(ref($cfg->{pages}{'/proxmod/loader.js'}), 'CODE', 'the loader is a dynamic page');
    is(ref($cfg->{pages}{'/'}), 'CODE', 'and the index page is still Proxmox own');
};

subtest 'the loader body carries the assets in order' => sub {
    plan tests => 6;

    reset_all();

    write_file("$WWW/a.js", '//a');
    write_file("$WWW/b.js", '//b');

    capture_log(sub {
        Proxmod::Frontend::install([
            ext(id => 'first', frontend => { assets => ['a.js'] }),
            ext(id => 'second', frontend => { assets => ['b.js', 'hello.js'] }),
        ]);
    });

    my $body = Proxmod::Frontend::loader_body(Proxmod::Frontend::assets());

    unlike($body, qr{"__PROXMOD_ASSETS__"}, 'the placeholder is gone');

    my ($json) = ($body =~ m{var assets = (\[.*?\]);});
    ok(defined $json, 'the substitution produced an array literal');

    my $assets = JSON::PP->new->decode($json);
    is_deeply(
        [map { $_->{id} } @$assets],
        [qw(proxmod first second second)],
        'proxmod own runtime first, then registry order',
    );
    like($assets->[0]{url}, qr{^/proxmod/proxmod-ui\.js\?v=}, 'the runtime asset url');
    is($assets->[1]{url}, '/proxmod/a.js?v=1.0', 'an extension asset carries its version');
    is($assets->[3]{url}, '/proxmod/hello.js?v=1.0', 'and a second asset from the same one');
};

subtest 'the loader is served as JavaScript, without authentication' => sub {
    plan tests => 4;

    reset_all();
    capture_log(sub { Proxmod::Frontend::install([ext()]) });

    my $self = PVE::Service::pveproxy->new;
    $self->init;

    my $handler = $self->{server_config}{pages}{'/proxmod/loader.js'};
    my ($resp, $userid) = $handler->($self, undef, {});

    is($resp->code, 200, 'it is a 200');
    like($resp->header('Content-Type'), qr{javascript}, 'served as JavaScript');
    like($resp->content, qr{/proxmod/hello\.js}, 'and names the extension asset');

    # Every entry in {pages} is reached before any authentication [PVE-F-022].
    # The undef is not an oversight; it is the contract, and it is why nothing
    # secret may ever appear in this body.
    is($userid, undef, 'no user is associated with the request');
};

subtest 'an asset that is not installed is dropped, loudly' => sub {
    plan tests => 4;

    reset_all();

    # The most common extension packaging bug: the manifest lists a file the
    # .deb forgot to ship. Serving the tag anyway means a 500 from a URL the
    # administrator has never heard of.
    my ($result, $log) = capture_log(sub {
        Proxmod::Frontend::install([ext(id => 'ghost',
            frontend => { assets => ['not-shipped.js'] })]);
    });

    is($result->{loaded}, 0, 'the extension is not counted as loaded');
    is($result->{failed}, 1, 'it is counted as failed');
    like($log, qr{ghost: asset not installed}, 'the journal names the extension and the file');
    unlike(Proxmod::Frontend::loader_body(Proxmod::Frontend::assets()),
        qr{not-shipped\.js}, 'and the loader does not mention it');
};

subtest 'asset names that could escape the www directory are refused' => sub {
    plan tests => 5;

    reset_all();

    # These names are interpolated into JavaScript that pveproxy serves to
    # anyone who can reach port 8006. Proxmod::Registry rejects them too; this
    # is the second lock, and it is here because the cost of one of them
    # getting through is a stored XSS on the login page.
    my @bad = (
        '../../etc/passwd',
        '/etc/passwd',
        'sub/dir.js',
        'evil.js"></script><script>alert(1)</script>',
    );

    my ($result, $log) = capture_log(sub {
        Proxmod::Frontend::install([ext(id => 'nasty', frontend => { assets => \@bad })]);
    });

    is($result->{failed}, 1, 'the extension is dropped');
    like($log, qr{refusing to serve asset}, 'each refusal is logged');

    my $body = Proxmod::Frontend::loader_body(Proxmod::Frontend::assets());
    unlike($body, qr{passwd}, 'nothing traversing out of the directory reached the loader');
    unlike($body, qr{alert\(1\)}, 'and nothing that closes a script tag did either');
    is(scalar(@{ Proxmod::Frontend::assets() }), 1,
        'only proxmod own runtime is left in the list');
};

subtest 'a missing seam costs the frontend and nothing else' => sub {
    plan tests => 4;

    reset_all();

    # What a Proxmox release that renames or removes get_index looks like from
    # in here. The daemon must still start and still serve its own pages.
    {
        no strict 'refs'; ## no critic (ProhibitNoStrict)
        no warnings 'redefine'; ## no critic (ProhibitNoWarnings)
        undef *PVE::Service::pveproxy::get_index;
    }

    my ($result, $log) = capture_log(sub { Proxmod::Frontend::install([ext()]) });

    is($result->{loaded}, 0, 'no extension is reported as loaded');
    is($result->{failed}, 1, 'every frontend extension is reported as failed');
    like($log, qr{index injection: not installed}, 'the journal says which half failed');
    is_deeply(Proxmod::Frontend::assets(), [],
        'and the asset list is emptied so the routes serve nothing');

    reset_all();
};

subtest 'a wrapper that throws still returns Proxmox own answer' => sub {
    plan tests => 3;

    reset_all();
    capture_log(sub { Proxmod::Frontend::install([ext()]) });

    # Simulate the injection blowing up on a page it has never seen. The
    # response the browser gets must be the one Proxmox built.
    my ($body, $log) = capture_log(sub {
        no warnings 'redefine'; ## no critic (ProhibitNoWarnings)
        local *Proxmod::Frontend::inject_tag = sub { die "something unforeseen\n" };
        return serve_index();
    });

    is($body, $INDEX, 'the page is served unmodified');
    like($log, qr{get_index wrapper failed}, 'the failure is recorded');
    like($log, qr{serving Proxmox}, '...along with what happened instead');
};

subtest 'a missing loader runtime is a comment, not a 500' => sub {
    plan tests => 3;

    reset_all();
    capture_log(sub { Proxmod::Frontend::install([ext()]) });

    my ($resp, $log) = capture_log(sub {
        local $Proxmod::Frontend::RUNTIME_FILE = "$ROOT/gone.js";
        my $self = PVE::Service::pveproxy->new;
        $self->init;
        my ($r) = $self->{server_config}{pages}{'/proxmod/loader.js'}->($self, undef, {});
        return $r;
    });

    is($resp->code, 200, 'still a 200');
    like($resp->content, qr{^/\* proxmod:}, 'with an inert body');
    like($log, qr{could not build /proxmod/loader\.js}, 'and a journal line saying why');
};

subtest 'the cache tag changes when the extension set does' => sub {
    plan tests => 2;

    reset_all();
    capture_log(sub { Proxmod::Frontend::install([ext()]) });
    my ($one) = (serve_index() =~ m{loader\.js\?v=([^"]+)});

    reset_all();
    capture_log(sub {
        Proxmod::Frontend::install([ext(), ext(id => 'other',
            frontend => { assets => ['a.js'] })]);
    });
    my ($two) = (serve_index() =~ m{loader\.js\?v=([^"]+)});

    ok(defined $one && defined $two, 'both pages carry a version token');
    isnt($one, $two, 'installing an extension changes it');
};

subtest 'an asset name off disk is rebuilt, not passed through' => sub {
    plan tests => 4;

    reset_all();

    # pveproxy runs under -T, and every asset name reached Frontend by way of
    # Proxmod::Registry reading a manifest off disk — so every one of them
    # arrives tainted. Frontend rebuilds each from a capture against $RE_ASSET.
    # Taint is not the hazard here (nothing in this path execs or requires);
    # it is the evidence. An untainted url proves the value in it came out of
    # the capture and therefore matched the pattern, rather than having been
    # interpolated straight from the manifest into JavaScript.
    my $tainted_name = 'hello.js' . substr(slurp("$WWW/hello.js"), 0, 0);
    ok(is_tainted($tainted_name), 'the name really does arrive tainted');

    capture_log(sub {
        Proxmod::Frontend::install([ext(frontend => { assets => [$tainted_name] })]);
    });

    my ($asset) = grep { $_->{id} eq 'hello' } @{ Proxmod::Frontend::assets() };
    ok(defined $asset, 'the asset survived');
    ok(!is_tainted($asset->{url}), 'and the url it will be served under is untainted');
    is($asset->{url}, '/proxmod/hello.js?v=1.0', 'with the name intact');
};
