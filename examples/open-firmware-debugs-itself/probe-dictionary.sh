#!/usr/bin/env bash
# spike0-word-inventory.sh [emu|coreboot] — SPIKE 0 for open-firmware-debugs-itself.
#
# Question: the audit found see/debug/.calls/map?/detokenize/... in the OFW
# SOURCE TREE. Are they in THIS BUILD'S DICTIONARY, and callable at the prompt?
# A word in forth/lib/ is not a word in the ROM — x86 configs routinely drop the
# decompiler and debugger to save space. The whole lab premise rests on this.
#
# Method: `' <word> .` per candidate (tick LOOKS UP without EXECUTING — we must
# not actually fire `debug` or `random-test`). Sync on the `ok` prompt, which
# returns either way, so a missing word cannot stall the drive. The verdict is
# parsed from the log afterward, not asserted in the expect script.
# This also avoids `words`, whose built-in pager would hang a scripted drive.
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
# shellcheck disable=SC2154  # rc is assigned inside the trap body
trap 'rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: spike exited early (rc=$rc)"' EXIT

case "$FLAVOR" in
  emu)      ROM="$WORKDIR/openfirmware/cpu/x86/pc/emu/build/emuofw.rom" ;;
  coreboot) ROM="$CB/build-ofw/coreboot.rom" ;;
  *) fail "usage: $0 [emu|coreboot]" ;;
esac
command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v python3 >/dev/null            || skip "python3 not installed"
[[ -f "$ROM" ]] || skip "no ROM at $ROM"

# The candidates, grouped by which vocabulary of the planned DSL needs them.
# (A=ofdiag boot forensics, B=ofscope memory/devices, C=fcode forensics,
#  0=baseline words the parent lab already proved.)
WORDS=(
  # --- 0: baseline, must be present or the harness itself is suspect
  words dev devalias dump
  # --- A: boot forensics
  see patch debug resume stepping ctrace showstack .calls
  # --- B: memory + devices
  'map?' config-l@ config-b@ mem-claim random-test
  # --- C: FCode forensics
  detokenize load-fcode byte-load
  # --- breakpoints (A, stretch)
  set-breakpoint show-breakpoints
  # --- delivery mechanism: without fload there is no DSL
  fload
)

SOCK="$WORKDIR/spike0-$FLAVOR.sock" LOG="$WORKDIR/spike0-$FLAVOR.log"
rm -f "$SOCK" "$LOG"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)
note "booting $FLAVOR ROM (accel=$ACCEL); probing ${#WORDS[@]} words -> $LOG"

qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 512 -bios "$ROM" \
  -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
QPID=$!

# Build the drive script: settle at the prompt, then one probe per word.
# A unique BEGIN/END marker per word makes the log unambiguously parseable even
# if the firmware's error text is chatty.
args=( --expect "ok" --send '\r' --expect "ok" )
for w in "${WORDS[@]}"; do
  args+=( --send "' $w .\r" --expect "ok" )
done

python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" \
  --timeout 300 --echo-gate "${args[@]}"
RC=$?
kill "$QPID" 2>/dev/null   # by PID, never by pattern (house rule)
wait "$QPID" 2>/dev/null

[[ -s "$LOG" ]] || fail "no serial output at all — see $LOG"
grep -q "Open Firmware" "$LOG" || fail "no Open Firmware banner (rc=$RC) — see $LOG"
[[ $RC -eq 125 ]] && fail "console dropped input even with --echo-gate — see $LOG"

# Parse: for each probe, the echoed command line is followed by either a hex
# address (word FOUND) or the firmware's undefined-word complaint (MISSING).
python3 - "$LOG" "$FLAVOR" "${WORDS[@]}" <<'PY'
import re, sys
log, flavor, words = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(log, errors="replace").read()
found, missing = [], []
for w in words:
    # locate the echo of this exact probe, then read what came after it
    m = re.search(r"'\s+" + re.escape(w) + r"\s+\.", text)
    if not m:
        missing.append((w, "probe never echoed"));  continue
    after = text[m.end(): m.end() + 200]
    # a bare hex number on the reply line == a valid execution token.
    # Split on the PROMPT, not on the bare string "ok" — `detokenize` contains
    # "ok" as a substring, and naive splitting truncated its reply to "det",
    # reaching the right verdict by luck. Anchor to the line-leading prompt.
    reply = re.split(r"[\r\n]+ok\b", after)[0]
    if re.search(r"\b[0-9a-f]{4,8}\b", reply, re.I) and "?" not in reply:
        found.append(w)
    else:
        missing.append((w, " ".join(reply.split())[:60] or "<no reply>"))
print(f"--- {flavor}: {len(found)} found / {len(missing)} missing ---")
print("FOUND  : " + " ".join(found) if found else "FOUND  : (none)")
for w, why in missing:
    print(f"MISSING: {w:<18} [{why}]")
open(log + ".inventory", "w").write(
    "found=" + " ".join(found) + "\nmissing=" + " ".join(w for w, _ in missing) + "\n")
sys.exit(0 if found else 1)
PY
PRC=$?

if [[ $RC -ne 0 ]]; then
  note "driver rc=$RC (some probes may not have completed) — log: $LOG"
fi
[[ $PRC -eq 0 ]] || fail "no candidate word resolved — the probe idiom itself is wrong, see $LOG"
pass "spike 0 ($FLAVOR): dictionary probed, inventory at $LOG.inventory"
