#!/usr/bin/env bash
# smoke-ofw.sh [emu|coreboot] — one-verdict smoke: boot the ROM headless, drive
# the ok prompt over the serial socket, and prove the firmware answers back.
#
# Checks (all over serial, deterministically, via tools/drive-serial-repl.py):
#   1. the OFW banner + an `ok` prompt appear;
#   2. `3 4 + .` evaluates to 7 (base-agnostic on purpose — the prompt is hex);
#   3. `dev / ls` walks the live device tree (the `openprom` node proves it).
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP (missing ROM, qemu, or python3).
set -u
FLAVOR="${1:-emu}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# Safety net: no silent exits, ever (house rule).
trap 'rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: test exited early (rc=$rc)"' EXIT

case "$FLAVOR" in
  emu)      ROM="$WORKDIR/openfirmware/cpu/x86/pc/emu/build/emuofw.rom" ;;
  coreboot) ROM="$CB/build-ofw/coreboot.rom" ;;
  *) fail "usage: $0 [emu|coreboot]" ;;
esac
command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v python3 >/dev/null            || skip "python3 not installed"
[[ -f "$ROM" ]] || skip "no ROM at $ROM — run ./build-ofw.sh first"

SOCK="$WORKDIR/smoke-ofw.sock" LOG="$WORKDIR/smoke-ofw-$FLAVOR.log"
rm -f "$SOCK" "$LOG"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)
note "booting $FLAVOR ROM (accel=$ACCEL), driving the ok prompt → $LOG"

# server=on with wait left ON: the guest must not boot before the driver
# connects, or the banner is emitted into the void (POC-2 pitfall).
qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 512 -bios "$ROM" \
  -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
QPID=$!

# emu autoboots (fails to netboot, ~10 s) then prompts; coreboot prompts at
# once. Waiting for the first `ok` + a settle newline handles both — the
# settle also absorbs the coreboot flavor's eaten-first-keystrokes quirk.
python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 90 \
  --expect "ok" --send '\r' \
  --expect "ok" --send '3 4 + .\r' --expect "7 " \
  --send 'dev / ls\r' --expect "openprom"
RC=$?
kill "$QPID" 2>/dev/null   # by PID, never by pattern

if [[ $RC -eq 0 ]]; then
  pass "OFW ($FLAVOR) answered 7 at the ok prompt and listed the device tree"
else
  grep -q "Open Firmware" "$LOG" 2>/dev/null && \
    fail "OFW ($FLAVOR) bannered but the REPL drive did not complete (rc=$RC) — see $LOG" || \
    fail "no Open Firmware banner on serial (rc=$RC) — see $LOG"
fi
