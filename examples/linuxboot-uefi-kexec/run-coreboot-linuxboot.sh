#!/usr/bin/env bash
# run-coreboot-linuxboot.sh — TIER A: boot the coreboot ROM under QEMU.
#
# `qemu -bios coreboot.rom` makes coreboot the machine's firmware (no SeaBIOS, no
# OVMF). coreboot runs its bootblock/romstage/ramstage, then jumps to its CBFS
# payload — a Linux kernel whose initramfs init is u-root. The truest LinuxBoot.
#
# u-root idles at a shell, so we cap with `timeout`: exit 124 is the success path.
# Serial → $WORKDIR/tierA.log.
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
ROM="${ROM:-$WORKDIR/coreboot/build/coreboot.rom}"
SECS="${SECS:-45}"
LOG="$WORKDIR/tierA.log"
[ -f "$ROM" ] || { echo "no ROM at $ROM — run ./build-coreboot.sh first" >&2; exit 1; }
ACCEL=$([ -w /dev/kvm ] && echo kvm || echo tcg)

echo "==> Tier A boot (${SECS}s cap, accel=$ACCEL) → $LOG"
timeout "$SECS" qemu-system-x86_64 \
  -M q35 -accel "$ACCEL" -m 2048 \
  -bios "$ROM" \
  -display none -serial "file:$LOG" -no-reboot 2>/dev/null || true

echo "==> proof (real coreboot firmware → Linux payload → u-root):"
sed 's/\x1b\[[0-9;]*m//g; s/\r//g' "$LOG" | grep -m1 'bootblock starting'      || true
sed 's/\x1b\[[0-9;]*m//g; s/\r//g' "$LOG" | grep -m1 'Jumping to boot code'    || true
sed 's/\x1b\[[0-9;]*m//g; s/\r//g' "$LOG" | grep -m1 'Linux version'           || true
sed 's/\x1b\[[0-9;]*m//g; s/\r//g' "$LOG" | grep -m1 'Welcome to u-root'       || true
