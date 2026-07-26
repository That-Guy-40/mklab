#!/usr/bin/env bash
# smoke-dsl.sh [stage|ofdiag|ofscope|fcode|stepper|dropin|autotrace|all] [emu|coreboot]
#   — one verdict per vocabulary. `dropin`/`autotrace` need ./build-dropin-rom.sh.
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
  *)  fail "usage: $0 [stage|ofdiag|ofscope|fcode|stepper|dropin|autotrace|all] [emu|coreboot]" ;;
esac

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v python3 >/dev/null            || skip "python3 not installed"
[ -f "$ROM" ]   || skip "no $FLAVOR ROM at $ROM — $ROMHINT"
[ -f "$MEDIA" ] || skip "no $MEDIA — run ./stage-dsl.sh"

ACCEL=$([ -w /dev/kvm ] && echo kvm || echo tcg)
GATE="--echo-gate"
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
    # GATE is --echo-gate by default (self-clocking, the house answer to dropped
    # bytes). The stepper smoke clears it: that debugger reads RAW keys, and its
    # echo of a space is indistinguishable from the whitespace already streaming
    # past -- exactly the non-echoing-prompt case --echo-gate is documented as
    # unsuitable for. Gating there silently stalls instead of stepping.
    # shellcheck disable=SC2086
    python3 "$DRIVE" "$sock" "$log" --timeout 200 $GATE \
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

# ── the in-ROM variants (./build-dropin-rom.sh) ──────────────────────────────
# These boot a ROM that CARRIES the vocabulary, so they attach NO media at all.
# Regression guard: ./stage-dsl.sh shipped broken once, because a ROM-only
# vocabulary (autotrace.fth, 9 chars) got picked up by the media stager and the
# 8.3 check rightly refused it -- and nothing in the suite ever ran the stager.
# The single-step debugger, genuinely driven.
#
# The trick is that `debug` has TWO display modes. With scrolling-debug? FALSE it
# uses setup-2d-display -- `page`, cursor positioning, a full-screen app that
# fights automation. With it TRUE it uses setup-scrolling-display, which is
# LINE-ORIENTED: every step reprints "Inside <word>  ( <stack> )" followed by the
# next word to execute. That line is the stable per-step anchor, so the driver can
# send exactly one key per settled display.
#
# Two further wins from scrolling mode: the stepper ECHOES each key (`dup emit`),
# and it never dumps the decompiled listing -- so a marker like OFDIAG-1 can only
# come from EXECUTION, not from source text being paged past. (An --expect that
# matched the listing gave a false PASS during development.)
smoke_stepper() {
    GATE=""          # raw-key reader: see the note in boot_and_drive
    boot_and_drive smoke-stepper "" \
        --send "fload $DEV:\\\\nopage.fth\r" --expect "nopage loaded" \
        --send 'true to scrolling-debug?\r'      --expect "ok" \
        --send "fload $DEV:\\\\ofdiag.fth\r" --expect "ofdiag loaded" \
        --send 'debug diag-open\r'               --expect "ok" \
        --send '" nosuchalias" diag-open\r'      --expect ": diag-open" \
        --send ' ' --expect "Inside diag-open" \
        --send ' ' --expect "Inside diag-open" \
        --send ' ' --expect "Inside diag-open" \
        --send ' ' --expect "Inside diag-open" \
        --send ' ' --expect "Inside diag-open" \
        --send 'G' --expect "OFDIAG-1"
    local steps
    steps=$(grep -c 'Inside diag-open' "$LOG")
    [ "$steps" -ge 5 ] || fail "REGRESSION: the stepper advanced only $steps time(s) — one key per settled display is no longer landing (see $LOG)"
    note "stepped $steps times, one key per settled display"
    # It must walk the word's ACTUAL words, in source order (see dsl/ofdiag.fth).
    grep -A1 'Inside diag-open' "$LOG" | grep -q '^2dup' \
        || fail "REGRESSION: the stepper never showed '2dup' — it is not walking diag-open's real words (see $LOG)"
    # Semantic proof, not just liveness: 2dup must DUPLICATE the visible stack,
    # and `type` must emit the argument we passed in.
    grep -q 'Inside diag-open .*( \([0-9a-f]*\) \([0-9a-f]*\) \1 \2 )' "$LOG" \
        || fail "REGRESSION: no stack duplication visible after 2dup — the stack display is not tracking execution (see $LOG)"
    note "the displayed stack duplicates across 2dup, and steps follow the source"
    grep -q 'type  *nosuchalias' "$LOG" \
        || fail "REGRESSION: stepping 'type' did not emit the argument 'nosuchalias' (see $LOG)"
    note "stepping 'type' emitted the argument — execution, not just display"
    # G runs to completion; OFDIAG-1 here can only be execution (scrolling mode
    # never lists the source, so there is nothing to false-positive against).
    grep -q 'OFDIAG-1: not a path' "$LOG" \
        || fail "REGRESSION: 'G' did not run the word to completion (no diagnosis emitted) — see $LOG"
    note "'G' ran it to completion and the diagnosis came out"
    pass "stepper: single-stepped a live word on bare metal, one key per settled display, and ran it out"
}

smoke_stage() {
    bash "$HERE/stage-dsl.sh" >/dev/null 2>&1 \
        || fail "REGRESSION: ./stage-dsl.sh fails — a ROM-only or non-8.3 vocabulary reached the media stager"
    note "stage-dsl.sh builds both media cleanly"
    pass "stage: the media stager accepts every vocabulary meant for media"
}

smoke_dropin() {
    ROM="$WORKDIR/ofdiag-emuofw.rom"; MEDIA_ARGS=""; PREFIX=()
    [ -f "$ROM" ] || skip "no $ROM — run ./build-dropin-rom.sh"
    boot_and_drive smoke-dropin "" \
        --send 'no-page\r' --expect "ok" \
        --send 'dir /dropin-fs:\\\r' --expect "ok" \
        --send 'fload /dropin-fs:\\ofdiag.fth\r' --expect "ofdiag loaded" \
        --send 'why-no-boot\r' --expect "ok"
    grep -q 'ofdiag.fth' "$LOG" || fail "the ROM's /dropin-fs does not carry ofdiag.fth — see $LOG"
    grep -q 'ofscope.fth' "$LOG" || fail "the ROM's /dropin-fs does not carry ofscope.fth — see $LOG"
    note "the vocabularies are inside the ROM, listed by /dropin-fs"
    grep -q 'OFDIAG-' "$LOG" || fail "the in-ROM vocabulary loaded but produced no diagnosis — see $LOG"
    note "loaded and ran with NO cdrom, NO floppy, NO staged media"
    pass "dropin: the DSL ships inside the ROM and loads with no media at all"
}

smoke_autotrace() {
    ROM="$WORKDIR/autotrace-emuofw.rom"; MEDIA_ARGS=""; PREFIX=()
    [ -f "$ROM" ] || skip "no $ROM — run ./build-dropin-rom.sh --boot-hook"
    # Send NOTHING before the prompt: any keypress cancels the autoboot countdown,
    # and the autoboot is the entire point. boot_and_drive's first step only waits.
    boot_and_drive smoke-autotrace ""
    grep -q '#T autotrace armed' "$LOG" \
        || fail "the boot- dropin never ran — no arming line before the countdown (see $LOG)"
    # The proof: #T lines BEFORE the first prompt, i.e. during the power-on
    # autoboot, with nothing typed and no media present.
    awk '/#T autotrace armed/{f=1} /^ok/{exit} f' "$LOG" | grep -q '#T open' \
        || fail "REGRESSION: the autoboot itself was NOT traced (no #T open before the first prompt) — see $LOG"
    note "the boot- dropin armed the tracers before do-auto-boot"
    note "the POWER-ON autoboot traced itself — nothing typed, no media"
    pass "autotrace: the autoboot traces itself from a boot- dropin inside the ROM"
}

case "$MODE" in
    stage)     smoke_stage ;;
    stepper)   smoke_stepper ;;
    dropin)    smoke_dropin ;;
    autotrace) smoke_autotrace ;;
    ofdiag)  smoke_ofdiag ;;
    ofscope) smoke_ofscope ;;
    fcode)   smoke_fcode ;;
    all)
        rc=0
        for m in stage ofdiag ofscope fcode stepper dropin autotrace; do
            printf '\n=== %s (%s) ===\n' "$m" "$FLAVOR"
            bash "$0" "$m" "$FLAVOR"; r=$?
            [ $r -eq 1 ] && rc=1
        done
        printf '\n'
        [ $rc -eq 0 ] && echo "PASS: all vocabularies verified ($FLAVOR)" || echo "FAIL: at least one vocabulary failed ($FLAVOR)"
        exit $rc ;;
    *) fail "usage: $0 [stage|ofdiag|ofscope|fcode|stepper|dropin|autotrace|all] [emu|coreboot]" ;;
esac
