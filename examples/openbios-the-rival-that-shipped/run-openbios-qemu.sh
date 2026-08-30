#!/usr/bin/env bash
# run-openbios-qemu.sh [multiboot|coreboot|ppc|amd64] — boot OpenBIOS
# interactively, `0 >` prompt on THIS terminal (Ctrl-A X quits QEMU).
#
#   multiboot → qemu -kernel openbios.multiboot -initrd openbios-x86.dict [default]
#   coreboot  → qemu -bios coreboot.rom   (coreboot → OpenBIOS payload chain)
#   ppc       → qemu-system-ppc -bios our openbios-qemu.elf  (the swap-in)
#   amd64     → the 64-BIT firmware, in long mode, with the NVRAM store on an
#               NVDIMM at 0x100000000 — an address a 32-bit firmware cannot
#               even form. See X86-64-FEASIBILITY.md.
#
# Things to type at the `0 >` prompt (RUNBOOK.md is the guided tour):
#   3 4 + .          the machine answers back (prompt shows stack DEPTH)
#   dev / ls         walk the live device tree
#   words            the dictionary
#
# ...and on `amd64`, the things the port bought:
#   -1 u.            ffffffffffffffff — a 64-bit cell (x86 prints ffffffff)
#   test-ctx-switch .            5a — a client context ran and switched back
#   0 200000000 !    a NAMED page fault with CR2 and a register dump — and the
#                    prompt COMES BACK. Recovery re-enters the interpreter on a
#                    fresh stack; the inherited arch/x86 shape never did.
#   setenv boot-file HELLO-64
#   " /nvram" " update-nvram" execute-device-method .        -1 = written
#                    ...then Ctrl-A X, run this again, and `printenv boot-file`
#                    still says HELLO-64. The image persists between runs.
#
# TYPE SLOWLY. The firmware's serial console has no flow control, so a PASTED
# line loses characters silently — measured: `3 4 + .` and `-1 u.` fed at pipe
# speed arrived as ` u.` and answered `Stack Underflow`. Hand-typing is fine.
# The lab build sets auto-boot?=false on x86, so you always land at the
# prompt; boot Linux by hand with (≤80 chars per line — the input buffer!):
#   boot /ide@1/cdrom@0:\vmlinuz console=ttyS0 initrd=/ide@1/cdrom@0:\uroot.img
set -euo pipefail
usage() {
    cat <<'USAGE'
run-openbios-qemu.sh [FLAVOR]   boot OpenBIOS interactively; 0 > on this terminal

FLAVOR:
  multiboot   32-bit, qemu -kernel openbios.multiboot (the default)
  coreboot    the same firmware as a coreboot payload, via -bios
  ppc         our own openbios-qemu.elf on qemu-system-ppc
  amd64       the 64-bit port, with an NVDIMM at 0x100000000 for /nvram

Quit with Ctrl-A X. The prompt is `0 > ` -- that leading digit is the STACK
DEPTH, not a version. Default number base is HEX.

TYPE SLOWLY: the serial console has no flow control and silently drops
characters that arrive faster than the firmware consumes them. Pasting a long
line loses its tail with no error.

Env:
  OPENBIOS_WORKDIR   where the clone and images live (default ~/openbios-lab)
  OPENBIOS_NO_PMEM=1 drop the amd64 NVDIMM; OPENBIOS_PMEM_IMG points it elsewhere
  OPENBIOS_CDROM     attach this ISO instead of $OPENBIOS_WORKDIR/boot.iso
  OPENBIOS_DISPLAY   gtk or sdl opens a window, so the VGA text buffer is
                     visible (default none). MANUAL-TYPE-LAYER.md needs it.
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

FLAVOR="${1:-multiboot}"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)

# Optional media: showcase ISO (vmlinuz + uroot.img) if present.
#
# OPENBIOS_CDROM overrides it, which is what MANUAL-TYPE-LAYER.md uses to hand
# the firmware dsl/struct.fth and an ELF to parse. Overriding rather than
# replacing $WORKDIR/boot.iso on purpose: the showcase ISO is what the Linux
# boot needs, and clobbering it to run a Forth walkthrough would break the
# other half of the lab silently.
CDROM=()
CDIMG="${OPENBIOS_CDROM:-$WORKDIR/boot.iso}"
if [[ -n "${OPENBIOS_CDROM:-}" && ! -f "$CDIMG" ]]; then
    echo "OPENBIOS_CDROM=$CDIMG does not exist" >&2; exit 1
fi
[[ -f "$CDIMG" ]] && CDROM=(-cdrom "$CDIMG")

# -display none is right for a serial-only session and WRONG the moment you
# want to see the VGA text buffer you just wrote to. OPENBIOS_DISPLAY=gtk (or
# sdl) opens a window; the prompt stays on this terminal either way, because
# -serial mon:stdio is unchanged. `ppc` ignores it -- that arm is -nographic
# -vga none because OpenBIOS-ppc only reads the muxed stdio.
DISPLAY_ARGS=(-display "${OPENBIOS_DISPLAY:-none}")

case "$FLAVOR" in
  multiboot)
    MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    [[ -f "$MB" ]] || { echo "no image at $MB — run ./build-openbios.sh x86" >&2; exit 1; }
    exec qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 \
      -kernel "$MB" -initrd "$WORKDIR/openbios/obj-x86/openbios-x86.dict" \
      "${CDROM[@]}" "${DISPLAY_ARGS[@]}" -serial mon:stdio -no-reboot ;;
  coreboot)
    ROM="$CB/build-openbios/coreboot.rom"
    [[ -f "$ROM" ]] || { echo "no ROM at $ROM — run ./build-coreboot-openbios.sh" >&2; exit 1; }
    exec qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -bios "$ROM" \
      "${CDROM[@]}" "${DISPLAY_ARGS[@]}" -serial mon:stdio -no-reboot ;;
  ppc)
    ELF="$WORKDIR/openbios/obj-ppc/openbios-qemu.elf"
    [[ -f "$ELF" ]] || { echo "no image at $ELF — run ./build-openbios.sh ppc" >&2; exit 1; }
    # -nographic -vga none: OpenBIOS-ppc console input only works on the
    # muxed stdio, not a bare -serial socket (see MANUAL_TESTING notes).
    exec qemu-system-ppc -bios "$ELF" -nographic -vga none ;;
  amd64)
    MB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    DICT="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    [[ -f "$MB" && -f "$DICT" ]] || { echo "no amd64 image at $MB — run ./build-openbios.sh amd64" >&2; exit 1; }
    # THE STORE IS ATTACHED BY DEFAULT AND KEPT, because the interesting thing
    # about P3 is what survives quitting QEMU. Created on first use; the first
    # boot on a fresh image prints "nvram error detected, zapping pram", which
    # is it formatting an empty store, once.
    #
    # OPENBIOS_NO_PMEM=1 boots without it — and that is the CONTROL, not just
    # an off switch: the firmware then reports "no memory at 0x100000000" and
    # falls back to a volatile buffer, which is how you tell a real backing
    # from a firmware that would have claimed success either way.
    PMEM=()
    if [[ -z "${OPENBIOS_NO_PMEM:-}" ]]; then
      NV="${OPENBIOS_PMEM_IMG:-$WORKDIR/pmem-nvram.img}"
      [[ -f "$NV" ]] || truncate -s 64M "$NV"
      # shellcheck disable=SC2054  # the commas are INSIDE one QEMU option string,
      # not element separators; splitting on them would hand qemu bad options.
      PMEM=(-object "memory-backend-file,id=nv,share=on,mem-path=$NV,size=64M"
            -device nvdimm,id=nv1,memdev=nv)
    fi
    # `boot` does NOT work here yet even with the ISO attached: arch/amd64's
    # linux_load.c is still a stub (Spike 3). The cdrom is there so /ide@1
    # enumerates something real.
    exec qemu-system-x86_64 -M "pc,accel=$ACCEL,nvdimm=on" -m 512,slots=2,maxmem=2G \
      -kernel "$MB" -initrd "$DICT" "${PMEM[@]}" \
      "${CDROM[@]}" "${DISPLAY_ARGS[@]}" -serial mon:stdio -no-reboot ;;
  *) echo "usage: $0 [multiboot|coreboot|ppc|amd64]" >&2; exit 1 ;;
esac
