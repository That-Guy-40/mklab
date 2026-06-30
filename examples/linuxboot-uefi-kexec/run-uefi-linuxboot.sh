#!/usr/bin/env bash
# run-uefi-linuxboot.sh — TIER B: boot a UKI under genuine OVMF/UEFI (EDK II).
#
# No -kernel/-initrd this time — only a firmware (OVMF pflash) and a FAT ESP. The
# firmware FINDS and launches \EFI\BOOT\BOOTX64.EFI (our UKI) the way a real machine
# boots. The UKI's u-root init then kexecs the 2nd kernel. This is LinuxBoot on
# genuine UEFI — the verifiable companion to the coreboot ROM (Tier A).
#
# Usage: ./run-uefi-linuxboot.sh [kexec|shell] [seconds]
#   kexec (default) — the full handoff (esp-kexec.img)
#   shell           — plain u-root shell under OVMF (esp.img), a firmware-path sanity check
# u-root idles at a shell, so we cap with `timeout`: exit 124 = expected success.
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
MODE="${1:-kexec}"
SECS="${2:-65}"
case "$MODE" in
  kexec) ESP="$WORKDIR/esp-kexec.img" ;;
  shell) ESP="$WORKDIR/esp.img" ;;
  *) echo "usage: $0 [kexec|shell] [seconds]" >&2; exit 2 ;;
esac
[[ -f "$ESP" ]] || { echo "no $ESP — run ./build-uki.sh first" >&2; exit 1; }

LOG="$WORKDIR/tierB-$MODE.log"
VARS="$WORKDIR/vars-$MODE.fd"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS"        # per-run writable NVRAM
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)

echo "==> Tier B boot ($MODE, ${SECS}s cap, accel=$ACCEL) → $LOG"
timeout "$SECS" qemu-system-x86_64 \
  -machine q35,accel="$ACCEL" -cpu host -m 3072 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$ESP",format=raw,if=virtio \
  -display none -serial "file:$LOG" || true

echo "==> proof (genuine UEFI launch + the handoff):"
grep -m1 'BdsDxe: starting'        "$LOG" || true
grep -m1 'EFI stub: Loaded initrd' "$LOG" || true
grep -m1 'EDK II'                  "$LOG" || true
echo -n "    u-root banners: "; grep -c 'Welcome to u-root' "$LOG" || true
grep 'Kernel command line' "$LOG" || true
