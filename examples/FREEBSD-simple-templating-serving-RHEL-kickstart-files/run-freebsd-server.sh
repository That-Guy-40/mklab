#!/usr/bin/env bash
# run-freebsd-server.sh — launch the FreeBSD "www" VM under QEMU/KVM.
#
# lab-vm.sh has no FreeBSD backend, so we drive QEMU directly. The VM gets TWO
# NICs (mirroring vermaden's two-interface host):
#   net0 = user-mode slirp  -> internet for pkg + an ssh hostfwd for management
#   lan  = qemu socket LAN  -> a rootless L2 segment shared with the AlmaLinux
#                              client (run-kickme-client.sh connects to it)
# Everything here is exactly what was used to verify the server in this lab.
#
# Quick start:
#   ./run-freebsd-server.sh up      # fetch image (once), seed, boot (background)
#   ssh -p 2222 -i "$WORKDIR/id_lab" freebsd@127.0.0.1      # then: su -  (pw: freebsd)
#   ./run-freebsd-server.sh stop
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/freebsd-kickstart-lab}"
FBSD_REL="${FBSD_REL:-14.3-RELEASE}"
IMG_XZ="FreeBSD-${FBSD_REL}-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz"
IMG_URL="https://download.freebsd.org/releases/VM-IMAGES/${FBSD_REL}/amd64/Latest/${IMG_XZ}"
BASE="$WORKDIR/FreeBSD-${FBSD_REL}-cloudinit.qcow2"
OVERLAY="$WORKDIR/www-overlay.qcow2"
SEED="$WORKDIR/seed.iso"
SERIAL="$WORKDIR/www-console.log"
PIDFILE="$WORKDIR/www.pid"
SSH_PORT="${SSH_PORT:-2222}"
LAN_PORT="${LAN_PORT:-12377}"          # socket-LAN rendezvous port (host loopback)
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$WORKDIR"

fetch_image() {
    [[ -f "$BASE" ]] && { echo "image present: $BASE"; return; }
    echo "==> fetching $IMG_URL"
    curl -fSL -o "$WORKDIR/$IMG_XZ" "$IMG_URL"
    echo "==> decompressing"
    xz -dk -T0 "$WORKDIR/$IMG_XZ"
    mv "$WORKDIR/FreeBSD-${FBSD_REL}-amd64-BASIC-CLOUDINIT-ufs.qcow2" "$BASE"
}

make_seed() {
    [[ -f "$WORKDIR/id_lab" ]] || ssh-keygen -t ed25519 -N '' -f "$WORKDIR/id_lab" -C lab@freebsd-kickstart >/dev/null
    local pub; pub="$(cat "$WORKDIR/id_lab.pub")"
    local tmp; tmp="$(mktemp -d)"
    sed "s|__LAB_PUBKEY__|$pub|" "$HERE/freebsd-server/cloud-init/user-data" > "$tmp/user-data"
    cp "$HERE/freebsd-server/cloud-init/meta-data" "$tmp/meta-data"
    genisoimage -quiet -output "$SEED" -volid cidata -joliet -rock "$tmp/user-data" "$tmp/meta-data"
    rm -rf "$tmp"
}

up() {
    command -v qemu-system-x86_64 >/dev/null || { echo "need qemu-system-x86_64" >&2; exit 1; }
    fetch_image
    make_seed
    [[ -f "$OVERLAY" ]] || qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$OVERLAY" 16G >/dev/null
    echo "==> booting FreeBSD www (serial -> $SERIAL, ssh -> 127.0.0.1:$SSH_PORT, LAN -> socket :$LAN_PORT)"
    qemu-system-x86_64 \
        -name freebsd-www -machine q35 -accel kvm -cpu host -m 2048 -smp 2 \
        -drive file="$OVERLAY",if=virtio,format=qcow2 \
        -drive file="$SEED",if=virtio,format=raw,readonly=on \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
        -device virtio-net-pci,netdev=net0,mac=52:54:00:11:11:10 \
        -netdev socket,id=lan,listen=:"$LAN_PORT" \
        -device virtio-net-pci,netdev=lan,mac=52:54:00:10:10:10 \
        -display none -serial file:"$SERIAL" -monitor none \
        -pidfile "$PIDFILE" -daemonize
    echo "==> up. PID $(cat "$PIDFILE"). First boot runs freebsd-update + reboots (~2-4 min)."
    echo "    ssh -p $SSH_PORT -i $WORKDIR/id_lab freebsd@127.0.0.1     # su -  (password: freebsd)"
    echo "    then provision:  see freebsd-server/setup-freebsd.sh"
}

stop() {
    # Kill by PID from the pidfile — never by pattern (the cmdline carries shared
    # strings). Fall back to the qemu-filtered PID if the pidfile is gone.
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")"; echo "stopped PID $(cat "$PIDFILE")"; rm -f "$PIDFILE"
    else
        for p in $(pgrep -f 'name freebsd-www' 2>/dev/null || true); do
            [[ "$(cat /proc/$p/comm 2>/dev/null)" == qemu-system-x86 ]] && { kill "$p"; echo "stopped PID $p"; }
        done
    fi
}

case "${1:-up}" in
    up)   up ;;
    stop) stop ;;
    *)    echo "usage: $0 [up|stop]" >&2; exit 1 ;;
esac
