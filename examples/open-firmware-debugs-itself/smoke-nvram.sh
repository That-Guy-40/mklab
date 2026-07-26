#!/usr/bin/env bash
# smoke-nvram.sh [persist|nvramrc|nvalias|reboot|all] — prove Open Firmware's
# configuration-variable store works on x86 once pseudo-nvram is switched on.
#
# EVERY check is a COLD POWER CYCLE. Writing a variable and reading it back in the
# same session proves nothing about persistence — it only proves the cache works.
# So each mode boots twice against the same floppy, killing QEMU in between.
#
# Needs ./build-nvram-rom.sh first (and --reboot-hook for the `reboot` mode).
# Exit: 0 PASS / 1 FAIL / 77 SKIP.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
ROM="$WORKDIR/nvram-emuofw.rom"
RROM="$WORKDIR/nvram-reboot-emuofw.rom"
CROM="$WORKDIR/autotrace-nvram-reboot-emuofw.rom"   # the COMBINED ROM
MODE="${1:-all}"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# shellcheck disable=SC2154
trap 'rc=$?; [ $rc -eq 0 ] || [ $rc -eq 1 ] || [ $rc -eq 77 ] || echo "FAIL: smoke exited early (rc=$rc)"' EXIT

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v mkfs.vfat          >/dev/null || skip "mkfs.vfat not installed (dosfstools)"
[ -f "$ROM" ] || skip "no $ROM — run ./build-nvram-rom.sh"
ACCEL=$([ -w /dev/kvm ] && echo kvm || echo tcg)

newfloppy() {  # $1 = path
    rm -f "$1"
    mkfs.vfat -F 12 -C "$1" 1440 >/dev/null 2>&1 || fail "could not create FAT12 floppy at $1"
}

boot() {   # $1=rom $2=floppy $3=tag $4...=repl args ; echoes the log path
    local rom="$1" fl="$2" tag="$3"; shift 3
    local sock="$WORKDIR/smn-$tag.sock" log="$WORKDIR/smn-$tag.log"
    rm -f "$sock" "$log"
    qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 256 -bios "$rom" \
        -fda "$fl" -display none -serial "unix:$sock,server=on" -no-reboot \
        >/dev/null 2>&1 &
    local qpid=$!
    python3 "$REPO/tools/drive-serial-repl.py" "$sock" "$log" --timeout 180 --echo-gate "$@" \
        >/dev/null 2>&1
    kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null      # by PID, never by pattern
    echo "$log"
}

do_persist() {
    local fl="$WORKDIR/smn-persist.img"; newfloppy "$fl"
    boot "$ROM" "$fl" p1 --expect "ok" --send '\r' --expect "ok" \
        --send 'setenv use-nvramrc? true\r' --expect "ok" >/dev/null
    local l; l=$(boot "$ROM" "$fl" p2 --expect "ok" --send '\r' --expect "ok" \
        --send 'printenv use-nvramrc?\r' --expect "ok")
    grep -aq 'Unimplemented package interface' "$l" \
        && fail "REGRESSION: no NVRAM store is bound — setenv still hits no-proc (see $l)"
    grep -aq 'Out of NVRAM environment space' "$l" \
        && fail "REGRESSION: cv-area is still a zero-length region (see $l)"
    grep -a -A1 'printenv use-nvramrc?' "$l" | grep -aq 'use-nvramrc? *= *true' \
        || fail "config variable did NOT survive a cold power cycle: use-nvramrc? is not true after reboot (see $l)"
    note "use-nvramrc?=true survived a cold power cycle"
}

do_nvramrc() {
    local fl="$WORKDIR/smn-nvramrc.img"; newfloppy "$fl"
    boot "$ROM" "$fl" n1 --expect "ok" --send '\r' --expect "ok" \
        --send '" .( SMOKE-NVRAMRC ) cr" to nvramrc\r' --expect "ok" \
        --send 'setenv use-nvramrc? true\r' --expect "ok" >/dev/null
    local l; l=$(boot "$ROM" "$fl" n2 --expect "ok" --send '\r' --expect "ok")
    grep -aq 'SMOKE-NVRAMRC' "$l" \
        || fail "nvramrc did not execute at startup — the marker never appeared in the boot stream (see $l)"
    note "nvramrc executed at startup with nothing typed"
}

do_nvalias() {
    local fl="$WORKDIR/smn-nvalias.img"; newfloppy "$fl"
    boot "$ROM" "$fl" a1 --expect "ok" --send '\r' --expect "ok" \
        --send 'nvalias labdisk /isa/fdc/disk@0\r' --expect "ok" >/dev/null
    local l; l=$(boot "$ROM" "$fl" a2 --expect "ok" --send '\r' --expect "ok" \
        --send 'devalias\r' --expect "ok")
    grep -aq 'labdisk' "$l" \
        || fail "nvalias did not persist — labdisk is absent from the devalias table after a power cycle (see $l)"
    note "nvalias labdisk survived a cold power cycle"
}

# The warm-reboot branch needs BOTH the NVRAM store AND copy-reboot-info in emu's
# startup. Checking the control arm is the whole point: it is what proves the two
# causes are independent, rather than letting "we enabled NVRAM and reboot started
# working" stand as a plausible but wrong story.
do_reboot() {
    [ -f "$RROM" ] || skip "no $RROM — run ./build-nvram-rom.sh --reboot-hook"
    local fl cl
    # control arm: NVRAM only -> must NOT take the reboot branch
    fl="$WORKDIR/smn-rb-ctl.img"; newfloppy "$fl"
    boot "$ROM" "$fl" c1 --expect "ok" --send '\r' --expect "ok" \
        --send 'setenv reboot-command .( SMOKE-WARM ) cr\r' --expect "ok" >/dev/null
    cl=$(boot "$ROM" "$fl" c2 --expect "ok" --send '\r' --expect "ok")
    grep -aq 'SMOKE-WARM' "$cl" \
        && fail "control arm took the warm-reboot branch without copy-reboot-info — the two causes are NOT independent, re-read NVRAM-ON-X86.md before trusting it (see $cl)"
    note "control: NVRAM alone does NOT reach the warm-reboot branch (reboot? stays false)"
    # test arm: NVRAM + copy-reboot-info -> must take it
    fl="$WORKDIR/smn-rb.img"; newfloppy "$fl"
    boot "$RROM" "$fl" r1 --expect "ok" --send '\r' --expect "ok" \
        --send 'setenv reboot-command .( SMOKE-WARM ) cr\r' --expect "ok" >/dev/null
    local l; l=$(boot "$RROM" "$fl" r2 --expect "ok" --send '\r' --expect "ok")
    grep -aq 'SMOKE-WARM' "$l" \
        || fail "warm-reboot branch not taken: reboot-command persisted but auto-boot never evaluated it (see $l)"
    grep -aq 'Boot device:' "$l" \
        && fail "auto-boot ran do-auto-boot anyway — the reboot? early exit at bootparm.fth:330 did not happen (see $l)"
    note "warm-reboot branch taken: command evaluated, do-auto-boot skipped"
}

# Delivery mechanism 3: nvramrc as an AUTOLOAD hook. NVRAM is 4096 bytes
# (h# 1000 constant /nvram, filenv.fth:9) and ofdiag.fth is 4959, so nvramrc
# cannot CARRY a vocabulary -- but it carries the one line that loads it. This
# proves M3 bootstrapping M2: no media, no rebuild, nothing typed.
do_autoload() {
    [ -f "$CROM" ] || skip "no $CROM — run ./build-dropin-rom.sh --boot-hook --reboot-hook"
    local fl="$WORKDIR/smn-autoload.img"; newfloppy "$fl"
    local l; l=$(boot "$CROM" "$fl" g0 --expect "ok" --send '\r' --expect "ok" \
        --send "' diag-open .\r" --expect "ok")
    grep -a -A1 "diag-open \." "$l" | grep -aq 'diag-open ?' \
        || fail "baseline wrong: diag-open is already defined before any autoload, so this proves nothing (see $l)"
    boot "$CROM" "$fl" g1 --expect "ok" --send '\r' --expect "ok" \
        --send '" fload /dropin-fs:\\ofdiag.fth" to nvramrc\r' --expect "ok" \
        --send 'setenv use-nvramrc? true\r' --expect "ok" >/dev/null
    l=$(boot "$CROM" "$fl" g2 --expect "ok" --send '\r' --expect "ok" \
        --send "' diag-open .\r" --expect "ok")
    grep -a -A1 "diag-open \." "$l" | grep -aq 'diag-open ?' \
        && fail "nvramrc autoload did not run: diag-open is still undefined after a power cycle (see $l)"
    note "nvramrc autoloaded the vocabulary from /dropin-fs — no media, nothing typed"
}

# The scenario banner- was CHOSEN for, and which nothing has ever observed: on the
# warm-reboot path auto-boot early-exits BEFORE `" boot-" do-drop-in`, so a
# boot--hooked tracer would emit nothing at all. banner- arms from banner(), which
# startup calls on every path. Needs the COMBINED ROM (tracer + NVRAM + reboot).
do_warmtrace() {
    [ -f "$CROM" ] || skip "no $CROM — run ./build-dropin-rom.sh --boot-hook --reboot-hook"
    local fl="$WORKDIR/smn-warmtrace.img"; newfloppy "$fl"
    boot "$CROM" "$fl" w1 --expect "ok" --send '\r' --expect "ok" \
        --send 'setenv reboot-command boot\r' --expect "ok" >/dev/null
    local l; l=$(boot "$CROM" "$fl" w2 --expect "ok" --send '\r' --expect "ok")
    grep -aq '#T autotrace armed' "$l" \
        || fail "the banner- tracer did not arm on the warm-reboot path (see $l)"
    grep -aq 'Rebooting with command' "$l" \
        || fail "not a warm reboot: auto-boot never took the reboot? branch (see $l)"
    grep -aq '#T open' "$l" \
        || fail "REGRESSION: warm reboot was NOT traced — no #T open lines, which is exactly what a boot--hooked tracer would produce (see $l)"
    grep -aq 'Type any key' "$l" \
        && fail "the normal autoboot ran too — do-auto-boot was not skipped, so this is not the warm-reboot path (see $l)"
    note "REAL warm reboot traced: tracer armed, #T open emitted, countdown skipped"
}

case "$MODE" in
    persist) do_persist; pass "config variables persist across a cold power cycle" ;;
    autoload)  do_autoload;  pass "nvramrc autoloads the vocabulary from the ROM — delivery mechanism 3" ;;
    warmtrace) do_warmtrace; pass "a REAL warm reboot is traced — the path a boot- dropin cannot see" ;;
    nvramrc) do_nvramrc; pass "nvramrc executes at startup" ;;
    nvalias) do_nvalias; pass "nvalias persists across a cold power cycle" ;;
    reboot)  do_reboot;  pass "auto-boot's warm-reboot branch is reachable, and needs copy-reboot-info as well as NVRAM" ;;
    all)     do_persist; do_nvramrc; do_nvalias
             if [ -f "$RROM" ]; then do_reboot
             else note "warm-reboot SKIPPED — no $RROM (build-nvram-rom.sh --reboot-hook)"; fi
             if [ -f "$CROM" ]; then do_autoload; do_warmtrace
             else note "autoload + warm-TRACE SKIPPED — no $CROM (build-dropin-rom.sh --boot-hook --reboot-hook)"; fi
             pass "NVRAM works on x86: variables persist, nvramrc fires, nvalias persists$([ -f "$RROM" ] && echo ', warm-reboot branch reachable')$([ -f "$CROM" ] && echo ', nvramrc autoloads, real warm reboot traced')" ;;
    *)       fail "unknown mode '$MODE' — use persist|nvramrc|nvalias|reboot|autoload|warmtrace|all" ;;
esac
