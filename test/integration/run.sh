#!/bin/bash
# The in-VM runner. Executes the numbered test scripts in order and prints one
# summary at the end.
#
# Order is load-bearing and the numbering is the schedule: 00 records the
# pristine baseline that 02 and 11 compare against, 01 installs what 11 purges,
# 04 installs the extension that 05 through 10 assume is present. So a failure
# in 00 or 01 aborts — every later result would be measured against a baseline
# that was never taken, or a package that was never installed.
#
# Everything after that continues on failure. A broken frontend should not stop
# us from learning whether the upgrade path works, and one run that reports six
# real failures is worth more than six runs that each report the first.
#
# Usage, inside the VM as root:
#     test/integration/run.sh            # everything, in order
#     test/integration/run.sh 03 07      # just those, still in order
#     KEEP_GOING=0 test/integration/run.sh   # stop at the first failure

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
KEEP_GOING="${KEEP_GOING:-1}"

if [ "$(id -u)" -ne 0 ]; then
    printf 'these tests modify a live PVE host and must run as root\n' >&2
    exit 64
fi

# Selection. An argument is a prefix: `03` matches 03-frontend.sh.
scripts=()
if [ "$#" -gt 0 ]; then
    for want in "$@"; do
        for f in "$HERE/${want}"*.sh; do
            [ -f "$f" ] && scripts+=("$f")
        done
    done
else
    for f in "$HERE"/[0-9][0-9]-*.sh; do
        [ -f "$f" ] && scripts+=("$f")
    done
fi

if [ "${#scripts[@]}" -eq 0 ]; then
    printf 'no test scripts matched\n' >&2
    exit 64
fi

bold()  { printf '\033[1m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }

passed=()
failed=()
started=$(date +%s)

for script in "${scripts[@]}"; do
    name=$(basename "$script" .sh)

    printf '\n%s\n' "$(bold "═══ $name ══════════════════════════════════════════")"

    bash "$script"
    rc=$?

    if [ "$rc" -eq 0 ]; then
        passed+=("$name")
        printf '%s %s\n' "$(green '═══ PASS')" "$name"
    else
        failed+=("$name")
        printf '%s %s (exit %d)\n' "$(red '═══ FAIL')" "$name" "$rc"

        case "$name" in
            00-*|01-*)
                printf '\n%s\n' "$(red "$name is a prerequisite for everything that follows — stopping.")"
                break
                ;;
        esac

        [ "$KEEP_GOING" = "1" ] || break
    fi
done

elapsed=$(( $(date +%s) - started ))

printf '\n%s\n' "$(bold '═══ summary ════════════════════════════════════════')"
for n in "${passed[@]+"${passed[@]}"}"; do printf '  %s %s\n' "$(green 'pass')" "$n"; done
for n in "${failed[@]+"${failed[@]}"}"; do printf '  %s %s\n' "$(red 'FAIL')" "$n"; done

printf '\n  %d passed, %d failed, %ds\n\n' \
    "${#passed[@]}" "${#failed[@]}" "$elapsed"

# One last look at the thing that matters more than any individual assertion.
# A suite that passed while leaving pvedaemon dead has not passed.
for unit in pvedaemon pveproxy; do
    state=$(systemctl is-active "$unit" 2>/dev/null)
    if [ "$state" = "active" ]; then
        printf '  %s %s is active\n' "$(green 'ok  ')" "$unit"
    else
        printf '  %s %s is %s\n' "$(red 'FAIL')" "$unit" "${state:-unknown}"
        failed+=("$unit-left-not-running")
    fi
done
printf '\n'

[ "${#failed[@]}" -eq 0 ]
