#!/bin/bash
# 03 — the frontend is live, with exactly one injected tag.
#
# "Exactly one" is the property that makes the design checkable. A per-request
# generated loader means the count cannot drift with the number of installed
# extensions, so any number other than 1 is a real defect: 0 means the
# get_index wrap did not take, and 2 means something is injecting by hand —
# usually a patch spec doing what the runtime already does.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "the injected tag"

assert_eq "the index serves 200"        "200" "$(http_status /)"
assert_eq "exactly one loader tag"      "1"   "$(loader_tag_count)"

index=$(http_body /)

# The tag has to land after pvemanagerlib.js — every PVE.* class must exist —
# and before the inline Ext.onReady, so no ready handler has run yet
# [PVE-F-021]. Comparing byte offsets is the only honest way to check that.
lib_at=$(printf '%s' "$index" | grep -bo 'pvemanagerlib\.js' | head -1 | cut -d: -f1)
tag_at=$(printf '%s' "$index" | grep -bo '/proxmod/loader\.js' | head -1 | cut -d: -f1)
ready_at=$(printf '%s' "$index" | grep -bo 'Ext\.onReady' | head -1 | cut -d: -f1)

if [ -n "$lib_at" ] && [ -n "$tag_at" ] && [ "$tag_at" -gt "$lib_at" ]; then
    ok "the tag comes after pvemanagerlib.js"
else
    no "the tag comes after pvemanagerlib.js" "lib at ${lib_at:-?}, tag at ${tag_at:-?}"
fi

if [ -n "$ready_at" ] && [ -n "$tag_at" ] && [ "$tag_at" -lt "$ready_at" ]; then
    ok "the tag comes before Ext.onReady"
else
    no "the tag comes before Ext.onReady" "tag at ${tag_at:-?}, onReady at ${ready_at:-?}"
fi

describe "the loader and the framework asset"

assert_eq "/proxmod/loader.js serves 200"     "200" "$(http_status /proxmod/loader.js)"
assert_eq "/proxmod/proxmod-ui.js serves 200" "200" "$(http_status /proxmod/proxmod-ui.js)"

loader=$(http_body /proxmod/loader.js)
assert_contains "the loader mentions proxmod-ui.js" "proxmod-ui.js" "$loader"

ui=$(http_body /proxmod/proxmod-ui.js)
assert_contains "the JS API defines the Proxmod global" "Proxmod" "$ui"

describe "injection is idempotent across restarts"

# get_index is wrapped once at INIT. A wrap applied twice, or a wrap over an
# already-injected body, would show up here as a second tag.
assert "restart both daemons" restart_daemons
assert_eq "still exactly one loader tag" "1" "$(loader_tag_count)"

describe "the other index bodies are left alone"

# get_index renders four different pages [PVE-F-022]. A loader in the noVNC
# console body would run ExtJS overrides against classes that are not there.
for page in "/?console=kvm&novnc=1&vmid=100&node=$(node_name)" \
            "/?console=shell&xtermjs=1&node=$(node_name)"; do
    body=$(http_body "$page")
    n=$(printf '%s' "$body" | grep -c '/proxmod/loader\.js' || true)
    assert_eq "no loader tag in ${page%%\?*}?${page#*\?}" "0" "$n"
done

describe "a path traversal through the asset route is refused"

# Asset names are path components in a URL pveproxy serves to unauthenticated
# clients [PVE-F-023], which is why the manifest pattern forbids slashes.
for evil in "/proxmod/../../../etc/passwd" "/proxmod/%2e%2e%2f%2e%2e%2fetc%2fpasswd"; do
    body=$(http_body "$evil")
    refute_contains "no /etc/passwd through $evil" "root:x:" "$body"
done

summary
