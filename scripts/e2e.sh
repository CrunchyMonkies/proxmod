#!/bin/bash
# e2e.sh — the host side of the integration suite.
#
# Builds both packages, boots a throwaway VM on top of the golden PVE image,
# copies the packages and the tests in, runs them, and brings the VM down.
# `make e2e` is this script with no arguments.
#
# The unit tests under t/ prove the code does what it says on a machine with no
# Proxmox on it. This proves the claims that can only be made about a live
# host: that a Proxmox daemon really is running our module, that an upgrade of
# pve-manager really does leave it running, and that removing the package
# really does leave the host as it was found.
#
# Nothing here touches the golden image. vm.sh boots a fresh qcow2 overlay and
# deletes it on stop, so a test that wrecks the host costs one run, not the
# forty minutes it takes to build a new image.
#
# Usage:
#     scripts/e2e.sh                 # build, boot, run everything, tear down
#     scripts/e2e.sh 03 07           # only those tests
#     PROXMOD_KEEP_VM=1 scripts/e2e.sh    # leave the VM up to poke at
#     PROXMOD_SKIP_BUILD=1 scripts/e2e.sh # reuse the debs already built
#
# Environment (see test/qemu/vm.sh for the rest):
#     PROXMOD_PVE_IMAGE   golden qcow2; build one with `test/qemu/vm.sh install`
#     PROXMOD_PVE_ISO     installer ISO; also the offline repo for test 08

set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
VM="$HERE/test/qemu/vm.sh"

KEEP_VM="${PROXMOD_KEEP_VM:-0}"
SKIP_BUILD="${PROXMOD_SKIP_BUILD:-0}"
STAGE="$HERE/test/qemu/.run/debs"
REMOTE_ROOT=/root/proxmod-e2e

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 is not installed"

image="${PROXMOD_PVE_IMAGE:-$HERE/test/qemu/pve-test.qcow2}"
[ -f "$image" ] || die "no golden image at $image
  Build one once with:  test/qemu/vm.sh install
  Or point PROXMOD_PVE_IMAGE at an existing PVE 9.x qcow2."

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

if [ "$SKIP_BUILD" = "1" ]; then
    say "reusing the packages already staged in $STAGE"
    [ -d "$STAGE" ] || die "nothing staged; run without PROXMOD_SKIP_BUILD first"
else
    say "building proxmod"
    ( cd "$HERE" && dpkg-buildpackage -us -uc -b ) \
        || die "the proxmod package did not build"

    say "building the example extension"
    ( cd "$HERE/examples/proxmod-example-hello" && dpkg-buildpackage -us -uc -b ) \
        || die "the example package did not build"

    rm -rf "$STAGE"; mkdir -p "$STAGE"

    # dpkg-buildpackage drops its output next to the source tree, so the
    # framework lands beside the repo and the example beside examples/.
    for glob in "$HERE/../proxmod_"*_all.deb "$HERE/examples/proxmod-example-hello_"*_all.deb; do
        for f in $glob; do [ -f "$f" ] && cp "$f" "$STAGE/"; done
    done

    ls "$STAGE"/proxmod_*_all.deb              >/dev/null 2>&1 || die "no proxmod deb was produced"
    ls "$STAGE"/proxmod-example-hello_*_all.deb >/dev/null 2>&1 || die "no example deb was produced"
    printf '  staged: %s\n' "$(cd "$STAGE" && echo *.deb)"
fi

# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------

started_vm=0
# `status` prints its answer rather than encoding it in an exit code, because
# it is written for a person at a terminal.
if "$VM" status 2>/dev/null | grep -q '^running'; then
    say "reusing the VM that is already running"
else
    say "booting a throwaway VM on an overlay over $(basename "$image")"
    "$VM" start || die "the VM did not come up"
    started_vm=1
fi

# shellcheck disable=SC2317,SC2329 # reached through the trap below, not by falling into
cleanup() {
    local rc=$?
    if [ "$started_vm" = "1" ] && [ "$KEEP_VM" != "1" ]; then
        say "stopping the VM"
        "$VM" stop >/dev/null 2>&1 || true
    elif [ "$KEEP_VM" = "1" ]; then
        printf '\n  VM left running. Shell in with:  test/qemu/vm.sh ssh\n'
        printf '  Web interface:                  https://localhost:%s/\n' \
            "${PROXMOD_WEB_PORT:-18006}"
        printf '  Stop it with:                   test/qemu/vm.sh stop\n\n'
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Copy in and run
# ---------------------------------------------------------------------------

say "copying the packages and tests into the VM"
"$VM" ssh "rm -rf $REMOTE_ROOT && mkdir -p $REMOTE_ROOT/debs" \
    || die "could not prepare $REMOTE_ROOT in the VM"
"$VM" push "$STAGE/."               "$REMOTE_ROOT/debs/"  || die "could not copy the packages in"
"$VM" push "$HERE/test/integration" "$REMOTE_ROOT/"       || die "could not copy the tests in"
"$VM" ssh "chmod +x $REMOTE_ROOT/integration/*.sh"

say "running the suite"
"$VM" ssh "PROXMOD_ROOT_PW='${PROXMOD_ROOT_PW:-testpassword}' \
           DEB_DIR=$REMOTE_ROOT/debs \
           $REMOTE_ROOT/integration/run.sh $*"
rc=$?

# ---------------------------------------------------------------------------
# Evidence
#
# Pulled out whether the run passed or failed: on a pass it is the record of
# what was proved, and on a failure it is usually the only place the reason is
# written down, since the VM is about to be destroyed.
# ---------------------------------------------------------------------------

artifacts="$HERE/test/qemu/.run/artifacts"
rm -rf "$artifacts"; mkdir -p "$artifacts"

say "collecting evidence into test/qemu/.run/artifacts"
for unit in pvedaemon pveproxy; do
    "$VM" ssh "journalctl -u $unit --no-pager -n 500" > "$artifacts/$unit.log" 2>&1 || true
done
"$VM" ssh "systemctl cat pvedaemon pveproxy 2>&1" > "$artifacts/units.txt" 2>&1 || true
"$VM" ssh "proxmod-verify --json 2>/dev/null || true" > "$artifacts/verify.json" 2>&1 || true
"$VM" pull /var/tmp/proxmod-e2e "$artifacts/state" 2>/dev/null || true

if [ "$rc" -eq 0 ]; then
    printf '\n\033[32m==> the integration suite passed\033[0m\n\n'
else
    printf '\n\033[31m==> the integration suite failed (exit %d)\033[0m\n' "$rc"
    printf '    evidence: %s\n\n' "$artifacts"
fi

exit "$rc"
