#!/bin/bash
# 05 — the most important safety test.
#
# A broken extension must cost its own tab and endpoint and nothing else. If
# this test fails, proxmod is a way to take a hypervisor's control plane down
# by installing a third-party package, and every other property it has is
# worthless.
#
# Three failure shapes, because they fail in different places: a module that
# does not exist (require fails), a module that dies while loading (require
# succeeds, execution does not), and a module that dies inside
# proxmod_register (loaded fine, registration throws).

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "plant three broken extensions"

mkdir -p /usr/share/perl5/ProxmodBroken

cat > /usr/share/perl5/ProxmodBroken/DiesAtLoad.pm <<'EOF'
package ProxmodBroken::DiesAtLoad;
use strict; use warnings;
die "e2e: this module dies while being loaded\n";
1;
EOF

cat > /usr/share/perl5/ProxmodBroken/DiesAtRegister.pm <<'EOF'
package ProxmodBroken::DiesAtRegister;
use strict; use warnings;
# Loads cleanly. Throws when proxmod calls it — and installs a __DIE__ handler
# first, so this also checks that proxmod's eval localises $SIG{__DIE__} and
# cannot be escaped through one.
sub proxmod_register {
    local $SIG{__DIE__} = sub { die "e2e: escaped through a die handler\n" };
    die "e2e: this extension dies during registration\n";
}
1;
EOF

for spec in \
    "90-broken-missing:ProxmodBroken::NoSuchModule" \
    "91-broken-load:ProxmodBroken::DiesAtLoad" \
    "92-broken-register:ProxmodBroken::DiesAtRegister"
do
    name="${spec%%:*}"; mod="${spec#*:}"
    cat > "/etc/proxmod/extensions.d/${name}.conf" <<EOF
{ "id": "${name#9?-}", "backend": { "module": "$mod" } }
EOF
done

# And one that is not valid JSON at all. A malformed manifest must not cost
# the well-formed ones.
printf '{ "id": "broken-json", "backend": {\n' > /etc/proxmod/extensions.d/93-broken-json.conf

ok "planted four broken extensions"

describe "restart with them in place"

systemctl restart pvedaemon pveproxy

assert "both daemons are active"   daemons_active
assert "the web interface answers" wait_for_web

# The whole point.
for unit in pvedaemon pveproxy; do
    assert_eq "$unit is active, not failed" "active" "$(systemctl is-active "$unit")"
done

describe "the good extension still works"

node=$(cat "$STATE_DIR/node")
PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET

assert_eq "the example endpoint still returns 200" "200" \
    "$(api_status "/api2/json/nodes/$node/proxmod/example-hello/greet")"
assert_eq "still exactly one loader tag" "1" "$(loader_tag_count)"
assert_contains "the loader still lists the example asset" \
    "proxmod-example-hello.js" "$(http_body /proxmod/loader.js)"

describe "the failures were reported, not swallowed"

listing=$(proxmodctl list 2>&1)
assert_contains "proxmodctl list still shows the good extension" "example-hello" "$listing"

logs=$(proxmodctl logs 2>&1)
assert_contains "the journal names the module that dies at load"     "DiesAtLoad"     "$logs"
assert_contains "the journal names the module that dies registering" "DiesAtRegister" "$logs"
refute_contains "the die handler did not escape the eval" "escaped through a die handler" "$logs"

# Extension failures are a warning, not an error: the isolation is designed
# behaviour, and an administrator who disabled something should not get a red
# alert. proxmod-verify must still exit 0 and still say so.
out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify still exits 0" "0" "$rc"
assert_contains "but it reports extension failures" "extension" "${out,,}"

describe "clean up"

rm -f /etc/proxmod/extensions.d/9?-broken-*.conf
rm -rf /usr/share/perl5/ProxmodBroken
assert "restart back to a clean state" restart_daemons

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0 with the broken ones gone" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

summary
