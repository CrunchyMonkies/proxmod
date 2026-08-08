#!/bin/bash
# 09 — an apt run that has nothing to do with proxmod must cost nothing.
#
# This is the regression test for the prior art's APT DPkg::Post-Invoke hook,
# which ran its reapply script after *every* apt invocation. On a hypervisor
# that means the web interface and the API daemon bounce whenever anyone
# installs an unrelated package — which trains administrators to expect brief
# outages from routine work, and buries a real failure in the noise.
#
# dpkg triggers do not have that shape: the trigger only fires when a package
# writes into a directory proxmod declared an interest in. Everything else is
# invisible to it. That is the property under test here.

# shellcheck source=test/integration/lib.sh
. "$(dirname "$0")/lib.sh"

describe "a genuinely no-op apt run"

before_proxy=$(unit_start_time pveproxy)
before_daemon=$(unit_start_time pvedaemon)

# Already installed at this version, so apt unpacks nothing and configures
# nothing — but it still runs the full apt/dpkg machinery, hooks included.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends proxmod \
    >/var/tmp/proxmod-noop-apt.log 2>&1 || true

assert_eq "pveproxy was not restarted"  "$before_proxy"  "$(unit_start_time pveproxy)"
assert_eq "pvedaemon was not restarted" "$before_daemon" "$(unit_start_time pvedaemon)"

describe "installing an unrelated package"

# Built here rather than pulled from a repository so the test is hermetic and
# so we can be certain the package ships nothing under any path proxmod
# watches. It is the ordinary case: an administrator installs something, and
# the hypervisor's control plane does not notice.
work=$(mktemp -d /var/tmp/proxmod-unrelated.XXXXXX)
mkdir -p "$work/pkg/DEBIAN" "$work/pkg/usr/share/doc/proxmod-e2e-unrelated"
cat > "$work/pkg/DEBIAN/control" <<'EOF'
Package: proxmod-e2e-unrelated
Version: 1.0
Architecture: all
Maintainer: proxmod e2e <root@localhost>
Description: A package that has nothing to do with proxmod.
 Used to prove that installing it does not restart the PVE daemons.
EOF
printf 'nothing to see here\n' > "$work/pkg/usr/share/doc/proxmod-e2e-unrelated/README"
dpkg-deb -b "$work/pkg" "$work/proxmod-e2e-unrelated_1.0_all.deb" >/dev/null

before_proxy=$(unit_start_time pveproxy)
before_daemon=$(unit_start_time pvedaemon)

assert "install the unrelated package" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "$work/proxmod-e2e-unrelated_1.0_all.deb"

assert_eq "pveproxy was still not restarted"  "$before_proxy"  "$(unit_start_time pveproxy)"
assert_eq "pvedaemon was still not restarted" "$before_daemon" "$(unit_start_time pvedaemon)"

assert "remove it again" \
    env DEBIAN_FRONTEND=noninteractive apt-get purge -y proxmod-e2e-unrelated

assert_eq "removing it did not restart pveproxy"  "$before_proxy"  "$(unit_start_time pveproxy)"
assert_eq "removing it did not restart pvedaemon" "$before_daemon" "$(unit_start_time pvedaemon)"

rm -rf "$work"

describe "convergence is idempotent on its own terms"

# proxmod-reapply is also run directly — from the boot unit, and by an
# administrator after editing something. Run twice against an already-correct
# system it must decide there is nothing to do, rather than restarting because
# it was asked to.
before_proxy=$(unit_start_time pveproxy)

assert "proxmod-reapply exits 0"        /usr/lib/proxmod/proxmod-reapply
assert "proxmod-reapply exits 0 again"  /usr/lib/proxmod/proxmod-reapply

assert_eq "and neither run restarted pveproxy" "$before_proxy" "$(unit_start_time pveproxy)"

describe "the system is still healthy after all that"

assert "both daemons are active" daemons_active
assert_eq "still exactly one loader tag" "1" "$(loader_tag_count)"

out=$(proxmod-verify 2>&1); rc=$?
assert_eq "proxmod-verify exits 0" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'

summary
