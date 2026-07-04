#!/usr/bin/env bash
# run-graphical.sh — boot the Kali image Packer baked, in a WINDOWED QEMU desktop.
#
# build-kali-box.sh produces a Vagrant `.box` (a gzipped tar of box.img +
# Vagrantfile + metadata.json).  box.img IS the QCOW2 disk.  This unpacks that
# QCOW2 and boots it the way it was installed: SeaBIOS (the packer qemu image is
# grub-pc / BIOS-MBR, not UEFI), a virtio-scsi disk (the interface Packer
# installed onto — see config.pkr.hcl `disk_interface = virtio-scsi`), a gtk
# window, and an SSH port-forward — on a copy-on-write overlay so the extracted
# master stays pristine.
#
# Usage:
#   examples/kali-packer-vagrant/run-graphical.sh [options]
#
# Options:
#   --box PATH      .box to boot. Default: newest packer_kalirolling_*.box under
#                   the work dir (checkout + workdir are searched).
#   --image PATH    Boot this QCOW2 directly, skipping .box extraction.
#   --workdir DIR   Where the checkout/box/images live (default: $KALI_PACKER_DIR
#                   or $HOME/kali-packer-build).
#   --extract-only  Unpack box.img → <workdir>/images/…qcow2 and exit (no boot).
#   --memory SIZE   Guest RAM (default: 4G)
#   --cpus N        vCPUs (default: 2)
#   --display BACK  gtk (default) | sdl | none
#   --ssh-port P    Host port forwarded to guest :22 (default: 2222; 0 = none)
#   --no-overlay    Boot the extracted master directly (mutates it).
#   --fresh         Recreate the overlay from the master before booting.
#   --snapshot      Ephemeral: discard all disk writes on shutdown (-snapshot).
#   --help          show this help and exit
#
# Login: vagrant / vagrant.  SSH: ssh -p <ssh-port> vagrant@127.0.0.1 (password
#   vagrant), or with the Vagrant insecure key (scripts/vagrant.sh installs its
#   public half). sshd is enabled by the preseed's late_command.

set -euo pipefail

WORKDIR="${KALI_PACKER_DIR:-$HOME/kali-packer-build}"
BOX=""
IMAGE=""
EXTRACT_ONLY=0
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
usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --box)       BOX="${2:?}"; shift 2 ;;
        --image)     IMAGE="${2:?}"; shift 2 ;;
        --workdir)   WORKDIR="${2:?}"; shift 2 ;;
        --extract-only) EXTRACT_ONLY=1; shift ;;
        --memory)    MEMORY="${2:?}"; shift 2 ;;
        --cpus)      CPUS="${2:?}"; shift 2 ;;
        --display)   DISPLAY_BACK="${2:?}"; shift 2 ;;
        --ssh-port)  SSH_PORT="${2:?}"; shift 2 ;;
        --no-overlay) OVERLAY=0; shift ;;
        --fresh)     FRESH=1; shift ;;
        --snapshot)  SNAPSHOT=1; shift ;;
        --help|-h)   usage 0 ;;
        *)           die "unknown argument: $1  (try --help)" ;;
    esac
done
case "$DISPLAY_BACK" in gtk|sdl|none) ;; *) die "invalid --display '$DISPLAY_BACK' (gtk|sdl|none)" ;; esac
[ "$EXTRACT_ONLY" -eq 1 ] || command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found (sudo apt install -y qemu-system-x86)"

# ── Get a bootable QCOW2: either given, or extracted from the .box ───────────
if [ -z "$IMAGE" ]; then
    if [ -z "$BOX" ]; then
        BOX="$(ls -t "$WORKDIR"/kali-packer/packer_kalirolling_*.box "$WORKDIR"/packer_kalirolling_*.box 2>/dev/null | head -1 || :)"
        [ -n "$BOX" ] || die "no .box found under $WORKDIR — build one first (build-kali-box.sh) or pass --box/--image"
    fi
    [ -r "$BOX" ] || die "box not readable: $BOX"
    command -v tar >/dev/null || die "tar not found"
    IMGDIR="$WORKDIR/images"; mkdir -p "$IMGDIR"
    IMAGE="$IMGDIR/$(basename "${BOX%.box}").qcow2"
    # Re-extract if the box is newer than a previously extracted image.
    if [ ! -e "$IMAGE" ] || [ "$BOX" -nt "$IMAGE" ]; then
        # The disk inside a vagrant/libvirt box is 'box.img'; be tolerant of a
        # differently named single *.img just in case.
        member="$(tar tzf "$BOX" 2>/dev/null | grep -E '(^|/)box\.img$' | head -1 || :)"
        [ -n "$member" ] || member="$(tar tzf "$BOX" 2>/dev/null | grep -E '\.img$' | head -1 || :)"
        [ -n "$member" ] || die "no *.img disk inside $BOX (is it a vagrant box?)"
        log "extracting $member from $(basename "$BOX") → $IMAGE"
        tar xzf "$BOX" -O "$member" > "$IMAGE" || die "extraction failed"
    else
        log "reusing extracted image: $IMAGE"
    fi
fi
[ -r "$IMAGE" ] || die "image not readable: $IMAGE"
log "master image: $IMAGE"
[ "$EXTRACT_ONLY" -eq 1 ] && { log "extract-only: done"; exit 0; }

# ── Decide the disk to boot (master vs overlay) ──────────────────────────────
DISK="$IMAGE"
if [ "$OVERLAY" -eq 1 ]; then
    command -v qemu-img >/dev/null || die "qemu-img not found (sudo apt install -y qemu-utils)"
    RUNDIR="$WORKDIR/run"; mkdir -p "$RUNDIR"
    DISK="$RUNDIR/$(basename "${IMAGE%.qcow2}").overlay.qcow2"
    if [ "$FRESH" -eq 1 ] && [ -e "$DISK" ]; then log "removing overlay (--fresh): $DISK"; rm -f "$DISK"; fi
    if [ -e "$DISK" ] && [ "$IMAGE" -nt "$DISK" ]; then
        log "master newer than overlay — recreating (rebuild detected): $DISK"; rm -f "$DISK"
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
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL="kvm"; else warn "/dev/kvm not accessible — slow TCG emulation"; fi

# ── QEMU. No OVMF: the packer qemu image is grub-pc (BIOS); SeaBIOS boots the
#    MBR. virtio-scsi matches config.pkr.hcl's disk_interface. ────────────────
QEMU=(
    qemu-system-x86_64
    -machine q35 -accel "$ACCEL"
    -m "$MEMORY" -smp "$CPUS"
    -device virtio-scsi-pci,id=scsi0
    -drive file="$DISK",format=qcow2,if=none,id=hd0
    -device scsi-hd,drive=hd0,bus=scsi0.0
    -vga virtio
    -device qemu-xhci -device usb-tablet
    -name "kali-packer:$(basename "$IMAGE")"
)
[ "$ACCEL" = kvm ] && QEMU+=(-cpu host)

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
    log "SSH forward: ssh -p $SSH_PORT vagrant@127.0.0.1  (password: vagrant)"
log "running: ${QEMU[*]}"
exec "${QEMU[@]}"
