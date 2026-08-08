#!/bin/bash
# 11 — removal, which is the promise being made to whoever installs this.
#
# The test is not that proxmod's files are gone. It is that the host is
# indistinguishable from one on which proxmod was never installed: the daemons
# start from Proxmox's own unit file, every Proxmox-owned file still matches
# its recorded checksum, and nothing belonging to another package was taken
# down as collateral.
#
# That last one is not hypothetical. Two of proxmod's directories are shared —
# an extension package's files live in /usr/share/proxmod/www and
# /usr/share/proxmod/extensions.d. 00-baseline planted a file there belonging
# to a notional third package, and if purging proxmod deletes it, the postrm is
# doing rm -rf on a directory it does not exclusively own.
#
# This runs last: it undoes what 01 installed.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

FOREIGN=/usr/share/proxmod/www/zz-foreign-tenant.js

describe "purge both packages"

foreign_sum=""
[ -f "$FOREIGN" ] && foreign_sum=$(sha256sum "$FOREIGN" | cut -d' ' -f1)
if [ -z "$foreign_sum" ]; then
    skip "the planted foreign file is missing — 00-baseline did not run?"
fi

assert "apt purge proxmod-example-hello proxmod" \
    env DEBIAN_FRONTEND=noninteractive apt-get purge -y proxmod-example-hello proxmod

assert_eq "proxmod is no longer installed" "" \
    "$(dpkg-query -W -f='${Status}' proxmod 2>/dev/null | grep -o 'install ok installed')"

describe "the daemons are Proxmox's again"

assert "both daemons are active"   daemons_active
assert "the web interface answers" wait_for_web

for unit in pvedaemon pveproxy; do
    assert "$unit has no proxmod drop-in" \
        bash -c "! test -e /etc/systemd/system/${unit}.service.d/10-proxmod.conf"

    execstart=$(systemctl show -p ExecStart --value "$unit")
    refute_contains "$unit starts from Proxmox's own ExecStart" "proxmod" "$execstart"

    # The ExecReload override has to go too. Leaving it behind would mean a
    # removed package still changing how a Proxmox daemon reloads.
    execreload=$(systemctl show -p ExecReload --value "$unit")
    refute_contains "$unit reloads the way Proxmox intended" "proxmod" "$execreload"
done

# A leftover empty drop-in directory is harmless, but a leftover *file* in one
# is not, so check the whole tree rather than the one filename.
strays=$(grep -rls 'proxmod' /etc/systemd/system/pve*.service.d/ 2>/dev/null)
assert_eq "no systemd drop-in anywhere mentions proxmod" "" "$strays"

describe "nothing of proxmod's is left running or on PATH"

for cmd in proxmodctl proxmod-verify; do
    assert "$cmd is gone" bash -c "! command -v $cmd >/dev/null"
done
assert "the wrapper is gone"      bash -c '! test -e /usr/lib/proxmod/proxmod-exec'
assert "the Perl module is gone"  bash -c '! test -e /usr/share/perl5/Proxmod.pm'
assert "the Perl tree is gone"    bash -c '! test -d /usr/share/perl5/Proxmod'

assert_eq "the served index has no loader tag" "0" "$(loader_tag_count)"
assert_eq "/proxmod/loader.js is not served"   "404" "$(http_status /proxmod/loader.js)"

node=$(cat "$STATE_DIR/node")
PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET
status=$(api_status "/api2/json/nodes/$node/proxmod/example-hello/greet")
if [ "$status" = "501" ] || [ "$status" = "404" ]; then
    ok "the extension endpoint is gone (HTTP $status)"
else
    no "the extension endpoint is gone" "expected 501 or 404, got $status"
fi

describe "Proxmox's own files are exactly as its packages shipped them"

verify_out=$(dpkg_verify_pve)
if [ -z "$verify_out" ]; then
    ok "dpkg -V $PVE_PACKAGES is silent"
else
    no "dpkg -V $PVE_PACKAGES is silent" "$verify_out"
fi

pve_file_manifest > "$STATE_DIR/pve-files.purged"
if diff_out=$(diff "$STATE_DIR/pve-files.before" "$STATE_DIR/pve-files.purged"); then
    ok "every PVE-owned file is byte-identical to the pre-install baseline"
else
    no "every PVE-owned file is byte-identical to the pre-install baseline" \
       "$(printf '%s' "$diff_out" | head -20)"
fi

describe "and another package's files were left alone"

if [ -n "$foreign_sum" ]; then
    if [ -f "$FOREIGN" ]; then
        assert_eq "the foreign asset survived the purge, unchanged" \
            "$foreign_sum" "$(sha256sum "$FOREIGN" | cut -d' ' -f1)"
        ok "and its directory was therefore not removed either"
    else
        no "the foreign asset survived the purge" \
           "$FOREIGN was deleted — postrm is removing a directory it shares"
    fi

    # Clean up the plant so a re-run of the suite starts from a clean host.
    rm -f "$FOREIGN"
    rmdir --ignore-fail-on-non-empty /usr/share/proxmod/www /usr/share/proxmod 2>/dev/null || true
fi

describe "no backup was orphaned in someone else's directory"

# The prior art left /usr/share/perl5/PVE/API2/Hardware.pm.pre-gpu behind
# forever: a file in Proxmox's own tree, owned by nothing, with nothing on the
# host left to explain it.
orphans=$(find /usr/share/perl5/PVE /usr/share/pve-manager \
              \( -name '*.bak' -o -name '*.orig' -o -name '*.pre-*' -o -name '*proxmod*' \) \
              2>/dev/null)
assert_eq "no backup or stray file under Proxmox's directories" "" "$orphans"

assert "no state directory left behind" bash -c '! test -d /var/lib/proxmod'

summary
