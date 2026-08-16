#!/bin/bash
# 11 — the registry a daemon loaded versus the registry on disk.
#
# The defect this covers is the quietest one proxmod can have. Removing an
# extension package deletes its manifest and fires our trigger. The drop-ins do
# not change, nothing is patched, and both daemons are healthy — so every gate
# short of this one says "already converged", and the extension the
# administrator just removed keeps serving requests out of a daemon that read
# the registry before it went away. Installing one has the same shape, and so
# does upgrading proxmod itself, which otherwise leaves the old Perl modules
# resident in a process nobody restarted.
#
# It is invisible to `prove`: the whole question is what a live daemon loaded.
#
# `--force` appears nowhere below on purpose. Every convergence here has to
# happen because dpkg fired a trigger and proxmod worked out for itself that
# something had moved.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

node=$(cat "$STATE_DIR/node")

describe "a running daemon says which registry it loaded"

for unit in pvedaemon pveproxy; do
    since=$(unit_start_time "$unit")
    booted=$(journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null \
        | grep -F 'proxmod: booted' | tail -1)
    assert_contains "$unit's booted line carries a registry fingerprint" \
        "registry=" "$booted"
done

# Both daemons must agree. pveproxy runs the frontend stage and pvedaemon does
# not, so anything derived from what each one loaded — a count of extensions,
# say — would differ between them for one registry and could not be compared
# with anything. This is the assertion that keeps the fingerprint a function of
# the registry alone.
fp_daemon=$(journalctl -u pvedaemon --since "$(unit_start_time pvedaemon)" --no-pager 2>/dev/null \
    | sed -n 's/.*proxmod: booted .*registry=\([0-9a-f]*\).*/\1/p' | tail -1)
fp_proxy=$(journalctl -u pveproxy --since "$(unit_start_time pveproxy)" --no-pager 2>/dev/null \
    | sed -n 's/.*proxmod: booted .*registry=\([0-9a-f]*\).*/\1/p' | tail -1)
assert_eq "both daemons report the same fingerprint" "$fp_daemon" "$fp_proxy"

on_disk=$(proxmod-verify --registry-only 2>/dev/null); rc=$?
assert_eq "--registry-only says the daemons are up to date" "0" "$rc"
assert_eq "and prints the fingerprint they are running" "$fp_daemon" "$on_disk"

describe "removing an extension takes it out of the running daemons"

before_start=$(unit_start_time pvedaemon)

assert "apt remove proxmod-example-hello" \
    env DEBIAN_FRONTEND=noninteractive apt-get remove -y proxmod-example-hello

assert "the manifest is gone" test ! -e /usr/share/proxmod/extensions.d/50-proxmod-example-hello.conf

# The assertion this file exists for. Nothing on disk that reapply watches has
# changed except the registry itself.
after_start=$(unit_start_time pvedaemon)
if [ "$before_start" != "$after_start" ]; then
    ok "removing an extension restarted pvedaemon, with no --force anywhere"
else
    no "removing an extension restarted pvedaemon" \
       "ExecMainStartTimestamp unchanged; the daemons are still serving a registry that no longer exists"
fi

assert "both daemons came back" daemons_active
assert "the web interface answers" wait_for_web

describe "and the extension is really gone, not just uninstalled"

PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET
status=$(api_status "/api2/json/nodes/$node/proxmod/example-hello/greet")
refute_contains "the endpoint no longer answers 200" "200" "$status"

assert_eq "no loader tag, because no extension asks for one" "0" "$(loader_tag_count)"

listing=$(proxmodctl list 2>&1)
refute_contains "proxmodctl no longer lists it" "example-hello" "$listing"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0 on the emptied host" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

assert_eq "--registry-only agrees" "0" "$(proxmod-verify --registry-only >/dev/null 2>&1; echo $?)"

describe "installing it again brings it back the same way"

before_start=$(unit_start_time pvedaemon)
deb=$(find "$DEB_DIR" -maxdepth 1 -name 'proxmod-example-hello_*_all.deb' 2>/dev/null | head -1)
assert "apt install $(basename "$deb")" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$deb"

after_start=$(unit_start_time pvedaemon)
if [ "$before_start" != "$after_start" ]; then
    ok "installing it again restarted pvedaemon"
else
    no "installing it again restarted pvedaemon" "ExecMainStartTimestamp unchanged"
fi

assert "both daemons came back" daemons_active
assert "the web interface answers" wait_for_web

PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET
assert_eq "the endpoint answers again" "200" \
    "$(api_status "/api2/json/nodes/$node/proxmod/example-hello/greet")"

describe "a converged host is still left alone"

# The other half of the contract, and the reason the gate is a fingerprint
# rather than a timer: having just proved proxmod restarts when it must, prove
# it does not restart when it must not. 09-noop-apt makes the same point about
# an unrelated apt run; this one is about our own trigger firing repeatedly.
before_start=$(unit_start_time pvedaemon)
assert "an explicit trigger converges" dpkg-trigger --by-package proxmod proxmod-reapply
assert "a second reapply run does nothing" /usr/lib/proxmod/proxmod-reapply
assert_eq "pvedaemon was not restarted" "$before_start" "$(unit_start_time pvedaemon)"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

summary
