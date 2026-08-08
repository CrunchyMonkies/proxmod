#!/bin/sh
# extract-pve-source.sh - read PVE source out of a Proxmox VE installer ISO.
#
# proxmod attaches to Proxmox VE at seams that are not documented API. Every
# claim we make about those seams has to be re-checkable against a specific
# pve-manager version, ideally by someone who does not have a PVE host to hand.
# This script is that mechanism: it streams files straight out of the .debs
# inside an installer ISO, writing nothing but what you asked for.
#
# Nothing here needs root, a loop mount, or a running Proxmox.
#
#   ./scripts/extract-pve-source.sh --iso pve.iso --list
#   ./scripts/extract-pve-source.sh --iso pve.iso --cat pve-manager \
#       ./usr/share/perl5/PVE/Service/pveproxy.pm
#   ./scripts/extract-pve-source.sh --iso pve.iso --control pve-manager triggers
#   ./scripts/extract-pve-source.sh --iso pve.iso --harvest docs/facts
#
set -eu

ISO=
MODE=
PKG=
MEMBER=
OUTDIR=

die() { echo "extract-pve-source: $*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --iso)     ISO=${2:?--iso needs a path}; shift 2 ;;
        --list)    MODE=list; shift ;;
        --cat)     MODE='cat';     PKG=${2:?--cat needs a package}; MEMBER=${3:?--cat needs a path}; shift 3 ;;
        --control) MODE=control; PKG=${2:?--control needs a package}; MEMBER=${3:?--control needs a member}; shift 3 ;;
        --harvest) MODE=harvest; OUTDIR=${2:?--harvest needs an output dir}; shift 2 ;;
        -h|--help) usage 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[ -n "$ISO" ]  || die "no --iso given"
[ -r "$ISO" ]  || die "cannot read ISO: $ISO"
[ -n "$MODE" ] || die "no mode given (--list, --cat, --control, --harvest)"

command -v 7z       >/dev/null 2>&1 || die "7z not found (apt install p7zip-full)"
command -v python3  >/dev/null 2>&1 || die "python3 not found"

# ---------------------------------------------------------------------------
# A .deb is an `ar` archive. `ar` cannot read a stream and bsdtar is not always
# installed, so we parse the (very simple) ar header format inline, emitting the
# one member we want on stdout. We decompress here too: GNU tar only sniffs
# compression on seekable input, and Debian has moved between gzip, xz and zstd
# over the years, so the shell downstream always gets a plain tar. Nothing
# touches the disk.
# ---------------------------------------------------------------------------
AR_MEMBER='
import sys, gzip, bz2, lzma, subprocess
want = sys.argv[1]
b = sys.stdin.buffer.read()
if b[:8] != b"!<arch>\n":
    sys.exit("not an ar archive (deb): %r" % b[:8])

def decompress(d):
    if d[:6] == b"\xfd7zXZ\x00":      return lzma.decompress(d)
    if d[:2] == b"\x1f\x8b":          return gzip.decompress(d)
    if d[:3] == b"BZh":               return bz2.decompress(d)
    if d[:4] == b"\x28\xb5\x2f\xfd":
        try:                          # python 3.14+
            import compression.zstd as z
            return z.decompress(d)
        except ImportError:
            pass
        try:
            return subprocess.run(["zstd", "-dc"], input=d, check=True,
                                  stdout=subprocess.PIPE).stdout
        except (OSError, subprocess.CalledProcessError):
            sys.exit("zstd member needs python 3.14+ or the zstd binary")
    return d                          # already a plain tar

o = 8
while o + 60 <= len(b):
    h = b[o:o+60]; o += 60
    name = h[0:16].decode("ascii", "replace").strip().rstrip("/")
    try:
        size = int(h[48:58].decode("ascii").strip())
    except ValueError:
        sys.exit("corrupt ar header at offset %d" % (o - 60))
    data = b[o:o+size]; o += size + (size % 2)
    if name.startswith(want):
        sys.stdout.buffer.write(decompress(data))
        sys.exit(0)
sys.exit("no ar member starting with %r" % want)
'

# GNU tar sniffs the compression itself when reading, so this copes with the
# gzip/xz/zstd churn Debian has been through without us having to guess.
untar_stdin() { # $1 = path inside the tar
    tar -xO -f - "$1" || die "member not found in tarball: $1"
}

deb_path_in_iso() { # $1 = source package name -> path inside ISO
    7z l -ba "$ISO" 2>/dev/null \
        | awk '{ print $NF }' \
        | grep -E "^proxmox/packages/${1}_[^/]*\.deb$" \
        | head -1
}

stream_deb() { # $1 = package name -> .deb bytes on stdout
    _p=$(deb_path_in_iso "$1")
    [ -n "$_p" ] || die "package not found in ISO: $1"
    7z x -so "$ISO" "$_p" 2>/dev/null
}

case "$MODE" in
list)
    7z l -ba "$ISO" 2>/dev/null | awk '{ print $NF }' \
        | grep -E '^proxmox/packages/.*\.deb$' | sort
    ;;

cat)
    stream_deb "$PKG" | python3 -c "$AR_MEMBER" data.tar | untar_stdin "$MEMBER"
    ;;

control)
    stream_deb "$PKG" | python3 -c "$AR_MEMBER" control.tar | untar_stdin "./$MEMBER"
    ;;

harvest)
    mkdir -p "$OUTDIR"
    ver=$(deb_path_in_iso pve-manager | sed -E 's|.*/pve-manager_([^_]+)_.*|\1|')
    [ -n "$ver" ] || die "could not determine pve-manager version"
    out="$OUTDIR/pve-$ver.txt"

    # Cache the two .debs we read repeatedly. /dev/shm keeps it off the repo.
    tmp=$(mktemp -d "${TMPDIR:-/dev/shm}/proxmod-harvest.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT INT TERM
    stream_deb pve-manager > "$tmp/pve-manager.deb"
    python3 -c "$AR_MEMBER" data.tar    < "$tmp/pve-manager.deb" > "$tmp/data.tar"
    python3 -c "$AR_MEMBER" control.tar < "$tmp/pve-manager.deb" > "$tmp/control.tar"

    # libpve-http-server-perl carries the request router; three of our facts
    # live there rather than in pve-manager.
    stream_deb libpve-http-server-perl > "$tmp/http.deb"
    python3 -c "$AR_MEMBER" data.tar < "$tmp/http.deb" > "$tmp/http-data.tar"

    # The REST tree's registration rules live in libpve-common-perl, and the
    # permission default that decides who may call a method lives in
    # libpve-access-control. Neither is pve-manager, and both are load-bearing
    # for what Proxmod::API refuses to let an extension do.
    stream_deb libpve-common-perl > "$tmp/common.deb"
    python3 -c "$AR_MEMBER" data.tar < "$tmp/common.deb" > "$tmp/common-data.tar"
    stream_deb libpve-access-control > "$tmp/access.deb"
    python3 -c "$AR_MEMBER" data.tar < "$tmp/access.deb" > "$tmp/access-data.tar"

    from_data()    { tar -xO -f "$tmp/data.tar"    "$1"   2>/dev/null || true; }
    from_control() { tar -xO -f "$tmp/control.tar" "./$1" 2>/dev/null || true; }
    from_http()    { tar -xO -f "$tmp/http-data.tar" "$1" 2>/dev/null || true; }
    from_common()  { tar -xO -f "$tmp/common-data.tar" "$1" 2>/dev/null || true; }
    from_access()  { tar -xO -f "$tmp/access-data.tar" "$1" 2>/dev/null || true; }

    {
        echo "# proxmod PVE fact harvest"
        echo "# iso:         $(basename "$ISO")"
        echo "# pve-manager: $ver"
        echo "# generated by scripts/extract-pve-source.sh (offline, from the ISO)"
        echo "#"
        echo "# Each block below is raw evidence for a [PVE-F-nnn] entry in"
        echo "# docs/pve-facts.md. Regenerate after every PVE point release and"
        echo "# diff, to see exactly which of our assumptions moved."
        echo

        echo "=== [PVE-F-002] pveproxy/pvedaemon run under taint mode (-T) ==="
        for d in pveproxy pvedaemon pvestatd; do
            printf '%s: ' "$d"; from_data "./usr/bin/$d" | head -1
        done
        echo

        echo "=== [PVE-F-020] the index-render seam in PVE::Service::pveproxy ==="
        # shellcheck disable=SC2016 # the $ are Perl sigils we are grepping for
        from_data ./usr/share/perl5/PVE/Service/pveproxy.pm \
            | grep -nE "sub get_index|pages *=>|dirs *=>|'/' *=>|index\.html\.tpl|template->process|HTTP::Response->new" \
            || echo "!! SEAM NOT FOUND - the frontend design assumption has broken"
        echo

        echo "=== [PVE-F-005] pve-manager reloads the daemons from its own postinst ==="
        from_control postinst \
            | grep -nE "reload-or-try-restart|pve-ssl\.pem|proxmox_install_mode|^ *triggered\)" \
            || echo "!! no reload path found in postinst"
        echo

        echo "=== [PVE-F-010] pve-manager uses dpkg triggers (our precedent) ==="
        from_control triggers || echo "(no triggers file)"
        echo

        echo "=== [PVE-F-021] index.html.tpl script order (our injection anchor) ==="
        from_data ./usr/share/pve-manager/index.html.tpl | grep -nE "<script|</head>" || true
        echo

        echo "=== [PVE-F-022] the four templates get_index can serve ==="
        # shellcheck disable=SC2016 # the $ are Perl sigils we are grepping for
        from_data ./usr/share/perl5/PVE/Service/pveproxy.pm \
            | grep -nE '\$basedirs->\{(manager|novnc|xtermjs|yew_mobile)\}|\$dir = ' \
            || echo "!! the template dispatch has moved - check the no-op on non-index pages"
        echo

        echo "=== [PVE-F-024] the pages/dirs routing tables ==="
        # shellcheck disable=SC2016 # the $ are Perl sigils we are grepping for
        from_http ./usr/share/perl5/PVE/APIServer/AnyEvent.pm \
            | grep -nE '\$self->\{pages\}|\$self->\{dirs\}|\^\(/\\S\+/\)' \
            || echo "!! the routing tables have moved - /proxmod/ will not be served"
        echo

        echo "=== [PVE-F-025] add_dirs walks the tree with File::Find ==="
        # shellcheck disable=SC2016 # the $ are Perl sigils we are grepping for
        from_http ./usr/share/perl5/PVE/APIServer/AnyEvent.pm \
            | grep -nE 'sub add_dirs|File::Find::dir|find\(\{' \
            || echo "(add_dirs not found; we do not call it, but the reasoning cites it)"
        echo

        echo "=== [PVE-F-026] Content-Length is recomputed from the body ==="
        # shellcheck disable=SC2016 # the $ are Perl sigils we are grepping for
        from_http ./usr/share/perl5/PVE/APIServer/AnyEvent.pm \
            | grep -nE 'content_length = length|Content-Length" =>' \
            || echo "!! Content-Length may no longer be recomputed - check the injection"
        echo

        echo "=== [PVE-F-030] ExtJS hook-host classes available to override ==="
        from_data ./usr/share/pve-manager/js/pvemanagerlib.js \
            | grep -noE "Ext\.define\('PVE\.(node|dc|qemu|lxc|storage)\.Config'" | head -20 \
            || echo "(pvemanagerlib.js not present or classes renamed)"
        echo

        echo "=== [PVE-F-031] insertNodes, the tab-insertion entry point ==="
        from_data ./usr/share/pve-manager/js/pvemanagerlib.js \
            | grep -noE "insertNodes: *function|insertNodes\(" | head -10 \
            || echo "!! insertNodes not found - the tab helper design has broken"
        echo

        echo "=== [PVE-F-032] what insertNodes throws on, and what it mutates ==="
        from_data ./usr/share/pve-manager/js/pvemanagerlib.js \
            | grep -noE "itemId already exists[^']*|id already exists|item\.groups\.shift\(\)|savedItems\[item\.itemId\]" \
            | head -10 \
            || echo "!! the collision behaviour has changed - recheck Proxmod.ui itemId handling"
        echo

        echo "=== [PVE-F-050] a method with no 'permissions' is root@pam-only ==="
        # The whole sub, not matching lines: the default is expressed by which
        # branch is missing, and a grep cannot show an absence.
        from_access ./usr/share/perl5/PVE/RPCEnvironment.pm \
            | sed -n '/^sub check_api2_permissions/,/^}/p' \
            | grep . \
            || echo "!! check_api2_permissions has moved - recheck Proxmod::API::_check_permissions"
        echo

        echo "=== [PVE-F-051] register_method's path rules, and fragmentDelimiter ==="
        from_common ./usr/share/perl5/PVE/RESTHandler.pm \
            | grep -nE "duplicate path|duplicate method definition|regex and fixed items|method name already defined|fragmentDelimiter|we only support the empty string" \
            | head -14 \
            || echo "!! the registration rules have moved - recheck Proxmod::API"
        echo

        echo "=== [PVE-F-052] the request lifecycle: permissions, proxyto, protected ==="
        # The order of these three decisions is the whole reason a backend
        # extension has to register in both daemons, and the reason an
        # unregistered path answers 501 rather than 404.
        from_data ./usr/share/perl5/PVE/HTTPServer.pm \
            | sed -n '/^sub rest_handler/,/^}/p' \
            | grep -nE "NOT_IMPLEMENTED|not implemented|find_handler|check_api2_permissions|proxyto|protected|euid|proxy => 'localhost'" \
            || echo "!! rest_handler has moved - recheck the daemon split in the docs"
        echo

        echo "=== [PVE-F-053] where each daemon listens, and as whom ==="
        from_data ./usr/share/perl5/PVE/Service/pvedaemon.pm \
            | grep -nE "max_workers|create_reusable_socket|trusted_env" \
            || echo "!! pvedaemon's socket setup has moved"
        # shellcheck disable=SC2016 # the $ are Perl sigils we are grepping for
        from_data ./usr/share/perl5/PVE/Service/pveproxy.pm \
            | grep -nE "setuid|setgid|max_workers|create_reusable_socket|trusted_env" \
            || echo "!! pveproxy's socket setup has moved"
    } > "$out"

    echo "wrote $out"
    ;;
esac
