#!/bin/bash
# 00 — capture the pristine state, before proxmod exists on this host.
#
# Everything test 02 and test 11 assert is a comparison against what this
# script records. If the host is not clean to begin with, the no-mutation claim
# cannot be tested at all, so this refuses rather than recording a dirty
# baseline and calling later drift a pass.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "baseline: a pristine Proxmox host"

assert "proxmod is not installed"            bash -c '! dpkg -s proxmod >/dev/null 2>&1'
assert "pvedaemon and pveproxy are running"  daemons_active
assert "the web interface answers"           wait_for_web

verify_out=$(dpkg_verify_pve)
assert_eq "dpkg -V is silent before we start" "" "$verify_out"

pve_file_manifest > "$STATE_DIR/pve-files.before"
count=$(wc -l < "$STATE_DIR/pve-files.before")
if [ "$count" -lt 100 ]; then
    no "the PVE file manifest looks implausibly small ($count files)" \
       "dpkg -L found almost nothing; the comparison in test 02 would be worthless"
else
    ok "recorded checksums for $count PVE-owned files"
fi

assert_eq "the index carries no loader tag yet" "0" "$(loader_tag_count)"

# Test 11 asserts that purging proxmod leaves another package's files in
# /usr/share/proxmod/www alone. Something has to be there to leave alone.
mkdir -p /usr/share/proxmod/www
echo '/* planted by the e2e suite; purge must not remove this */' \
    > /usr/share/proxmod/www/zz-foreign-tenant.js
sha256sum /usr/share/proxmod/www/zz-foreign-tenant.js > "$STATE_DIR/foreign.sha"
ok "planted a foreign file in /usr/share/proxmod/www for the purge test"

hostname > "$STATE_DIR/node"
ok "node is $(cat "$STATE_DIR/node")"

summary
