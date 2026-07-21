#!/usr/bin/env bash
# showcase-rival-boots-linux.sh [multiboot|coreboot] — the finale, unattended:
# OpenBIOS boots Linux to a u-root shell, typed at the 0 > prompt over serial.
#
# Chain (multiboot):  qemu -kernel openbios.multiboot → 0 > prompt →
#   boot /ide@1/cdrom@0:\vmlinuz console=ttyS0 initrd=/ide@1/cdrom@0:\uroot.img
#   → Found Linux 6.3 → Loading kernel/initrd → "Welcome to u-root!"
# Chain (coreboot):   qemu -bios coreboot.rom → same prompt, same command.
#
# One line does what took the OFW lab five (POC-4 tells the whole story):
#   - `initrd=` is parsed by the FIRMWARE (linux_load.c) — no hand-staging
#   - the zero page at 0x90000 is built by C code — no `fix-zp` pokes
#   - the memory map is real e820 / forwarded coreboot tables — no memmap=
# ...because this rival's loader could be PATCHED instead of worked around.
#
# Kernel + initrd default to the linuxboot lab's cached artifacts.
# Exit: 0 PASS / 1 FAIL / 77 SKIP.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
KERNEL="${KERNEL:-$HOME/linuxboot-lab/payload-bzImage}"
INITRD="${INITRD:-$HOME/linuxboot-lab/uroot.cpio}"
FLAVOR="${1:-multiboot}"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
trap 'rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: test exited early (rc=$rc)"' EXIT

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v python3 >/dev/null            || skip "python3 not installed"
command -v genisoimage >/dev/null        || skip "genisoimage not installed"
[[ -f "$KERNEL" ]] || skip "no kernel at $KERNEL (set KERNEL=; an x86_64 bzImage with serial console)"
[[ -f "$INITRD" ]] || skip "no initrd at $INITRD (set INITRD=; a cpio the kernel can unpack)"

case "$FLAVOR" in
  multiboot)
    MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    [[ -f "$MB" ]] || skip "no image at $MB — run ./build-openbios.sh x86 first"
    QEMU=(qemu-system-x86_64 -m 512 -kernel "$MB"
          -initrd "$WORKDIR/openbios/obj-x86/openbios.dict") ;;
  coreboot)
    ROM="$CB/build-openbios/coreboot.rom"
    [[ -f "$ROM" ]] || skip "no ROM at $ROM — run ./build-coreboot-openbios.sh first"
    QEMU=(qemu-system-x86_64 -m 512 -bios "$ROM") ;;
  *) echo "usage: $0 [multiboot|coreboot]" >&2; exit 1 ;;
esac

ISO="$WORKDIR/boot.iso" SOCK="$WORKDIR/showcase.sock" LOG="$WORKDIR/showcase-$FLAVOR.log"
STAGE="$WORKDIR/iso-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"; rm -f "$ISO" "$SOCK" "$LOG"
cp "$KERNEL" "$STAGE/VMLINUZ"; cp "$INITRD" "$STAGE/UROOT.IMG"
genisoimage -quiet -o "$ISO" -V OBISO -r -J "$STAGE"   # -r lowercases: \vmlinuz

ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)
note "booting $FLAVOR (accel=$ACCEL), one boot line at the prompt → $LOG"

"${QEMU[@]}" -M "pc,accel=$ACCEL" -cdrom "$ISO" \
  -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
QPID=$!

# NOTE the whole boot line is 78 chars — the firmware's input buffer eats
# anything past ~80 (found the hard way: ".img" fell off — see POC-4).
python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 240 \
  --expect "0 > " \
  --send 'boot /ide@1/cdrom@0:\\vmlinuz console=ttyS0 initrd=/ide@1/cdrom@0:\\uroot.img\r' \
  --expect "Loading kernel... ok" --expect "Loading initrd... ok" \
  --expect "Linux version" --expect "Welcome to u-root"
RC=$?
kill "$QPID" 2>/dev/null   # by PID, never by pattern

if [[ $RC -eq 0 ]]; then
  pass "the rival boots Linux: OpenBIOS ($FLAVOR) loaded kernel+initrd and reached u-root"
else
  grep -aq "Linux version" "$LOG" 2>/dev/null && \
    fail "kernel started but no u-root banner (rc=$RC) — see $LOG" || \
    fail "did not reach the kernel (rc=$RC) — see $LOG"
fi
