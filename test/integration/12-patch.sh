#!/bin/bash
# 12 — the managed patch facility, against a real Proxmox file and a real
# pve-manager upgrade.
#
# Patch.pm's whole design rationale is upgrade survival. Its module header names
# four failures from the prior art — a stale backup restored over a newer file,
# a revert fired during an upgrade, a leaked backup, a patch reapplied on top of
# itself — and every one of them is a thing that happens when dpkg replaces the
# file underneath a patch. Up to now that claim was proven only against stubs in
# t/07-patch.t, which cannot replace a file the way dpkg does, cannot run the
# trigger, and cannot make dpkg -V disagree with anything.
#
# This runs before 13-purge, and it must leave the host clean: the patch is
# reverted before the end, so the file manifest 13 compares against still means
# what it meant.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

TARGET=/usr/share/pve-manager/index.html.tpl
SPEC_ID=example-index-banner
SPEC_SRC=/usr/share/proxmod/patches/50-${SPEC_ID}.conf
SPEC_ON=/etc/proxmod/patches/50-${SPEC_ID}.conf
STATE=/var/lib/proxmod/patches.state
BACKUP=/var/lib/proxmod/backups/${SPEC_ID}.bak

# Undo whatever this script did, whichever assertion it died on. A patched
# index.html.tpl left behind would fail 13-purge with a finding that has
# nothing to do with purging.
cleanup() {
    rm -f "$SPEC_ON"
    proxmod-patch revert "$SPEC_ID" >/dev/null 2>&1 || true
    proxmod-patch converge >/dev/null 2>&1 || true
}
trap cleanup EXIT

describe "it ships inert"

# ADR 0008. Installing proxmod patches nothing: the one spec in the package is
# enabled=0, and an administrator has to make a deliberate, visible edit before
# any Proxmox file changes. This is checked first because everything below
# depends on the starting state actually being pristine.
assert "the example spec is installed" test -f "$SPEC_SRC"
assert_contains "and ships disabled" '"enabled": 0' "$(cat "$SPEC_SRC")"

status=$(proxmod-patch status)
assert_contains "status knows about it" "$SPEC_ID" "$status"
assert_contains "and reports it disabled" "disabled" "$status"

assert "the target carries no marker" \
    bash -c "! grep -q 'proxmod:begin' '$TARGET'"

verify_out=$(dpkg_verify_pve)
assert_eq "dpkg -V is silent before we touch anything" "" "$verify_out"

assert "nothing has been backed up" test ! -e "$BACKUP"

describe "enable it and converge"

# The administrator-owned overlay: /etc/proxmod/patches wins over
# /usr/share/proxmod/patches by basename, so enabling a shipped spec is a copy
# and one edit, and `dpkg -V proxmod` stays silent because the package's own
# copy was never touched.
mkdir -p /etc/proxmod/patches
sed 's/"enabled": 0/"enabled": 1/' "$SPEC_SRC" > "$SPEC_ON"
assert_contains "the overlay is enabled" '"enabled": 1' "$(cat "$SPEC_ON")"

before_sha=$(sha256sum "$TARGET" | cut -d' ' -f1)

out=$(proxmod-patch converge 2>&1); rc=$?
assert_eq "converge exits 0" "0" "$rc"
assert_contains "and reports one change" "changed=1 failed=0" "$out"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

assert "the target now carries the begin marker" \
    bash -c "grep -q 'proxmod:begin $SPEC_ID' '$TARGET'"
assert "and the end marker" \
    bash -c "grep -q 'proxmod:end $SPEC_ID' '$TARGET'"
assert "and the text between them" \
    bash -c "grep -q 'proxmod example patch' '$TARGET'"

assert "a backup was taken" test -f "$BACKUP"
assert_eq "and it is the file we started with" "$before_sha" \
    "$(sha256sum "$BACKUP" | cut -d' ' -f1)"
assert "the state database records it" \
    bash -c "grep -q '$SPEC_ID' '$STATE'"

# The honest cost, stated as an assertion rather than a footnote. Every other
# test in this suite asserts that dpkg -V is silent; this is the one place
# proxmod deliberately makes it speak, and an administrator who enables a spec
# has traded that silence away. If this ever passes, the patch did nothing.
verify_out=$(dpkg_verify_pve)
assert_contains "dpkg -V now reports the patched file — this is what a patch costs" \
    "index.html.tpl" "$verify_out"

status=$(proxmod-patch status)
assert_contains "status says applied" "applied" "$status"

describe "converging again changes nothing"

# The fourth prior-art defect: a patch reapplied on top of itself, producing a
# file with the insertion twice and a backup of the already-patched version.
# The markers exist so the engine can recognise its own work.
patched_sha=$(sha256sum "$TARGET" | cut -d' ' -f1)

out=$(proxmod-patch converge 2>&1)
assert_contains "the second converge reports no change" "changed=0 failed=0" "$out"
assert_eq "and the file is byte-identical" "$patched_sha" \
    "$(sha256sum "$TARGET" | cut -d' ' -f1)"
assert_eq "the insertion appears exactly once" "1" \
    "$(grep -c 'proxmod:begin' "$TARGET")"
assert_eq "and the backup is still the unpatched file" "$before_sha" \
    "$(sha256sum "$BACKUP" | cut -d' ' -f1)"

describe "survive a pve-manager upgrade"

# The reason this file exists. dpkg replaces index.html.tpl wholesale during a
# pve-manager upgrade, which destroys the patch and makes the backup stale in
# the same instant. What must NOT happen is the prior art's failure: restoring
# that backup over the newer file, silently reverting whatever the upgrade
# changed in it and leaving the host running a mixture of two releases.
if ! iso_repo_available; then
    skip "no installer ISO attached — the upgrade half cannot run"
    skip "attach one with PROXMOD_PVE_ISO and re-run"
else
    src=$(find "$ISO_MNT/dists" -name 'pve-manager_*_all.deb' | head -1)
    if [ -z "$src" ]; then
        no "found pve-manager on the ISO" "nothing matching pve-manager_*_all.deb"
    else
        cur=$(dpkg-query -W -f='${Version}' pve-manager)
        new="${cur}+proxmodpatch1"
        work=$(mktemp -d /var/tmp/proxmod-patch-e2e.XXXXXX)

        # A marker only the repacked file carries, so "the upgrade's version of
        # this file survived" is a thing that can be asserted rather than
        # assumed. Without it, a restored backup and a correctly reapplied
        # patch look identical from the outside.
        dpkg-deb -R "$src" "$work/pkg" >/dev/null
        sed -i "s/^Version: .*/Version: $new/" "$work/pkg/DEBIAN/control"
        printf '<!-- proxmod-e2e upgrade marker -->\n' \
            >> "$work/pkg/usr/share/pve-manager/index.html.tpl"
        repacked="$work/pve-manager_${new}_all.deb"
        dpkg-deb -b "$work/pkg" "$repacked" >/dev/null
        assert "repacked pve-manager $new with a marker in the template" test -f "$repacked"

        if DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
               --no-install-recommends "$repacked" >"$work/apt.log" 2>&1; then
            ok "the upgrade installed"
        else
            no "the upgrade installed" "$(tail -20 "$work/apt.log")"
        fi

        assert "both daemons are active afterwards" daemons_active
        assert "the web interface answers"          wait_for_web

        # The assertion the whole file is for. The upgrade's own change to this
        # file is still here — so nothing restored a stale backup over it.
        assert "the upgrade's version of the file survived" \
            bash -c "grep -q 'proxmod-e2e upgrade marker' '$TARGET'"

        # And proxmod's trigger reconverged onto the new file rather than
        # leaving the spec enabled-but-not-applied. Either outcome is safe;
        # this one is the one that is also correct.
        assert "the patch was reapplied to the upgraded file" \
            bash -c "grep -q 'proxmod:begin $SPEC_ID' '$TARGET'"
        assert_eq "still exactly once" "1" "$(grep -c 'proxmod:begin' "$TARGET")"

        # The backup is now of the UPGRADED file, not the pre-upgrade one.
        # That is the property that makes revert safe: reverting after an
        # upgrade has to give back the file the upgrade installed.
        assert "the backup was retaken against the new file" \
            bash -c "grep -q 'proxmod-e2e upgrade marker' '$BACKUP'"
        assert "and holds no patch of its own" \
            bash -c "! grep -q 'proxmod:begin' '$BACKUP'"

        out=$(proxmod-patch status)
        assert_contains "status reports it applied, not drifted" "applied" "$out"
        refute_contains "and not orphaned" "no spec describes it" "$out"

        rm -rf "$work"
    fi
fi

describe "revert puts the file back exactly"

out=$(proxmod-patch revert "$SPEC_ID" 2>&1); rc=$?
assert_eq "revert exits 0" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

assert "no marker is left in the file" \
    bash -c "! grep -q 'proxmod:begin' '$TARGET'"

verify_out=$(dpkg_verify_pve)
assert_eq "dpkg -V is silent again — byte-for-byte, not approximately" "" "$verify_out"

# The third prior-art defect: a leaked backup. A backup that outlives its patch
# is what lets a stale copy be restored over a newer file months later.
assert "the backup was removed" test ! -e "$BACKUP"

describe "disabling a spec un-applies it"

# The state a host is in after an administrator decides a patch was a mistake.
# Converge has to undo it — an enabled spec and an applied patch are the same
# fact, so removing one has to remove the other, without anyone naming the id.
sed 's/"enabled": 0/"enabled": 1/' "$SPEC_SRC" > "$SPEC_ON"
proxmod-patch converge >/dev/null 2>&1
assert "applied again, to have something to undo" \
    bash -c "grep -q 'proxmod:begin' '$TARGET'"

rm -f "$SPEC_ON"
out=$(proxmod-patch converge 2>&1)
assert_contains "converge undoes it" "changed=1 failed=0" "$out"
assert "the marker is gone" bash -c "! grep -q 'proxmod:begin' '$TARGET'"
assert "and so is the backup"  test ! -e "$BACKUP"

verify_out=$(dpkg_verify_pve)
assert_eq "dpkg -V is silent" "" "$verify_out"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0 with the host back to normal" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

describe "leave the host as 13-purge expects to find it"

# If the upgrade half ran, pve-manager's files are legitimately different from
# the ones 00 recorded. 13 compares against this manifest to prove that purging
# proxmod changed nothing, so it has to be re-recorded here for the same reason
# 08 re-records it — otherwise 13 reports the upgrade as damage proxmod did.
pve_file_manifest > "$STATE_DIR/pve-files.before"
ok "re-recorded the PVE file manifest"

summary
