#!/usr/bin/env bash
# run-linuxboot.sh — TIER C: the fast inner loop. QEMU loads the kernel + u-root
# directly with -kernel/-initrd (no firmware), u-root's init kexecs a 2nd kernel.
#
# This is the *mechanic* in isolation — quickest to iterate on the boot policy.
# Tier B (run-uefi-linuxboot.sh) does the same handoff but behind genuine UEFI.
#
# u-root idles at a shell after the handoff, so we cap the run with `timeout`:
# exit 124 is the EXPECTED success path. Serial → $WORKDIR/tierC.log.
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
KERNEL="${KERNEL:-$WORKDIR/vmlinuz}"
SECS="${SECS:-45}"
INITRD="$WORKDIR/initramfs-stage1.cpio"
LOG="$WORKDIR/tierC.log"

[[ -f "$INITRD" ]] || { echo "no $INITRD — run ./build-uroot.sh first" >&2; exit 1; }
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)

echo "==> Tier C boot (${SECS}s cap, accel=$ACCEL) → $LOG"
timeout "$SECS" qemu-system-x86_64 \
  -name linuxboot-tierC -machine q35 -accel "$ACCEL" -m 2048 \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append "console=ttyS0 LINUXBOOT_STAGE1=boot" \
  -display none -serial "file:$LOG" -monitor none -no-reboot || true

echo "==> proof (expect 2 u-root banners + STAGE1→STAGE2 cmdlines):"
echo -n "    u-root banners: "; grep -c 'Welcome to u-root' "$LOG" || true
grep 'Kernel command line' "$LOG" || true
grep -o 'LINUXBOOT_STAGE[12]=[a-z]*' "$LOG" | sort -u || true
