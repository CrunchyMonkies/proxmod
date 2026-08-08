#!/bin/bash
# serial.sh — talk to the VM's serial console over a QEMU unix socket.
#
# Sourced by vm.sh. Used for exactly one job: get far enough into a freshly
# booted VM to install an SSH key. Everything after that goes over SSH, which
# gives real exit codes, real stdio and scp.
#
# The prior art (~/dev/pmxxpuiov/test/qemu/serial-cmd.sh) opened a fresh socat
# connection per line sent, alongside a background listener on the same socket.
# QEMU's socket chardev services one client at a time, so the second connection
# sits in the listen backlog until the first drops — which is why that script
# needed sleeps between every line and still raced. Here there is exactly one
# connection for the whole session: a writer fd into a FIFO, socat in the
# middle, and every byte the console emits appended to one log we grep.

# shellcheck shell=bash

SERIAL_LOG=""
SERIAL_FIFO=""
SERIAL_SOCAT_PID=""

# serial_open <socket-path>
serial_open() {
    local sock="$1"

    [ -S "$sock" ] || { echo "serial: no socket at $sock" >&2; return 1; }
    command -v socat >/dev/null 2>&1 || { echo "serial: socat not installed" >&2; return 1; }

    SERIAL_LOG=$(mktemp -t proxmod-serial-log.XXXXXX)
    SERIAL_FIFO=$(mktemp -u -t proxmod-serial-fifo.XXXXXX)
    mkfifo "$SERIAL_FIFO"

    socat "UNIX-CONNECT:${sock}" - < "$SERIAL_FIFO" > "$SERIAL_LOG" 2>/dev/null &
    SERIAL_SOCAT_PID=$!

    # Hold the write end open ourselves. Without this the FIFO sees EOF as soon
    # as the first `echo >` finishes and socat exits.
    exec 9>"$SERIAL_FIFO"
}

serial_close() {
    exec 9>&- 2>/dev/null || true
    [ -n "$SERIAL_SOCAT_PID" ] && kill "$SERIAL_SOCAT_PID" 2>/dev/null
    [ -n "$SERIAL_SOCAT_PID" ] && wait "$SERIAL_SOCAT_PID" 2>/dev/null
    rm -f "$SERIAL_FIFO"
    SERIAL_SOCAT_PID=""
}

# serial_send <text> — written verbatim, no newline appended.
serial_send() { printf '%s' "$1" >&9; }

# serial_line <text> — one line plus a carriage return, which is what a tty wants.
serial_line() { printf '%s\r' "$1" >&9; }

# serial_wait <regex> <timeout-seconds> [label]
# Waits for the console output to match, from the top of the log each time so a
# pattern that arrived while we were doing something else still counts.
serial_wait() {
    local pattern="$1" timeout="${2:-120}" label="${3:-$1}"
    local waited=0

    while [ "$waited" -lt "$timeout" ]; do
        if grep -qE "$pattern" "$SERIAL_LOG" 2>/dev/null; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    echo "serial: timed out after ${timeout}s waiting for ${label}" >&2
    echo "serial: last 20 lines of console:" >&2
    tail -n 20 "$SERIAL_LOG" >&2 || true
    return 1
}

# serial_truncate — forget everything seen so far, so the next serial_wait
# cannot match an older occurrence of its pattern.
serial_truncate() { : > "$SERIAL_LOG"; }

# serial_login <user> <password> <timeout>
# Idempotent: if a shell prompt is already up (a re-run against a VM someone
# left logged in), pressing return produces one and we skip the credentials.
serial_login() {
    local user="$1" password="$2" timeout="${3:-300}"

    serial_line ""
    sleep 2

    if grep -qE '(login:|Password:)' "$SERIAL_LOG" 2>/dev/null; then
        : # a prompt is waiting; fall through and answer it
    else
        serial_wait 'login:' "$timeout" 'the login prompt' || return 1
    fi

    if grep -q 'login:' "$SERIAL_LOG" 2>/dev/null; then
        serial_truncate
        serial_line "$user"
        serial_wait 'Password:' 30 'the password prompt' || return 1
        serial_truncate
        serial_line "$password"
    fi

    # A prompt string is not proof of a working shell — the console echoes
    # plenty that looks like one. Ask for a token instead, and compute it in
    # the shell: the tty echoes the literal `$((6*7))` we typed, so a match on
    # SHELL_42_READY can only have come from a shell that evaluated it.
    serial_truncate
    # shellcheck disable=SC2016 # expanded by the shell in the VM, not this one
    serial_line 'echo SHELL_$((6*7))_READY'
    serial_wait 'SHELL_42_READY' 30 'a usable root shell' || return 1
}

# serial_run <command> — fire and forget. Bootstrap only; anything whose output
# or exit status matters belongs over SSH.
serial_run() {
    serial_truncate
    serial_line "$1"
    sleep 1
}
