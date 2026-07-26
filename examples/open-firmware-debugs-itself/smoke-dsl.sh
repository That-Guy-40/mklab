#!/usr/bin/env bash
# smoke-dsl.sh [ofdiag|ofscope|fcode|all] [emu|coreboot] — one verdict per vocabulary.
#
# Every check runs headless over the serial socket. Exit: 0 PASS / 1 FAIL / 77 SKIP.
#
# TWO FLAVORS, and they differ in more than the ROM (all inherited findings):
#
#   emu       -bios emuofw.rom         media = ISO9660 on the ATAPI path
#   coreboot  -bios coreboot.rom       media = FAT16 on the LEGACY ISA-IDE path
#
# The coreboot payload additionally needs a live repair before it can read ANY
# file: `allocate-dma` is a defer aimed at `null-allocate-dma` that nothing ever
# re-points on this flavor (only the emu flavor's PCI parent chain supplies the
# `dma-alloc` it falls back from), so the filesystem stack fails with "Can't open
# deblocker package". The sister lab found this -- see its POC-3, step 4.
#
# Note the bootstrap order that forces: the repair that makes file loading work
# CANNOT ITSELF BE LOADED FROM A FILE. It has to be typed. It is deliberately
# short, and --echo-gate self-clocks it, because a serial console has no flow
# control and a long typed colon definition arrives silently mangled.
set -u
MODE="${1:-all}"
FLAVOR="${2:-emu}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
CARD="$WORKDIR/fcode-card.rom"
DRIVE="$REPO/tools/drive-serial-repl.py"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# House rule: no silent exits, ever.
# shellcheck disable=SC2154  # rc is assigned inside the trap body
trap 'rc=$?; [ $rc -eq 0 ] || [ $rc -eq 1 ] || [ $rc -eq 77 ] || echo "FAIL: smoke exited early (rc=$rc)"' EXIT

# Per-flavor: ROM, the media QEMU attaches, the device path the firmware reads it
# through, and any repair that must precede the first fload.
PREFIX=()
case "$FLAVOR" in
  emu)
      ROM="${OFW_ROM:-$WORKDIR/openfirmware/cpu/x86/pc/emu/build/emuofw.rom}"
      MEDIA="$WORKDIR/dsl.iso"
      MEDIA_ARGS="-cdrom $MEDIA"
      DEV='/pci/pci-ide@1,1/ide@1/cdrom@0'
      ROMHINT="run the sister lab's ./build-ofw.sh"
      ;;
  coreboot)
      ROM="${OFW_ROM_COREBOOT:-$CB/build-ofw/coreboot.rom}"
      MEDIA="$WORKDIR/dsl.img"
      MEDIA_ARGS="-drive file=$MEDIA,format=raw,if=ide,index=0"
      DEV='/isa/ide@i1f0/disk@0'
      ROMHINT="run the sister lab's ./build-coreboot-ofw.sh"
      # re-point the dead defer, or every file operation below fails
      PREFIX=( --send ': my-dma h# 1000 mem-claim ;\r' --expect "ok"
               --send "' my-dma to allocate-dma\r"     --expect "ok" )
      ;;
  *)  fail "usage: $0 [ofdiag|ofscope|fcode|all] [emu|coreboot]" ;;
esac

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v python3 >/dev/null            || skip "python3 not installed"
[ -f "$ROM" ]   || skip "no $FLAVOR ROM at $ROM — $ROMHINT"
[ -f "$MEDIA" ] || skip "no $MEDIA — run ./stage-dsl.sh"

ACCEL=$([ -w /dev/kvm ] && echo kvm || echo tcg)
QPID=""
cleanup() { [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; }   # by PID, never by pattern
trap 'cleanup' INT TERM

# boot_and_drive <logname> <extra-qemu-args> <drive-args...>
boot_and_drive() {
    local log="$WORKDIR/$1-$FLAVOR.log" sock="$WORKDIR/$1-$FLAVOR.sock" extra="$2"; shift 2
    rm -f "$log" "$sock"
    # -m 256 is LOAD-BEARING: OFW anchors its PCI window at ~0x10000000
    # regardless of RAM, so at -m 512 a card's BARs land inside DRAM and the
    # device is silently shadowed. Do not "helpfully" raise this.
    # shellcheck disable=SC2086
    qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 256 -bios "$ROM" $MEDIA_ARGS \
        $extra -display none -serial "unix:$sock,server=on" -no-reboot >/dev/null 2>&1 &
    QPID=$!
    # The settle newline also absorbs the coreboot flavor's eaten-first-keystrokes
    # quirk; PREFIX (if any) applies the flavor's pre-fload repair.
    python3 "$DRIVE" "$sock" "$log" --timeout 200 --echo-gate \
        --expect "ok" --send '\r' --expect "ok" "${PREFIX[@]}" "$@"
    local rc=$?
    kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""
    LOG="$log"
    [ $rc -eq 125 ] && fail "serial console dropped input even with --echo-gate — see $log"
    grep -q "Open Firmware" "$log" 2>/dev/null || fail "no Open Firmware banner — see $log"
    return $rc
}

smoke_ofdiag() {
    boot_and_drive smoke-ofdiag "" \
        --send "fload $DEV:\\\\ofdiag.fth\r" --expect "ofdiag loaded" \
        --send '" nosuchalias" diag-open\r'   --expect "ok" \
        --send '" /pci/nosuch@9" diag-open\r' --expect "ok" \
        --send '" /pci/ethernet" diag-open\r' --expect "ok" \
        --send "\" $DEV\" diag-open\r"        --expect "ok" \
        --send 'why-no-boot\r'                --expect "ok" \
        --send 'trace-boot\r'                 --expect "tracing ON" \
        --send "load $DEV:\\\\ofdiag.fth\r"   --expect "ok" \
        --send 'boot\r'                       --expect "ok" \
        --send 'untrace\r'                    --expect "tracing OFF" \
        --send 'boot\r'                       --expect "ok"
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
    awk '/tracing ON/,/tracing OFF/' "$LOG" | grep -q '#T load-begin' \
        || fail "REGRESSION: trace-boot did not hook the LOAD path (no #T load-begin while tracing was ON)"
    # The real thing, not a stand-in: a `boot` must trip the ?show-device site
    # immediately before open-dev, not merely the load hooks. Assert the SHAPE,
    # not a device path -- the flavors differ in what they try to boot (emu goes
    # for /pci/ethernet, the coreboot payload for /isa/fdc/disk@0:\vmlinuz), and
    # hardcoding one of them made this fail on coreboot for the wrong reason.
    awk '/^ok boot/{f=1} /tracing OFF/{f=0} f' "$LOG" | grep -q '#T open' \
        || fail "REGRESSION: trace-boot did not hook a real BOOT (no #T open between \`boot\` and untrace)"
    awk '/tracing OFF/,0' "$LOG" | grep -q '#T ' \
        && fail "REGRESSION: untrace left a tracer installed (#T lines after tracing OFF)"
    note "tracer covers a real \`boot\` (list walk + device open) and a load; untrace restores cleanly"
    pass "ofdiag ($FLAVOR): 4 distinct fault diagnoses + boot tracer installed and cleanly removed"
}

smoke_ofscope() {
    boot_and_drive smoke-ofscope "" \
        --send "fload $DEV:\\\\ofscope.fth\r" --expect "ok" \
        --send 'dev /pci pci-map device-end\r' --expect "#P end" \
        --send 'mem-map\r' --expect "#M end" \
        --send 'load-base h# 400 region-snap\r' --expect "ok" \
        --send 'region-diff\r' --expect "total-diffs" \
        --send "load $DEV:\\\\ofscope.fth\r" --expect "ok" \
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
    pass "ofscope ($FLAVOR): pci-map + mem-map + region-diff verified, both region-diff controls hold"
}

smoke_fcode() {
    [ -f "$CARD" ] || skip "no $CARD — run ./build-fcode-rom.sh"
    boot_and_drive smoke-fcode "-device e1000,romfile=$CARD" \
        --send 'dev /pci ls\r' --expect "ok" \
        --send 'dev /pci/fcode-card .properties device-end\r' --expect "ok"
    grep -q 'fcode-card' "$LOG" \
        || fail "the card's FCode never ran: no fcode-card node. If you changed -m, note OFW anchors its PCI window at ~0x10000000 and >256M RAM shadows the ROM BAR (see $LOG)"
    grep -q 'FCODE-FROM-CARD-RAN' "$LOG" \
        || fail "fcode-card node exists but the marker property is missing — see $LOG"
    grep -q 'fcode-rom-offset' "$LOG" \
        || fail "no fcode-rom-offset property — the firmware did not record finding the ROM image"
    note "the firmware probed, validated and byte-loaded the card's FCode"
    pass "fcode ($FLAVOR): a PCI card's bytecode driver ran on the bare machine and named its own node"
}

case "$MODE" in
    ofdiag)  smoke_ofdiag ;;
    ofscope) smoke_ofscope ;;
    fcode)   smoke_fcode ;;
    all)
        rc=0
        for m in ofdiag ofscope fcode; do
            printf '\n=== %s (%s) ===\n' "$m" "$FLAVOR"
            bash "$0" "$m" "$FLAVOR"; r=$?
            [ $r -eq 1 ] && rc=1
        done
        printf '\n'
        [ $rc -eq 0 ] && echo "PASS: all vocabularies verified ($FLAVOR)" || echo "FAIL: at least one vocabulary failed ($FLAVOR)"
        exit $rc ;;
    *) fail "usage: $0 [ofdiag|ofscope|fcode|all] [emu|coreboot]" ;;
esac
