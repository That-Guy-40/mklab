#!/usr/bin/env bash
# run-openbios-qemu.sh [multiboot|coreboot|ppc] — boot OpenBIOS interactively,
# `0 >` prompt on THIS terminal (Ctrl-A X quits QEMU).
#
#   multiboot → qemu -kernel openbios.multiboot -initrd openbios.dict [default]
#   coreboot  → qemu -bios coreboot.rom   (coreboot → OpenBIOS payload chain)
#   ppc       → qemu-system-ppc -bios our openbios-qemu.elf  (the swap-in)
#
# Things to type at the `0 >` prompt (RUNBOOK.md is the guided tour):
#   3 4 + .          the machine answers back (prompt shows stack DEPTH)
#   dev / ls         walk the live device tree
#   words            the dictionary
# The lab build sets auto-boot?=false on x86, so you always land at the
# prompt; boot Linux by hand with (≤80 chars per line — the input buffer!):
#   boot /ide@1/cdrom@0:\vmlinuz console=ttyS0 initrd=/ide@1/cdrom@0:\uroot.img
set -euo pipefail
FLAVOR="${1:-multiboot}"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)

# Optional media: showcase ISO (vmlinuz + uroot.img) if present.
CDROM=()
[[ -f "$WORKDIR/boot.iso" ]] && CDROM=(-cdrom "$WORKDIR/boot.iso")

case "$FLAVOR" in
  multiboot)
    MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    [[ -f "$MB" ]] || { echo "no image at $MB — run ./build-openbios.sh x86" >&2; exit 1; }
    exec qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 \
      -kernel "$MB" -initrd "$WORKDIR/openbios/obj-x86/openbios.dict" \
      "${CDROM[@]}" -display none -serial mon:stdio -no-reboot ;;
  coreboot)
    ROM="$CB/build-openbios/coreboot.rom"
    [[ -f "$ROM" ]] || { echo "no ROM at $ROM — run ./build-coreboot-openbios.sh" >&2; exit 1; }
    exec qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -bios "$ROM" \
      "${CDROM[@]}" -display none -serial mon:stdio -no-reboot ;;
  ppc)
    ELF="$WORKDIR/openbios/obj-ppc/openbios-qemu.elf"
    [[ -f "$ELF" ]] || { echo "no image at $ELF — run ./build-openbios.sh ppc" >&2; exit 1; }
    # -nographic -vga none: OpenBIOS-ppc console input only works on the
    # muxed stdio, not a bare -serial socket (see MANUAL_TESTING notes).
    exec qemu-system-ppc -bios "$ELF" -nographic -vga none ;;
  *) echo "usage: $0 [multiboot|coreboot|ppc]" >&2; exit 1 ;;
esac
