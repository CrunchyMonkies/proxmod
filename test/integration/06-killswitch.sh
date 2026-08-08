#!/bin/bash
# 06 — the kill switch.
#
# The thing an administrator reaches for at 3am. It has to work without
# uninstalling anything, without editing a unit file, and without leaving the
# daemons in some third state: with it set, pvedaemon and pveproxy must start
# exactly the way Proxmox ships them.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "disable"

assert "proxmodctl disable" proxmodctl disable
assert "the flag file exists" test -f /etc/proxmod/disabled

assert "both daemons are active" daemons_active
assert "the web interface answers" wait_for_web

assert_eq "no loader tag in the index" "0" "$(loader_tag_count)"
assert_eq "/proxmod/loader.js is not served" "404" "$(http_status /proxmod/loader.js)"

node=$(cat "$STATE_DIR/node")
PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET
status=$(api_status "/api2/json/nodes/$node/proxmod/example-hello/greet")
if [ "$status" = "501" ] || [ "$status" = "404" ]; then
    ok "the extension endpoint is gone (HTTP $status)"
else
    no "the extension endpoint is gone" "expected 501 or 404, got $status"
fi

describe "the drop-ins are still in place — this is a runtime switch"

# Disabling must not tear down the systemd configuration. If it did, enabling
# again would depend on the package being reinstalled.
for unit in pvedaemon pveproxy; do
    assert "$unit still has its drop-in" \
        test -f "/etc/systemd/system/${unit}.service.d/10-proxmod.conf"
done

describe "verification says disabled, not broken"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify still exits 0" "0" "$rc"
assert_contains "and reports the kill switch" "disabled" "${out,,}"

describe "re-enable"

assert "proxmodctl enable" proxmodctl enable
refute "the flag file is gone" test -f /etc/proxmod/disabled

assert "both daemons are active" daemons_active
assert "the web interface answers" wait_for_web
assert_eq "the loader tag is back, exactly once" "1" "$(loader_tag_count)"

PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET
assert_eq "the extension endpoint answers again" "200" \
    "$(api_status "/api2/json/nodes/$node/proxmod/example-hello/greet")"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

summary
