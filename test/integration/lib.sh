#!/bin/bash
# lib.sh — assertions and shared helpers for the integration suite.
#
# These scripts run INSIDE the VM, as root, in order, sharing state through
# $STATE_DIR. They are numbered because several of them depend on what the
# previous one left behind: 00 captures the pristine baseline that 02 and 11
# compare against, and 11 purges what 01 installed.

# shellcheck shell=bash

set -uo pipefail

STATE_DIR="${STATE_DIR:-/var/tmp/proxmod-e2e}"
DEB_DIR="${DEB_DIR:-/root/proxmod-e2e/debs}"
ISO_MNT="${ISO_MNT:-/mnt/proxmod-iso}"

mkdir -p "$STATE_DIR"

PASS=0
FAIL=0
FAILED_NAMES=()

# ------------------------------------------------------------- reporting

_green() { printf '\033[32m%s\033[0m' "$1"; }
_red()   { printf '\033[31m%s\033[0m' "$1"; }
_dim()   { printf '\033[2m%s\033[0m' "$1"; }

describe() { printf '\n%s\n' "$(_dim "--- $* ---")"; }

ok() {
    PASS=$((PASS + 1))
    printf '  %s %s\n' "$(_green 'ok  ')" "$1"
}

no() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$1")
    printf '  %s %s\n' "$(_red 'FAIL')" "$1"
    [ "$#" -gt 1 ] && printf '       %s\n' "$2"
    return 0
}

# Every test script ends with this. Non-zero exit stops the run.
summary() {
    printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
    if [ "$FAIL" -gt 0 ]; then
        printf '\n  failed:\n'
        for n in "${FAILED_NAMES[@]}"; do printf '    - %s\n' "$n"; done
        return 1
    fi
    return 0
}

# ------------------------------------------------------------ assertions

# assert <name> <command...> — passes when the command exits 0.
assert() {
    local name="$1"; shift
    local out
    if out=$("$@" 2>&1); then
        ok "$name"
    else
        no "$name" "exit $? from: $* ${out:+| $out}"
    fi
}

# refute <name> <command...> — passes when the command exits non-zero.
refute() {
    local name="$1"; shift
    local out
    if out=$("$@" 2>&1); then
        no "$name" "expected failure, got exit 0 from: $* ${out:+| $out}"
    else
        ok "$name"
    fi
}

# assert_eq <name> <expected> <actual>
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        ok "$name"
    else
        no "$name" "expected '$want', got '$got'"
    fi
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) ok "$name" ;;
        *)           no "$name" "expected to find '$needle' in: $(printf '%.400s' "$hay")" ;;
    esac
}

# refute_contains <name> <needle> <haystack>
refute_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) no "$name" "did not expect '$needle' in: $(printf '%.400s' "$hay")" ;;
        *)           ok "$name" ;;
    esac
}

skip() { printf '  %s %s\n' "$(_dim 'skip')" "$1"; }

# ---------------------------------------------------------------- helpers

# The three packages whose files proxmod claims never to touch.
PVE_PACKAGES="pve-manager libpve-common-perl libpve-http-server-perl"

# dpkg -V prints nothing when every file matches its recorded checksum. That
# silence is the headline claim, and it is checked after install, after an
# upgrade, and after purge.
dpkg_verify_pve() {
    # shellcheck disable=SC2086  # deliberate word splitting of the package list
    dpkg -V $PVE_PACKAGES 2>&1
}

# A checksum of every dpkg-owned file in the two trees proxmod could plausibly
# want to edit. Stronger than dpkg -V: it also catches a file being ADDED, and
# a file whose mtime changed while its content did not.
pve_file_manifest() {
    # shellcheck disable=SC2086
    dpkg -L $PVE_PACKAGES 2>/dev/null \
        | grep -E '^/usr/share/(pve-manager|perl5/PVE)/' \
        | sort -u \
        | while IFS= read -r f; do
            [ -f "$f" ] && sha256sum "$f"
          done
}

node_name() { hostname; }

# A PVE ticket for root@pam. pvesh cannot be used to reach proxmod endpoints:
# it builds its own API tree in a process that never went through proxmod's
# ExecStart wrapper, so it sees no proxmod routes at all. Everything here goes
# over HTTP, the way a browser does.
api_ticket() {
    local pw="${PROXMOD_ROOT_PW:-testpassword}"
    curl -sk --max-time 20 \
        --data-urlencode "username=root@pam" \
        --data-urlencode "password=$pw" \
        https://127.0.0.1:8006/api2/json/access/ticket \
        | sed -n 's/.*"ticket":"\([^"]*\)".*/\1/p'
}

# api_get <path> — authenticated GET, prints the body.
api_get() {
    local path="$1"
    local ticket="${PROXMOD_TICKET:-}"
    [ -n "$ticket" ] || ticket=$(api_ticket)
    curl -sk --max-time 20 -H "Cookie: PVEAuthCookie=$ticket" \
        "https://127.0.0.1:8006${path}"
}

# api_status <path> — authenticated GET, prints just the HTTP status.
api_status() {
    local path="$1"
    local ticket="${PROXMOD_TICKET:-}"
    [ -n "$ticket" ] || ticket=$(api_ticket)
    curl -sk --max-time 20 -o /dev/null -w '%{http_code}' \
        -H "Cookie: PVEAuthCookie=$ticket" "https://127.0.0.1:8006${path}"
}

# http_status <path> — unauthenticated. The index and everything under
# /proxmod/ are served without authentication [PVE-F-023], so these checks
# deliberately send no ticket.
http_status() {
    curl -sk --max-time 20 -o /dev/null -w '%{http_code}' "https://127.0.0.1:8006$1"
}

http_body() {
    curl -sk --max-time 20 "https://127.0.0.1:8006$1"
}

# How many loader tags the served index carries. Exactly one is correct, no
# matter how many extensions are installed.
loader_tag_count() {
    http_body / | grep -c '/proxmod/loader\.js' || true
}

# Wait for pveproxy to answer again after a restart. Without this, a check
# racing the restart reports a failure that is really just timing.
wait_for_web() {
    local waited=0
    until [ "$(http_status /)" = "200" ]; do
        waited=$((waited + 2))
        [ "$waited" -gt 90 ] && return 1
        sleep 2
    done
    return 0
}

restart_daemons() {
    systemctl restart pvedaemon pveproxy
    wait_for_web
}

daemons_active() {
    systemctl is-active --quiet pvedaemon && systemctl is-active --quiet pveproxy
}

unit_start_time() {
    systemctl show -p ExecMainStartTimestamp --value "$1"
}

# The ISO carries a complete Debian repository. Mounting it read-only gives the
# upgrade test a real apt source with no network and no subscription.
iso_repo_available() {
    [ -e /dev/sr0 ] || return 1
    mkdir -p "$ISO_MNT"
    mountpoint -q "$ISO_MNT" || mount -o ro /dev/sr0 "$ISO_MNT" 2>/dev/null || return 1
    [ -f "$ISO_MNT/dists/trixie/pve/binary-amd64/Packages" ]
}
