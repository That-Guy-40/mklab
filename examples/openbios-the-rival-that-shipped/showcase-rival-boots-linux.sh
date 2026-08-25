#!/usr/bin/env bash
# showcase-rival-boots-linux.sh [multiboot|coreboot|amd64] — the finale, unattended:
# OpenBIOS boots Linux to a u-root shell, typed at the 0 > prompt over serial.
#
# Chain (multiboot):  qemu -kernel openbios.multiboot → 0 > prompt →
#   boot /ide@1/cdrom@0:\vmlinuz console=ttyS0 initrd=/ide@1/cdrom@0:\uroot.img
#   → Found Linux 6.3 → Loading kernel/initrd → "Welcome to u-root!"
# Chain (coreboot):   qemu -bios coreboot.rom → same prompt, same command.
# Chain (amd64):      the same command, typed at a 64-bit firmware's prompt.
#   Spike 3. Same ISO, same kernel, same one line — the point is that the
#   success signature did NOT have to change to move to long mode. What
#   changed is underneath: arch/amd64 does not relocate itself, so it is
#   sitting at the 1 MiB a bzImage runs at. The kernel is therefore staged
#   above the firmware and a position-independent stub in low memory copies
#   it down over the firmware and jumps. See arch/amd64/switch.S.
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
# shellcheck disable=SC2154  # rc IS assigned, by the `rc=$?` at the start of this same
# single-quoted trap body; shellcheck analyses the string without carrying the assignment
# into the uses that follow it.
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
          -initrd "$WORKDIR/openbios/obj-x86/openbios-x86.dict") ;;
  coreboot)
    ROM="$CB/build-openbios/coreboot.rom"
    [[ -f "$ROM" ]] || skip "no ROM at $ROM — run ./build-coreboot-openbios.sh first"
    QEMU=(qemu-system-x86_64 -m 512 -bios "$ROM") ;;
  amd64)
    MB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    DICT="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    [[ -f "$MB" && -f "$DICT" ]] \
      || skip "no amd64 image at $MB — run ./build-openbios.sh amd64 first"
    # No NVDIMM here, unlike run-openbios-qemu.sh: /nvram is P3's subject, not
    # this one, and a volatile store is one less thing between the prompt and
    # the kernel. The firmware says so on the way past.
    QEMU=(qemu-system-x86_64 -m 512 -kernel "$MB" -initrd "$DICT") ;;
  *) echo "usage: $0 [multiboot|coreboot|amd64]" >&2; exit 1 ;;
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

# NOTE the boot line is close to the firmware's ~80-char input buffer, which
# silently eats the tail past it (found the hard way: ".img" fell off — see
# POC-4). Deliberately NOT restating the length as an integer here: it was
# written as "78" in three places and measured 75, and a number nobody
# re-counts is the thing that goes stale.
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
  # "Linux version" AS A SUBSTRING IS A LIAR, and it lied on the first control
  # that ever ran against it (2026-08-25, the amd64 handoff with its CR3 switch
  # removed): the FIRMWARE prints "Found Linux version 6.3.0 ..." as soon as it
  # recognises the image, long before anything is jumped to. So the old
  # `grep -aq "Linux version"` reported "kernel started but no u-root banner"
  # about a machine that triple-faulted inside the loader. It is the shape this
  # repo keeps re-finding: a match on a string that is always present.
  #
  # The kernel's own banner STARTS a line; the firmware's is prefixed. Anchor.
  CLEAN="$(tr -d '\r' < "$LOG" 2>/dev/null)"
  if grep -qE '^Linux version ' <<<"$CLEAN"; then
    fail "the kernel started and did not reach u-root (rc=$RC) — see $LOG"
  elif grep -qE 'Jumping to entry point|Moving kernel' <<<"$CLEAN"; then
    # Specific to the 64-bit handoff, and the most confusing outcome there: a
    # kernel that is running correctly can be COMPLETELY SILENT, because a
    # panic before console_init goes to the printk ring buffer and never to a
    # console. Do not read this as "the kernel never ran".
    fail "the firmware handed off and the kernel said nothing (rc=$RC) — this is silence, not proof of a dead kernel: read the panic out of the printk ring buffer (QMP pmemsave + strings) before assuming the handoff is at fault; see $LOG and X86-64-FEASIBILITY.md § Spike 3"
  else
    fail "did not reach the kernel (rc=$RC) — see $LOG"
  fi
fi
