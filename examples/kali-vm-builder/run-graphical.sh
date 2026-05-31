#!/usr/bin/env bash
# run-graphical.sh — boot a kali-vm-built Kali image in a WINDOWED QEMU desktop.
#
# kali-vm's `qemu` variant is a BIOS/MBR (grub-pc) QCOW2 with the XFCE desktop +
# qemu-guest-agent/spice-vdagent — meant to be run with a real display, not a
# serial console.  This boots it the way it's intended: SeaBIOS (no UEFI), a
# virtio disk, a virtio GPU, a gtk window, and an SSH port-forward.
#
# By default it runs a per-image OVERLAY (copy-on-write) so the freshly built
# master image stays pristine; your changes persist in the overlay across runs.
#
# Usage:
#   examples/kali-vm-builder/run-graphical.sh [options]
#
# Options:
#   --image PATH    Image to boot. Default: newest images/kali-linux-*-qemu-amd64.qcow2
#                   under the work dir.
#   --workdir DIR   Where the checkout/images live (default: $KALI_VM_DIR or
#                   $HOME/kali-vm-build). Used to locate the image + store overlays.
#   --memory SIZE   Guest RAM (default: 4G)
#   --cpus N        vCPUs (default: 2)
#   --display BACK  gtk (default) | sdl | none
#   --ssh-port P    Host port forwarded to guest :22 (default: 2222; 0 = no forward)
#   --no-overlay    Boot the master image directly (mutates it). Off by default.
#   --fresh         Recreate the overlay from the master before booting.
#   --snapshot      Ephemeral: discard all disk writes on shutdown (-snapshot).
#   --help          show this help and exit
#
# Login: kali / kali  (whatever you passed to build-kali-vm.sh -U). SSH in with:
#   ssh -p <ssh-port> kali@127.0.0.1   (after you `sudo systemctl enable --now ssh` once)

set -euo pipefail

WORKDIR="${KALI_VM_DIR:-$HOME/kali-vm-build}"
IMAGE=""
MEMORY="4G"
CPUS="2"
DISPLAY_BACK="gtk"
SSH_PORT="2222"
OVERLAY=1
FRESH=0
SNAPSHOT=0

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || :; }
log()  { _c 36; printf '[run]'   >&2; _c 0; printf ' %s\n' "$*" >&2; }
warn() { _c 33; printf '[run] WARNING:' >&2; _c 0; printf ' %s\n' "$*" >&2; }
die()  { _c 31; printf '[run] ERROR:'   >&2; _c 0; printf ' %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --image)     IMAGE="${2:?--image needs a path}";   shift 2 ;;
        --workdir)   WORKDIR="${2:?--workdir needs a path}"; shift 2 ;;
        --memory)    MEMORY="${2:?--memory needs a size}";  shift 2 ;;
        --cpus)      CPUS="${2:?--cpus needs a number}";    shift 2 ;;
        --display)   DISPLAY_BACK="${2:?--display needs a value}"; shift 2 ;;
        --ssh-port)  SSH_PORT="${2:?--ssh-port needs a value}";    shift 2 ;;
        --no-overlay) OVERLAY=0; shift ;;
        --fresh)     FRESH=1; shift ;;
        --snapshot)  SNAPSHOT=1; shift ;;
        --help|-h)   usage 0 ;;
        *)           die "unknown argument: $1  (try --help)" ;;
    esac
done

case "$DISPLAY_BACK" in gtk|sdl|none) ;; *) die "invalid --display '$DISPLAY_BACK' (gtk|sdl|none)" ;; esac
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found (sudo apt install -y qemu-system-x86)"

# ── Locate the image ─────────────────────────────────────────────────────────
if [ -z "$IMAGE" ]; then
    IMAGE="$(ls -t "$WORKDIR"/kali-vm/images/kali-linux-*-qemu-amd64.qcow2 2>/dev/null | head -1 || :)"
    [ -n "$IMAGE" ] || die "no image found under $WORKDIR/kali-vm/images/ — build one first (build-kali-vm.sh) or pass --image"
fi
[ -r "$IMAGE" ] || die "image not readable: $IMAGE"
log "master image: $IMAGE"

# ── Decide the disk to boot (master vs overlay) ──────────────────────────────
DISK="$IMAGE"
if [ "$OVERLAY" -eq 1 ]; then
    command -v qemu-img >/dev/null || die "qemu-img not found (sudo apt install -y qemu-utils)"
    RUNDIR="$WORKDIR/run"; mkdir -p "$RUNDIR"
    DISK="$RUNDIR/$(basename "${IMAGE%.qcow2}").overlay.qcow2"
    if [ "$FRESH" -eq 1 ] && [ -e "$DISK" ]; then log "removing overlay (--fresh): $DISK"; rm -f "$DISK"; fi
    # Auto-refresh a stale overlay: a rebuild reuses the same image filename, so an
    # overlay backed by the OLD master would now point at changed content (boot junk).
    if [ -e "$DISK" ] && [ "$IMAGE" -nt "$DISK" ]; then
        log "master is newer than the overlay — recreating (rebuild detected): $DISK"
        rm -f "$DISK"
    fi
    if [ ! -e "$DISK" ]; then
        log "creating overlay (master stays pristine): $DISK"
        qemu-img create -f qcow2 -F qcow2 -b "$IMAGE" "$DISK" >/dev/null
    else
        log "reusing overlay: $DISK"
    fi
fi

# ── Accel: KVM if available, else TCG (slow) ─────────────────────────────────
ACCEL="tcg"
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL="kvm"; else warn "/dev/kvm not accessible — falling back to slow TCG emulation"; fi

# ── QEMU command.  No -bios/OVMF: the image is grub-pc (BIOS), SeaBIOS boots
#    the MBR. virtio disk + virtio-gpu match the qemu variant's guest agents. ──
QEMU=(
    qemu-system-x86_64
    -machine q35 -accel "$ACCEL"
    -m "$MEMORY" -smp "$CPUS"
    -drive file="$DISK",format=qcow2,if=virtio
    -vga virtio
    -device qemu-xhci -device usb-tablet
    -name "kali-vm:$(basename "$IMAGE")"
)
[ "$ACCEL" = kvm ] && QEMU+=(-cpu host)

# Networking: user-mode (slirp) + optional SSH forward.
if [ "$SSH_PORT" = "0" ] || [ -z "$SSH_PORT" ]; then
    QEMU+=(-nic user,model=virtio-net-pci)
else
    QEMU+=(-nic "user,model=virtio-net-pci,hostfwd=tcp::${SSH_PORT}-:22")
fi

case "$DISPLAY_BACK" in
    gtk)  QEMU+=(-display gtk) ;;
    sdl)  QEMU+=(-display sdl) ;;
    none) QEMU+=(-display none) ;;
esac

[ "$SNAPSHOT" -eq 1 ] && QEMU+=(-snapshot)

log "booting (accel=$ACCEL, display=$DISPLAY_BACK, disk=$DISK)"
[ "$SSH_PORT" != "0" ] && [ -n "$SSH_PORT" ] && \
    log "SSH forward: ssh -p $SSH_PORT kali@127.0.0.1  (enable in guest first: sudo systemctl enable --now ssh)"
log "running: ${QEMU[*]}"
exec "${QEMU[@]}"
