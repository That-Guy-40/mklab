#!/usr/bin/env bash
# smoke-openbios.sh [multiboot|coreboot|ppc] — one verdict per track.
#
#   multiboot: QEMU's multiboot loader starts openbios.multiboot + dict;
#              prompt answers `3 4 + .` → 7 and lists the device tree.
#   coreboot:  coreboot ROM hands off to the openbios-builtin.elf payload;
#              same prompt checks.
#   ppc:       OUR openbios-qemu.elf swapped in via -bios; proves the blob
#              is ours (build-date banner ≠ the distro blob's) + answers 7.
# Exit: 0 PASS / 1 FAIL / 77 SKIP.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
FLAVOR="${1:-multiboot}"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# shellcheck disable=SC2154  # rc IS assigned, by the `rc=$?` at the start of this same
# single-quoted trap body; shellcheck analyses the string without carrying the assignment
# into the uses that follow it.
trap 'rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: test exited early (rc=$rc)"' EXIT

command -v python3 >/dev/null || skip "python3 not installed"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)
LOG="$WORKDIR/smoke-openbios-$FLAVOR.log"
SOCK="$WORKDIR/smoke-$FLAVOR.sock"
rm -f "$LOG" "$SOCK"

case "$FLAVOR" in
  multiboot|coreboot)
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    if [[ "$FLAVOR" == multiboot ]]; then
      MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
      [[ -f "$MB" ]] || skip "no image at $MB — run ./build-openbios.sh x86 first"
      QEMU=(qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB"
            -initrd "$WORKDIR/openbios/obj-x86/openbios.dict")
    else
      ROM="$CB/build-openbios/coreboot.rom"
      [[ -f "$ROM" ]] || skip "no ROM at $ROM — run ./build-coreboot-openbios.sh first"
      QEMU=(qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -bios "$ROM")
    fi
    note "booting $FLAVOR (accel=$ACCEL), driving the 0 > prompt → $LOG"
    "${QEMU[@]}" -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
    QPID=$!
    # (no banner expect: on x86 the banner goes to the VGA console path;
    # the serial side begins life at the bare prompt)
    python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 90 \
      --expect "0 > " \
      --send '3 4 + .\r' --expect "7 " \
      --send 'dev / ls\r' --expect "openprom" --expect "0 > "
    RC=$?
    kill "$QPID" 2>/dev/null   # by PID, never by pattern
    [[ $RC -eq 0 ]] && pass "OpenBIOS ($FLAVOR) answered 7 at the 0 > prompt and listed the device tree"
    fail "no prompt conversation on the $FLAVOR track (rc=$RC) — see $LOG" ;;
  ppc)
    command -v qemu-system-ppc >/dev/null || skip "qemu-system-ppc not installed"
    ELF="$WORKDIR/openbios/obj-ppc/openbios-qemu.elf"
    [[ -f "$ELF" ]] || skip "no image at $ELF — run ./build-openbios.sh ppc first"
    note "booting OUR openbios-ppc via -bios (pty: ppc console input needs muxed stdio) → $LOG"
    python3 "$REPO/tools/drive-pty-repl.py" "$LOG" --timeout 90 \
      --expect "Welcome to OpenBIOS" --expect "0 > " \
      --send '3 4 + .\r' --expect "7 " \
      -- qemu-system-ppc -bios "$ELF" -nographic -vga none
    RC=$?
    [[ $RC -eq 0 ]] || fail "our openbios-ppc did not answer at the prompt (rc=$RC) — see $LOG"
    OURS=$(grep -ao 'built on [0-9A-Za-z: ]*' "$LOG" | head -1)
    note "banner: OpenBIOS $OURS"
    # The proof of the swap-in: the distro blob (QEMU's default -bios) shows a
    # DIFFERENT build date. Boot it briefly and compare banners.
    THEIRS=$(timeout 20 qemu-system-ppc -nographic -vga none </dev/null 2>/dev/null \
             | grep -ao 'built on [0-9A-Za-z: ]*' | head -1 || true)
    if [[ -n "$THEIRS" ]]; then
      [[ "$OURS" == "$THEIRS" ]] && \
        fail "REGRESSION: banner build date matches the distro blob ($THEIRS) — -bios swap-in did not take"
      note "distro blob: $THEIRS — different, so the running firmware is OURS"
    fi
    pass "our own openbios-ppc (${OURS:-build date n/a}) answered 7 at the 0 > prompt" ;;
  nvram)
    # The persistence ladder's P0 checkpoint, made durable.
    #
    # TWO-SIDED ON PURPOSE. The expectation is DERIVED from the clone rather
    # than hardcoded: if patches/04-x86-nvram-p0.patch is applied, /nvram must
    # be in the tree; if it is not applied, /nvram must be ABSENT. Either way
    # a mismatch fails by name. A one-sided "assert nvram is there" would pass
    # vacuously on an unpatched build the day someone forgets to apply it, and
    # the recorded negative control -- the `dev / ls` that stops at `console` --
    # would be lost the moment it stopped being re-measured.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    [[ -f "$MB" ]] || skip "no image at $MB — run ./build-openbios.sh x86 first"
    # DERIVE THE EXPECTATION FROM THE CAUSE, NOT FROM A PATCH. The first draft
    # asked `git apply --reverse --check patches/04`, i.e. "is exactly that diff
    # present" -- and it broke the moment P1 edited the same file: P0 was still
    # in effect, the node was still there, and the check said it should be
    # absent. A patch is a DIFF, which is a cache of a state; the state itself
    # is the one line that makes the node exist.
    SRC="$WORKDIR/openbios/arch/x86/openbios.c"
    [[ -f "$SRC" ]] || skip "no clone at $SRC — run ./build-openbios.sh x86 first"
    if grep -q 'nvram_init(' "$SRC"; then WANT=present; else WANT=absent; fi
    note "P0 patch is $([[ $WANT == present ]] && echo applied || echo 'NOT applied') → /nvram must be $WANT"
    note "booting multiboot (accel=$ACCEL), listing the device tree → $LOG"
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" \
      -initrd "$WORKDIR/openbios/obj-x86/openbios.dict" \
      -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
    QPID=$!
    python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 90 \
      --expect "0 > " --send 'dev / ls\r' --expect "0 > "
    RC=$?
    kill "$QPID" 2>/dev/null   # by PID, never by pattern
    [[ $RC -eq 0 ]] || fail "no prompt conversation on the nvram track (rc=$RC) — see $LOG"
    # `dev / ls` prints "<hex-phandle> <name>" per line. Anchor on that shape so
    # the word "nvram" appearing in a banner or an error message cannot pass for
    # a device-tree entry.
    if grep -qE '^[0-9a-f]+ nvram[[:space:]]*$' "$LOG"; then GOT=present; else GOT=absent; fi
    if [[ "$GOT" != "$WANT" ]]; then
      [[ "$WANT" == present ]] && \
        fail "REGRESSION: P0 is applied to the clone but the running firmware has NO /nvram node — the patch is in the source and not in the image (rebuild with ./build-openbios.sh x86) — see $LOG"
      fail "REGRESSION: /nvram is in the device tree of a firmware built WITHOUT P0 — the negative control this ladder rests on no longer holds — see $LOG"
    fi
    [[ "$WANT" == absent ]] && \
      pass "control holds: without P0 the device tree stops at console and has no nvram node"
    # P0's store is volatile, and says so on every boot. When P1 lands a real
    # backing this must stop appearing — so it is asserted, not just observed.
    # This track attaches NO drive, so a backed build still comes up volatile
    # here — the message must describe THIS BOOT, not infer a patch level from
    # it. `persist` is the track that judges the backing.
    if grep -q 'zapping pram' "$LOG"; then VOL=" (no store on this boot — nothing attached at ide@, so it came up blank and re-formatted)"; else VOL=" (the store arrived already valid on this boot)"; fi
    pass "P0: /nvram is in the device tree${VOL}"
    ;;
  persist|persist-flash)
    # The ladder's P1+P2 checkpoint: a config variable that survives a POWER
    # CYCLE, asserted on the HOST'S FILE and on a brand-new QEMU process.
    #
    # Reading a variable back inside one session proves nothing -- dictionary
    # state answers identically, which is the illusion this ladder exists to
    # dispel. So this boots three times: write, read back in a FRESH process,
    # and a CONTROL with no drive attached that must NOT see the value.
    #
    # The control is not decoration. An earlier hand-run of this check used
    # `auto-boot?`, whose x86 default is already "false" -- so it passed while
    # measuring the default. The control printed the identical line and that is
    # what exposed it. Hence a NONCE below, which no default can equal.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    [[ -f "$MB" ]] || skip "no image at $MB — run ./build-openbios.sh x86 first"
    # Same rule as the nvram track: derive from the cause, per backing.
    SRC="$WORKDIR/openbios/arch/x86/openbios.c"
    [[ -f "$SRC" ]] || skip "no clone at $SRC — run ./build-openbios.sh x86 first"

    NONCE="P1-PERSIST-$$"
    if [[ "$FLAVOR" == persist-flash ]]; then
      # pflash0 IS the BIOS on -M pc: an empty one removes the SeaBIOS that
      # loads the multiboot image and the machine goes dark (measured). So the
      # code unit has to carry a BIOS for the vars unit to be reachable at all.
      SEABIOS=$(ls /usr/share/seabios/bios.bin /usr/share/qemu/bios.bin 2>/dev/null | head -1)
      [[ -n "$SEABIOS" ]] || skip "no seabios image found — pflash0 must hold a BIOS or nothing boots"
      grep -q 'lab_flash_present' "$WORKDIR/openbios/arch/x86/openbios.c" \
        || skip "no CFI flash backing in arch/x86/openbios.c — this track measures the pflash store"
      F0="$WORKDIR/flash0.img"; NV="$WORKDIR/flash1.img"
      truncate -s 4M "$F0"
      dd if="$SEABIOS" of="$F0" bs=1 seek=$(( 4*1024*1024 - $(stat -c%s "$SEABIOS") )) \
         conv=notrunc status=none
      rm -f "$NV"; truncate -s 128k "$NV"
      DRIVE=(-drive "if=pflash,format=raw,file=$F0,unit=0"
             -drive "if=pflash,format=raw,file=$NV,unit=1")
      WANT_BACKEND="pflash@0xffbe0000"
    else
      grep -q 'ob_ide_write_blocks_nr' "$SRC" \
        || skip "the store has no IDE backing in $SRC (P1 not applied) — this track measures a backed store"
      NV="$WORKDIR/nvram-store.img"
      rm -f "$NV"; truncate -s 1M "$NV"
      DRIVE=(-drive "if=ide,index=3,format=raw,cache=writethrough,file=$NV")
      WANT_BACKEND="ide@3"
    fi
    BEFORE=$(sha256sum "$NV" | cut -d" " -f1)

    _boot() { # _boot <log> <send-args...> -- trailing args after -- are qemu extras
      local log="$1"; shift
      rm -f "$SOCK" "$log"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" \
        -initrd "$WORKDIR/openbios/obj-x86/openbios.dict" "${QEXTRA[@]}" \
        -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
      local qp=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$log" --timeout 90 "$@" >/dev/null 2>&1
      local rc=$?
      kill "$qp" 2>/dev/null   # by PID, never by pattern
      sleep 1
      return $rc
    }

    note "1/3 writing boot-file=$NONCE and calling update-nvram → $LOG.write"
    QEXTRA=("${DRIVE[@]}")
    _boot "$LOG.write" --expect "0 > " \
      --send "setenv boot-file $NONCE\r" --expect "0 > " \
      --send "\" /nvram\" \" update-nvram\" execute-device-method .\r" --expect "0 > " \
      || fail "no prompt conversation while writing the store — see $LOG.write"
    grep -q '^0 > " /nvram" " update-nvram" execute-device-method \. -1' <(tr -d "\r" < "$LOG.write") \
      || fail "update-nvram did not report success (-1) — see $LOG.write"
    # WHICH backing answered matters: with both attached, flash wins, and a
    # "flash" run could otherwise pass while measuring the IDE store.
    grep -q "nvram: backed by $WANT_BACKEND" "$LOG.write" \
      || fail "this track measures $WANT_BACKEND but the firmware reported: $(grep -o 'nvram: backed by .*' "$LOG.write" | tr -d '\r' | head -1)"
    AFTER=$(sha256sum "$NV" | cut -d" " -f1)
    [[ "$BEFORE" != "$AFTER" ]] \
      || fail "REGRESSION: update-nvram reported success and the host image is byte-identical — the write never reached the disk"
    note "   host image changed: ${BEFORE:0:12}… → ${AFTER:0:12}…"

    note "2/3 fresh QEMU process, same image, reading it back → $LOG.read"
    QEXTRA=("${DRIVE[@]}")
    _boot "$LOG.read" --expect "0 > " --send "printenv boot-file\r" --expect "0 > " \
      || fail "no prompt conversation on the read-back boot — see $LOG.read"
    grep -q "$NONCE" "$LOG.read" \
      || fail "REGRESSION: boot-file did not survive a power cycle — the store is not backed — see $LOG.read"
    grep -q "zapping pram" "$LOG.read" \
      && fail "REGRESSION: the store was re-formatted on the read-back boot — it did not arrive valid — see $LOG.read"

    note "3/3 control: identical boot with NO drive attached → $LOG.control"
    QEXTRA=()
    _boot "$LOG.control" --expect "0 > " --send "printenv boot-file\r" --expect "0 > " \
      || fail "no prompt conversation on the control boot — see $LOG.control"
    grep -q "$NONCE" "$LOG.control" \
      && fail "REGRESSION: the control saw $NONCE with no drive attached — this check cannot fail and proves nothing"
    grep -q "no backing store found" "$LOG.control" \
      || fail "the control did not report a missing backing store — the firmware found a store somewhere this test did not attach one, so the control is not a control — see $LOG.control"

    pass "P1+P2: boot-file=$NONCE survived a power cycle on $WANT_BACKEND (host image changed, arrived valid, and the no-drive control did NOT see it)"
    ;;
  floppy)
    # The floppy backing, which is HALF done, and this track asserts exactly the
    # half that works rather than pretending either more or less.
    #
    # WHAT IT PROVES: the FDC read path functions on x86 -- which it did not
    # before, because read_ok() compared ST0's head field to the REQUESTED head
    # while floppy_read_sectors() sets the MT bit, so every multi-track read was
    # judged a failure after transferring perfectly. That bug sat behind
    # CONFIG_DRIVER_FLOPPY=false for x86. If the store comes back reporting
    # floppy0 as its backing, the read worked.
    #
    # WHAT IT DOES NOT PROVE: writing. See the KNOWN-BLOCKED note in
    # drivers/floppy.c -- 512 bytes transfer and the controller never turns the
    # bus around. That gap is deliberately NOT a permanently-red test here; it is
    # recorded in the doc and in the driver. This track would go green either way
    # on the read, so it also asserts the write gap is still the gap it was,
    # which is what makes it notice if someone fixes it.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    [[ -f "$MB" ]] || skip "no image at $MB — run ./build-openbios.sh x86 first"
    grep -q 'CONFIG_DRIVER_FLOPPY" type="boolean" value="true"' \
      "$WORKDIR/openbios/config/examples/x86_config.xml" \
      || skip "CONFIG_DRIVER_FLOPPY is off for x86 in the clone — nothing to measure"

    FD="$WORKDIR/nvram-floppy.img"
    rm -f "$FD"; truncate -s 1474560 "$FD"     # exactly 1.44 MB: the H1440 geometry
    rm -f "$SOCK" "$LOG"
    note "booting with a blank 1.44 MB floppy at fd0 → $LOG"
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" \
      -initrd "$WORKDIR/openbios/obj-x86/openbios.dict" \
      -drive "if=floppy,index=0,format=raw,file=$FD" \
      -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
    QPID=$!
    python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 120 \
      --expect "0 > " \
      --send "setenv boot-file FLOPPY-PROBE\r" --expect "0 > " \
      --send "\" /nvram\" \" update-nvram\" execute-device-method .\r" --expect "0 > "
    RC=$?
    kill "$QPID" 2>/dev/null   # by PID, never by pattern
    [[ $RC -eq 0 ]] || fail "no prompt conversation on the floppy track (rc=$RC) — see $LOG"

    grep -q "nvram: backed by floppy0" "$LOG" \
      || fail "REGRESSION: the floppy read path no longer selects floppy0 as a backing — the ST0_HA/MT fix in read_ok() has come undone, or the media was not read — see $LOG"
    note "read path OK: the store was read off fd0 and floppy0 was selected"

    if grep -q "WRITE FAILED to floppy0" "$LOG"; then
      pass "floppy: the FDC READ path works on x86 (backing selected off a 1.44 MB image) and the write is still the known-blocked gap, failing honestly rather than hanging"
    fi
    # The gap closed. That is good news and must not slip by unnoticed.
    grep -q "nvram: WRITE FAILED" "$LOG" \
      || fail "the floppy WRITE no longer reports failure — if the known-blocked turnaround is fixed, this track and the KNOWN-BLOCKED note in drivers/floppy.c both need updating, and persist-floppy should become a real track — see $LOG"
    fail "the floppy write failed against a backing that is not floppy0 — this track is not measuring what it thinks — see $LOG"
    ;;
  persist-os|persist-os-flash)
    # P2's OTHER half: not just a power cycle, but a POWER CYCLE WITH AN OS IN
    # BETWEEN. The distinction matters because the OS owns the machine while it
    # runs -- it enumerates the disks, and anything it decides to reuse is gone.
    # A store that survives `qemu exit; qemu start` has not been asked that
    # question at all.
    #
    # Three boots: write / boot Linux / read back.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v genisoimage >/dev/null || skip "genisoimage not installed"
    MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    [[ -f "$MB" ]] || skip "no image at $MB — run ./build-openbios.sh x86 first"
    SRC="$WORKDIR/openbios/arch/x86/openbios.c"
    grep -q 'ob_ide_write_blocks_nr' "$SRC" 2>/dev/null \
      || skip "the store has no IDE backing in $SRC — this track measures a backed store"
    KERNEL="${KERNEL:-$HOME/linuxboot-lab/payload-bzImage}"
    INITRD="${INITRD:-$HOME/linuxboot-lab/uroot.cpio}"
    [[ -f "$KERNEL" ]] || skip "no kernel at $KERNEL (set KERNEL=; an x86_64 bzImage with a serial console)"
    [[ -f "$INITRD" ]] || skip "no initrd at $INITRD (set INITRD=)"

    NONCE="P2-OS-$$"
    if [[ "$FLAVOR" == persist-os-flash ]]; then
      SEABIOS=$(ls /usr/share/seabios/bios.bin /usr/share/qemu/bios.bin 2>/dev/null | head -1)
      [[ -n "$SEABIOS" ]] || skip "no seabios image found — pflash0 must hold a BIOS or nothing boots"
      grep -q 'lab_flash_present' "$SRC" || skip "no CFI flash backing in $SRC"
      F0="$WORKDIR/os-flash0.img"; NV="$WORKDIR/os-flash1.img"
      truncate -s 4M "$F0"
      dd if="$SEABIOS" of="$F0" bs=1 seek=$(( 4*1024*1024 - $(stat -c%s "$SEABIOS") )) \
         conv=notrunc status=none
      rm -f "$NV"; truncate -s 128k "$NV"
      DRIVE=(-drive "if=pflash,format=raw,file=$F0,unit=0"
             -drive "if=pflash,format=raw,file=$NV,unit=1")
      WANT_BACKEND="pflash@0xffbe0000"
    else
      NV="$WORKDIR/persist-os-store.img"
      rm -f "$NV"; truncate -s 1M "$NV"        # 1 MiB == 2048 sectors, asserted below
      DRIVE=(-drive "if=ide,index=3,format=raw,cache=writethrough,file=$NV")
      WANT_BACKEND="ide@3"
    fi
    ISO="$WORKDIR/persist-os.iso"; STAGE="$WORKDIR/persist-os-stage"
    rm -rf "$STAGE"; mkdir -p "$STAGE"; rm -f "$ISO"
    cp "$KERNEL" "$STAGE/VMLINUZ"; cp "$INITRD" "$STAGE/UROOT.IMG"
    genisoimage -quiet -o "$ISO" -V OBISO -r -J "$STAGE"

    _boot() { # _boot <log> <timeout> <send-args...>; QEXTRA holds qemu extras
      local log="$1" tmo="$2"; shift 2
      rm -f "$SOCK" "$log"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" \
        -initrd "$WORKDIR/openbios/obj-x86/openbios.dict" "${QEXTRA[@]}" \
        -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
      local qp=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$log" --timeout "$tmo" "$@" >/dev/null 2>&1
      local rc=$?
      kill "$qp" 2>/dev/null   # by PID, never by pattern
      sleep 1
      return $rc
    }

    note "1/3 writing boot-file=$NONCE → $LOG.write"
    QEXTRA=("${DRIVE[@]}")
    _boot "$LOG.write" 90 --expect "0 > " \
      --send "setenv boot-file $NONCE\r" --expect "0 > " \
      --send "\" /nvram\" \" update-nvram\" execute-device-method .\r" --expect "0 > " \
      || fail "no prompt conversation while writing the store — see $LOG.write"
    grep -q "nvram: backed by $WANT_BACKEND" "$LOG.write" \
      || fail "this track measures $WANT_BACKEND but the write boot reported: $(grep -o 'nvram: backed by .*' "$LOG.write" | tr -d '\r' | head -1)"

    note "2/3 booting Linux with the store still attached → $LOG.os"
    QEXTRA=("${DRIVE[@]}" -cdrom "$ISO")
    # The boot line is 78 chars; the firmware's input buffer eats past ~80 (POC-4).
    _boot "$LOG.os" 260 --expect "0 > " \
      --send 'boot /ide@1/cdrom@0:\\vmlinuz console=ttyS0 initrd=/ide@1/cdrom@0:\\uroot.img\r' \
      --expect "Welcome to u-root" \
      || fail "Linux did not reach u-root, so no OS ever owned the machine and this track measured nothing — see $LOG.os"
    if [[ "$FLAVOR" == persist-os ]]; then
      # THE OS MUST HAVE SEEN THE STORE. Without this the "OS in between" is
      # just a slow reboot: an OS that never enumerated the disk cannot have
      # spared it. Bound to OUR disk by size (1 MiB == 2048 sectors).
      grep -q "ATA-7: QEMU HARDDISK" "$LOG.os" \
        || fail "the kernel never enumerated an ATA disk — the store was not visible to the OS, so this run does not answer the OS-in-between question — see $LOG.os"
      grep -q "2048 sectors" "$LOG.os" \
        || fail "the kernel enumerated a disk but not one of 2048 sectors — it saw something other than this track's store — see $LOG.os"
      note "   the OS booted AND enumerated the store (ATA-7 QEMU HARDDISK, 2048 sectors)"
    else
      # A WEAKER CLAIM, STATED AS SUCH. Linux does not enumerate the vars pflash
      # as a block device, so there is no equivalent line to assert and this
      # track cannot show the OS ever met the store. That is the point of the
      # backing -- a region the firmware OWNS rather than one it shares -- but it
      # also means this run proves "survived an OS boot", NOT "survived an OS
      # that could have clobbered it". The ide track is the one that shows that.
      note "   the OS booted; NOT asserting the OS saw the store — Linux does not"
      note "   enumerate a vars pflash, so this rung is weaker here than on ide@3"
    fi

    note "3/3 fresh firmware boot, reading it back → $LOG.read"
    QEXTRA=("${DRIVE[@]}")
    _boot "$LOG.read" 90 --expect "0 > " --send "printenv boot-file\r" --expect "0 > " \
      || fail "no prompt conversation on the read-back boot — see $LOG.read"
    grep -q "$NONCE" "$LOG.read" \
      || fail "REGRESSION: boot-file did not survive a boot with an OS in between — the store was lost or reused while Linux owned the machine — see $LOG.read"
    grep -q "zapping pram" "$LOG.read" \
      && fail "REGRESSION: the store was re-formatted after the OS boot — it did not arrive valid — see $LOG.read"

    if [[ "$FLAVOR" == persist-os ]]; then
      pass "P2 (OS in between): boot-file=$NONCE survived a full Linux boot that enumerated the very disk holding it"
    fi
    pass "P2 (OS in between): boot-file=$NONCE survived a full Linux boot on $WANT_BACKEND (the OS was not shown to have seen the store — see the note above)"
    ;;
  amd64)
    # SPIKE 1: the firmware itself running in LONG MODE, on bare metal.
    #
    # Not openbios-unix. That hosted binary has answered ffffffffffffffff since
    # before this lab existed, and it proves the Forth engine is 64-bit clean --
    # nothing about the arch layer. This track boots obj-amd64/openbios.multiboot32
    # under QEMU and asks the same question of the metal.
    #
    # AND IT IS A REAL ELF64, asserted below. QEMU does print "Cannot load
    # x86-64 image, give a 32bit one" -- but only on its ELF path. The image
    # carries the multiboot a.out-kludge flag, so the loader never parses the
    # ELF and never reaches that check. Asserting the ELF class is the point:
    # without it this track would pass just as happily on the ELF32-wrapped
    # variant, and the claim "QEMU booted a 64-bit ELF" would go unmeasured.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    MB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    DICT="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    [[ -f "$MB" ]] || skip "no image at $MB — run ./build-openbios.sh amd64 first"
    readelf -h "$MB" 2>/dev/null | grep -q 'ELF64' \
      || fail "$MB is not an ELF64 — this track's claim is that QEMU boots a 64-BIT ELF, and an ELF32 would pass every assertion below while proving something weaker"
    [[ -f "$DICT" ]] || skip "no dictionary at $DICT"
    note "booting the 64-bit firmware (accel=$ACCEL) → $LOG"
    rm -f "$SOCK" "$LOG"
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DICT" \
      -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
    QPID=$!
    python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 90 \
      --expect "0 > " \
      --send '3 4 + .\r' --expect "7 " \
      --send '-1 u.\r' --expect "0 > " \
      --send 'dev / ls\r' --expect "0 > "
    RC=$?
    kill "$QPID" 2>/dev/null   # by PID, never by pattern
    # A triple fault under -no-reboot exits QEMU with rc=0 (POC-2's pitfall
    # list), so NEVER read a clean exit as success: assert the prompt.
    [[ $RC -eq 0 ]] || fail "the 64-bit firmware did not answer at the prompt (rc=$RC) — see $LOG"
    grep -q 'ffffffffffffffff' "$LOG" \
      || fail "REGRESSION: the prompt answered but '-1 u.' did not print ffffffffffffffff — the cell is not 64-bit on the metal — see $LOG"
    # The trampoline's own witness. If relocation ever comes back, long mode's
    # indifference to segment bases makes it a silent corruptor, so the skip is
    # asserted rather than assumed.
    grep -q 'long mode ignores segment bases' "$LOG" \
      || fail "the firmware did not report skipping relocation — see $LOG"
    grep -q 'openprom' "$LOG" \
      || fail "no device tree at the 64-bit prompt — see $LOG"
    pass "SPIKE 1: QEMU booted a 64-bit ELF (via the multiboot a.out kludge) and the firmware runs in long mode — 0 > answered 7, '-1 u.' printed ffffffffffffffff, and the device tree is there"
    ;;
  *) echo "usage: $0 [multiboot|coreboot|ppc|nvram|persist|persist-flash|floppy|persist-os|persist-os-flash|amd64]" >&2; exit 1 ;;
esac
