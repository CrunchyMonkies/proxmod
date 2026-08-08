#!/bin/bash
# 04 — install the example extension and reach its endpoint over HTTP.
#
# This is the consumer contract end to end: a package with no maintainer
# scripts writes three files into directories proxmod watches, a dpkg trigger
# fires, proxmod-reapply converges, and a tab and an endpoint appear.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "install the example extension"

deb=$(find "$DEB_DIR" -maxdepth 1 -name 'proxmod-example-hello_*_all.deb' 2>/dev/null | head -1)
if [ -z "$deb" ]; then
    no "the example package is present in $DEB_DIR" "nothing to install"
    summary; exit 1
fi

before_start=$(unit_start_time pvedaemon)

assert "apt install $(basename "$deb")" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$deb"

assert "the Perl module landed"  test -f /usr/share/perl5/ProxmodExample/Hello.pm
assert "the manifest landed"     test -f /usr/share/proxmod/extensions.d/50-proxmod-example-hello.conf
assert "the asset landed"        test -f /usr/share/proxmod/www/proxmod-example-hello.js

# The package ships no maintainer scripts. If it needed any, the contract in
# the documentation is wrong.
scripts=$(dpkg -e "$deb" /tmp/e2e-ctrl 2>/dev/null && \
          find /tmp/e2e-ctrl -maxdepth 1 -type f \
               \( -name postinst -o -name preinst -o -name prerm -o -name postrm \) -printf '%f ')
rm -rf /tmp/e2e-ctrl
assert_eq "the extension package ships no maintainer scripts" "" "${scripts:-}"

describe "the trigger converged"

after_start=$(unit_start_time pvedaemon)
if [ "$before_start" != "$after_start" ]; then
    ok "installing an extension restarted pvedaemon (a new backend module needs it)"
else
    no "installing an extension restarted pvedaemon" \
       "ExecMainStartTimestamp unchanged; the dpkg trigger did not converge"
fi

assert "both daemons came back" daemons_active
assert "the web interface answers" wait_for_web

describe "the extension is registered"

listing=$(proxmodctl list 2>&1)
assert_contains "proxmodctl list names it" "example-hello" "$listing"
refute_contains "and does not report it as failed" "fail" "${listing,,}"

for unit in pvedaemon pveproxy; do
    since=$(unit_start_time "$unit")
    if journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null | grep -qi 'example-hello'; then
        ok "$unit's journal records the registration"
    else
        no "$unit's journal records the registration" "nothing about example-hello since $since"
    fi
done

describe "the endpoint answers over HTTP"

node=$(cat "$STATE_DIR/node")
PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET
if [ -z "$PROXMOD_TICKET" ]; then
    no "obtained a PVE ticket for root@pam" "check PROXMOD_ROOT_PW"
    summary; exit 1
fi
ok "obtained a PVE ticket for root@pam"

path="/api2/json/nodes/$node/proxmod/example-hello/greet"

status=$(api_status "$path")
assert_eq "GET $path returns 200" "200" "$status"

# 501, not 404, is what an unregistered route returns here: rest_handler
# defaults the response to HTTP_NOT_IMPLEMENTED, so a tree registered only in
# pvedaemon answers 501 for everything through pveproxy [PVE-F-052]. Naming
# that in the failure message saves the next person an afternoon.
[ "$status" = "501" ] && printf '       %s\n' \
    "501 means pveproxy has no such method in its own tree — registered in pvedaemon only?"

body=$(api_get "$path")
assert_contains "the response carries a data object" '"data"' "$body"

describe "the frontend half of the same extension"

assert_eq "the asset is served"       "200" "$(http_status /proxmod/proxmod-example-hello.js)"
assert_contains "the loader lists it" "proxmod-example-hello.js" "$(http_body /proxmod/loader.js)"
assert_eq "still exactly one loader tag" "1" "$(loader_tag_count)"

describe "verification is still clean"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

summary
