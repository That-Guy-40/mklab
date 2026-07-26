#!/usr/bin/env bash
# smoke-dsl.sh [ofdiag|ofscope|fcode|all] — one verdict per vocabulary.
#
# Every check runs headless over the serial socket. Exit: 0 PASS / 1 FAIL / 77 SKIP.
set -u
MODE="${1:-all}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
ROM="${OFW_ROM:-$WORKDIR/openfirmware/cpu/x86/pc/emu/build/emuofw.rom}"
ISO="$WORKDIR/dsl.iso"
CARD="$WORKDIR/fcode-card.rom"
CD='/pci/pci-ide@1,1/ide@1/cdrom@0'
DRIVE="$REPO/tools/drive-serial-repl.py"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# House rule: no silent exits, ever.
trap 'rc=$?; [ $rc -eq 0 ] || [ $rc -eq 1 ] || [ $rc -eq 77 ] || echo "FAIL: smoke exited early (rc=$rc)"' EXIT

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v python3 >/dev/null            || skip "python3 not installed"
[ -f "$ROM" ] || skip "no ROM at $ROM — run the parent lab's ./build-ofw.sh"
[ -f "$ISO" ] || skip "no $ISO — run ./stage-dsl.sh"

ACCEL=$([ -w /dev/kvm ] && echo kvm || echo tcg)
QPID=""
cleanup() { [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; }   # by PID, never by pattern
trap 'cleanup' INT TERM

# boot_and_drive <logname> <extra-qemu-args> <drive-args...>
boot_and_drive() {
    local log="$WORKDIR/$1.log" sock="$WORKDIR/$1.sock" extra="$2"; shift 2
    rm -f "$log" "$sock"
    # -m 256 is LOAD-BEARING: OFW anchors its PCI window at ~0x10000000
    # regardless of RAM, so at -m 512 a card's BARs land inside DRAM and the
    # device is silently shadowed. Do not "helpfully" raise this.
    # shellcheck disable=SC2086
    qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 256 -bios "$ROM" -cdrom "$ISO" \
        $extra -display none -serial "unix:$sock,server=on" -no-reboot >/dev/null 2>&1 &
    QPID=$!
    python3 "$DRIVE" "$sock" "$log" --timeout 200 --echo-gate "$@"
    local rc=$?
    kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""
    LOG="$log"
    [ $rc -eq 125 ] && fail "serial console dropped input even with --echo-gate — see $log"
    grep -q "Open Firmware" "$log" 2>/dev/null || fail "no Open Firmware banner — see $log"
    return $rc
}

smoke_ofdiag() {
    boot_and_drive smoke-ofdiag "" \
        --expect "ok" --send '\r' --expect "ok" \
        --send "fload $CD:\\\\ofdiag.fth\r" --expect "ofdiag loaded" \
        --send '" nosuchalias" diag-open\r'   --expect "ok" \
        --send '" /pci/nosuch@9" diag-open\r' --expect "ok" \
        --send '" /pci/ethernet" diag-open\r' --expect "ok" \
        --send "\" $CD\" diag-open\r"         --expect "ok" \
        --send 'why-no-boot\r'                --expect "ok" \
        --send 'trace-boot\r'                 --expect "tracing ON" \
        --send "load $CD:\\\\ofdiag.fth\r"    --expect "ok" \
        --send 'untrace\r'                    --expect "tracing OFF" \
        --send "load $CD:\\\\ofdiag.fth\r"    --expect "ok"
    # The fault matrix: four DISTINCT diagnoses. A diagnostic that always says
    # the same thing is the failure mode this guards (v0 really did that).
    local n
    for n in 0 1 2 3; do
        grep -q "OFDIAG-$n:" "$LOG" || fail "REGRESSION: fault class OFDIAG-$n never reported — the diagnosis ladder stopped discriminating (see $LOG)"
    done
    note "four distinct fault classes reported (OFDIAG-0/1/2/3)"
    grep -q "OFDIAG: boot-device =" "$LOG" || fail "why-no-boot did not report boot-device"
    note "why-no-boot walked the boot-device list"
    # Tracer: #T lines while ON, silence after untrace.
    awk '/tracing ON/,/tracing OFF/' "$LOG" | grep -q '#T open' \
        || fail "REGRESSION: trace-boot installed no tracer (#T lines absent while tracing was ON)"
    awk '/tracing OFF/,0' "$LOG" | grep -q '#T ' \
        && fail "REGRESSION: untrace left a tracer installed (#T lines after tracing OFF)"
    note "tracer emits #T milestones, and untrace restores the hooks cleanly"
    pass "ofdiag: 4 distinct fault diagnoses + boot tracer installed and cleanly removed"
}

smoke_ofscope() {
    boot_and_drive smoke-ofscope "" \
        --expect "ok" --send '\r' --expect "ok" \
        --send "fload $CD:\\\\ofscope.fth\r" --expect "ok" \
        --send 'dev /pci pci-map device-end\r' --expect "#P end" \
        --send 'mem-map\r' --expect "#M end" \
        --send 'load-base h# 400 region-snap\r' --expect "ok" \
        --send 'region-diff\r' --expect "total-diffs" \
        --send "load $CD:\\\\ofscope.fth\r" --expect "ok" \
        --send 'region-diff\r' --expect "total-diffs"
    grep -q 'id=12378086' "$LOG" || fail "pci-map did not find the i440FX host bridge (8086:1237) — see $LOG"
    grep -q 'fn=1'       "$LOG" || fail "REGRESSION: pci-map missed multifunction devices (no fn=1 line) — see $LOG"
    note "pci-map walked config space including multifunction devices"
    grep -q '#M total='  "$LOG" || fail "mem-map produced no total — see $LOG"
    note "mem-map decoded /memory@0 available regions"
    # region-diff needs BOTH controls: a no-op must be clean, a load must not be.
    grep -q 'total-diffs=0 ' "$LOG" || fail "REGRESSION: region-diff reported changes after a no-op (false positive) — see $LOG"
    grep -v 'total-diffs=0 ' "$LOG" | grep -q 'total-diffs=' \
        || fail "REGRESSION: region-diff saw no change after a load (false negative) — see $LOG"
    note "region-diff: clean on a no-op, detects a load (both controls)"
    pass "ofscope: pci-map + mem-map + region-diff verified, both region-diff controls hold"
}

smoke_fcode() {
    [ -f "$CARD" ] || skip "no $CARD — run ./build-fcode-rom.sh"
    boot_and_drive smoke-fcode "-device e1000,romfile=$CARD" \
        --expect "ok" --send '\r' --expect "ok" \
        --send 'dev /pci ls\r' --expect "ok" \
        --send 'dev /pci/fcode-card .properties device-end\r' --expect "ok"
    grep -q 'fcode-card' "$LOG" \
        || fail "the card's FCode never ran: no fcode-card node. If you changed -m, note OFW anchors its PCI window at ~0x10000000 and >256M RAM shadows the ROM BAR (see $LOG)"
    grep -q 'FCODE-FROM-CARD-RAN' "$LOG" \
        || fail "fcode-card node exists but the marker property is missing — see $LOG"
    grep -q 'fcode-rom-offset' "$LOG" \
        || fail "no fcode-rom-offset property — the firmware did not record finding the ROM image"
    note "the firmware probed, validated and byte-loaded the card's FCode"
    pass "fcode: a PCI card's bytecode driver ran on the bare machine and named its own node"
}

case "$MODE" in
    ofdiag)  smoke_ofdiag ;;
    ofscope) smoke_ofscope ;;
    fcode)   smoke_fcode ;;
    all)
        rc=0
        for m in ofdiag ofscope fcode; do
            printf '\n=== %s ===\n' "$m"
            bash "$0" "$m"; r=$?
            [ $r -eq 1 ] && rc=1
        done
        printf '\n'
        [ $rc -eq 0 ] && echo "PASS: all vocabularies verified" || echo "FAIL: at least one vocabulary failed"
        exit $rc ;;
    *) fail "usage: $0 [ofdiag|ofscope|fcode|all]" ;;
esac
