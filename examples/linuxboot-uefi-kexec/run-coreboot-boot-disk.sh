#!/usr/bin/env bash
# run-coreboot-boot-disk.sh — TIER A FINALE: boot a real OS off a disk via LinuxBoot.
#
# coreboot ROM (firmware) -> Linux + u-root -> [type `boot`] -> u-root's localboot
# parses the disk's grub.cfg, picks the OS kernel, and kexecs it -> the installed
# OS boots. This is the real LinuxBoot production lifecycle (firmware boots Linux,
# which boots the installed OS off disk), not a synthetic 2nd kernel.
#
# Needs: a driver-enabled ROM (build-coreboot.sh adds virtio/AHCI/fs/partition) and
# an OS disk (fetch-os-disk.sh). We attach the disk on a COW overlay (base stays
# pristine) and drive `boot` over a serial socket with drive-boot.py.
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
ROM="${ROM:-$WORKDIR/coreboot/build/coreboot.rom}"
DISK="${DISK:-$WORKDIR/debian-os.qcow2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$ROM" ]]  || { echo "no ROM at $ROM — run ./build-coreboot.sh first" >&2; exit 1; }
[[ -f "$DISK" ]] || { echo "no OS disk at $DISK — run ./fetch-os-disk.sh first" >&2; exit 1; }
command -v python3 >/dev/null || { echo "need python3 to drive the console" >&2; exit 1; }

OVL="$WORKDIR/os-overlay.qcow2"; SOCK="$WORKDIR/ttyA.sock"; LOG="$WORKDIR/tierA-boot.log"
qemu-img create -f qcow2 -b "$DISK" -F qcow2 -o force_overwrite "$OVL" >/dev/null
rm -f "$SOCK"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)

echo "==> launch coreboot ROM + OS disk (serial socket); driver types \`boot\` → $LOG"
qemu-system-x86_64 -M q35 -accel "$ACCEL" -m 3072 \
  -bios "$ROM" \
  -drive file="$OVL",format=qcow2,if=virtio \
  -chardev socket,id=s0,path="$SOCK",server=on,wait=on -serial chardev:s0 \
  -display none -no-reboot >/dev/null 2>&1 &
QPID=$!
python3 "$HERE/drive-boot.py" "$SOCK" "$LOG" || true
kill "$QPID" 2>/dev/null || true           # stop the VM by PID (never by pattern)

echo "==> proof — two kernels (coreboot-built → the disk's OS) + real userspace:"
sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r/\n/g' "$LOG" | grep -E "Linux version 6\.3\.0|Welcome to u-root|Debian GNU/Linux, with Linux|Linux version 6\.1|Welcome to Debian|localhost ttyS0" | sed 's/(.*//' | head
