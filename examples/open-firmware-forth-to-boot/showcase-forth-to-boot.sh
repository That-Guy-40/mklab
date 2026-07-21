#!/usr/bin/env bash
# showcase-forth-to-boot.sh — the finale, end-to-end and unattended:
# Open Firmware boots Linux to a u-root shell, every step typed at the ok
# prompt over serial by the repo's REPL driver.
#
# Chain: emuofw.rom → ok prompt → stage initrd HIGH by hand (Forth) →
#        boot bzImage from ISO9660 → Linux 6.3 → "Welcome to u-root!"
#
# The three prompt-level moves are the lab's lesson in miniature (POC-2 Act 5):
#   load <cd>:\uroot.img                     OFW reads the cpio (byte-perfect)
#   loaded dup to /ramdisk h# 3d000000 swap move   place it at 976 MB, out of
#                                            the kernel stub's 16 MB work zone
#   h# 3d000000 to ramdisk-adr               memory-limit's own early-exit path
#                                            blesses our placement
#   boot <cd>:\vmlinuz console=ttyS0 memmap=1023M@1M   the e801-era zero page
#                                            under-reports RAM; memmap= is the
#                                            kernel's own escape hatch
#
# Kernel + initrd default to the linuxboot lab's cached artifacts.
# Exit: 0 PASS / 1 FAIL / 77 SKIP.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
KERNEL="${KERNEL:-$HOME/linuxboot-lab/urootcfg-bzImage}"
INITRD="${INITRD:-$HOME/linuxboot-lab/uroot.cpio}"
ROM="$WORKDIR/openfirmware/cpu/x86/pc/emu/build/emuofw.rom"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
trap 'rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: test exited early (rc=$rc)"' EXIT

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v python3 >/dev/null            || skip "python3 not installed"
command -v genisoimage >/dev/null        || skip "genisoimage not installed"
[[ -f "$ROM" ]]    || skip "no ROM at $ROM — run ./build-ofw.sh emu first"
[[ -f "$KERNEL" ]] || skip "no kernel at $KERNEL (set KERNEL=; an x86_64 bzImage with serial console)"
[[ -f "$INITRD" ]] || skip "no initrd at $INITRD (set INITRD=; a cpio the kernel can unpack)"

SIZEHEX=$(printf '%x' "$(stat -c %s "$INITRD")")
ISO="$WORKDIR/forth-to-boot.iso" SOCK="$WORKDIR/showcase.sock" LOG="$WORKDIR/showcase.log"
STAGE="$WORKDIR/iso-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"; rm -f "$ISO" "$SOCK" "$LOG"
cp "$KERNEL" "$STAGE/VMLINUZ"; cp "$INITRD" "$STAGE/UROOT.IMG"
genisoimage -quiet -o "$ISO" -V OFWISO -r -J "$STAGE"

ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)
CD='/pci/pci-ide@1,1/ide@1/cdrom@0'   # the ATAPI path (the 2015 ATA disk probe
                                      # dislikes QEMU 8.2; the packet side works)
note "booting emuofw.rom (accel=$ACCEL), initrd=0x$SIZEHEX bytes → $LOG"

qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 1024 -bios "$ROM" -cdrom "$ISO" \
  -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
QPID=$!

python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 200 \
  --expect "Type any key to interrupt automatic startup" --send '\r' \
  --expect "ok" --send "load $CD:\\\\uroot.img\r" \
  --expect "ok" --send 'loaded dup to /ramdisk h# 3d000000 swap move\r' \
  --expect "ok" --send 'h# 3d000000 to ramdisk-adr\r' \
  --expect "ok" --send "boot $CD:\\\\vmlinuz console=ttyS0 memmap=1023M@1M\r" \
  --expect "Linux version" --expect "Welcome to u-root"
RC=$?
kill "$QPID" 2>/dev/null   # by PID, never by pattern

if [[ $RC -eq 0 ]]; then
  pass "Forth to boot: OFW hand-staged the initrd and booted Linux to u-root"
else
  grep -aq "Linux version" "$LOG" 2>/dev/null && \
    fail "kernel started but no u-root banner (rc=$RC) — see $LOG" || \
    fail "did not reach the kernel (rc=$RC) — see $LOG"
fi
