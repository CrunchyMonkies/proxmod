#!/bin/bash
# 02 — the headline test.
#
# proxmod's central claim is that it modifies no Proxmox-owned file. This is
# what makes update survival a matter of converging files proxmod owns rather
# than repairing files Proxmox owns, and it is checkable with a tool the
# administrator already trusts.
#
# The prior art fails this test by construction: it seds index.html.tpl and
# awks PVE/API2/Hardware.pm, so `dpkg -V pve-manager` reports both files
# forever, and a reinstall of pve-manager silently discards the backend route.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "no Proxmox-owned file was modified"

verify_out=$(dpkg_verify_pve)
if [ -z "$verify_out" ]; then
    ok "dpkg -V $PVE_PACKAGES is silent"
else
    no "dpkg -V $PVE_PACKAGES is silent" "$verify_out"
fi

# dpkg -V compares against recorded checksums, which catches modification.
# The manifest comparison also catches a file being added or removed, and is
# what would catch a patch that edits a file and then repairs its md5sums
# entry — something a determined installer script can do and dpkg -V cannot see.
pve_file_manifest > "$STATE_DIR/pve-files.after"

if diff_out=$(diff "$STATE_DIR/pve-files.before" "$STATE_DIR/pve-files.after"); then
    n=$(wc -l < "$STATE_DIR/pve-files.after")
    ok "all $n PVE-owned files are byte-identical to the baseline"
else
    no "all PVE-owned files are byte-identical to the baseline" \
       "$(printf '%s' "$diff_out" | head -20)"
fi

describe "specifically, the files the prior art patched"

assert "index.html.tpl carries no injected script tag" \
    bash -c '! grep -q "proxmod" /usr/share/pve-manager/index.html.tpl'

assert "no PVE API module mentions proxmod" \
    bash -c '! grep -rqs "proxmod" /usr/share/perl5/PVE/API2/'

assert "pvemanagerlib.js is untouched" \
    bash -c '! grep -qs "proxmod" /usr/share/pve-manager/js/pvemanagerlib.js'

describe "and nothing was shipped into a Proxmox-owned directory"

# Namespacing is not tidiness: dpkg -V being silent only means something if
# proxmod also added nothing new to Proxmox's trees.
strays=$(find /usr/share/pve-manager /usr/share/perl5/PVE -iname '*proxmod*' 2>/dev/null)
assert_eq "no proxmod-named file under PVE's directories" "" "$strays"

summary
