#!/bin/bash
# vm.sh — QEMU lifecycle for the proxmod integration suite.
#
#   ./vm.sh install         build the golden image from the ISO, unattended
#   ./vm.sh start           boot a throwaway overlay on the golden image
#   ./vm.sh ssh <cmd...>    run a command in the VM
#   ./vm.sh push <l> <r>    copy a file in
#   ./vm.sh pull <r> <l>    copy a file out
#   ./vm.sh console         attach an interactive serial console
#   ./vm.sh stop            kill the VM and delete the overlay
#   ./vm.sh status
#
# Two things this does that the harness it was adapted from did not:
#
#   * The golden image is never opened for writing. Every run gets a fresh
#     qcow2 overlay, so a test that corrupts the host cannot cost you the
#     forty minutes it takes to reinstall. `stop` throws the overlay away.
#
#   * The installer ISO is attached as a second, read-only CD. It carries a
#     complete Debian repository at dists/trixie/pve/binary-amd64/, which is
#     what makes the upgrade-survival test offline and reproducible: no
#     enterprise subscription, no network, no drift between runs.
#
# Environment:
#   PROXMOD_PVE_IMAGE   golden qcow2            (default test/qemu/pve-test.qcow2)
#   PROXMOD_PVE_ISO     installer ISO           (default test/qemu/proxmox-ve_9.1-1.iso)
#   PROXMOD_SSH_PORT    host port -> VM 22      (default 22206)
#   PROXMOD_WEB_PORT    host port -> VM 8006    (default 18006)
#   PROXMOD_VM_MEM      megabytes               (default 2560)
#   PROXMOD_VM_CPUS                             (default 2)
#   PROXMOD_ROOT_PW     VM root password        (default testpassword)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/qemu/serial.sh
. "$HERE/serial.sh"

BASE_IMAGE="${PROXMOD_PVE_IMAGE:-$HERE/pve-test.qcow2}"
ISO="${PROXMOD_PVE_ISO:-$HERE/proxmox-ve_9.1-1.iso}"
SSH_PORT="${PROXMOD_SSH_PORT:-22206}"
WEB_PORT="${PROXMOD_WEB_PORT:-18006}"
VM_MEM="${PROXMOD_VM_MEM:-2560}"
VM_CPUS="${PROXMOD_VM_CPUS:-2}"
ROOT_PW="${PROXMOD_ROOT_PW:-testpassword}"

RUN_DIR="$HERE/.run"
OVERLAY="$RUN_DIR/overlay.qcow2"
SERIAL_SOCK="$RUN_DIR/serial.sock"
MONITOR_SOCK="$RUN_DIR/monitor.sock"
PIDFILE="$RUN_DIR/qemu.pid"
SSH_KEY="$RUN_DIR/id_ed25519"

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o BatchMode=yes
)

say()  { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "$c is required but not installed"
    done
}

# ---------------------------------------------------------------- lifecycle

vm_running() {
    [ -f "$PIDFILE" ] || return 1
    kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

cmd_status() {
    if vm_running; then
        echo "running (pid $(cat "$PIDFILE"))"
        echo "  ssh    localhost:${SSH_PORT}"
        echo "  web    https://localhost:${WEB_PORT}"
        echo "  serial ${SERIAL_SOCK}"
    else
        echo "stopped"
        [ -f "$BASE_IMAGE" ] && echo "  golden image present: $BASE_IMAGE" \
                             || echo "  no golden image; run: $0 install"
    fi
}

cmd_stop() {
    if vm_running; then
        say "stopping the VM"
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        for _ in $(seq 1 20); do vm_running || break; sleep 0.5; done
        if vm_running; then kill -9 "$(cat "$PIDFILE")" 2>/dev/null || true; fi
    fi
    rm -f "$PIDFILE" "$SERIAL_SOCK" "$MONITOR_SOCK" "$OVERLAY"
}

cmd_start() {
    need qemu-system-x86_64 qemu-img socat ssh

    [ -f "$BASE_IMAGE" ] || die "no golden image at $BASE_IMAGE
Build one with:   $0 install
Or point at an existing one:   PROXMOD_PVE_IMAGE=/path/to/pve-test.qcow2 $0 start"

    vm_running && die "a VM is already running (pid $(cat "$PIDFILE")). $0 stop"

    mkdir -p "$RUN_DIR"
    rm -f "$SERIAL_SOCK" "$MONITOR_SOCK"

    # The golden image is a backing file and is only ever read. Everything this
    # run writes lands in the overlay, which cmd_stop deletes.
    say "creating a throwaway overlay on $(basename "$BASE_IMAGE")"
    qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$BASE_IMAGE")" "$OVERLAY" >/dev/null

    local iso_args=()
    if [ -f "$ISO" ]; then
        iso_args=(-drive "file=$ISO,media=cdrom,readonly=on")
    else
        say "WARNING: no ISO at $ISO — the offline upgrade test will be skipped"
    fi

    say "booting (ssh :$SSH_PORT, web :$WEB_PORT)"
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$VM_MEM" \
        -smp "$VM_CPUS" \
        -drive "file=$OVERLAY,format=qcow2,if=virtio" \
        ${iso_args[@]+"${iso_args[@]}"} \
        -boot c \
        -netdev "user,id=n0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${WEB_PORT}-:8006" \
        -device virtio-net-pci,netdev=n0 \
        -chardev "socket,id=serial0,path=$SERIAL_SOCK,server=on,wait=off" \
        -serial chardev:serial0 \
        -monitor "unix:$MONITOR_SOCK,server,nowait" \
        -display none \
        -pidfile "$PIDFILE" \
        -daemonize

    for _ in $(seq 1 20); do [ -S "$SERIAL_SOCK" ] && break; sleep 1; done
    [ -S "$SERIAL_SOCK" ] || die "the serial socket never appeared"

    bootstrap_ssh
    say "ready"
}

# Log in on the console once, install a throwaway key, and never use the
# console again. SSH gives us exit codes and scp; the console gives us neither.
bootstrap_ssh() {
    say "waiting for boot and installing a test SSH key"

    [ -f "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C proxmod-e2e -f "$SSH_KEY"
    local pubkey
    pubkey=$(cat "${SSH_KEY}.pub")

    serial_open "$SERIAL_SOCK"
    trap 'serial_close' RETURN

    serial_login root "$ROOT_PW" "${PROXMOD_BOOT_TIMEOUT:-420}" \
        || die "could not get a root shell on the console"

    serial_run "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
    serial_run "printf '%s\\n' '$pubkey' >> /root/.ssh/authorized_keys"
    serial_run "chmod 600 /root/.ssh/authorized_keys"
    # PVE ships sshd enabled; this is belt and braces for a rebuilt image.
    serial_run "systemctl is-active --quiet ssh || systemctl restart ssh"

    say "waiting for SSH"
    local waited=0
    until ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" -p "$SSH_PORT" root@localhost true 2>/dev/null; do
        waited=$((waited + 3))
        [ "$waited" -gt 120 ] && die "SSH never came up on port $SSH_PORT"
        sleep 3
    done

    # pvedaemon and pveproxy start late. A test that installs proxmod before
    # they are up would restart daemons that had not finished starting, and the
    # failure would land on the test rather than on the bug.
    say "waiting for the PVE daemons"
    waited=0
    until vm_ssh 'systemctl is-active --quiet pvedaemon pveproxy' 2>/dev/null; do
        waited=$((waited + 5))
        [ "$waited" -gt 300 ] && die "pvedaemon/pveproxy did not become active"
        sleep 5
    done
}

# ------------------------------------------------------------------ access

vm_ssh() {
    ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" -p "$SSH_PORT" root@localhost "$@"
}

cmd_ssh() {
    vm_running || die "no VM is running. $0 start"
    if [ "$#" -eq 0 ]; then
        ssh "${SSH_OPTS[@]}" -o BatchMode=no -i "$SSH_KEY" -p "$SSH_PORT" root@localhost
    else
        vm_ssh "$@"
    fi
}

cmd_push() {
    local src="${1:?usage: push <local> <remote>}" dst="${2:?usage: push <local> <remote>}"
    vm_running || die "no VM is running. $0 start"
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" -q -r "$src" "root@localhost:$dst"
}

cmd_pull() {
    local src="${1:?usage: pull <remote> <local>}" dst="${2:?usage: pull <remote> <local>}"
    vm_running || die "no VM is running. $0 start"
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" -q -r "root@localhost:$src" "$dst"
}

cmd_console() {
    vm_running || die "no VM is running. $0 start"
    need socat
    echo "attaching to the serial console; ctrl-o to detach" >&2
    socat -,raw,echo=0,escape=0x0f "UNIX-CONNECT:$SERIAL_SOCK"
}

# ----------------------------------------------------------------- install

# Unattended install into a fresh golden image. Run once; every test run after
# that is an overlay on top of it.
cmd_install() {
    need qemu-system-x86_64 qemu-img socat genisoimage

    [ -f "$ISO" ] || die "no installer ISO at $ISO
Download one:  wget -O '$ISO' https://enterprise.proxmox.com/iso/proxmox-ve_9.1-1.iso"

    if [ -f "$BASE_IMAGE" ]; then
        die "$BASE_IMAGE already exists. Delete it first if you mean to rebuild."
    fi

    mkdir -p "$RUN_DIR"
    local answer_disk="$RUN_DIR/answer.img"
    build_answer_disk "$answer_disk"

    say "creating a 32G golden image"
    qemu-img create -q -f qcow2 "$BASE_IMAGE" 32G

    rm -f "$SERIAL_SOCK" "$MONITOR_SOCK"
    say "running the unattended installer (this takes a while)"

    # The answer disk is a USB mass storage device with the label the installer
    # looks for. Attached that way it is found without touching the boot media.
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$VM_MEM" \
        -smp "$VM_CPUS" \
        -drive "file=$BASE_IMAGE,format=qcow2,if=virtio" \
        -drive "file=$ISO,media=cdrom,readonly=on" \
        -boot d \
        -drive "file=$answer_disk,format=raw,if=none,id=ais" \
        -device usb-ehci,id=ehci \
        -device usb-storage,bus=ehci.0,drive=ais,removable=on \
        -netdev user,id=n0 \
        -device virtio-net-pci,netdev=n0 \
        -chardev "socket,id=serial0,path=$SERIAL_SOCK,server=on,wait=off" \
        -serial chardev:serial0 \
        -monitor "unix:$MONITOR_SOCK,server,nowait" \
        -display none \
        -pidfile "$PIDFILE" \
        -daemonize

    for _ in $(seq 1 20); do [ -S "$MONITOR_SOCK" ] && break; sleep 1; done

    # The boot menu's fourth entry is "Automated Installation".
    say "selecting Automated Installation from the boot menu"
    sleep 15
    for _ in 1 2 3; do
        echo "sendkey down" | socat - "UNIX-CONNECT:$MONITOR_SOCK" >/dev/null
        sleep 0.5
    done
    echo "sendkey ret" | socat - "UNIX-CONNECT:$MONITOR_SOCK" >/dev/null

    say "installing; the VM powers off when it finishes"
    local waited=0 limit="${PROXMOD_INSTALL_TIMEOUT:-1800}"
    while vm_running; do
        [ "$waited" -ge "$limit" ] && break
        if [ $((waited % 60)) -eq 0 ] && [ "$waited" -gt 0 ]; then
            say "  ${waited}s — image is $(du -h "$BASE_IMAGE" | cut -f1)"
        fi
        sleep 10
        waited=$((waited + 10))
    done

    if vm_running; then
        cmd_stop
        rm -f "$BASE_IMAGE"
        die "the installer did not finish within ${limit}s; golden image discarded"
    fi

    rm -f "$PIDFILE" "$SERIAL_SOCK" "$MONITOR_SOCK" "$answer_disk"
    say "golden image built: $BASE_IMAGE"
    say "now run: $0 start"
}

build_answer_disk() {
    local out="$1"
    local dir
    dir=$(mktemp -d -t proxmod-answer.XXXXXX)

    cat > "$dir/answer.toml" <<EOF
[global]
keyboard = "en-us"
country = "us"
timezone = "UTC"
fqdn = "pve-test.local"
mailto = "root@pve-test.local"
root_password = "$ROOT_PW"

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk_list = ["vda"]
EOF

    # The installer identifies the answer medium by filesystem label.
    genisoimage -quiet -o "$out" -V proxmox-ais -J -r "$dir"
    rm -rf "$dir"
}

# -------------------------------------------------------------------- main

case "${1:-}" in
    install) shift; cmd_install "$@" ;;
    start)   shift; cmd_start "$@" ;;
    stop)    shift; cmd_stop "$@" ;;
    status)  shift; cmd_status "$@" ;;
    ssh)     shift; cmd_ssh "$@" ;;
    push)    shift; cmd_push "$@" ;;
    pull)    shift; cmd_pull "$@" ;;
    console) shift; cmd_console "$@" ;;
    *)
        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
