#!/bin/bash
# 01 — install proxmod and prove it is actually loaded into both daemons.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "install"

deb=$(find "$DEB_DIR" -maxdepth 1 -name 'proxmod_*_all.deb' 2>/dev/null | head -1)
if [ -z "$deb" ]; then
    no "the proxmod package is present in $DEB_DIR" "nothing to install"
    summary; exit 1
fi

assert "apt install $(basename "$deb")" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$deb"

assert "the wrapper is executable"  test -x /usr/lib/proxmod/proxmod-exec
assert "the converge routine is executable" test -x /usr/lib/proxmod/proxmod-reapply
assert "proxmodctl is on PATH"      command -v proxmodctl
assert "proxmod-verify is on PATH"  command -v proxmod-verify

describe "the systemd drop-ins"

for unit in pvedaemon pveproxy; do
    dropin="/etc/systemd/system/${unit}.service.d/10-proxmod.conf"
    assert "$unit has a drop-in"           test -f "$dropin"

    execstart=$(systemctl show -p ExecStart --value "$unit")
    assert_contains "$unit starts through the wrapper" "/usr/lib/proxmod/proxmod-exec" "$execstart"

    # Without this override PVE's graceful reload re-execs the original argv,
    # which has no -MProxmod in it, and proxmod vanishes leaving a daemon that
    # looks perfectly healthy [PVE-F-005]. Test 07 exercises the consequence.
    execreload=$(systemctl show -p ExecReload --value "$unit")
    assert_contains "$unit reloads by restarting" "restart" "$execreload"
done

describe "both daemons are actually running proxmod"

assert "the daemons are active" daemons_active
assert "the web interface answers" wait_for_web

# The gate that matters. Not `perl -MProxmod -e1`, which proves the module
# compiles on this host today and says nothing about the process currently
# serving the API — that is exactly the check that passed for pve-token-copy
# while its endpoint had never once loaded.
for unit in pvedaemon pveproxy; do
    since=$(unit_start_time "$unit")
    if journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null | grep -q 'proxmod'; then
        ok "$unit's journal shows proxmod booting in the current process"
    else
        no "$unit's journal shows proxmod booting in the current process" \
           "nothing from proxmod since $since"
    fi
done

describe "proxmod-verify"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

json=$(proxmod-verify --json 2>/dev/null)
assert_contains "--json reports healthy" '"healthy":true' "${json// /}"

summary
