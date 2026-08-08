#!/bin/bash
# 08 — upgrade survival, offline and reproducible.
#
# The claim under test: after a pve-manager upgrade there is nothing to
# reapply. This is the property the prior art did not have — its reapply script
# targeted a file the installer no longer patched, so the backend route
# silently disappeared on the first upgrade and the tab stayed, leaving an
# interface that looked healthy in front of an API that was gone.
#
# A reinstall would not test this: it skips prerm/preinst and does not exercise
# the upgrade path. So the real pve-manager deb is repacked with a higher
# version and installed as an upgrade, which runs the genuine maintainer
# scripts and the genuine trigger sequence. The deb comes from the repository
# on the installer ISO, so this needs no network and no subscription, and does
# not drift between runs.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "prepare an upgrade from the ISO repository"

if ! iso_repo_available; then
    skip "no installer ISO attached — the offline upgrade test cannot run"
    skip "attach one with PROXMOD_PVE_ISO and re-run"
    summary; exit 0
fi
ok "mounted the ISO repository at $ISO_MNT"

src=$(find "$ISO_MNT/dists" -name 'pve-manager_*_all.deb' | head -1)
if [ -z "$src" ]; then
    no "found pve-manager on the ISO" "nothing matching pve-manager_*_all.deb"
    summary; exit 1
fi

cur=$(dpkg-query -W -f='${Version}' pve-manager)
new="${cur}+proxmode2e1"
ok "repacking $(basename "$src") as $new (installed: $cur)"

work=$(mktemp -d /var/tmp/proxmod-repack.XXXXXX)
dpkg-deb -R "$src" "$work/pkg" >/dev/null
sed -i "s/^Version: .*/Version: $new/" "$work/pkg/DEBIAN/control"
repacked="$work/pve-manager_${new}_all.deb"
dpkg-deb -b "$work/pkg" "$repacked" >/dev/null
assert "the repacked package built" test -f "$repacked"

describe "record what we have before the upgrade"

before_proxy=$(unit_start_time pveproxy)
node=$(cat "$STATE_DIR/node")
PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET
assert_eq "the endpoint answers beforehand" "200" \
    "$(api_status "/api2/json/nodes/$node/proxmod/example-hello/greet")"

describe "upgrade pve-manager"

# The upgrade path, not a reinstall: prerm of the old, unpack, postinst
# configure of the new, then trigger processing.
if DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
       --no-install-recommends "$repacked" >"$work/apt.log" 2>&1; then
    ok "apt install of the repacked pve-manager succeeded"
else
    no "apt install of the repacked pve-manager succeeded" "$(tail -20 "$work/apt.log")"
fi

assert_eq "pve-manager is now $new" "$new" "$(dpkg-query -W -f='${Version}' pve-manager)"

describe "proxmod survived, with nothing reapplied by hand"

assert "both daemons are active"    daemons_active
assert "the web interface answers"  wait_for_web

if [ "$before_proxy" != "$(unit_start_time pveproxy)" ]; then
    ok "pveproxy went through a restart during the upgrade"
else
    no "pveproxy went through a restart during the upgrade" \
       "it was reloaded in place, which would have dropped -MProxmod"
fi

for unit in pvedaemon pveproxy; do
    since=$(unit_start_time "$unit")
    if journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null | grep -q 'proxmod'; then
        ok "$unit is running proxmod after the upgrade"
    else
        no "$unit is running proxmod after the upgrade" "nothing from proxmod since $since"
    fi
done

assert_eq "exactly one loader tag" "1" "$(loader_tag_count)"

PROXMOD_TICKET=$(api_ticket); export PROXMOD_TICKET
assert_eq "the endpoint still answers" "200" \
    "$(api_status "/api2/json/nodes/$node/proxmod/example-hello/greet")"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0 after the upgrade" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

describe "and the upgraded files are still pristine"

# pve-manager replaced index.html.tpl and the whole js/ tree. Because proxmod
# never edited them, dpkg -V has nothing to report — and, unlike a patching
# design, there was no window in which a stale backup could be restored over
# the newer file.
verify_out=$(dpkg_verify_pve)
if [ -z "$verify_out" ]; then
    ok "dpkg -V is silent after the upgrade"
else
    no "dpkg -V is silent after the upgrade" "$verify_out"
fi

assert "the upgraded index.html.tpl carries no injected tag" \
    bash -c '! grep -q "proxmod" /usr/share/pve-manager/index.html.tpl'

# The baseline manifest is stale now — the upgrade legitimately replaced those
# files. Re-record it so test 11's purge comparison is against current reality.
pve_file_manifest > "$STATE_DIR/pve-files.before"
ok "re-recorded the PVE file manifest at the upgraded version"

rm -rf "$work"
summary
