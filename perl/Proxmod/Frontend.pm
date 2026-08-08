package Proxmod::Frontend;

use strict;
use warnings;

use Proxmod::Log qw(log_debug log_info log_warn log_error);

use JSON::PP ();

our $VERSION = '0.1.0';

# Getting extension JavaScript into the Proxmox VE web interface without
# modifying a single file that Proxmox owns.
#
# Called from Proxmod::Boot inside pveproxy only, from the INIT phase — so
# PVE::Service::pveproxy is compiled but its init() has not run yet. Two glob
# wraps are installed on that package, each behind its own probe and its own
# eval:
#
#   init      -> add /proxmod/ to the static file table and /proxmod/loader.js
#                to the dynamic page table
#   get_index -> insert exactly one <script> tag into the rendered index
#
# Neither wrap touches a file on disk. `dpkg -V pve-manager` is clean after
# installing proxmod, which is the entire point of the design and the property
# every change to this file has to preserve.
#
# THE PRIME DIRECTIVE. Everything here runs inside the process that serves the
# web interface. A missing tab is acceptable; a pveproxy that will not start, or
# an index page that fails to render, is not. Every wrapper calls through to the
# original first and treats its own work as optional.

# The package we wrap. A variable so the tests can point at a double, not
# because it is ever anything else in production.
our $TARGET = 'PVE::Service::pveproxy';

# Where extension assets live, and the URL prefix they are served under. Both
# are string literals, and that is load-bearing: pveproxy runs under -T, and a
# path derived from readdir would be tainted. See _add_routes.
our $WWW_DIR = '/usr/share/proxmod/www';
our $URL_PREFIX = '/proxmod/';
our $LOADER_PATH = '/proxmod/loader.js';

# Read at request time and substituted into. Deliberately NOT under $WWW_DIR:
# everything in there is served to unauthenticated clients, and this file is a
# template with a placeholder in it, not something to hand out.
our $RUNTIME_FILE = '/usr/share/proxmod/loader-runtime.js';
our $RUNTIME_PLACEHOLDER = '"__PROXMOD_ASSETS__"';

# proxmod's own asset, always loaded before any extension's. It creates the
# Proxmod global that every extension asset expects to find.
our $UI_ASSET = 'proxmod-ui.js';

# Repeated from Proxmod::Registry rather than imported. The value is
# interpolated into JavaScript that pveproxy serves to unauthenticated clients,
# and a second bounds check on the way out costs one regex.
my $RE_ASSET = qr/\A([A-Za-z0-9][A-Za-z0-9._-]{0,127}\.js)\z/;
my $RE_ID = qr/\A([a-z0-9][a-z0-9_-]{0,63})\z/;
my $RE_VERSION = qr/\A([A-Za-z0-9][A-Za-z0-9._+~-]{0,31})\z/;

# The asset list the loader is generated from, set once at boot.
my $ASSETS = [];

# Only for the tests.
sub _reset { $ASSETS = []; return }

sub assets { return $ASSETS }

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

# Returns { loaded => n, failed => n }, counted in extensions: an extension
# whose assets are queued is loaded, one we had to drop is failed. If the seam
# itself is gone, every frontend extension has failed, which is exactly what an
# administrator needs told.
sub install {
    my ($exts) = @_;

    my @wanted = grep { $_->{frontend} && @{ $_->{frontend}{assets} || [] } } @{ $exts || [] };

    if (!@wanted) {
        # Nothing to serve, so nothing is wrapped and the index is not touched.
        # proxmod's footprint on a host with no frontend extension is zero.
        log_debug('no extension declares a frontend asset, leaving the index alone');
        return { loaded => 0, failed => 0 };
    }

    my ($assets, $failed) = _collect(\@wanted);
    $ASSETS = $assets;

    my $loaded = scalar(@wanted) - $failed;

    for my $stage (['static routes', \&_wrap_init], ['index injection', \&_wrap_get_index]) {
        my ($name, $code) = @$stage;
        my $ok = eval {
            local $SIG{__DIE__} = 'DEFAULT';
            $code->();
            1;
        };
        next if $ok;

        my $err = $@ || 'unknown error';
        $err =~ s/\s+$//;
        $err =~ s/\s*\n\s*/ /g;
        log_error("$name: not installed, the web interface is unchanged: $err");

        # The order of the two stages is what keeps a partial install safe. If
        # the routes fail we never reach the injection, so there is no tag
        # pointing at a URL nothing serves. If the injection fails the routes
        # are live but unreferenced, which costs nothing. Emptying the asset
        # list makes the second case inert as well.
        $ASSETS = [];
        return { loaded => 0, failed => scalar(@wanted) };
    }

    log_info('frontend ready: ' . scalar(@$assets) . ' asset(s) below /proxmod/');

    return { loaded => $loaded, failed => $failed };
}

# Build the ordered asset list. proxmod's own runtime first, then each
# extension's assets in registry order.
sub _collect {
    my ($exts) = @_;

    my @assets = ({
        id => 'proxmod',
        file => $UI_ASSET,
        url => "$URL_PREFIX$UI_ASSET?v=$VERSION",
    });

    my $failed = 0;

    for my $ext (@$exts) {
        my ($id) = (($ext->{id} // '') =~ $RE_ID);
        if (!defined $id) {
            log_warn('frontend: ignoring an extension with an unusable id');
            $failed++;
            next;
        }

        my ($version) = (("" . ($ext->{version} // '0')) =~ $RE_VERSION);
        $version = '0' if !defined $version;

        my @ok;
        for my $name (@{ $ext->{frontend}{assets} }) {
            my ($file) = (($name // '') =~ $RE_ASSET);
            if (!defined $file) {
                log_warn("$id: refusing to serve asset '" . ($name // 'undef') . "'");
                next;
            }

            # A manifest naming a file that is not installed is a packaging
            # bug, and the browser would report it as a 500 from a URL nobody
            # recognises. Catch it here, where the message can name the
            # extension.
            if (!-f "$WWW_DIR/$file") {
                log_warn("$id: asset not installed, skipping it: $WWW_DIR/$file");
                next;
            }

            push @ok, {
                id => $id,
                file => $file,
                # The query string is cache-busting only. pveproxy serves
                # /proxmod/ files with an Expires header of now, so this exists
                # for intermediate caches and for humans reading a HAR.
                url => "$URL_PREFIX$file?v=$version",
            };
        }

        if (!@ok) {
            log_warn("$id: declared a frontend but none of its assets are usable");
            $failed++;
            next;
        }

        push @assets, @ok;
        log_debug("$id: " . scalar(@ok) . ' frontend asset(s) queued');
    }

    return (\@assets, $failed);
}

# ---------------------------------------------------------------------------
# The wraps
# ---------------------------------------------------------------------------

# Replace $TARGET::$name with a sub that calls the original and then does our
# work. Dies if the seam is not there, which the caller turns into one log line
# and no injection.
sub _wrap {
    my ($name, $after) = @_;

    my $orig = $TARGET->can($name)
        or die "$TARGET has no $name() to wrap; this is not a Proxmox VE we know\n";

    {
        no strict 'refs'; ## no critic (ProhibitNoStrict)
        no warnings 'redefine'; ## no critic (ProhibitNoWarnings)
        *{"${TARGET}::${name}"} = sub {
            my @args = @_;
            my @ret = $orig->(@args);

            # Our half is optional; theirs is not. Whatever happens below, the
            # original's return value is what the caller gets.
            my $ok = eval {
                local $SIG{__DIE__} = 'DEFAULT';
                $after->(\@args, \@ret);
                1;
            };
            if (!$ok) {
                my $err = $@ || 'unknown error';
                $err =~ s/\s+$//;
                $err =~ s/\s*\n\s*/ /g;
                log_error("$name wrapper failed, serving Proxmox's own output: $err");
            }

            return wantarray ? @ret : $ret[0];
        };
    }

    log_debug("wrapped ${TARGET}::${name}");

    return;
}

sub _wrap_init { return _wrap('init', \&_add_routes) }

sub _wrap_get_index { return _wrap('get_index', sub { _inject($_[1][0]) }) }

# ---------------------------------------------------------------------------
# Serving /proxmod/
# ---------------------------------------------------------------------------

# init() builds $self->{server_config}, which is what PVE::APIServer::AnyEvent
# consumes: {dirs} maps a URL prefix to a directory, {pages} maps an exact path
# to a handler [PVE-F-024]. Adding to both is all the routing we need.
sub _add_routes {
    my ($args) = @_;

    my $self = $args->[0];
    my $cfg = ref($self) ? $self->{server_config} : undef;
    die "no server_config after init(); not adding any route\n" if ref($cfg) ne 'HASH';

    # NOT PVE::APIServer::AnyEvent::add_dirs. That helper walks the directory
    # with File::Find to register every subdirectory as its own alias, and under
    # -T every path it produces is tainted [PVE-F-025]. We serve one flat
    # directory, so a literal assignment does the same job and cannot be
    # tainted by construction.
    $cfg->{dirs} = {} if ref($cfg->{dirs}) ne 'HASH';
    $cfg->{dirs}{$URL_PREFIX} = "$WWW_DIR/";

    # pages is checked before dirs and matched on the exact path, so this wins
    # over any file that happens to be called loader.js.
    $cfg->{pages} = {} if ref($cfg->{pages}) ne 'HASH';
    $cfg->{pages}{$LOADER_PATH} = sub { return _loader_page(@_) };

    log_debug("serving $URL_PREFIX from $WWW_DIR, and $LOADER_PATH dynamically");

    return;
}

# The dynamic page handler. AnyEvent calls it as ($server, $request, $params)
# and expects ($response, $userid).
#
# NOTE: like every entry in {pages}, this is reached WITHOUT authentication
# [PVE-F-023]. It returns the names of the installed extensions and nothing
# else, and must never return more than that.
sub _loader_page {
    my $body;

    my $ok = eval {
        local $SIG{__DIE__} = 'DEFAULT';
        $body = loader_body($ASSETS);
        1;
    };
    if (!$ok) {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+$//;
        $err =~ s/\s*\n\s*/ /g;
        log_error("could not build $LOADER_PATH: $err");

        # 200 with an inert body, not a 500. The tag is in the page already; a
        # 500 here puts a red line in every administrator's console on every
        # page load, and changes nothing about the outcome.
        $body = "/* proxmod: loader unavailable, see the pveproxy journal */\n";
    }

    require HTTP::Headers;
    require HTTP::Response;

    my $headers = HTTP::Headers->new(
        Content_Type => 'application/javascript; charset=utf-8',
    );

    return (HTTP::Response->new(200, 'OK', $headers, $body), undef);
}

# Generate the loader from the runtime template and the asset list. Separated
# from the page handler so the tests can call it directly.
sub loader_body {
    my ($assets) = @_;

    my $runtime = _read_file($RUNTIME_FILE);
    die "cannot read $RUNTIME_FILE: $!\n" if !defined $runtime;

    # Exactly once, or not at all. A second occurrence — a comment mentioning
    # the placeholder is the way this happens — means substr would land on the
    # wrong one and produce a syntactically valid loader that loads nothing.
    my $count = () = ($runtime =~ /\Q$RUNTIME_PLACEHOLDER\E/g);
    die "$RUNTIME_FILE does not contain the asset placeholder\n" if $count == 0;
    die "$RUNTIME_FILE contains the asset placeholder $count times\n" if $count > 1;

    my $index = index($runtime, $RUNTIME_PLACEHOLDER);

    # canonical for a byte-identical body from an identical registry, which is
    # what makes the loader diffable across two hosts in a cluster.
    my $json = JSON::PP->new->canonical->encode([
        map { { id => $_->{id}, url => $_->{url} } } @{ $assets || [] }
    ]);

    substr($runtime, $index, length($RUNTIME_PLACEHOLDER)) = $json;

    return $runtime;
}

sub _read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    binmode($fh);
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content;
}

# ---------------------------------------------------------------------------
# Injecting the tag
# ---------------------------------------------------------------------------

# The rendered index only. get_index also serves the noVNC, xterm.js and mobile
# pages from different templates [PVE-F-022]; this string appears in the
# manager index and in none of the others, which is what makes the no-op on
# those pages structural rather than a list of exceptions to maintain.
our $INDEX_MARKER = 'pvemanagerlib.js';

sub _inject {
    my ($resp) = @_;

    return if !ref($resp);
    return if !eval { $resp->can('content') };

    my $body = $resp->content;
    return if !defined $body || $body eq '';

    my $new = inject_tag($body);
    return if !defined $new;

    $resp->content($new);

    # Content-Length is recomputed by PVE::APIServer::AnyEvent::response from
    # the content we just replaced [PVE-F-026], so there is no header to fix.
    return;
}

# Returns the new body, or undef if nothing should change. Pure, so the unit
# tests can run it against the real vendored index.html.tpl.
sub inject_tag {
    my ($body) = @_;

    return undef if index($body, $INDEX_MARKER) < 0;

    # Idempotent. A second wrap installed by a reload, or by another copy of
    # proxmod, must not produce two tags.
    return undef if index($body, $LOADER_PATH) >= 0;

    my $at = _anchor($body);
    if (!defined $at) {
        log_warn('could not find the injection point in the index page;'
            . ' no extension frontend will load');
        return undef;
    }

    my $tag = qq{<script type="text/javascript" src="$LOADER_PATH?v=}
        . _cache_tag() . qq{"></script>\n};

    substr($body, $at, 0) = $tag;

    return $body;
}

# Where the tag goes: immediately before the inline block that calls
# Ext.onReady, which is the last script in <head> [PVE-F-021]. At that point
# every PVE.* class is defined and no ready handler has been registered, so an
# extension can override a class and still be in place before the workspace is
# built.
sub _anchor {
    my ($body) = @_;

    my $ready = index($body, 'Ext.onReady');
    if ($ready >= 0) {
        my $tag = rindex($body, '<script', $ready);
        return $tag if $tag >= 0;
    }

    # Fallback for an index that has moved the ready call: straight after the
    # script tag that loads pvemanagerlib.js. Later than ideal only in that a
    # locale file loads after us, which no extension depends on.
    my $lib = index($body, $INDEX_MARKER);
    if ($lib >= 0) {
        my $end = index($body, '</script>', $lib);
        return $end + length('</script>') + 1 if $end >= 0;
    }

    return undef;
}

# A short token that changes when the set of extensions changes, so a browser
# behind a caching proxy picks up a newly installed extension. Not a checksum
# in any security sense — unpack's %32C* is a sum of bytes, and is used here
# precisely because nobody could mistake it for one.
sub _cache_tag {
    my $material = join('|', $VERSION, map { "$_->{id}:$_->{url}" } @$ASSETS);
    return sprintf('%s-%08x', $VERSION, unpack('%32C*', $material));
}

1;
