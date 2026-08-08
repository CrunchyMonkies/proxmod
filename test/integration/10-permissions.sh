#!/bin/bash
# 10 — the permission guard, which is a security boundary and not a nicety.
#
# Everything proxmod loads runs as root inside pvedaemon. If any of the paths
# it reads from can be written by someone who is not root, then that someone
# has unauthenticated root code execution on the hypervisor — they write a
# module, wait for the next restart, and the daemon runs it.
#
# So the wrapper refuses to inject when it finds such a path. Refusing means
# starting the daemon exactly as Proxmox ships it: the hypervisor keeps
# working, proxmod does not load, and proxmod-verify says so loudly. A guard
# that failed the other way — refusing to start the daemon — would turn a
# permissions mistake into an outage.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

target=/usr/share/perl5/Proxmod.pm
orig_mode=$(stat -c '%a' "$target")

restore() {
    chmod "$orig_mode" "$target" 2>/dev/null || true
    chmod 0755 /usr/share/proxmod/extensions.d 2>/dev/null || true
}
trap 'restore' EXIT

describe "make a loaded file group-writable"

assert "chmod g+w $target" chmod g+w "$target"
assert "restart both daemons" restart_daemons

describe "the hypervisor is unharmed"

# The point of failing this way round.
assert "both daemons are active"   daemons_active
assert "the web interface answers" wait_for_web

describe "but proxmod did not load"

assert_eq "no loader tag in the index" "0" "$(loader_tag_count)"
assert_eq "/proxmod/loader.js is not served" "404" "$(http_status /proxmod/loader.js)"

for unit in pvedaemon pveproxy; do
    since=$(unit_start_time "$unit")
    journal=$(journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null)

    assert_contains "$unit's journal records the refusal" "refusing to inject" "$journal"
    assert_contains "and names the offending path" "Proxmod.pm" "$journal"
done

describe "and verification fails loudly, not quietly"

# This is the whole reason proxmod-verify exists. The failure it is reporting
# is invisible from the web interface: everything looks normal, the extension
# is simply not there.
out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits non-zero" "1" "$rc"
assert_contains "and says the daemon is running without proxmod" \
    "without proxmod" "${out,,}"

json=$(proxmod-verify --json 2>/dev/null)
assert_contains "--json reports unhealthy" '"healthy":false' "${json// /}"

describe "a group-writable directory is refused the same way"

assert "restore the file's mode" chmod "$orig_mode" "$target"
assert "chmod g+w the extension directory" chmod g+w /usr/share/proxmod/extensions.d
assert "restart both daemons" restart_daemons

assert "both daemons are still active" daemons_active
assert_eq "still no loader tag" "0" "$(loader_tag_count)"

proxmod-verify >/dev/null 2>&1; rc=$?
assert_eq "proxmod-verify still exits non-zero" "1" "$rc"

describe "put it back"

assert "restore the directory's mode" chmod 0755 /usr/share/proxmod/extensions.d
assert "restart both daemons" restart_daemons

assert "both daemons are active" daemons_active
assert_eq "the loader tag is back, exactly once" "1" "$(loader_tag_count)"

node=$(cat "$STATE_DIR/node")
PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET
assert_eq "the extension endpoint answers again" "200" \
    "$(api_status "/api2/json/nodes/$node/proxmod/example-hello/greet")"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0 again" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

summary
