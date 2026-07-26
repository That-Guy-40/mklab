#!/usr/bin/env bash
# showcase-diagnose-a-broken-boot.sh — the finale, unattended.
#
# Every boot of this firmware ends "Can't open boot device" and tells you
# nothing else. The lab's vocabulary turns that into a specific, per-entry
# diagnosis, and then repairs it from the firmware's own prompt:
#
#   1. why-no-boot   -> boot-device is the LIST "disk net", and each entry
#                       fails for a DIFFERENT reason (OFDIAG-2 vs OFDIAG-3)
#   2. devalias      -> repoint the BROKEN ALIAS at a device that exists
#   3. why-no-boot   -> OFDIAG-0: opens OK
#
# The repair is a devalias, not a setenv, for two reasons: it is what the
# diagnosis actually points at (the `disk` alias resolves to a 2015-era ATA path
# QEMU 8.2 does not have), and `setenv` fails on the emu flavor anyway --
# "Out of NVRAM environment space", the demo build has no working NVRAM.
#
# One verdict. Exit: 0 PASS / 1 FAIL / 77 SKIP.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
ROM="${OFW_ROM:-$WORKDIR/openfirmware/cpu/x86/pc/emu/build/emuofw.rom}"
ISO="$WORKDIR/dsl.iso"
CD='/pci/pci-ide@1,1/ide@1/cdrom@0'

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# shellcheck disable=SC2154  # rc is assigned inside the trap body
trap 'rc=$?; [ $rc -eq 0 ] || [ $rc -eq 1 ] || [ $rc -eq 77 ] || echo "FAIL: showcase exited early (rc=$rc)"' EXIT

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
[ -f "$ROM" ] || skip "no ROM at $ROM — run the parent lab's ./build-ofw.sh"
[ -f "$ISO" ] || skip "no $ISO — run ./stage-dsl.sh"

LOG="$WORKDIR/showcase-diagnose.log" SOCK="$WORKDIR/showcase-diagnose.sock"
rm -f "$LOG" "$SOCK"
ACCEL=$([ -w /dev/kvm ] && echo kvm || echo tcg)
note "booting, diagnosing the default boot failure, repairing it at the prompt"

qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 256 -bios "$ROM" -cdrom "$ISO" \
    -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
QPID=$!
python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 200 --echo-gate \
    --expect "ok" --send '\r' --expect "ok" \
    --send "fload $CD:\\\\ofdiag.fth\r" --expect "ofdiag loaded" \
    --send 'why-no-boot\r'              --expect "ok" \
    --send "devalias disk $CD\r"        --expect "ok" \
    --send 'why-no-boot\r'              --expect "ok"
RC=$?
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null   # by PID, never by pattern
[ $RC -eq 125 ] && fail "serial console dropped input even with --echo-gate — see $LOG"
grep -q "Open Firmware" "$LOG" || fail "no Open Firmware banner — see $LOG"

# Act 1: the diagnosis must be PER-ENTRY and the two entries must differ.
BEFORE="$(sed -n '/^ok why-no-boot/,/^ok devalias/p' "$LOG")"
echo "$BEFORE" | grep -q 'boot-device = disk net' || fail "why-no-boot did not read the default boot-device list — see $LOG"
echo "$BEFORE" | grep -q 'OFDIAG-2:' || fail "the 'disk' entry was not diagnosed as a missing node — see $LOG"
echo "$BEFORE" | grep -q 'OFDIAG-3:' || fail "the 'net' entry was not diagnosed as an open failure — see $LOG"
note "diagnosed both boot-device entries, with DIFFERENT causes (OFDIAG-2 and OFDIAG-3)"

# Act 2: after the repair, the same word must report the device opens.
AFTER="$(sed -n '/^ok devalias/,$p' "$LOG")"
echo "$AFTER" | grep -q 'OFDIAG-0:' \
    || fail "REGRESSION: after repointing the 'disk' devalias at a real device, why-no-boot still did not report OFDIAG-0 (opens OK) — see $LOG"
note "repointed the broken 'disk' alias at the prompt; the same word now reports OFDIAG-0"

pass "diagnosed a boot failure the firmware only called \"Can't open boot device\", repaired the broken alias live, and verified the repair"
