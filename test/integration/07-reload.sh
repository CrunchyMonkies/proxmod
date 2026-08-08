#!/bin/bash
# 07 — reload survival. The regression test for the ExecReload override.
#
# PVE's graceful reload is an in-process exec() of the original argv, which
# does not contain -MProxmod. Without the override, `systemctl reload pveproxy`
# silently unloads proxmod and leaves a daemon that looks perfectly healthy and
# serves nothing.
#
# This is not a corner case. pve-manager's own postinst runs
# `deb-systemd-invoke reload-or-try-restart` on every upgrade [PVE-F-005],
# which prefers reload — so without the override proxmod would come undone on
# exactly the event it exists to survive. The second case below is that code
# path, run directly.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "systemctl reload"

for unit in pveproxy pvedaemon; do
    before=$(unit_start_time "$unit")

    systemctl reload "$unit" || true
    sleep 3
    wait_for_web || true

    assert_eq "$unit is still active"      "active" "$(systemctl is-active "$unit")"

    after=$(unit_start_time "$unit")
    if [ "$before" != "$after" ]; then
        ok "$unit was restarted rather than reloaded in place"
    else
        no "$unit was restarted rather than reloaded in place" \
           "ExecMainStartTimestamp unchanged — the ExecReload override is not in effect"
    fi

    since=$(unit_start_time "$unit")
    if journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null | grep -q 'proxmod'; then
        ok "$unit is running proxmod after the reload"
    else
        no "$unit is running proxmod after the reload" "nothing from proxmod since $since"
    fi
done

assert_eq "still exactly one loader tag" "1" "$(loader_tag_count)"

describe "deb-systemd-invoke reload-or-try-restart — PVE's own upgrade path"

before_proxy=$(unit_start_time pveproxy)
before_daemon=$(unit_start_time pvedaemon)

deb-systemd-invoke reload-or-try-restart pveproxy.service pvedaemon.service || true
sleep 3
assert "the web interface answers again" wait_for_web

assert "both daemons are active" daemons_active

for pair in "pveproxy:$before_proxy" "pvedaemon:$before_daemon"; do
    unit="${pair%%:*}"; before="${pair#*:}"
    if [ "$before" != "$(unit_start_time "$unit")" ]; then
        ok "$unit went through a real restart"
    else
        no "$unit went through a real restart" "reload-or-try-restart reloaded it in place"
    fi
done

assert_eq "still exactly one loader tag" "1" "$(loader_tag_count)"

node=$(cat "$STATE_DIR/node")
PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET
assert_eq "the extension endpoint still answers" "200" \
    "$(api_status "/api2/json/nodes/$node/proxmod/example-hello/greet")"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

describe "and if the override goes missing, verification says so"

# The failure this guards against is silent, so the warning has to be loud.
cp /etc/systemd/system/pveproxy.service.d/10-proxmod.conf "$STATE_DIR/dropin.bak"
grep -v 'ExecReload' "$STATE_DIR/dropin.bak" > /etc/systemd/system/pveproxy.service.d/10-proxmod.conf
systemctl daemon-reload

out=$(proxmod-verify 2>&1) || true
assert_contains "proxmod-verify warns about losing proxmod on reload" "reload" "${out,,}"

cp "$STATE_DIR/dropin.bak" /etc/systemd/system/pveproxy.service.d/10-proxmod.conf
systemctl daemon-reload
rm -f "$STATE_DIR/dropin.bak"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "restored, and proxmod-verify exits 0 again" "0" "$rc"

summary
