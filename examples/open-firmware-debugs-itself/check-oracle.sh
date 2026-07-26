#!/usr/bin/env bash
# check-oracle.sh — cross-check what the firmware BELIEVES against what QEMU KNOWS.
#
# An explorer that is never checked against ground truth is a very confident
# random-number generator. This runs both of the lab's outside checks and gives
# one verdict:
#
#   1. pci-map's `#P` lines vs QMP `query-pci` on the SAME running VM.
#      Must agree on every function, id and class. This check has already earned
#      its keep: it caught two bugs in the lab's own walker (a missed
#      multifunction sweep, and class decoding off by 8 bits).
#
#   2. mem-map's `available` total vs the `-m` the machine was actually given.
#      Expected to DISAGREE, by exactly 32 MB, at every size — the region starts
#      at 32 MB but its size is the full installed RAM instead of
#      (installed - start). The firmware is wrong; the tool reports it faithfully,
#      so this asserts the KNOWN DEFECT and fails if it ever silently changes.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
ROM="${OFW_ROM:-$WORKDIR/openfirmware/cpu/x86/pc/emu/build/emuofw.rom}"
ISO="$WORKDIR/dsl.iso"
CARD="$WORKDIR/fcode-card.rom"
CD='/pci/pci-ide@1,1/ide@1/cdrom@0'

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# shellcheck disable=SC2154  # rc is assigned inside the trap body
trap 'rc=$?; [ $rc -eq 0 ] || [ $rc -eq 1 ] || [ $rc -eq 77 ] || echo "FAIL: check exited early (rc=$rc)"' EXIT

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
[ -f "$ROM" ] || skip "no ROM at $ROM — run the sister lab's ./build-ofw.sh"
[ -f "$ISO" ] || skip "no $ISO — run ./stage-dsl.sh"
ACCEL=$([ -w /dev/kvm ] && echo kvm || echo tcg)
EXTRA=""; [ -f "$CARD" ] && EXTRA="-device e1000,romfile=$CARD"

# ── 1. PCI: inside vs outside, same VM ───────────────────────────────────────
SOCK="$WORKDIR/oracle.sock" QMP="$WORKDIR/oracle-qmp.sock" LOG="$WORKDIR/oracle-pci.log"
rm -f "$SOCK" "$QMP" "$LOG"
# shellcheck disable=SC2086
qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 256 -bios "$ROM" -cdrom "$ISO" $EXTRA \
    -display none -serial "unix:$SOCK,server=on" \
    -qmp "unix:$QMP,server=on,wait=off" -no-reboot >/dev/null 2>&1 &
QPID=$!
python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 200 --echo-gate \
    --expect "ok" --send '\r' --expect "ok" \
    --send "fload $CD:\\\\ofscope.fth\r" --expect "ok" \
    --send 'dev /pci pci-map device-end\r' --expect "#P end" >/dev/null 2>&1
DRC=$?
if [ $DRC -ne 0 ]; then kill "$QPID" 2>/dev/null; fail "could not drive pci-map (rc=$DRC) — see $LOG"; fi

python3 - "$LOG" "$QMP" <<'PY'
import re, sys, json, socket
log, qmp = sys.argv[1], sys.argv[2]
fw = {}
for ln in open(log, errors="replace"):
    m = re.search(r"#P dev=(\w+)\s+fn=(\w+)\s+id=(\w+)\s+class=(\w+)", ln)
    if m:
        # the firmware prints the RAW class register: class_code(24)<<8 | revision(8),
        # so QEMU's 16-bit class/subclass is raw>>16 (not >>8 — learned by getting it wrong)
        fw[(int(m[1],16), int(m[2],16))] = (m[3].lower(), int(m[4],16) >> 16)
s = socket.socket(socket.AF_UNIX); s.connect(qmp)
f = s.makefile("rw"); f.readline()
f.write(json.dumps({"execute":"qmp_capabilities"})+"\n"); f.flush(); f.readline()
f.write(json.dumps({"execute":"query-pci"})+"\n"); f.flush()
qm = {}
for bus in json.loads(f.readline())["return"]:
    for d in bus["devices"]:
        qm[(d["slot"], d["function"])] = (f'{d["id"]["device"]:04x}{d["id"]["vendor"]:04x}',
                                          d["class_info"]["class"])
bad = 0
for k in sorted(set(fw) | set(qm)):
    a, b = fw.get(k), qm.get(k)
    ok = a == b
    bad += 0 if ok else 1
    print(f'  dev={k[0]} fn={k[1]}  {a[0] if a else "-"} class={a[1]:#06x}   '
          f'{"MATCH" if ok else f"DIFFER (qemu={b})"}' if a else
          f'  dev={k[0]} fn={k[1]}  MISSING INSIDE (qemu={b})')
print(f'  {len(fw)} functions inside, {len(qm)} outside')
sys.exit(1 if (bad or not fw) else 0)
PY
PRC=$?
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null    # by PID, never by pattern
[ $PRC -eq 0 ] || fail "pci-map disagrees with QEMU's own query-pci — see $LOG"
note "pci-map agrees with QMP query-pci on every function, id and class"

# ── 2. Memory: the firmware's map vs the machine it is running on ────────────
for MEM in 128 256 512; do
    S="$WORKDIR/oracle-m$MEM.sock" L="$WORKDIR/oracle-m$MEM.log"
    rm -f "$S" "$L"
    qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m "$MEM" -bios "$ROM" -cdrom "$ISO" \
        -display none -serial "unix:$S,server=on" -no-reboot >/dev/null 2>&1 &
    P=$!
    python3 "$REPO/tools/drive-serial-repl.py" "$S" "$L" --timeout 150 --echo-gate \
        --expect "ok" --send '\r' --expect "ok" \
        --send "fload $CD:\\\\ofscope.fth\r" --expect "ok" \
        --send 'mem-map\r' --expect "#M end" >/dev/null 2>&1
    kill "$P" 2>/dev/null; wait "$P" 2>/dev/null
    # the big region: starts at 32 MB, size should be (installed - 32M) but is (installed)
    got=$(grep -o '#M region start=2000000 size=[0-9a-f]*' "$L" | head -1 | sed 's/.*size=//')
    [ -n "$got" ] || fail "mem-map produced no 32 MB-based region at -m $MEM — see $L"
    want=$(printf '%x' $((MEM * 1024 * 1024)))
    [ "$got" = "$want" ] \
        || fail "REGRESSION: at -m $MEM the region size is 0x$got; the known firmware defect gives 0x$want (full installed RAM). If this changed, re-read the finding before trusting it."
    note "-m $MEM: available overruns the end of RAM by exactly 32 MB (the known defect)"
done

pass "oracle: pci-map matches QEMU's view; mem-map still reproduces the 32 MB overrun at 128/256/512"
