#!/usr/bin/env bash
# run-graphical.sh — boot a debos-built Debian image in a WINDOWED QEMU desktop.
#
# The image debian-vm.yaml produces is UEFI + systemd-boot (GPT/ESP), so — unlike
# kali-vm-builder's grub-pc/BIOS image — this boots it with OVMF firmware (not
# SeaBIOS), a virtio disk + virtio GPU, a gtk window, and an SSH port-forward.
#
# By default it runs a per-image OVERLAY (copy-on-write) so the freshly built
# master stays pristine; your changes persist in the overlay across runs.
#
# Usage:
#   examples/debian-vm-builder/run-graphical.sh [options]
#
# Options:
#   --image PATH    Image to boot. Default: <workdir>/debian-vm.qcow2
#   --workdir DIR   Where the image lives (default: $DEBIAN_VM_DIR or ~/debian-vm-build)
#   --memory SIZE   Guest RAM (default: 2G)
#   --cpus N        vCPUs (default: 2)
#   --display BACK  gtk (default) | sdl | none  (none + --serial = headless)
#   --serial        Also attach a serial console to the terminal (the image has
#                   console=ttyS0); pair with --display none for a headless boot.
#   --ssh-port P    Host port forwarded to guest :22 (default: 2222; 0 = none)
#   --no-overlay    Boot the master image directly (mutates it). Off by default.
#   --fresh         Recreate the overlay from the master before booting.
#   --snapshot      Ephemeral: discard all disk writes on shutdown (-snapshot).
#   --help          show this help and exit
#
# Login: debian / debian  (or root / lab).  SSH: ssh -p <ssh-port> debian@127.0.0.1

set -euo pipefail

WORKDIR="${DEBIAN_VM_DIR:-$HOME/debian-vm-build}"
IMAGE="" MEMORY="2G" CPUS="2" DISPLAY_BACK="gtk" SERIAL=0 SSH_PORT="2222"
OVERLAY=1 FRESH=0 SNAPSHOT=0

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || :; }
log()  { _c 36; printf '[run]'   >&2; _c 0; printf ' %s\n' "$*" >&2; }
warn() { _c 33; printf '[run] WARNING:' >&2; _c 0; printf ' %s\n' "$*" >&2; }
die()  { _c 31; printf '[run] ERROR:'   >&2; _c 0; printf ' %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --image)      IMAGE="${2:?}"; shift 2 ;;
        --workdir)    WORKDIR="${2:?}"; shift 2 ;;
        --memory)     MEMORY="${2:?}"; shift 2 ;;
        --cpus)       CPUS="${2:?}"; shift 2 ;;
        --display)    DISPLAY_BACK="${2:?}"; shift 2 ;;
        --serial)     SERIAL=1; shift ;;
        --ssh-port)   SSH_PORT="${2:?}"; shift 2 ;;
        --no-overlay) OVERLAY=0; shift ;;
        --fresh)      FRESH=1; shift ;;
        --snapshot)   SNAPSHOT=1; shift ;;
        --help|-h)    usage 0 ;;
        *)            die "unknown argument: $1  (try --help)" ;;
    esac
done
case "$DISPLAY_BACK" in gtk|sdl|none) ;; *) die "invalid --display '$DISPLAY_BACK'" ;; esac
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found (sudo apt install -y qemu-system-x86)"

# ── Locate the image ─────────────────────────────────────────────────────────
[ -n "$IMAGE" ] || IMAGE="$WORKDIR/debian-vm.qcow2"
[ -r "$IMAGE" ] || die "image not readable: $IMAGE  (build one with build-debian-vm.sh, or pass --image)"
log "master image: $IMAGE"

# ── Locate OVMF (UEFI firmware) — the image is systemd-boot, needs UEFI ──────
OVMF_CODE="" OVMF_VARS=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF_CODE.fd; do
    [ -r "$c" ] && { OVMF_CODE="$c"; break; }
done
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
         /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/qemu/OVMF_VARS.fd; do
    [ -r "$v" ] && { OVMF_VARS="$v"; break; }
done
COMBINED=""
if [ -z "$OVMF_CODE" ]; then
    for f in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd; do [ -r "$f" ] && { COMBINED="$f"; break; }; done
    [ -n "$COMBINED" ] || die "no OVMF firmware found — install it: sudo apt install -y ovmf"
fi

# ── Disk to boot (master vs copy-on-write overlay) ───────────────────────────
DISK="$IMAGE"
if [ "$OVERLAY" -eq 1 ]; then
    command -v qemu-img >/dev/null || die "qemu-img not found (sudo apt install -y qemu-utils)"
    RUNDIR="$WORKDIR/run"; mkdir -p "$RUNDIR"
    DISK="$RUNDIR/$(basename "${IMAGE%.qcow2}").overlay.qcow2"
    { [ "$FRESH" -eq 1 ] || { [ -e "$DISK" ] && [ "$IMAGE" -nt "$DISK" ]; }; } && rm -f "$DISK"
    if [ ! -e "$DISK" ]; then
        log "creating overlay (master stays pristine): $DISK"
        qemu-img create -f qcow2 -F qcow2 -b "$IMAGE" "$DISK" >/dev/null
    else log "reusing overlay: $DISK"; fi
fi

ACCEL="tcg"
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL="kvm"; else warn "/dev/kvm not accessible — slow TCG emulation"; fi

QEMU=(qemu-system-x86_64 -machine q35 -accel "$ACCEL" -m "$MEMORY" -smp "$CPUS"
      -drive file="$DISK",format=qcow2,if=virtio -vga virtio
      -device qemu-xhci -device usb-tablet -name "debian-vm:$(basename "$IMAGE")")
[ "$ACCEL" = kvm ] && QEMU+=(-cpu host)

# UEFI firmware: pflash (CODE + a writable per-run copy of VARS) if we have the
# split build; else the combined -bios OVMF.fd.
if [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]; then
    VARS_COPY="${WORKDIR}/run/OVMF_VARS.$(basename "$IMAGE").fd"
    mkdir -p "$(dirname "$VARS_COPY")"
    [ -e "$VARS_COPY" ] || cp "$OVMF_VARS" "$VARS_COPY"
    QEMU+=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
           -drive "if=pflash,format=raw,unit=1,file=$VARS_COPY")
    log "UEFI: $OVMF_CODE + $VARS_COPY"
elif [ -n "$OVMF_CODE" ]; then
    QEMU+=(-bios "$OVMF_CODE"); log "UEFI: $OVMF_CODE (no VARS — removable-media boot path)"
else
    QEMU+=(-bios "$COMBINED"); log "UEFI: $COMBINED"
fi

if [ "$SSH_PORT" = "0" ] || [ -z "$SSH_PORT" ]; then QEMU+=(-nic user,model=virtio-net-pci)
else QEMU+=(-nic "user,model=virtio-net-pci,hostfwd=tcp::${SSH_PORT}-:22"); fi

case "$DISPLAY_BACK" in gtk) QEMU+=(-display gtk);; sdl) QEMU+=(-display sdl);; none) QEMU+=(-display none);; esac
[ "$SERIAL" -eq 1 ] && QEMU+=(-serial mon:stdio)
[ "$SNAPSHOT" -eq 1 ] && QEMU+=(-snapshot)

log "booting (accel=$ACCEL, display=$DISPLAY_BACK, disk=$DISK)"
[ "$SSH_PORT" != "0" ] && [ -n "$SSH_PORT" ] && log "SSH: ssh -p $SSH_PORT debian@127.0.0.1  (password: debian)"
exec "${QEMU[@]}"
