#!/usr/bin/env bash
# run-ofw-qemu.sh [emu|coreboot] — boot Open Firmware interactively, ok prompt
# on THIS terminal (serial console; Ctrl-A X quits QEMU).
#
#   emu       → -bios emuofw.rom        (QEMU-direct flavor)   [default]
#   coreboot  → -bios coreboot.rom      (coreboot → OFW payload chain)
#
# Things to type once you're at the `ok` prompt (see RUNBOOK.md for the tour):
#   3 4 + .          banner arithmetic — the machine answers back
#   dev /  ls        walk the live device tree
#   devalias         (its own pager will stop mid-list — firmware ships a more)
#   words            the whole dictionary
# NOTE the prompt's default number base is HEX: d# 40 2 + . prints 2a.
set -euo pipefail
FLAVOR="${1:-emu}"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
case "$FLAVOR" in
  emu)      ROM="$WORKDIR/openfirmware/cpu/x86/pc/emu/build/emuofw.rom" ;;
  coreboot) ROM="$CB/build-ofw/coreboot.rom" ;;
  *) echo "usage: $0 [emu|coreboot]" >&2; exit 1 ;;
esac
[[ -f "$ROM" ]] || { echo "no ROM at $ROM — run ./build-ofw.sh (and ./build-coreboot-ofw.sh for coreboot)" >&2; exit 1; }
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)

# Optional disk: a FAT16 image at $WORKDIR/disk.img appears as the legacy IDE
# primary master (dir /isa/ide@i1f0/disk@0:\ on coreboot, or attach media on emu).
DISK=()
[[ -f "$WORKDIR/disk.img" ]] && DISK=(-drive "file=$WORKDIR/disk.img,format=raw,if=ide,index=0")

exec qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 1024 \
  -bios "$ROM" "${DISK[@]}" \
  -display none -serial mon:stdio -no-reboot
