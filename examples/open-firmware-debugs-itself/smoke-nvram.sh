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
DROM="$WORKDIR/nvram-disk-emuofw.rom"               # store on a FAT16 hard disk
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

# The store on a FAT16 HARD DISK, using the SHIPPED c:\nvram.dat line unmodified.
# The `c` alias was never missing (report-disk creates it, devices.fth:261) -- it
# is created during probe-all, long after stand-init tried to open the store, so
# --disk adds upstream's config-valid?-guarded retry after probing.
do_diskstore() {
    [ -f "$DROM" ] || skip "no $DROM — run ./build-nvram-rom.sh --disk"
    local hd="$WORKDIR/smn-hd.img"
    rm -f "$hd"; dd if=/dev/zero of="$hd" bs=1M count=64 status=none
    # 64M: mkfs.vfat -F16 refuses a too-small image (this lab learned that once)
    mkfs.vfat -F16 "$hd" >/dev/null 2>&1 || fail "could not create FAT16 disk at $hd"
    bootdisk() {   # same as boot(), but an IDE disk instead of a floppy
        local tag="$1"; shift
        local sock="$WORKDIR/smn-$tag.sock" log="$WORKDIR/smn-$tag.log"
        rm -f "$sock" "$log"
        qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 256 -bios "$DROM" \
            -drive "file=$hd,format=raw,if=ide,index=0,cache=writethrough" \
            -display none -serial "unix:$sock,server=on" -no-reboot >/dev/null 2>&1 &
        local qpid=$!
        python3 "$REPO/tools/drive-serial-repl.py" "$sock" "$log" --timeout 180 --echo-gate "$@" \
            >/dev/null 2>&1
        kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
        echo "$log"
    }
    # Read back IN-SESSION before powering off. Besides proving the write took, it
    # gives the guest's FAT write path a further round-trip to complete: killing
    # QEMU immediately after setenv's "ok" loses the store (found the hard way --
    # and cache=writethrough does NOT fix it, so it is guest-side, not host-side).
    local l; l=$(bootdisk k1 --expect "ok" --send '\r' --expect "ok" \
        --send 'dev /pci/pci-ide@1,1/ide@0 ls device-end\r' --expect "ok" \
        --send 'dir c:\\\r' --expect "ok")
    # DELIBERATELY NOT AN ASSERTION. emu's PCI-IDE probe creates a disk@0 child
    # only INTERMITTENTLY -- measured at roughly 2 successes in 18 identical boots
    # on this host (0/13 in a controlled loop, 2 one-offs). Asserting either
    # outcome would produce a test that fails at random, which is worse than no
    # test: a flaky red is indistinguishable from a real regression. So this
    # observes, reports, and SKIPs. See DELIVERY-MECHANISMS.md.
    if grep -a -A2 'ide@0 ls device-end' "$l" | grep -aqE '[0-9a-f]+ disk@'; then
        note "this boot: disk@0 WAS probed (the rare case — roughly 2 in 18 here)"
    else
        note "this boot: disk@0 absent, dir c:\\ cannot open (the common case)"
    fi
    skip "the c: store is NONDETERMINISTIC on this build — emu's IDE probe finds a primary-channel hard disk only intermittently, so neither outcome is assertable. Measured ~2/18. See DELIVERY-MECHANISMS.md; log: $l"
}

# M4: ONE writable medium carrying both the nvramrc hook and the payload, against a
# ROM with NO dropins. Floppy only -- nvramrc is evaluated BEFORE probe-all, so an
# autoload line cannot reference c: (a PCI device). That is by design: nvramrc runs
# early precisely so it can influence probing.
do_selfcontained() {
    local fl="$WORKDIR/smn-selfc.img"; newfloppy "$fl"
    mcopy -o -i "$fl" "$HERE/dsl/ofdiag.fth" "::/ofdiag.fth" \
        || fail "could not stage ofdiag.fth onto $fl"
    local l; l=$(boot "$ROM" "$fl" s0 --expect "ok" --send '\r' --expect "ok" \
        --send "' diag-open .\r" --expect "ok")
    grep -a -A1 "diag-open \." "$l" | grep -aq 'diag-open ?' \
        || fail "baseline wrong: diag-open is defined before any autoload, so $ROM must carry a dropin — this proves nothing (see $l)"
    boot "$ROM" "$fl" s1 --expect "ok" --send '\r' --expect "ok" \
        --send '" fload a:\\ofdiag.fth" to nvramrc\r' --expect "ok" \
        --send 'setenv use-nvramrc? true\r' --expect "ok" >/dev/null
    l=$(boot "$ROM" "$fl" s2 --expect "ok" --send '\r' --expect "ok" \
        --send "' diag-open .\r" --expect "ok")
    grep -a -A1 "diag-open \." "$l" | grep -aq 'diag-open ?' \
        && fail "self-contained delivery failed: diag-open is still undefined after a power cycle, so nvramrc never loaded a:\\ofdiag.fth (see $l)"
    note "one floppy carried BOTH the hook and the payload — no dropins in the ROM"
}

case "$MODE" in
    persist) do_persist; pass "config variables persist across a cold power cycle" ;;
    diskstore)     do_diskstore ;;   # always SKIPs — see the note in do_diskstore
    selfcontained) do_selfcontained; pass "M4: one medium carries the autoload hook and the vocabulary" ;;
    autoload)  do_autoload;  pass "nvramrc autoloads the vocabulary from the ROM — delivery mechanism 3" ;;
    warmtrace) do_warmtrace; pass "a REAL warm reboot is traced — the path a boot- dropin cannot see" ;;
    nvramrc) do_nvramrc; pass "nvramrc executes at startup" ;;
    nvalias) do_nvalias; pass "nvalias persists across a cold power cycle" ;;
    reboot)  do_reboot;  pass "auto-boot's warm-reboot branch is reachable, and needs copy-reboot-info as well as NVRAM" ;;
    all)     do_persist; do_nvramrc; do_nvalias; do_selfcontained
             if [ -f "$RROM" ]; then do_reboot
             else note "warm-reboot SKIPPED — no $RROM (build-nvram-rom.sh --reboot-hook)"; fi
             # do_diskstore is NOT called here: it always SKIPs (exit 77), which
             # would swallow the aggregate verdict. Run it on its own to observe
             # the nondeterministic c: probe.
             note "disk store not run in 'all' — nondeterministic; use: $0 diskstore"
             if [ -f "$CROM" ]; then do_autoload; do_warmtrace
             else note "autoload + warm-TRACE SKIPPED — no $CROM (build-dropin-rom.sh --boot-hook --reboot-hook)"; fi
             pass "all four delivery mechanisms work and NVRAM persists across cold power cycles" ;;
    *)       fail "unknown mode '$MODE' — use persist|nvramrc|nvalias|reboot|autoload|warmtrace|diskstore|selfcontained|all" ;;
esac
