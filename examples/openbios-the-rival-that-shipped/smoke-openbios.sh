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
usage() {
    cat <<'USAGE'
smoke-openbios.sh [TRACK]   one-verdict smoke tests against a real boot

TRACK (default multiboot):
  multiboot coreboot ppc      the firmware answers 7 at the 0 > prompt
  coreboot-amd64              ...and the 64-bit firmware does it as a coreboot
                              payload, with the dictionary compiled in
  nvram floppy                the NVRAM package, and its floppy backing
  persist persist-flash       a config variable survives a power cycle
  persist-os persist-os-flash ...and survives an OS boot in between
  dict-identity               proves the x86 tracks load openbios-x86.dict --
                              the SUPERSET -- and not the arch-less base
  amd64                       the 64-bit prompt (Spike 1)
  amd64-fault amd64-ctx       exceptions and the context switch (Spike 2)
  amd64-pmem                  /nvram on an NVDIMM above 4 GiB (P3)
  amd64-linux                 the 64-bit firmware boots Linux (Spike 3)
  memory-available            TODO 17.3: /memory's available, and the claim it describes
  property-abi                TODO 13.2's four property.fs defects, watched
                              to bite on both arches
  vga                         PCI enumeration on amd64, and the VGA FCode
                              blob that had never been evaluated on either
  diagnostics                 the Forth bindings report their own failures
                              (silent on a clean boot, loud on a real one),
                              and libc/vsprintf.c's %s precision clips
  client-forth                `go` runs a Forth payload loaded off media --
                              the trampoline's segments (TODO 13.3(A))
  pmem-writer                 a 1275 structure written to an NVDIMM above
                              4 GiB and found in the host file (TODO 16)
  flash-writer                and why CFI flash is NOT the same seam: a bare
                              store is a command, not data (TODO 16)
  mmio-writer                 stores into the VGA aperture, seen by QEMU's
                              screendump — an observer outside the firmware
  struct-layer                REVIEW G2: a TYPE layer (dsl/struct.fth) over
                              the firmware's own struct/field, pointed at a
                              real ELF64 header
  struct-array                ...and ARRAYS of a type: the ELF64 program-header
                              table walked, graded by a derived sum
  struct-device               ...and over a LIVE DEVICE's registers, which is
                              what turned up patch 49 — 1275 5.3.7.2's six
                              register words had EMPTY bodies
  elf-methods                 REVIEW E1/E4 from poke-elf: constraints that
                              REFUSE a file, and vaddr>off / load-base /
                              section names (dsl/elf.fth)
  rmw-fields                  read-modify-write bits in a typed field
                              (t-set/t-clr/t-tog) — mudge's register idiom,
                              generalized; preserves neighbours where t! clobbers

Exit: 0 PASS / 1 FAIL / 77 SKIP. Each track ends on exactly one verdict line.
Env: OPENBIOS_WORKDIR, KERNEL, INITRD, COREBOOT_DIR
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

# assert_memory_reg <log> — /memory must carry a `reg`, and it must add up.
#
# THE DEFECT WAS ABSENCE, so presence is most of the assertion: until 2026-08-28
# /memory carried nothing but its name on BOTH x86 arches and on every path
# (measured on x86 too, before blaming the coreboot one). ppc and sparc get this
# from ofmem; arch/x86 says in its own source that it has none, and arch/amd64
# mentions it nowhere.
#
# It sums the SIZE column rather than stopping at "a reg exists", because an empty
# or zero-filled property is exactly what a broken encoder would emit and it would
# satisfy a presence check. .properties prints the cells as 8-hex-digit columns;
# with the root's #address-cells 1 / #size-cells 1 that is (base, size).
assert_memory_reg() {
    local log="$1" total=0 sz nranges
    grep -qa '^reg ' "$log" \
        || fail "REGRESSION: /memory carries no 'reg' property — publish_memory_ranges() did not run or found no ranges, so the device tree does not say where RAM is — see $log"
    while read -r sz; do
        [[ -n "$sz" ]] && total=$(( total + 0x$sz ))
    done < <(sed -n '/^reg /,/ ok/p' "$log" | grep -oE '[0-9a-f]{8}[[:space:]]+[0-9a-f]{8}' | awk '{print $2}')
    nranges="$(sed -n '/^reg /,/ ok/p' "$log" | grep -cE '[0-9a-f]{8}[[:space:]]+[0-9a-f]{8}' || true)"
    (( total >= 0x10000000 )) \
        || fail "REGRESSION: /memory's reg totals only $(( total / 1024 / 1024 )) MB of the 512 MB QEMU was given — the property is present but its cells are wrong — see $log"
    note "/memory reg publishes $(( total / 1024 / 1024 )) MB across $nranges range(s)"
}

# _count_blue <ppm> — VGA attribute 1f is white on BLUE, and the console only ever
# paints grey on black, so this colour cannot arrive by accident. Shared by the
# mmio-writer and struct-device tracks: it IS the assertion in both, and a copy
# would be a second implementation of the thing under test.
_count_blue() {
  python3 - "$1" <<'PYC'
import sys
d=open(sys.argv[1],'rb').read()
i=d.index(b'255\n')+4
px=d[i:]
n=sum(1 for k in range(0,len(px)-2,3) if px[k:k+3]==b'\x00\x00\xa8')
print(n)
PYC
}

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
# THE X86 DICTIONARY IS openbios-x86.dict, NOT openbios.dict — and this lab had
# it backwards for months. arch/x86/build.xml declares
# `<dictionary name="openbios-x86" init="openbios">`: that is CUMULATIVE, "start
# from the openbios dict and add these", so openbios-x86.dict is a SUPERSET
# (105,812 → 109,032 bytes on 2026-08-23). The `.d` file lists only the
# incremental inputs, and POC-2 read that as "the overlay, not the system".
#
# Booting the base dict means booting x86 WITHOUT arch/x86/init.fs: no /memory,
# no /cpus, no /chosen preopens, and no set-defaults. That last omission is why
# the persistence tracks looked greener than the firmware was — see the
# `dict-identity` track, which exists so this cannot silently come back.
XDICT="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
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
            -initrd "$XDICT")
    else
      ROM="$CB/build-openbios/coreboot.rom"
      [[ -f "$ROM" ]] || skip "no ROM at $ROM — run ./build-coreboot-openbios.sh first"
      # THE ROM IS NOT IN THE TREE UNDER TEST, and until 2026-08-27 nothing said so.
      # Unlike the multiboot arm above — which boots straight out of $WORKDIR — this
      # one boots a ROM built at some earlier time from the linuxboot lab's tree. So
      # it PASSED against an empty $OPENBIOS_WORKDIR, reporting a prompt for a tree
      # that had never been built, and on this machine it spent two days reporting on
      # a payload that predated every fix in the tree beside it. Nothing errored: the
      # ROM is readable and it does answer 7. It was a record outliving its subject.
      PAYLOAD="$WORKDIR/openbios/obj-x86/openbios-builtin.elf"
      PROV="$("$REPO/tools/openbios-rom-provenance.sh" --check "$ROM" "$PAYLOAD" 2>&1)"; PRC=$?
      case $PRC in
        0)  note "provenance: $PROV" ;;
        77) skip "$PROV" ;;
        *)  fail "$PROV" ;;
      esac
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
      --send 'variable ap-probe  5 ap-probe !\r' --expect "0 > " \
      --send 'device-end  ." AP=" ap-probe @ . cr\r' --expect "0 > " \
      --send 'dev / ls\r' --expect "openprom" --expect "0 > " \
      --send 'dev /memory  .properties\r' --expect "0 > "
    RC=$?
    kill "$QPID" 2>/dev/null   # by PID, never by pattern
    # The x86 arm of the amd64 track's clean-prompt probe, and it is here as a
    # CONTROL: x86's preopen has always ended in device-end (init.fs:52), so
    # this has always passed. An assertion that only ever runs on the arch it
    # was written for cannot distinguish "the fix works" from "the probe cannot
    # fail". If this line ever goes red, the shared shape regressed, not amd64.
    if [[ $RC -eq 0 ]]; then
      assert_memory_reg "$LOG"
      grep -q 'AP=5' "$LOG" \
        || fail "REGRESSION: a variable defined at the x86 prompt did not survive device-end — arch/x86/init.fs's preopen has ended in device-end since forever, so the firmware is now leaving a node active the way amd64 used to — see $LOG"
      pass "OpenBIOS ($FLAVOR) answered 7 at the 0 > prompt, listed the device tree, and left no device node active (a prompt-defined variable survives device-end)"
    fi
    fail "no prompt conversation on the $FLAVOR track (rc=$RC) — see $LOG" ;;
  coreboot-amd64)
    # OPENBIOS IN LONG MODE, AS A COREBOOT PAYLOAD. The other half of the coreboot
    # story: arch/x86 has been a LinuxBIOS payload since 2003, arch/amd64 could not
    # be one at all because it built no embedded image. Patches 36-38 fixed that in
    # three steps that each hid the next -- build.xml had no IMAGE_ELF_EMBEDDED
    # rules (so `builtin-amd64` exited 0 having built nothing), builtin.c never
    # declared the array its own comment describes (so it could not compile), and
    # openbios.c knew only the multiboot dictionary path (so it reached long mode,
    # started Forth, and panicked with "no dictionary entry point").
    #
    # coreboot enters a payload in 32-bit protected mode, so the payload is the
    # ELF32 that arch/amd64/build.xml's objcopy produces; the firmware takes itself
    # to long mode. THE 64-BIT ASSERTION IS THE POINT OF THE TRACK -- a prompt alone
    # would be satisfied by the x86 ROM sitting in the tree next door.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    ROM="$CB/build-openbios-amd64/coreboot.rom"
    [[ -f "$ROM" ]] || skip "no ROM at $ROM — run ./build-coreboot-openbios.sh amd64 first"
    PAYLOAD="$WORKDIR/openbios/obj-amd64/openbios-builtin.elf32"
    PROV="$("$REPO/tools/openbios-rom-provenance.sh" --check "$ROM" "$PAYLOAD" 2>&1)"; PRC=$?
    case $PRC in
      0)  note "provenance: $PROV" ;;
      77) skip "$PROV" ;;
      *)  fail "$PROV" ;;
    esac
    note "booting the amd64 coreboot payload (accel=$ACCEL) → $LOG"
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -bios "$ROM" \
      -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
    QPID=$!
    python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 90 \
      --expect "0 > " \
      --send '3 4 + .\r' --expect "7 " \
      --send '-1 u.\r' --expect "> " \
      --send 'dev / ls\r' --expect "openprom" --expect "0 > " \
      --send 'dev /memory  .properties\r' --expect "0 > "
    RC=$?
    kill "$QPID" 2>/dev/null   # by PID, never by pattern
    if [[ $RC -eq 0 ]]; then
      assert_memory_reg "$LOG"
      grep -q 'ffffffffffffffff' "$LOG" \
        || fail "REGRESSION: the coreboot payload reached a prompt but '-1 u.' did not print ffffffffffffffff — a 32-bit firmware is answering, so this ROM is not carrying the amd64 payload — see $LOG"
      # THE COREBOOT MEMORY TABLE, asserted as a VALUE and not as "it printed
      # something". libopenbios/linuxbios.h used a plain uint64_t in a WIRE
      # format: the i386 ABI aligns that to 4 and x86-64 to 8, so the same struct
      # is 20 bytes compiled 32-bit and 24 compiled 64-bit. coreboot emits 20, so
      # this firmware strode `map[i]` by 24 over 20-byte records -- the first
      # entry read correctly and every one after it was garbage, ending in
      # "RAM 0 MB" (patch 39). A guard that only checked for the word "RAM" would
      # have passed throughout.
      RAMMB="$(grep -aoE '^RAM ([0-9]+) MB' "$LOG" | grep -oE '[0-9]+' | head -1)"
      [[ -n "$RAMMB" ]] \
        || fail "REGRESSION: the boot printed no 'RAM <n> MB' line at all — the coreboot table was not read — see $LOG"
      (( RAMMB >= 256 )) \
        || fail "REGRESSION: the firmware found only ${RAMMB} MB of the 512 MB QEMU was given — libopenbios/linuxbios.h has lost the aligned(4) lb_uint64_t (patch 39), so a 64-bit reader is striding 24 bytes over coreboot's 20-byte memory records — see $LOG"
      note "coreboot memory table: ${RAMMB} MB of the 512 MB given to QEMU"
      grep -q 'no dictionary entry point' "$LOG" \
        && fail "REGRESSION: 'panic: no dictionary entry point' is back — arch/amd64/openbios.c has lost the sys_info.dict_last branch (patch 38), so an embedded dictionary is being parsed as a dictionary FILE again — see $LOG"
      pass "OpenBIOS runs IN LONG MODE as a coreboot payload: the ROM's embedded dictionary reached the 0 > prompt, answered 7, printed ffffffffffffffff for '-1 u.' (64-bit cells, so this is arch/amd64 and not the x86 ROM beside it), and carries a device tree"
    fi
    fail "no prompt conversation on the coreboot-amd64 track (rc=$RC) — see $LOG" ;;

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
      -initrd "$XDICT" \
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
        -initrd "$XDICT" "${QEXTRA[@]}" \
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
    if ! grep -q "$NONCE" "$LOG.read"; then
      # TWO VERY DIFFERENT CAUSES LOOK THE SAME HERE, and this message used to
      # assert the first one. If the firmware found the backing and did NOT
      # re-format it, the bytes arrived: the value was read and then thrown
      # away, which is the set-defaults ordering bug (see dict-identity and
      # arch/x86/init.fs).
      if grep -q "nvram: backed by $WANT_BACKEND" "$LOG.read" && ! grep -q "zapping pram" "$LOG.read"; then
        fail "REGRESSION: the store arrived valid on $WANT_BACKEND and boot-file is still the default — the bytes made the round trip and something after nvconf_init reset /options; check that set-defaults is a PREPOST-initializer in arch/x86/init.fs, not a SYSTEM one — see $LOG.read"
      fi
      fail "REGRESSION: boot-file did not survive a power cycle — the store is not backed — see $LOG.read"
    fi
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
      -initrd "$XDICT" \
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
        -initrd "$XDICT" "${QEXTRA[@]}" \
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
      --send 'variable ap-probe  5 ap-probe !\r' --expect "0 > " \
      --send 'device-end  ." AP=" ap-probe @ . cr\r' --expect "0 > " \
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
    # THE PROMPT MUST BE CLEAN, and until 2026-08-26 amd64's was not: the last
    # preopen of the SYSTEM-initializer left /chosen active because
    # arch/amd64/init.fs's preopen was missing the device-end x86:52 has. That
    # is not cosmetic. active-package! sets CURRENT to the active node's method
    # list -- correct IEEE 1275, it is how `: open ... ;` becomes a node method
    # -- so with a node left open EVERY definition made at the prompt landed in
    # /chosen and vanished the instant anything called device-end:
    #
    #     0 > variable la  5 la !  la @ .    5  ok
    #     0 > device-end  la @ .             la: undefined word.
    #
    # The assertion is the OUTCOME -- a word defined at the prompt is still
    # there after device-end -- not `active-package u.`, which is the
    # mechanism and would keep passing if the walk were fixed some other way.
    # The x86 arm of this same probe lives in the multiboot track, where it has
    # ALWAYS passed: that is the control proving this assertion is not vacuous.
    grep -q 'AP=5' "$LOG" \
      || fail "REGRESSION: a variable defined at the amd64 prompt did not survive device-end — the firmware is coming up with a device node still active (it was /chosen), so every definition made at the prompt is quietly a node method — see $LOG"
    # ── 2/2: does a 64-bit firmware see memory ABOVE 4 GiB? ─────────────────
    # The whole premise of the port, and it was false until 2026-08-28. The
    # Multiboot info struct's fields were fixed to uint32_t in Spike 1 with a
    # comment explaining that they are wire-format -- but the two structs in the
    # UNION immediately before mmap_length/mmap_addr kept `unsigned long`. On LP64
    # that union is 32 bytes instead of 16, so those two fields were read at offset
    # 64 where Multiboot says 44. The firmware got garbage, computed ZERO map
    # entries, printed "Multiboot mmap is broken", and fell back to
    # mem_lower/mem_upper -- which cannot express anything above 4 GiB.
    #
    # It did not crash and it did not print an absurd number: with -m 5G it said
    # 3071 MB, which looks like an answer. Only asking for MORE than 4 GiB and
    # checking the total against what QEMU was given can tell those apart, which is
    # why this boots a second time rather than reusing the -m 512 boot above.
    HILOG="$LOG.highmem"
    note "2/2 booting with -m 5G — does it see past 4 GiB? → $HILOG"
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 5G -kernel "$MB" -initrd "$DICT" \
      -display none -serial "file:$HILOG" -no-reboot >/dev/null 2>&1 &
    HPID=$!
    sleep 20
    kill "$HPID" 2>/dev/null   # by PID, never by pattern
    wait "$HPID" 2>/dev/null
    grep -qa 'Multiboot mmap is broken' "$HILOG" \
      && fail "REGRESSION: 'Multiboot mmap is broken' — the Multiboot info struct's offsets are wrong again, so the firmware fell back to mem_lower/mem_upper and cannot see above 4 GiB (arch/amd64/multiboot.h: the aout/elf structs in the union must be uint32_t, not unsigned long) — see $HILOG"
    HIMB="$(grep -aoE '^RAM ([0-9]+) MB' "$HILOG" | grep -oE '[0-9]+' | head -1)"
    [[ -n "$HIMB" ]] \
      || fail "REGRESSION: the -m 5G boot printed no 'RAM <n> MB' line at all — see $HILOG"
    (( HIMB >= 4096 )) \
      || fail "REGRESSION: with 5 GB the firmware found only ${HIMB} MB — it is not seeing memory above 4 GiB, which is the premise of the whole port. 3071 MB specifically means the Multiboot mmap was rejected and mem_lower/mem_upper answered instead — see $HILOG"
    note "with -m 5G the firmware sees ${HIMB} MB"

    pass "SPIKE 1: QEMU booted a 64-bit ELF (via the multiboot a.out kludge) and the firmware runs in long mode — 0 > answered 7, '-1 u.' printed ffffffffffffffff, the device tree is there, a variable defined at the prompt survives device-end (no node left active), and with -m 5G it sees ${HIMB} MB, i.e. past the 4 GiB that mem_lower/mem_upper can express"
    ;;
  amd64-fault)
    # SPIKE 2, first half: the 64-bit exception layer.
    #
    # Before this, the firmware had NO IDT: the first exception was a triple
    # fault and the machine simply vanished -- which is precisely how Spike 1's
    # SSE bug presented, and why it cost a debug session to find.
    #
    # The fault is provoked ABOVE the identity map rather than at address 0. A
    # null-write trap was built and REVERTED: page 0 on a PC holds the real-mode
    # IVT and the BIOS Data Area, and this firmware's console reads the BDA to
    # find the VGA CRTC port, so unmapping it faults during boot.
    #
    # AND THE ADDRESS MOVED ONCE ALREADY. It was 0x100000000 until P3 extended
    # the map to 5 GiB to reach the pmem store -- at which point this track went
    # red, because the write it counts on faulting simply SUCCEEDED. That is the
    # track doing its job: the fault address is a property of the memory map,
    # not a constant, and pinning it to 8 GiB only holds until something maps
    # that too. If this fails again, check the map before the handler.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    MB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    DICT="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    [[ -f "$MB" && -f "$DICT" ]] || skip "no amd64 image — run ./build-openbios.sh amd64 first"
    grep -q 'amd64_exception' "$WORKDIR/openbios/arch/amd64/exception.c" 2>/dev/null \
      || skip "no arch/amd64/exception.c in the clone — this track measures the exception layer"
    note "provoking a page fault above 4 GiB → $LOG"
    rm -f "$SOCK" "$LOG"
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DICT" \
      -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
    QPID=$!
    python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 90 \
      --expect "0 > " \
      --send '0 200000000 !\r' --expect "page fault" --expect "0 > " \
      --send '0 210000000 !\r' --expect "page fault" --expect "0 > " \
      --send '0 220000000 !\r' --expect "page fault" --expect "0 > " \
      --send '3 4 + .\r' --expect "7 " --expect "0 > " \
      --send 'dev / ls\r' --expect "nvram" --expect "0 > "
    RC=$?
    kill "$QPID" 2>/dev/null   # by PID, never by pattern
    # THE FAILURE MESSAGE HAS TO NAME THE RIGHT DEFECT. A wedged recovery times
    # out waiting for the prompt, which the driver reports identically to "the
    # fault never happened" -- and the control run proved that: it printed "no
    # named fault" about a run whose fault was named perfectly. Look before
    # blaming.
    if [[ $RC -ne 0 ]]; then
      grep -q 'Unexpected Exception: page fault' "$LOG" \
        && fail "REGRESSION: the fault WAS named and the prompt never came back (rc=$RC) — recovery wedged: this is the do_nothing-return shape arch/amd64/exception.c was rewritten to replace — see $LOG"
      fail "no named fault at the 64-bit prompt (rc=$RC) — see $LOG"
    fi

    grep -q 'Unexpected Exception: page fault' "$LOG" \
      || fail "REGRESSION: the fault was not NAMED — the IDT is gone or its gates are wrong, and an unnamed fault is a triple fault waiting to happen — see $LOG"
    # The faulting address is the whole point: CR2, not the frame, and it must
    # be the 4 GiB one we asked for rather than whatever else went wrong.
    grep -q 'Faulting address: 0000000200000000' "$LOG" \
      || fail "REGRESSION: the handler named a page fault but not at 0x200000000 — it is reporting CR2 wrongly, a DIFFERENT fault beat ours to it, or the identity map has grown to cover 8 GiB — see $LOG"
    grep -q 'dstackcnt=' "$LOG" \
      || fail "the dump carries no Forth engine state — see $LOG"

    # SURVIVING A FAULT IS NOT THE SAME AS RECOVERING FROM ONE, and until
    # 2026-08-23 this track recorded the difference as a known limit: the
    # machine printed its dump, printed one " ok", and then accepted no
    # further input -- alive and not listening.
    #
    # The cause was arch/x86's recovery shape, which arch/amd64 had copied:
    # zero the Forth stacks, aim PC at the outer interpreter, and resume at a
    # do-nothing function so the C stack unwinds back into enterforth's loop.
    # That loop is `while (rstackcnt > tmp)` with tmp captured at ENTRY, so
    # `rstackcnt = 0` makes it false for every enterforth frame on the stack:
    # measured, the frame it returned into had tmp=8 and exited without
    # calling next() once, and four nested frames unwound the same way. The
    # PC was never executed. arch/amd64/exception.c now abandons the faulted
    # stack instead -- iretq onto _estack and re-enter the interpreter.
    #
    # So the assertion is the OUTCOME, not the mechanism: type at the prompt
    # after the fault and require an answer. Three faults in a row are driven
    # because a recovery that works once and wedges on the second is a
    # different bug wearing this one's clothes.
    grep -qE '^0 > 3 4 \+ \. 7' <(tr -d "\r" < "$LOG") \
      || fail "REGRESSION: the prompt does not answer after a fault — the machine survived but stopped listening, which is the wedge arch/amd64/exception.c was rewritten to fix — see $LOG"
    grep -q 'nvram' "$LOG" \
      || fail "REGRESSION: the device tree does not walk after a fault — recovery re-entered the interpreter but the dictionary did not survive it — see $LOG"
    FAULTS=$(grep -ac 'Faulting address: 00000002' <(tr -d "\r" < "$LOG"))
    [[ "$FAULTS" -eq 3 ]] \
      || fail "REGRESSION: expected 3 recovered page faults, saw $FAULTS — a later fault was not caught, or the 'second fault before restart' guard fired — see $LOG"
    grep -q 'halting' "$LOG" \
      && fail "REGRESSION: the handler halted instead of recovering — see $LOG"
    pass "SPIKE 2 (exceptions): three page faults above the identity map, each NAMED with CR2 and a full machine+Forth dump, each RECOVERED — the prompt answers 7 and still walks the device tree afterwards"
    ;;
  amd64-ctx)
    # SPIKE 2, second half: the context switch, and the checkpoint's own words --
    # "the client-program context still switches back to the prompt".
    #
    # `test-ctx-switch` runs THE SAME MACHINERY a client program uses:
    # init_context builds a frame on a fresh stack, the entry point is planted
    # by hand, switch_to() runs it, the callee sets 0x5A and RETURNS -- which
    # lands on __exit_context and switches back. A switch that never came back
    # cannot fake this: the word simply never returns and the prompt never comes,
    # so the timeout is itself a failure mode this track detects.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    MB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    DICT="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    [[ -f "$MB" && -f "$DICT" ]] || skip "no amd64 image — run ./build-openbios.sh amd64 first"
    grep -q 'context_self_test' "$WORKDIR/openbios/arch/amd64/context.c" 2>/dev/null \
      || skip "no context_self_test in the clone — this track measures the switch"
    note "switching into a client context and back → $LOG"
    rm -f "$SOCK" "$LOG"
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DICT" \
      -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
    QPID=$!
    python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 90 \
      --expect "0 > " \
      --send 'test-ctx-switch .\r' --expect "0 > " \
      --send '3 4 + .\r' --expect "7 " \
      --send '-1 u.\r' --expect "ffffffffffffffff"
    RC=$?
    kill "$QPID" 2>/dev/null   # by PID, never by pattern
    [[ $RC -eq 0 ]] || fail "the prompt did not come back after switching into a client context (rc=$RC) — see $LOG"

    # 0x5A is set BY THE CODE RUNNING IN THE OTHER CONTEXT. Without it the word
    # could return 0 through a switch that never actually ran anything, and the
    # prompt coming back would prove only that nothing happened.
    grep -q '^0 > test-ctx-switch \. switching to new context:' "$LOG" \
      || fail "switch_to() was not reached — see $LOG"
    grep -q '5a  ok' "$LOG" \
      || fail "REGRESSION: the client context did not set its flag — the switch returned without running the entry point, so the round trip is a no-op — see $LOG"
    # And the engine must still be intact afterwards, not merely responsive.
    grep -q 'ffffffffffffffff' "$LOG" \
      || fail "REGRESSION: the prompt came back but the 64-bit cell did not survive the round trip — see $LOG"
    pass "SPIKE 2 (context): switched into a client context, it ran and set 0x5a, __exit_context switched back, and the prompt still evaluates 7 and ffffffffffffffff"
    ;;
  amd64-pmem)
    # P3: the ONE backing that needed the port.
    #
    # IDE sectors, CFI flash and a floppy are all reachable from the 32-bit
    # firmware and were built there. A file-backed pmem region is not: QEMU
    # places device memory at 0x100000000 on -M pc, and that is the first
    # address a 32-bit firmware cannot form. Reaching it is what Spikes 1-2
    # were for.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    MB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    DICT="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    [[ -f "$MB" && -f "$DICT" ]] || skip "no amd64 image — run ./build-openbios.sh amd64 first"
    grep -q 'PMEM_BASE' "$WORKDIR/openbios/arch/amd64/openbios.c" 2>/dev/null \
      || skip "no pmem backing in arch/amd64/openbios.c — this track measures P3"

    NV="$WORKDIR/pmem-store.img"
    rm -f "$NV"; truncate -s 64M "$NV"
    BEFORE=$(sha256sum "$NV" | cut -d" " -f1)
    # shellcheck disable=SC2054  # the commas are INSIDE one QEMU option string,
    # not element separators; splitting on them would hand qemu five bad options.
    PM=(-object "memory-backend-file,id=nv,share=on,mem-path=$NV,size=64M"
        -device nvdimm,id=nv1,memdev=nv)
    _pboot() { # _pboot <log> <send-args...>; QEXTRA holds the pmem device or not
      local log="$1"; shift
      rm -f "$SOCK" "$log"
      qemu-system-x86_64 -M "pc,accel=$ACCEL,nvdimm=on" -m 512,slots=2,maxmem=2G \
        -kernel "$MB" -initrd "$DICT" "${QEXTRA[@]}" \
        -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
      local q=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$log" --timeout 90 "$@" >/dev/null 2>&1
      local rc=$?
      kill "$q" 2>/dev/null   # by PID, never by pattern
      sleep 1
      return $rc
    }

    note "1/3 writing the store to pmem at 0x100000000 → $LOG.write"
    QEXTRA=("${PM[@]}")
    _pboot "$LOG.write" --expect "0 > " \
      --send 'setenv boot-file P3-PMEM\r' --expect "0 > " \
      --send '" /nvram" " update-nvram" execute-device-method .\r' --expect "0 > " \
      || fail "no prompt conversation while writing the pmem store — see $LOG.write"
    grep -q 'nvram: backed by pmem@0x100000000' "$LOG.write" \
      || fail "REGRESSION: the store is not backed by pmem — the identity map may no longer reach past 4 GiB, or the probe found nothing there — see $LOG.write"
    AFTER=$(sha256sum "$NV" | cut -d" " -f1)
    [[ "$BEFORE" != "$AFTER" ]] \
      || fail "REGRESSION: the firmware reported a pmem backing and the host file is byte-identical — the write went nowhere"
    note "   host pmem image changed: ${BEFORE:0:12}… → ${AFTER:0:12}…"
    grep -q 'boot-file=P3-PMEM' <(strings "$NV" 2>/dev/null | head -200) \
      || fail "the value is not in the host image — see $LOG.write"

    note "2/3 fresh QEMU process, same pmem file → $LOG.read"
    QEXTRA=("${PM[@]}")
    _pboot "$LOG.read" --expect "0 > " --send 'printenv boot-file\r' --expect "0 > " \
      || fail "no prompt conversation on the read-back boot — see $LOG.read"
    grep -q 'nvram: backed by pmem@0x100000000' "$LOG.read" \
      || fail "the read-back boot did not find the pmem store — see $LOG.read"
    # The STRUCTURE survived if the store did not have to be re-formatted.
    grep -q 'zapping pram' "$LOG.read" \
      && fail "REGRESSION: the pmem store was re-formatted on the read-back boot — it did not arrive valid — see $LOG.read"

    note "3/3 control: identical boot with NO nvdimm attached → $LOG.control"
    QEXTRA=()
    _pboot "$LOG.control" --expect "0 > " --send 'printenv boot-file\r' --expect "0 > " \
      || fail "no prompt conversation on the control boot — see $LOG.control"
    grep -q 'no memory at 0x100000000' "$LOG.control" \
      || fail "the control did not report an absent region — the presence probe is not probing, so a 'backed' verdict means nothing — see $LOG.control"

    # THE VALUE ITSELF, not just the bytes. Until 2026-08-23 this was a
    # recorded gap: the store round-tripped structurally and `printenv` still
    # showed the compile-time default. The cause was NOT amd64's addressing --
    # running `nvram-load-configs` by hand at the prompt, on the same store,
    # set every variable correctly. It was WHEN set-defaults runs.
    #
    # arch/amd64/init.fs (and arch/x86/init.fs, and ia64's) registered
    # set-defaults as a SYSTEM-initializer. arch_init -- which calls
    # nvconf_init() -- is registered from C as a PREPOST-initializer, and
    # PREPOST runs first, so the store was read, parsed, applied to /options,
    # and then overwritten with defaults every boot. ppc/qemu, sparc32 and
    # sparc64 all say PREPOST-initializer. amd64 and x86 now do too.
    grep -q 'P3-PMEM' "$LOG.read" \
      || fail "REGRESSION: the store arrived valid and the config variable is still the default — something after nvconf_init is resetting /options; check that set-defaults is a PREPOST-initializer in arch/amd64/init.fs, not a SYSTEM one — see $LOG.read"
    grep -q 'P3-PMEM' "$LOG.control" \
      && fail "REGRESSION: the no-nvdimm control saw P3-PMEM — this check cannot fail and proves nothing"
    pass "P3: the store lives in pmem at 0x100000000 — above 4 GiB, reachable only in long mode — the host image changed, the value is in it, the structure survived a power cycle, boot-file reads back as P3-PMEM, and the no-nvdimm control saw neither the region nor the value"
    ;;
  dict-identity)
    # WHICH DICTIONARY IS THE X86 FIRMWARE ACTUALLY RUNNING?
    #
    # This lab booted `openbios.dict` on x86 for months, on a conclusion
    # POC-2 wrote down as a pitfall -- *"openbios-x86.dict is NOT the
    # dictionary; the <platform> name is the decoy"*. That conclusion was
    # drawn while chasing a panic whose real cause was elsewhere
    # (load_dictionary was never called), and nobody re-derived it once the
    # panic was fixed. A cached fact outliving its evidence, in a document.
    #
    # arch/x86/build.xml says `<dictionary name="openbios-x86" init="openbios">`
    # -- CUMULATIVE: start from the openbios dict, then add arch/x86/init.fs.
    # The `.d` file lists only the increment, which is what "overlay" was read
    # off. The superset is bigger, and it carries /memory, /cpus, the /chosen
    # preopens and set-defaults. Booting the base dict quietly ran x86 without
    # any of them -- which is exactly why the persistence tracks looked
    # greener than the firmware was.
    #
    # So this track asks the question two ways that can both fail: the file
    # sizes, and what the running device tree contains. The base-dict boot IS
    # the control -- it must NOT show the nodes.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    BASE="$WORKDIR/openbios/obj-x86/openbios.dict"
    [[ -f "$MB" && -f "$XDICT" && -f "$BASE" ]] \
      || skip "no x86 images — run ./build-openbios.sh x86 first"

    SZ_ARCH=$(stat -c%s "$XDICT"); SZ_BASE=$(stat -c%s "$BASE")
    note "openbios.dict=$SZ_BASE bytes, openbios-x86.dict=$SZ_ARCH bytes"
    [[ "$SZ_ARCH" -gt "$SZ_BASE" ]] \
      || fail "REGRESSION: \$XDICT ($SZ_ARCH bytes) is not larger than openbios.dict ($SZ_BASE) — most likely XDICT is pointed back at the base dict; failing that, the build changed or the 'overlay' reading was right after all"

    _dboot() { # _dboot <dict-path> <log>
      rm -f "$SOCK" "$2"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$1" \
        -display none -serial "unix:$SOCK,server=on" -no-reboot >/dev/null 2>&1 &
      local q=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$SOCK" "$2" --timeout 60 \
        --expect "0 > " --send 'dev / ls\r' --expect "0 > " >/dev/null 2>&1
      local rc=$?
      kill "$q" 2>/dev/null   # by PID, never by pattern
      sleep 1
      return $rc
    }
    # `dev / ls` prints "<hex-phandle> <name>"; anchor on that shape so the
    # word appearing in prose cannot pass for a node.
    #
    # THE `@unit` SUFFIX IS OPTIONAL AND THAT IS NOT LAXITY. A 1275 node carrying a
    # `reg` has a unit address, and `ls` prints the full name -- so the moment
    # patch 40 started publishing /memory's map, this node went from `memory` to
    # `memory@0` and this assertion failed while nothing was broken. That is the
    # second direction of the mechanism-not-outcome trap in CLAUDE.md, the
    # expensive one: an assertion that fails when the mechanism is replaced by a
    # BETTER one. The outcome being tested is "the arch dict carries this node",
    # and a unit address does not change that. Still anchored, so `memoryfoo` or a
    # word in prose cannot match.
    _has() { grep -qE "^[0-9a-f]+ $2(@[0-9a-f,]+)?[[:space:]]*\$" <(tr -d "\r" < "$1"); }

    note "1/2 booting the ARCH dict → $LOG.arch"
    _dboot "$XDICT" "$LOG.arch" || fail "no prompt on the arch-dict boot — see $LOG.arch"
    for n in memory cpus; do
      _has "$LOG.arch" "$n" \
        || fail "REGRESSION: /$n is missing from the device tree with openbios-x86.dict — that node exists ONLY because arch/x86/init.fs is in the dictionary, so the firmware is not running the arch dict — see $LOG.arch"
    done

    note "2/2 control: the BASE dict, which must NOT have them → $LOG.base"
    _dboot "$BASE" "$LOG.base" || fail "no prompt on the base-dict control boot — see $LOG.base"
    for n in memory cpus; do
      _has "$LOG.base" "$n" \
        && fail "the base dict ALSO carries /$n — then these two dictionaries no longer differ in the way this track measures, and its arch-dict assertion above cannot fail — re-derive what openbios.dict contains before trusting either — see $LOG.base"
    done
    grep -qE '^[0-9a-f]+ openprom[[:space:]]*$' <(tr -d "\r" < "$LOG.base") \
      || fail "the base-dict control did not produce a device tree at all — it proves nothing about /memory — see $LOG.base"

    pass "the x86 tracks boot openbios-x86.dict ($SZ_ARCH bytes, the superset): /memory and /cpus are in the running device tree, and the base openbios.dict ($SZ_BASE bytes) boots to a prompt WITHOUT them"
    ;;
  amd64-linux)
    # SPIKE 3: the 64-bit firmware boots Linux.
    #
    # THE ASSERTION IS THE OUTCOME -- u-root's banner -- and not any of the
    # five mechanisms that had to be right to reach it. That matters here more
    # than usual, because every one of those mechanisms failed SILENTLY while
    # the firmware itself kept reporting success:
    #
    #   1. CONFIG_FSYS_ISO9660 was false, so the loader never saw a file.
    #   2. arch/amd64 does not relocate, so it is sitting at the 1 MiB a
    #      bzImage runs at -- the read overwrote the running firmware and the
    #      machine stopped mid-word, with no fault to report.
    #   3. the copy stub then demolished the page tables it was translated
    #      through (they are in .bss at 0x184000, inside the destination).
    #   4. the initrd placement inherited x86's "we are at the top of RAM"
    #      assumption, and `end - size` UNDERFLOWED to 0xff501000.
    #   5. `unsigned long type` made struct e820entry 24 bytes instead of 20,
    #      so the kernel saw one memory range instead of two, decided it had
    #      640 KiB, and panicked in init_mem_mapping BEFORE console_init --
    #      the panic went to the printk ring buffer and never to a console.
    #
    # Defect 5 is the one to keep in mind when reading this track: the kernel
    # was RUNNING and completely silent. A track asserting "no error appeared
    # on the console" would have passed. Only "u-root said hello" catches it.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v genisoimage >/dev/null || skip "genisoimage not installed"
    MB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    DICT="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    [[ -f "$MB" && -f "$DICT" ]] || skip "no amd64 image — run ./build-openbios.sh amd64 first"
    KERNEL="${KERNEL:-$HOME/linuxboot-lab/payload-bzImage}"
    INITRD="${INITRD:-$HOME/linuxboot-lab/uroot.cpio}"
    [[ -f "$KERNEL" ]] || skip "no kernel at $KERNEL (set KERNEL=; an x86_64 bzImage)"
    [[ -f "$INITRD" ]] || skip "no initrd at $INITRD (set INITRD=; a cpio the kernel can unpack)"
    # Drive the SHIPPED showcase rather than re-implementing its boot line: a
    # copy of a harness drifts from it and then proves something about the copy.
    note "handing off to showcase-rival-boots-linux.sh amd64"
    OUT="$($HERE/showcase-rival-boots-linux.sh amd64 2>&1)"; RC=$?
    printf '%s\n' "$OUT" | sed 's/^/    /'
    [[ $RC -eq 77 ]] && skip "showcase skipped: $(printf '%s' "$OUT" | tail -1)"
    [[ $RC -eq 0 ]] \
      || fail "REGRESSION: the 64-bit firmware no longer boots Linux to u-root (rc=$RC) — see $WORKDIR/showcase-amd64.log; the five silent failure modes in this track's comment are where to look"
    # The showcase already required "Welcome to u-root", but assert the memory
    # map here too: defect 5 is invisible at the banner (a 640 KiB machine and
    # a 512 MiB one both reach u-root or both do not, depending only on how
    # much the kernel needs) and this is the cheap way to keep it honest.
    LOG="$WORKDIR/showcase-amd64.log"
    N=$(grep -ac 'BIOS-e820: \[mem ' <(tr -d "\r" < "$LOG") || true)
    [[ "$N" -eq 2 ]] \
      || fail "REGRESSION: the kernel logged $N e820 entries, expected 2 — struct e820entry has drifted off the 20-byte zero-page ABI again (the LINUX_ABI_ASSERT in arch/amd64/linux_load.c should have caught this at BUILD time; if it did not, it has been disabled) — see $LOG"
    grep -q 'Moving kernel' "$LOG" \
      || fail "the kernel was not staged-and-copied — arch/amd64 has started relocating itself, or load_linux_header's address changed; the handoff stub's reason for existing is gone and this track no longer proves it — see $LOG"
    pass "SPIKE 3: the 64-bit firmware boots Linux — one line at the 0 > prompt stages a bzImage above the firmware, copies it over the firmware from a stub in low memory, enters at +0x200 in long mode, and reaches u-root with both e820 ranges intact"
    ;;
  property-abi)
    # TODO 13.2: the 1275 encode/decode wordset at a 64-bit cell.
    #
    # A CHARACTERIZATION TRACK, not a pass/fail on correctness. Three defects in
    # forth/device/property.fs had been READ but never WATCHED TO BITE; this runs
    # them on BOTH arches and asserts the disagreement, because the disagreement
    # is the defect's signature:
    #
    #   (a) l@-be accumulates 4 bytes into a CELL, zero-extending. So the same
    #       four bytes decode to -1 on a 32-bit cell and ffffffff on a 64-bit one.
    #       forth/admin/devices.fs:434 compares a decoded int against a phandle.
    #   NOTE ON `[']` BELOW, because the first draft got this wrong and shipped
    #   the wrong reason. `' encode-int catch` inside the probe's if/else failed
    #   with a nameless ": undefined word.", and that was written up as "a tick
    #   in evaluated text parses an empty name". It is not. Measured 2026-08-27:
    #   `'` works fine at the top level of evaluated text, and fails only INSIDE
    #   an interpreted if...then -- because bootstrap.fs:201's `if` calls
    #   setup-tmp-comp, which switches to COMPILE state and builds the body as a
    #   temporary definition that `then` executes afterwards. A non-immediate
    #   word like `'` is therefore compiled and runs when >in is already past the
    #   whole construct, so its parse-word returns nothing. `[']` is immediate,
    #   parses at compile time, and works. Standard Forth, not a firmware defect:
    #   an interpreted `if` here IS a definition.
    #
    #   (b) FIXED (patch 26). l!-be used to mask to 4 bytes with no overflow
    #       check, so a value >= 2^32 was silently truncated -- and the tree
    #       encodes ihandles through this path, so /chosen's stdin could name a
    #       different object with nothing reporting it. It now REFUSES by name:
    #       LIED down to HALTED. Still UNREPRESENTABLE on x86, which is an
    #       UNKNOWN and is reported as one rather than as a pass.
    #   (c) FIXED (patch 27). encode+ was `nip +` -- adjacency-by-assumption, not
    #       concatenation. AND THE LENGTH IS NOT WHAT IT GOT WRONG: 13.2 recorded
    #       it as "lies about the length" and the control disproved that. `nip +`
    #       returns l1+l2, which is right; what it returns is the wrong ARRAY --
    #       a1 followed by whatever sits at a1+l1. With one `allot` forced
    #       between the fragments the second decode-int came back 30302f63, the
    #       gap read as an integer. Bit on BOTH arches, so it was never a 64-bit
    #       issue; 13.2 called it "correct today", and today was doing the work in
    #       that sentence.
    #
    # IF THIS TRACK FAILS SAYING "appears FIXED", that is good news and not a
    # regression: somebody changed the wordset. Update the expectations here and
    # TODO 13.2 together.
    #
    #   (d) decode-bytes -- the only one of the four that is FIXED here rather
    #       than characterized. It had two bare `r>` and no `>r`, so it took two
    #       cells off the RETURN stack and left them on the data stack: six items
    #       out where four are documented, and it RETURNED, which is worse than
    #       the crash this comment used to predict. The first `r>` is a
    #       transposed `>r` (patch 25); the assertion is the DEPTH, and it runs
    #       last so that a robbed stack could not have invalidated (a)-(c).
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v genisoimage >/dev/null || skip "genisoimage not installed"
    AMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    ADI="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    XMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    XDI2="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
    for f in "$AMB" "$ADI" "$XMB" "$XDI2"; do
      [[ -f "$f" ]] || skip "missing $f — run ./build-openbios.sh amd64 and x86 first"
    done
    # The probe is multi-line Forth LOADED OFF MEDIA. That is only possible since
    # patches 14/15/16; before them `load` could not reach (init-program) and every
    # line had to be typed through the firmware's ~80-char input truncation.
    PST="$WORKDIR/prop-stage"; rm -rf "$PST"; mkdir -p "$PST"
    cat > "$PST/PROP.FTH" <<'FTH'
\ TODO 13.2 probe. Base is HEX.
." P132-START" cr
create tgt 20 allot
." cell-bits=" 1 cells 8 * . cr
\ FIRST, before this probe decodes anything of its own: the counters as the
\ BOOT left them. Read at the end instead and the measurement includes the
\ measurer -- section (a) below decodes ffffffff on purpose.
." a-decodes-boot=" l@be-count @ . cr
." a-signbit-boot=" l@be-signbit @ . ." a-last-boot=" l@be-last @ . cr
-1 encode-int decode-int
." a-decoded=" dup . cr
-1 = if ." a-ROUNDTRIP-OK" else ." a-ROUNDTRIP-BROKEN" then cr
2drop
100000000 dup 0= if
  drop ." b-UNREPRESENTABLE-ON-THIS-CELL" cr
else
  ['] encode-int catch ?dup if
    ." b-REFUSED=" . cr
  else
    decode-int
    ." b-decoded=" dup . cr
    100000000 = if ." b-WIDE-OK" else ." b-WIDE-TRUNCATED" then cr
  then
then
clear
ffffffff encode-int 2drop ." b-ctl-u32-OK" cr
-1 encode-int 2drop ." b-ctl-neg-OK" cr
\ TODO 16: write where the caller says, and do not move HERE doing it.
tgt 20 ff fill
here
12345678 tgt int!
here = if ." s-int-HERE-UNCHANGED" else ." s-int-HERE-MOVED" then cr
12345678 encode-int drop
tgt swap 4 comp 0= if ." s-int-BYTES-MATCH" else ." s-int-BYTES-DIFFER" then cr
tgt 20 ff fill
here
" ab" tgt string!
here = if ." s-str-HERE-UNCHANGED" else ." s-str-HERE-MOVED" then cr
." s-str-len=" " ab" /string . cr
." s-str-nul=" tgt 2 + c@ . cr
." s-str-txt=" tgt 2 type cr
clear
\ TODO 16, the cursor: a whole structure at an address the caller chose,
\ then read back with the stock 1275 decoder.
tgt 20 ff fill
here
tgt
11111111 swap int!+
22222222 swap int!+
33333333 swap int!+
tgt - ." w-advanced=" dup . cr
drop
here = if ." w-HERE-UNCHANGED" else ." w-HERE-MOVED" then cr
tgt c decode-int ." w-i1=" . cr
decode-int ." w-i2=" . cr
decode-int ." w-i3=" . cr
2drop
clear
3 encode-int
4 encode-int
3 pick 3 pick + 2 pick = if ." c-fast-ADJACENT" else ." c-fast-NOT" then cr
encode+
." c-fast-len=" dup . cr
decode-int ." c-fast-i1=" . cr
decode-int ." c-fast-i2=" . cr
2drop
1 encode-int
10 allot
2 encode-int
3 pick 3 pick + 2 pick = if ." c-slow-ADJACENT" else ." c-slow-NOT" then cr
encode+
." c-slow-len=" dup . cr
decode-int ." c-slow-i1=" . cr
decode-int ." c-slow-i2=" . cr
2drop
dev /
." e-len-root=" 0 0 0 0 encode-phys nip . cr
clear
dev /ide@1
." e-len-ide=" 0 0 0 0 encode-phys nip . cr
clear
dev /pci8086,1237@0/QEMU,VGA@2
." e-len-vga=" 0 0 0 0 encode-phys nip . cr
clear
\ TODO 17.1 PRE-CHECK: the PARENT half of a `ranges` entry, taken at the bus
\ where one lives. A ranges entry is (child-phys, PARENT-phys, child-size), and
\ its three strides come from two different nodes: the child halves use the
\ bus's own #address-cells 3 / #size-cells 2 (patch 34) while the parent half
\ is encoded in the ROOT's cells. decode-phys IS my-#acells calls to
\ decode-int, so this is decode-int's CALLING CODE at exactly the seam a root
\ #address-cells change moves -- and it is written to hold at 1 cell and at 2,
\ so it can be landed BEFORE the root moves and then say whether the move broke
\ anything. The cells are read back with explicit decode-ints rather than by
\ counting stack items, because how many items decode-phys leaves is itself a
\ function of my-#acells: an earlier draft printed the remaining LENGTH at one
\ cell and the low ADDRESS cell at two, from the same line.
clear
dev /pci8086,1237@0
." r-pacells=" my-#acells . cr
" #address-cells" active-package get-package-property 0= if
  decode-int nip nip ." r-cacells=" . cr else ." r-cacells-NONE" cr then
" #size-cells" active-package get-package-property 0= if
  decode-int nip nip ." r-cscells=" . cr else ." r-cscells-NONE" cr then
0 0 deadbeef c0000000 encode-phys
." r-plen=" 2dup nip . cr
2dup decode-int nip nip ." r-c0=" u. cr
2dup decode-int drop decode-int nip nip ." r-c1=" u. cr
clear
." d-depth-pre=" depth . cr
" ab" encode-bytes 2 decode-bytes
." d-depth=" depth . cr
." d-data=" 2dup type cr
2drop
." d-len2=" . cr
drop
." d-depth-post=" depth . cr
." a-signbit-end=" l@be-signbit @ . cr
\ Review 2's fourth assertion, and the UNKNOWN under it: does /chosen's
\ stdin survive a round trip, and where do instances actually land?
." h-live=" stdin @ . cr
" stdin" " /chosen" find-dev drop get-package-property 0= if
  decode-int nip nip ." h-prop=" . cr
else
  ." h-NOPROP" cr
then
." h-hi=" /n /l = if 0 else stdin @ 20 rshift then . cr
\ The must-NOT-match control, in the same run: a DIFFERENT ihandle from the
\ same node must not compare equal, or "they matched" would be a sentence about
\ the comparison rather than about the round trip.
" stdout" " /chosen" find-dev drop get-package-property 0= if
  decode-int nip nip ." h-other=" . cr
else
  ." h-NOOTHER" cr
then
clear
." P132-END" cr
FTH
    genisoimage -quiet -o "$WORKDIR/prop.iso" -V PROPISO -r -J "$PST"
    note "running the probe on both arches → $WORKDIR/prop-{amd64,x86}.log"
    for A in amd64 x86; do
      if [[ "$A" == amd64 ]]; then MB="$AMB"; DI="$ADI"; else MB="$XMB"; DI="$XDI2"; fi
      PSOCK="$WORKDIR/pa-$A.sock"; PLOG="$WORKDIR/prop-$A.log"; rm -f "$PSOCK" "$PLOG"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DI" \
        -cdrom "$WORKDIR/prop.iso" -display none -serial "unix:$PSOCK,server=on" \
        -no-reboot >/dev/null 2>&1 &
      PQ=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$PSOCK" "$PLOG" --timeout 120 \
        --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\prop.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "P132-END"
      PRC=$?
      kill "$PQ" 2>/dev/null   # by PID, never by pattern
      # THE (d) LINE IS READ BEFORE THE rc GATE, and the control is why. A
      # decode-bytes that robs the return stack does not merely leave six items:
      # it derails the rest of the evaluation, so the run times out and the
      # GENERIC message below fires — blaming patches 14/15/16 for a defect the
      # probe had already measured and printed two lines earlier. A failure that
      # names the wrong subject is worse than a slow one.
      grep -qF 'b-WIDE-TRUNCATED' "$PLOG" \
        && fail "REGRESSION: 13.2(b) is back on $A — a value >= 2^32 went through l!-be and came out as its low 32 bits with no error. The tree encodes ihandles this way (forth/admin/iocontrol.fs:42,76), so this is /chosen's stdin quietly naming a different object$([[ $PRC -ne 0 ]] && echo " (rc=$PRC: the probe also left the stack short and the prompt came back as '2 > ', which is the same defect downstream)") — see $PLOG"
      PD="$(grep -aoE 'd-depth=[0-9a-f]+' "$PLOG" | head -1 | cut -d= -f2)"
      [[ -z "$PD" || "$PD" == 4 ]] \
        || fail "REGRESSION: 13.2(d) on $A: decode-bytes left $PD items on the stack, not 4 — the documented effect is ( addr1 len1 #bytes -- addr2 len2 addr1 #bytes ), and anything above 4 is cells pulled off the RETURN stack by a bare r>$([[ $PRC -ne 0 ]] && echo " (and the probe then failed to finish, rc=$PRC, which is the same defect downstream)") — see $PLOG"
      # ESCAPED backticks. Unescaped, `load` here was COMMAND SUBSTITUTION: bash
      # ran it, wrote "load: command not found" to stderr, and spliced the empty
      # result into the message, so the failure read "if  no longer reaches". Same
      # bug class as the usage-heredoc rule in CLAUDE.md, pointed at a fail string
      # — and it only ever showed on a run that was already failing.
      [[ $PRC -eq 0 ]] \
        || fail "the probe did not complete on $A (rc=$PRC) — loading Forth off media is what patches 14/15/16 bought; if \`load\` no longer reaches (init-program), that is the regression, not the wordset — see $PLOG"
    done
    AL="$(tr -d "\r" < "$WORKDIR/prop-amd64.log")"
    XL="$(tr -d "\r" < "$WORKDIR/prop-x86.log")"

    grep -q 'a-ROUNDTRIP-BROKEN' <<<"$AL" \
      || fail "13.2(a) appears FIXED on amd64: -1 encode-int decode-int now round-trips. Good news — update this track and TODO §13.2 together"
    grep -q 'a-ROUNDTRIP-OK' <<<"$XL" \
      || fail "REGRESSION: 13.2(a) now bites on x86 too — the 32-bit cell used to round-trip -1 correctly; something changed l@-be or the cell width"
    grep -q 'a-decoded=ffffffff' <<<"$AL" \
      || fail "13.2(a) on amd64 decoded something other than ffffffff — the zero-extension is the whole claim; see $WORKDIR/prop-amd64.log"

    # 13.2(a) IS TOLERATED ON A PREMISE, and the premise is a claim about the
    # corpus: nothing in this tree decodes a property value with bit 31 set, so
    # zero-extension has never yet produced a wrong answer for a real consumer.
    # That is a cache. These counters derive it on every boot instead.
    #
    # It matters because the obvious fix is NOT safe: sign-extending l@-be makes
    # -1 round-trip and turns every decoded address with bit 31 set into a
    # negative cell — and assigned-addresses carries PCI physical addresses that
    # drivers/vga.fs:148 hands to pci-bar>pci-addr. The day a-signbit goes
    # non-zero, that hazard has a first instance and the decision is forced.
    #
    # THE COUNT IS THE CONTROL. A zero from an instrument nobody ran reads
    # exactly like a zero that means what it says.
    for A in amd64 x86; do
      SL="$(tr -d "\r" < "$WORKDIR/prop-$A.log")"
      AN="$(grep -aoE 'a-decodes-boot=[0-9a-f]+' <<<"$SL" | head -1 | cut -d= -f2)"
      AE="$(grep -aoE 'a-signbit-end=[0-9a-f]+' <<<"$SL" | head -1 | cut -d= -f2)"
      [[ -n "$AN" && "$AN" != 0 ]] \
        || fail "13.2(a) on $A: l@be-count is ${AN:-absent} at the start of the probe — no property was decoded during the whole boot, so a sign-bit count of zero measures nothing. The instrument, not the firmware, is what failed — see $WORKDIR/prop-$A.log"
      # ...AND IT MUST BE ABLE TO COUNT. Section (a) decodes ffffffff on purpose
      # a few lines below the boot reading, so by the end of the probe the sign-bit
      # counter MUST have moved. Without this, a counter wired to nothing reports
      # the same reassuring 0 as a firmware that never saw one — the first draft
      # of this assertion read the counters at the END and duly caught the probe's
      # own ffffffff, which is how the scoping error was found.
      [[ -n "$AE" && "$AE" != 0 ]] \
        || fail "13.2(a) on $A: the sign-bit counter is still ${AE:-absent} AFTER the probe decoded ffffffff on purpose — it is not attached to l@-be, so its zero during boot proves nothing — see $WORKDIR/prop-$A.log"
      grep -qE 'a-signbit-boot=[[:space:]]*0( |$)' <<<"$SL" \
        || fail "13.2(a) on $A: a property value with BIT 31 SET was decoded DURING BOOT ($(grep -aoE 'a-(signbit|last)-boot=[0-9a-f]+ ?' <<<"$SL" | tr '\n' ' ')) — that is the first real consumer of the zero-extension, and it ends the premise this defect has been tolerated on. Sign-extending l@-be is still not the fix on its own: it would corrupt exactly this value if it is an address. Read TODO §13.2(a) before changing either side — see $WORKDIR/prop-$A.log"
      note "$A: $AN four-byte decodes during boot, 0 with bit 31 set — and the counter moved to $AE once the probe decoded one on purpose, so that 0 is a measurement"
    done

    # 13.2(b) FIXED (patch 26), and this is the one place in the track where a
    # fix means the assertion inverts. `l!-be` now REFUSES a value that cannot
    # survive the four bytes 1275 encodes an integer into, rather than writing
    # the low half and saying nothing — LIED down to HALTED, which is the whole
    # of the ladder in CLAUDE.md.
    grep -qE 'b-REFUSED=[[:space:]]*-2( |$)' <<<"$AL" \
      || fail "13.2(b) on amd64: encode-int of 100000000 did not throw -2 — either the refusal is gone or something else threw: $(grep -aoE 'b-(REFUSED|decoded|WIDE|ctl)[^ ]*.{0,16}' <<<"$AL" | head -2 | tr '\n' ' ') — see $WORKDIR/prop-amd64.log"
    grep -qF 'encode-int: value does not fit' <<<"$AL" \
      || fail "13.2(b) on amd64: -2 was thrown but l!-be's message never reached the console, so the refusal cannot tell an operator what it refused — see $WORKDIR/prop-amd64.log"
    grep -q 'b-UNREPRESENTABLE-ON-THIS-CELL' <<<"$XL" \
      || fail "13.2(b) reported a verdict on x86, where a 4-byte cell cannot express the input — that can only mean the probe stopped checking the literal survived, which is the false PASS this track was written to avoid"

    # TODO 16, THE FIRST DELIVERABLE OF THE STORAGE DECISION. `int!` and
    # `string!` take the destination as a stack parameter, and `encode-int` /
    # `encode-string` are redefined in terms of them — one implementation per
    # encoding, shared by the device tree and by anything aimed elsewhere.
    #
    # `here` UNCHANGED IS THE WHOLE ASSERTION. Bytes landing at the right address
    # is satisfied by a writer that allocates in the arena and copies; only a
    # writer that leaves HERE alone can ever be pointed at flash or MMIO. The
    # byte-match line is necessary too — writing nothing moves HERE just as
    # little — so neither is sufficient by itself.
    for A in amd64 x86; do
      SW="$(tr -d "\r" < "$WORKDIR/prop-$A.log")"
      grep -qF 's-int-HERE-UNCHANGED' <<<"$SW" \
        || fail "REGRESSION: TODO 16 on $A: int! moved HERE — it allocated instead of writing where it was told, and that is the one property that lets this be aimed at memory the firmware does not own (F2 in REVIEW-preboot-forth-binary-structures.md) — see $WORKDIR/prop-$A.log"
      grep -qF 's-int-BYTES-MATCH' <<<"$SW" \
        || fail "REGRESSION: TODO 16 on $A: the four bytes int! wrote to a caller-chosen buffer differ from what encode-int produces for the same value — one encoding used two ways is the whole point of the split — see $WORKDIR/prop-$A.log"
      grep -qF 's-str-HERE-UNCHANGED' <<<"$SW" \
        || fail "REGRESSION: TODO 16 on $A: string! moved HERE — see $WORKDIR/prop-$A.log"
      grep -qE 's-str-len=[[:space:]]*3( |$)' <<<"$SW" \
        || fail "TODO 16 on $A: /string of a 2-byte string is not 3 — the sizer and the terminator disagree, so a caller sizing a buffer with it comes up short: $(grep -aoE 's-str-len=.{0,12}' <<<"$SW" | head -1) — see $WORKDIR/prop-$A.log"
      grep -qE 's-str-nul=[[:space:]]*0( |$)' <<<"$SW" \
        || fail "TODO 16 on $A: string! left no terminator — the buffer is poisoned with ff first precisely so an inherited zero cannot pass for a written one: $(grep -aoE 's-str-nul=.{0,12}' <<<"$SW" | head -1) — see $WORKDIR/prop-$A.log"
      grep -qF 's-str-txt=ab' <<<"$SW" \
        || fail "TODO 16 on $A: string! did not copy the bytes — see $WORKDIR/prop-$A.log"

      # THE CURSOR. Three fields written at a caller-chosen address and read back
      # with the stock 1275 decoder — the toolkit's minimum viable shape, since
      # the read half was already general and only the write half was arena-bound.
      #
      # The decode assertions are what make this more than the single-field case:
      # a cursor that advances by the wrong amount still writes the first field
      # correctly, so field ONE proves nothing. Fields two and three are where a
      # bad stride shows.
      grep -qE 'w-advanced=[[:space:]]*c( |$)' <<<"$SW" \
        || fail "REGRESSION: TODO 16 on $A: three int!+ calls advanced the cursor by $(grep -aoE 'w-advanced=[0-9a-f]+' <<<"$SW" | head -1 | cut -d= -f2) bytes, not c — the stride disagrees with /int, so every field after the first lands in the wrong place — see $WORKDIR/prop-$A.log"
      grep -qF 'w-HERE-UNCHANGED' <<<"$SW" \
        || fail "REGRESSION: TODO 16 on $A: the cursor moved HERE — composing at a chosen address must not touch the arena, or the whole point of the split is lost — see $WORKDIR/prop-$A.log"
      for f in 1:11111111 2:22222222 3:33333333; do
        grep -qE "w-i${f%%:*}=[[:space:]]*${f#*:}( |\$)" <<<"$SW" \
          || fail "REGRESSION: TODO 16 on $A: field ${f%%:*} of the cursor-written structure decoded as $(grep -aoE "w-i${f%%:*}=[0-9a-f-]+" <<<"$SW" | head -1 | cut -d= -f2), not ${f#*:} — written at a caller-chosen address and read back with the stock decode-int, these have to agree or the two halves do not meet — see $WORKDIR/prop-$A.log"
      done
    done

    # THE MUST-NOT-CATCH PAIR, and without it the line above is satisfied by a
    # gate that refuses EVERYTHING — which would be a firmware that cannot encode
    # an integer at all. Both halves of the 32-bit range have to survive: an
    # unsigned quantity (ffffffff, an address or a phandle) and a sign-extended
    # negative (-1 as a full cell). (a)'s `a-decoded=ffffffff` two lines up is a
    # third instance of the same control, from before this fix existed.
    for A in amd64 x86; do
      BL="$(tr -d "\r" < "$WORKDIR/prop-$A.log")"
      grep -qF 'b-ctl-u32-OK' <<<"$BL" \
        || fail "13.2(b) on $A: encode-int REFUSED ffffffff, an ordinary unsigned 32-bit value — an address or a phandle — so the fit test is rejecting the top half of the range it exists to protect (the probe aborted there and printed no marker) — see $WORKDIR/prop-$A.log"
      grep -qF 'b-ctl-neg-OK' <<<"$BL" \
        || fail "13.2(b) on $A: encode-int REFUSED -1 — a sign-extended negative fills a cell with ones and still fits in four bytes; refusing it would break every negative property value — see $WORKDIR/prop-$A.log"
    done

    # 13.2(c) FIXED (patch 27), and BOTH BRANCHES are exercised because a fix that
    # only ever runs the fast path is indistinguishable from no fix at all. The
    # `c-slow-NOT` line is what says the concatenating branch actually ran.
    #
    # The old assertion here used `grep -q 'ENCODE\+-WOULD'`, and in a BASIC regex
    # `\+` is a QUANTIFIER, not a literal plus — it asked for one-or-more E and
    # matched nothing, reporting (c) FIXED while both logs plainly contained the
    # string. Hence -F everywhere below.
    for A in amd64 x86; do
      CL2="$(tr -d "\r" < "$WORKDIR/prop-$A.log")"
      grep -qF 'c-fast-ADJACENT' <<<"$CL2" \
        || fail "13.2(c) on $A: two back-to-back encode-ints did NOT come out adjacent, so the fast path this fix preserves was never taken and the run says nothing about it — see $WORKDIR/prop-$A.log"
      # REVIEW 2's FOURTH ASSERTION, and the UNKNOWN underneath it. The entry
      # asked for /chosen's stdin to survive a round trip "at whatever address
      # instances actually land on in long mode" — and the review's own closing
      # section named the prior question: whether an amd64 instance can land
      # above 4 GiB at all. Both are answered per boot rather than once.
      HL="$(grep -aoE 'h-live=[0-9a-f]+' <<<"$CL2" | tail -1 | cut -d= -f2)"
      HP="$(grep -aoE 'h-prop=[0-9a-f]+' <<<"$CL2" | tail -1 | cut -d= -f2)"
      HO="$(grep -aoE 'h-other=[0-9a-f]+' <<<"$CL2" | tail -1 | cut -d= -f2)"
      [[ -n "$HL" && "$HL" == "$HP" ]] \
        || fail "13.3(E)/review §2: on $A, /chosen's stdin property decodes to ${HP:-absent} but the live ihandle is ${HL:-absent} — encode-int/decode-int does not round-trip the pointer the tree stores there, which is the hazard 13.2(b)'s refusal exists to make honest — see $WORKDIR/prop-$A.log"
      [[ -n "$HO" && "$HO" != "$HL" ]] \
        || fail "13.3(E)/review §2: on $A, stdout's ihandle (${HO:-absent}) is not distinguishable from stdin's ($HL), so 'they matched' above is a statement about the comparison and not about the round trip — see $WORKDIR/prop-$A.log"
      grep -qE 'h-hi=[[:space:]]*0( |$)' <<<"$CL2" \
        || fail "13.3(E)/review §2: on $A an instance now lands ABOVE 4 GiB (top 32 bits $(grep -aoE 'h-hi=[0-9a-f]+' <<<"$CL2" | tail -1 | cut -d= -f2)) — the truncation hazard the review named is live from this boot on. 13.2(b) means encode-int will REFUSE rather than truncate it, so expect an honest abort where /chosen used to be written; that is the good failure, but it is a failure — see $WORKDIR/prop-$A.log"
      note "$A: /chosen stdin round-trips ($HL), stdout is distinguishable ($HO), and instances land below 4 GiB"

      grep -qF 'c-slow-NOT' <<<"$CL2" \
        || fail "13.2(c) on $A: an allot between two encode-ints no longer separates them, so the CONCATENATING branch never ran — a fix whose slow path is unreachable is not a fix — see $WORKDIR/prop-$A.log"
      # The length is the WEAK check and is here only to catch a mis-sized
      # allocation on the new path: `nip +` got the length right and the bytes
      # wrong, which is why the decodes below are what actually bite.
      for W in fast slow; do
        grep -qE "c-$W-len=[[:space:]]*8( |\$)" <<<"$CL2" \
          || fail "13.2(c) on $A: encode+ of two 4-byte ints returned $(grep -aoE "c-$W-len=[0-9a-f]+" <<<"$CL2" | head -1 | cut -d= -f2) bytes on the $W path, not 8 — see $WORKDIR/prop-$A.log"
      done
      grep -qE 'c-fast-i1=[[:space:]]*3( |$)' <<<"$CL2" && grep -qE 'c-fast-i2=[[:space:]]*4( |$)' <<<"$CL2" \
        || fail "13.2(c) on $A: the adjacent case decoded back to $(grep -aoE 'c-fast-i[12]=[0-9a-f]+ ?' <<<"$CL2" | tr '\n' ' ') instead of 3 and 4 — the length can be right while the bytes are not — see $WORKDIR/prop-$A.log"
      grep -qE 'c-slow-i1=[[:space:]]*1( |$)' <<<"$CL2" && grep -qE 'c-slow-i2=[[:space:]]*2( |$)' <<<"$CL2" \
        || fail "REGRESSION: 13.2(c) on $A: the NON-adjacent case decoded back to $(grep -aoE 'c-slow-i[12]=[0-9a-f]+ ?' <<<"$CL2" | tr '\n' ' ') instead of 1 and 2 — encode+ returned a plausible length over the wrong bytes, which is exactly what it used to do silently — see $WORKDIR/prop-$A.log"
    done

    # encode-phys is NOT fixed-width: it encodes my-#acells ints, and my-#acells
    # reads the PARENT's #address-cells (clamped 1-4, default 2 when there is no
    # parent). Measured: `dev /` gives 2 cells = 8 bytes -- the DEFAULT, because
    # root has no parent -- while `dev /ide@1` gives 1 cell = 4 bytes, from root's
    # own `#address-cells 1`. So the same call yields a different length in two
    # contexts, and root is the trap: its property says 1 while encode-phys under
    # it uses 2.
    # The comparison is done HERE and not in the probe, and the reason this
    # comment used to give was WRONG. It said `variable` "does not stick inside
    # the evaluated text". Re-derived 2026-08-27 on both arches:
    #
    #   variable qw  7 qw !  qw @ .      in evaluated text -> 7, and still 7 at
    #                                    the prompt afterwards
    #   dev /  variable la  9 la !       -> la @ is 9 while the context is open
    #   device-end  la @                 -> "la: undefined word."
    #
    # So the original observation was never about `evaluate` at all: the probe
    # defined `la` after a `dev /`, and $create defines into the ACTIVE PACKAGE's
    # method list, which device-end drops from the search order. That is correct
    # IEEE 1275 and this lab's own documented rule, misfiled as a limitation of
    # evaluated text. The comparison stays here because two measured values
    # differing is the proof anyway.
    # encode-phys is NOT fixed-width, measured in THREE contexts per arch. This
    # used to be a two-way comparison of / against /ide@1, and TODO 17.1 broke
    # it -- not by breaking anything, but by making the two EQUAL on amd64,
    # where the root now declares the same 2 cells that the no-parent default
    # already used. That is the mechanism-not-outcome trap in its expensive
    # direction: nothing was wrong and the suite would have insisted otherwise.
    #
    # The third context is what makes the claim survive the change. /ide@1 reads
    # the root's declaration, which is now per-arch (1 on x86, 2 on amd64) and
    # is therefore DERIVED from r-pacells rather than written down; the VGA node
    # reads the PCI bus's own 3 (patch 34), which no root change can move. A
    # fixed-width encode-phys makes all three equal on both arches.
    for A in amd64 x86; do
      EL="$(tr -d "\r" < "$WORKDIR/prop-$A.log")"
      ELR="$(grep -aoE 'e-len-root=[0-9a-f]+' <<<"$EL" | head -1 | cut -d= -f2)"
      ELI="$(grep -aoE 'e-len-ide=[0-9a-f]+'  <<<"$EL" | head -1 | cut -d= -f2)"
      ELV="$(grep -aoE 'e-len-vga=[0-9a-f]+'  <<<"$EL" | head -1 | cut -d= -f2)"
      ELP="$(grep -aoE 'r-pacells=[0-9a-f]+'  <<<"$EL" | head -1 | cut -d= -f2)"
      [[ -n "$ELR" && -n "$ELI" && -n "$ELV" && -n "$ELP" ]] \
        || fail "13.2 on $A: the encode-phys probe printed no lengths (root=${ELR:-absent} ide=${ELI:-absent} vga=${ELV:-absent} pacells=${ELP:-absent}) — see $WORKDIR/prop-$A.log"
      [[ "$ELR" == 8 ]] \
        || fail "13.2 on $A: encode-phys under / is $ELR bytes, not 8 — my-#acells falls back to 2 there because root has no parent; if that default moved, every caller's idea of a phys length moved with it — see $WORKDIR/prop-$A.log"
      WANTIDE="$(printf '%x' $(( 0x$ELP * 4 )))"
      [[ "$ELI" == "$WANTIDE" ]] \
        || fail "13.2 on $A: encode-phys under /ide@1 is $ELI bytes for a root declaring $ELP address cell(s), which wants $WANTIDE — the encoder and the root disagree about how wide an address under / is — see $WORKDIR/prop-$A.log"
      [[ "$ELV" == c ]] \
        || fail "REGRESSION: patch 34 on $A: encode-phys under /pci8086,1237@0/QEMU,VGA@2 is $ELV bytes, not c — the PCI bus's own #address-cells 3 is what makes that 12, and losing it is the defect that shifted pci-bar>pci-addr's stack and faulted the display open — see $WORKDIR/prop-$A.log"
      [[ "$ELV" != "$ELI" ]] \
        || fail "13.2 on $A: encode-phys returned the SAME length ($ELV) under /ide@1 and under a PCI child whose parent declares 3 address cells — somebody made encode-phys fixed-width, which is the misreading this assertion exists to prevent — see $WORKDIR/prop-$A.log"
      note "$A: encode-phys is context-sized — 8 under / (no parent, default 2), $ELI under /ide@1 (root's own $ELP), c under a PCI child (the bus's 3)"
    done

    # TODO 17.1 PRE-CHECK, on BOTH arches: the parent half of a `ranges` entry.
    #
    # EVERY EXPECTATION HERE IS DERIVED FROM r-pacells, which is the root's own
    # declaration read back off the running firmware. That is the whole point: a
    # hard-coded "4 bytes" would be a cached copy of a number this lab is about
    # to change on purpose, and it would fail on the change rather than on a
    # defect — the mechanism-not-outcome trap in its expensive direction, which
    # has already cost this lab a day (the dict-identity pattern, patch 40).
    #
    # What is NOT derived is the bus's own 3/2: that is patch 34's fix and is a
    # property of the PCI binding, not of the root, so it is asserted flat.
    for A in amd64 x86; do
      RL="$(tr -d "\r" < "$WORKDIR/prop-$A.log")"
      RPA="$(grep -aoE 'r-pacells=[0-9a-f]+' <<<"$RL" | head -1 | cut -d= -f2)"
      RPL="$(grep -aoE 'r-plen=[0-9a-f]+'    <<<"$RL" | head -1 | cut -d= -f2)"
      RC0="$(grep -aoE 'r-c0=[0-9a-f]+'      <<<"$RL" | head -1 | cut -d= -f2)"
      RC1="$(grep -aoE 'r-c1=[0-9a-f]+'      <<<"$RL" | head -1 | cut -d= -f2)"
      [[ -n "$RPA" ]] \
        || fail "17.1 on $A: the ranges probe printed no r-pacells — it never reached /pci8086,1237@0, so everything below it is an UNKNOWN and not a pass — see $WORKDIR/prop-$A.log"
      grep -qE 'r-cacells=[[:space:]]*3( |$)' <<<"$RL" \
        || fail "REGRESSION: patch 34 on $A: the PCI bus no longer declares #address-cells 3 ($(grep -aoE 'r-cacells[^ ]*.{0,6}' <<<"$RL" | head -1)) — every Forth decode under it then reads one cell short, which is the defect that faulted the display open — see $WORKDIR/prop-$A.log"
      grep -qE 'r-cscells=[[:space:]]*2( |$)' <<<"$RL" \
        || fail "REGRESSION: patch 34 on $A: the PCI bus no longer declares #size-cells 2 ($(grep -aoE 'r-cscells[^ ]*.{0,6}' <<<"$RL" | head -1)) — a ranges entry's size half is read with this — see $WORKDIR/prop-$A.log"
      WANTLEN="$(printf '%x' $(( 0x$RPA * 4 )))"
      [[ "$RPL" == "$WANTLEN" ]] \
        || fail "17.1 on $A: encode-phys at the PCI bus produced $RPL bytes for a root declaring $RPA address cell(s); $WANTLEN is the only length that decodes — the parent half of every ranges entry is this wide — see $WORKDIR/prop-$A.log"
      [[ "$RC0" == c0000000 ]] \
        || fail "17.1 on $A: the FIRST cell of the encoded parent address is $RC0, not c0000000 — 1275 puts phys.hi first, and a consumer reading this ranges entry would map the wrong window — see $WORKDIR/prop-$A.log"
      # The low cell is where a wrong stride actually shows: at one address cell
      # there is no second cell and decode-int correctly returns 0 for an
      # exhausted property; at two there must be the value that was encoded. A
      # test that accepted either would be satisfied by a decoder that read
      # nothing.
      if [[ "$RPA" == 1 ]]; then
        [[ "$RC1" == 0 ]] \
          || fail "17.1 on $A: with ONE address cell the property is exhausted after the first, so a second decode-int must return 0, not $RC1 — decode-int is reading past the end of the property — see $WORKDIR/prop-$A.log"
      else
        [[ "$RC1" == deadbeef ]] \
          || fail "17.1 on $A: with $RPA address cells the SECOND cell must be deadbeef, the low half of what encode-phys was given; it is $RC1 — the stride between cells disagrees between the encoder and the decoder, which is patch 34's defect one level up — see $WORKDIR/prop-$A.log"
      fi
      note "$A: ranges parent half = $RPA cell(s)/$RPL bytes at the PCI bus (child 3/2), phys.hi first, round-tripped through decode-int"
    done

    # 13.2(d) decode-bytes: FIXED (patch 25) rather than deleted. Upstream had two
    # bare `r>` and no `>r`, so it robbed the RETURN stack of two cells and left
    # them on the data stack -- returning CLEANLY with six items where the
    # documented effect is four, which is worse than a crash. The first `r>` is a
    # transposed `>r`; with it, the stack comments and IEEE 1275-1994 5.3.5.2
    # agree line for line.
    #
    # THE DEPTH IS THE ASSERTION, not the decoded text. A round trip that prints
    # "ab" proves the bytes were found; it says nothing about the two cells taken
    # from underneath the caller -- and it is the second thing that took the
    # machine down when it ran out of return stack to rob.
    for A in amd64 x86; do
      DL2="$(tr -d "\r" < "$WORKDIR/prop-$A.log")"
      grep -qE 'd-depth=[[:space:]]*4( |$)' <<<"$DL2" \
        || fail "13.2(d) on $A: no d-depth=4 line — the probe never reached the decode-bytes section, so its silence is an UNKNOWN and not a pass (the depth itself is gated above, where a wrong one can be named before the run's rc is) — see $WORKDIR/prop-$A.log"
      grep -qE 'd-depth-pre=[[:space:]]*0( |$)' <<<"$DL2" && grep -qE 'd-depth-post=[[:space:]]*0( |$)' <<<"$DL2" \
        || fail "13.2(d) on $A: the stack was not empty before or after the decode-bytes probe, so its depth of 4 is not a measurement of decode-bytes — see $WORKDIR/prop-$A.log"
      grep -qF 'd-data=ab' <<<"$DL2" \
        || fail "13.2(d) on $A: decode-bytes returned a data pointer/length that does not name the two bytes encode-bytes was given — a balanced stack over the wrong bytes is still broken: $(grep -aoE 'd-data=.{0,12}' <<<"$DL2" | head -1) — see $WORKDIR/prop-$A.log"
      grep -qE 'd-len2=[[:space:]]*0( |$)' <<<"$DL2" \
        || fail "13.2(d) on $A: the remainder length after decoding all 2 bytes of a 2-byte property is not 0 — decode-bytes is not subtracting #bytes from prop-len1: $(grep -aoE 'd-len2=.{0,12}' <<<"$DL2" | head -1) — see $WORKDIR/prop-$A.log"
    done

    pass "TODO 13.2 watched to bite: (a) the SAME four bytes decode to ffffffff on amd64 and -1 on x86 — encode-int/decode-int is not a round trip at a 64-bit cell — and the premise it is tolerated on is now DERIVED rather than assumed: every four-byte decode of the boot is counted, and none has bit 31 set, which is the only reason zero-extension has yet to give a real consumer a wrong answer; (b) FIXED — a value >= 2^32 is now REFUSED BY NAME on amd64 where it used to be silently truncated into four bytes, with ffffffff and -1 both still encoding cleanly in the same run so the gate is not simply refusing everything, and the input still UNREPRESENTABLE on x86, reported as an UNKNOWN not a pass; (c) FIXED — encode+ used to be \`nip +\`, adjacency-by-assumption: it returned the RIGHT length over the WRONG bytes the moment anything moved HERE between fragments, so the second decode-int read the gap (30302f63) rather than the fragment, and §13.2's own \"lies about the length\" was disproved by the control; it now concatenates, with BOTH branches exercised in the same run (adjacent 3,4 and non-adjacent 1,2 each coming back out of an 8-byte array) so a fix whose slow path never runs cannot pass; and encode-phys is NOT fixed-width, measured in three contexts per arch — 8 bytes under / (the no-parent default of 2 cells), the root's OWN declaration under /ide@1 (derived per arch, since TODO 17.1 gives amd64 two address cells and leaves x86 at one), and c under a PCI child whose bus declares 3; and the parent half of a \`ranges\` entry round-trips through decode-int at whatever width the root is currently declaring, phys.hi first; and (d) decode-bytes, which used to return CLEANLY with six items where four are documented — two cells robbed off the return stack — now round-trips encode-bytes on both arches at depth exactly 4, from an empty stack back to an empty one; and review §2's fourth assertion is closed — /chosen's stdin round-trips through encode-int/decode-int at the address instances actually land on, a different ihandle from the same node is distinguishable so that match means something, and the top 32 bits are derived per boot rather than assumed, which answers the review's own UNKNOWN: an amd64 instance does NOT land above 4 GiB today; and TODO 16's storage split holds on both arches — int!/string! write where the caller says with HERE unchanged, and the cursor composes three fields at a chosen address that the stock 1275 decode-int reads back unchanged"
    ;;
  memory-available)
    # TODO 17.3: /memory's `available` -- the UNALLOCATED subset -- and the
    # `claim` it is supposed to describe.
    #
    # WHAT WAS ACTUALLY MISSING WAS BIGGER THAN THE PROPERTY. arch/amd64 bound
    # no cif-claim and no cif-release at all, so the 1275 `claim` service fell
    # through ciface.fs's `else 3drop -1` and every allocation on the 64-bit
    # firmware failed. Measured before writing a line of this, with the positive
    # control in the same run: `" cif-claim" find-method` found it on x86 and did
    # NOT on amd64. Publishing `available` there first would have advertised
    # memory nothing could take.
    #
    # THE ASSERTION IS THAT THE PROPERTY MOVES, not that it exists. `available`
    # describes a cursor, and a snapshot taken at boot is a record that outlives
    # its subject the first time a client claims -- bug class #1 in CLAUDE.md. So
    # this claims a page, asserts the base advanced by EXACTLY that page and the
    # size shrank by it, releases, and asserts it went back.
    #
    # AND THE REFUSAL IS THE CONTROL. A property that changed on every call would
    # pass "it moves" while tracking nothing, so the run ends with a claim no
    # window can hold: it must return -1 and `available` must NOT move. Without
    # that row, "it moves" and "it is wired to a random number" are the same
    # measurement.
    #
    # WHAT THIS DOES NOT ASSERT, said out loud: that `available` is a SUBSET of
    # `reg`. It is by construction -- the window is derived from the same
    # sys_info -- but nothing here parses `reg` and checks containment, so that
    # is a claim from reading, not a measurement.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v genisoimage >/dev/null || skip "genisoimage not installed"
    AMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    ADI="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    XMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    XDI3="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
    for f in "$AMB" "$ADI" "$XMB" "$XDI3"; do
      [[ -f "$f" ]] || skip "missing $f — run ./build-openbios.sh amd64 and x86 first"
    done
    MST="$WORKDIR/mem-stage"; rm -rf "$MST"; mkdir -p "$MST"
    cat > "$MST/MEMAV.FTH" <<'FTH'
\ TODO 17.3 probe. Base is HEX.
." MA-START" cr
clear
\ Four cells covers both regimes: at #address-cells 1 the property is
\ [base][size] and the last two decode-ints return 0 off an exhausted property;
\ at 2 it is [0][base][0][size]. Which cells carry the value is computed from
\ m-acells rather than assumed here.
: .avail
  decode-int ." m-c0=" u. cr
  decode-int ." m-c1=" u. cr
  decode-int ." m-c2=" u. cr
  decode-int ." m-c3=" u. cr
  2drop ;
: ?avail
  " available" " /memory" find-dev drop get-package-property 0= if
    ." m-len=" 2dup nip . cr .avail
  else
    ." m-AVAIL-ABSENT" cr
  then ;
\ Every cell of a property on one line, however many there are -- `reg` carries
\ three ranges of (acells + scells) cells and the count is per-arch.
: .allcells ( a l -- )
  begin dup 0> while decode-int u. repeat 2drop ;
: ?reg
  " reg" " /memory" find-dev drop get-package-property 0= if
    ." m-regcells=" .allcells cr
  else
    ." m-REG-ABSENT" cr
  then ;
variable cb
dev /memory
." m-acells=" my-#acells . cr
." m-scells=" my-#scells . cr
device-end
clear
" /openprom/client-services" find-dev if
  " cif-claim"   2 pick find-method if ." m-claim-FOUND" cr   drop else ." m-claim-MISSING" cr then
  " cif-release" 2 pick find-method if ." m-release-FOUND" cr drop else ." m-release-MISSING" cr then
  drop
else
  ." m-cs-MISSING" cr
then
clear
?reg
clear
." m-phase=before" cr ?avail
clear
dev /openprom/client-services
0 1000 1000 cif-claim dup cb ! ." m-claimed=" u. cr
device-end
clear
." m-phase=afterclaim" cr ?avail
clear
dev /openprom/client-services
cb @ 1000 cif-release
device-end
clear
." m-phase=afterrelease" cr ?avail
clear
\ THE CONTROL: a claim nothing can satisfy. -1 back, and available unmoved.
dev /openprom/client-services
0 ffffff000 1000 cif-claim ." m-huge=" u. cr
device-end
clear
." m-phase=afterhuge" cr ?avail
clear
." MA-END" cr
FTH
    genisoimage -quiet -o "$WORKDIR/memav.iso" -V MEMAV -r -J "$MST"
    note "asking both arches what /memory says is free → $WORKDIR/memav-{amd64,x86}.log"
    for A in amd64 x86; do
      if [[ "$A" == amd64 ]]; then MB="$AMB"; DI="$ADI"; else MB="$XMB"; DI="$XDI3"; fi
      MSOCK="$WORKDIR/ma-$A.sock"; MLOG="$WORKDIR/memav-$A.log"; rm -f "$MSOCK" "$MLOG"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DI" \
        -cdrom "$WORKDIR/memav.iso" -display none -serial "unix:$MSOCK,server=on" \
        -no-reboot >/dev/null 2>&1 &
      MQ=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$MSOCK" "$MLOG" --timeout 120 \
        --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\memav.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "MA-END"
      MRC=$?
      kill "$MQ" 2>/dev/null   # by PID, never by pattern
      ML="$(tr -d "\r" < "$MLOG")"

      # Read the claim binding BEFORE the rc gate: if cif-claim is missing the
      # probe still completes, but every number below it is meaningless, and a
      # timeout would otherwise blame the property for a missing method.
      grep -qF 'm-claim-FOUND' <<<"$ML" \
        || fail "REGRESSION: $A has no cif-claim on /openprom/client-services — the 1275 claim service falls through ciface.fs's 'else 3drop -1' and every client allocation returns -1. This is what arch/amd64 shipped until TODO 17.3; publishing 'available' without it advertises memory nothing can take — see $MLOG"
      grep -qF 'm-release-FOUND' <<<"$ML" \
        || fail "REGRESSION: $A has no cif-release — claim without release is a one-way allocator, and the LIFO path below cannot be exercised — see $MLOG"
      [[ $MRC -eq 0 ]] \
        || fail "the probe did not complete on $A (rc=$MRC) — see $MLOG"

      grep -qF 'm-AVAIL-ABSENT' <<<"$ML" \
        && fail "REGRESSION: /memory has no 'available' on $A — TODO 17.3 publishes it beside 'reg', and a client asking what is free before it claims gets no answer at all — see $MLOG"

      MAC="$(grep -aoE 'm-acells=[0-9a-f]+' <<<"$ML" | head -1 | cut -d= -f2)"
      MSC="$(grep -aoE 'm-scells=[0-9a-f]+' <<<"$ML" | head -1 | cut -d= -f2)"
      [[ -n "$MAC" && -n "$MSC" ]] \
        || fail "17.3 on $A: the probe printed no cell counts, so it cannot say which cells carry the address — see $MLOG"
      # The property is encoded with the ROOT's counts, which patch 43 made
      # per-arch. Deriving the length here is what lets one assertion cover both.
      MWANT="$(printf '%x' $(( (0x$MAC + 0x$MSC) * 4 )))"
      MLEN="$(grep -aoE 'm-len=[0-9a-f]+' <<<"$ML" | head -1 | cut -d= -f2)"
      [[ "$MLEN" == "$MWANT" ]] \
        || fail "17.3 on $A: 'available' is $MLEN bytes where the root's #address-cells $MAC / #size-cells $MSC want $MWANT — it is not encoded with the counts that decode it — see $MLOG"

      # phase <n> -> the cells of that phase's `available`
      ma_cell() { # ma_cell <phase> <index>
        sed -n "/m-phase=$1\$/,/m-c3=/p" <<<"$ML" | grep -aoE "m-c$2=[0-9a-f]+" | head -1 | cut -d= -f2
      }
      MBI=$(( 0x$MAC - 1 ))            # last address cell
      MSI=$(( 0x$MAC + 0x$MSC - 1 ))   # last size cell
      B0="$(ma_cell before      "$MBI")"; S0="$(ma_cell before      "$MSI")"
      B1="$(ma_cell afterclaim  "$MBI")"; S1="$(ma_cell afterclaim  "$MSI")"
      B2="$(ma_cell afterrelease "$MBI")"; S2="$(ma_cell afterrelease "$MSI")"
      B3="$(ma_cell afterhuge   "$MBI")"; S3="$(ma_cell afterhuge   "$MSI")"
      for v in "$B0" "$S0" "$B1" "$S1" "$B2" "$S2" "$B3" "$S3"; do
        [[ -n "$v" ]] \
          || fail "17.3 on $A: a phase of the probe printed no available cells (before=$B0/$S0 afterclaim=$B1/$S1 afterrelease=$B2/$S2 afterhuge=$B3/$S3) — see $MLOG"
      done
      (( 0x$S0 > 0 )) \
        || fail "17.3 on $A: 'available' says 0 bytes are free at boot, before anything claimed — the window is empty, so either claim_limit found no usable range or the base sits outside every one of them — see $MLOG"

      # available MUST BE A SUBSET OF reg, and until 2026-08-29 this was a claim
      # from READING the source rather than a measurement -- "it is by
      # construction, the window comes from the same sys_info". That sentence is
      # exactly the shape of every stale record this lab has found: true when
      # written, unchecked afterwards. A window that drifts outside `reg` would
      # hand a client memory the firmware has not told it exists.
      #
      # reg's cells are read off the running firmware and regrouped with the
      # ROOT's counts (per-arch since patch 43), so one assertion covers both.
      MREG="$(grep -aoE 'm-regcells=[0-9a-f ]+' <<<"$ML" | head -1 | cut -d= -f2)"
      [[ -n "$MREG" ]] \
        || fail "17.3 on $A: /memory has no 'reg' cells in the probe output — patch 40 publishes it, and without it there is nothing to check 'available' against — see $MLOG"
      read -r -a MRC <<<"$MREG"
      (( ${#MRC[@]} % (0x$MAC + 0x$MSC) == 0 && ${#MRC[@]} > 0 )) \
        || fail "17.3 on $A: 'reg' has ${#MRC[@]} cells, which is not a whole number of (acells $MAC + scells $MSC) entries — the property and the root's counts disagree — see $MLOG"
      # join <first-index> <count> -> the value of a multi-cell field, hi first
      ma_join() { local i n v=0; for (( i=$1, n=0; n < $2; i++, n++ )); do v=$(( (v << 32) | 0x${MRC[$i]} )); done; printf '%d' "$v"; }
      AB=$(( 0x$B0 )); AE=$(( 0x$B0 + 0x$S0 ))
      MCONTAINED=0; MRANGES=""
      for (( r = 0; r < ${#MRC[@]}; r += 0x$MAC + 0x$MSC )); do
        rb=$(ma_join "$r" "$((0x$MAC))"); rs=$(ma_join "$(( r + 0x$MAC ))" "$((0x$MSC))")
        MRANGES+="$(printf '%x..%x ' "$rb" "$(( rb + rs ))")"
        (( AB >= rb && AE <= rb + rs )) && MCONTAINED=1
      done
      (( MCONTAINED == 1 )) \
        || fail "17.3 on $A: the free window $(printf '%x..%x' "$AB" "$AE") is NOT inside any range of /memory's reg ($MRANGES) — 'available' is advertising memory the firmware has not said exists, which is worse than advertising none — see $MLOG"
      note "$A: available $(printf '%x..%x' "$AB" "$AE") lies inside reg's $MRANGES— measured, not argued from construction"

      # THE OUTCOME: a page claimed moves the base up by a page and the size down
      # by a page. Both halves, because a base that advances while the size stays
      # put describes a window running off its own end.
      (( 0x$B1 == 0x$B0 + 0x1000 )) \
        || fail "17.3 on $A: after claiming 0x1000 the free base is $B1, not $B0 + 0x1000 — 'available' is not tracking the allocator, which is the whole reason it is republished rather than snapshotted — see $MLOG"
      (( 0x$S1 == 0x$S0 - 0x1000 )) \
        || fail "17.3 on $A: after claiming 0x1000 the free size is $S1, not $S0 - 0x1000 — the base moved and the size did not, so the window now runs past its own end — see $MLOG"
      # The LIFO release path, which is the only release a bump allocator honours.
      [[ "$B2" == "$B0" && "$S2" == "$S0" ]] \
        || fail "17.3 on $A: releasing the page just claimed left 'available' at $B2/$S2 instead of back at $B0/$S0 — a LIFO release is the one case the bump allocator can undo, and the property did not follow it — see $MLOG"
      # THE CONTROL. Without this, "it moves" is satisfied by a property wired to
      # anything that changes.
      MHUGE="$(grep -aoE 'm-huge=[0-9a-f]+' <<<"$ML" | head -1 | cut -d= -f2)"
      [[ "$MHUGE" =~ ^f+$ ]] \
        || fail "17.3 on $A: a claim of 0xffffff000 bytes returned $MHUGE instead of -1 — the allocator handed out a window larger than the machine has, so every bound below it is decorative — see $MLOG"
      [[ "$B3" == "$B2" && "$S3" == "$S2" ]] \
        || fail "17.3 on $A: a REFUSED claim still moved 'available' ($B2/$S2 -> $B3/$S3) — the property changes on calls that allocated nothing, so the movement asserted above says nothing about the allocator — see $MLOG"
      note "$A: available=$B0/$S0 at boot (root cells $MAC/$MSC, $MLEN bytes) → claim 1000 → $B1/$S1 → release → $B2/$S2 → refused claim leaves it at $B3/$S3"
    done
    pass "TODO 17.3: /memory carries an 'available' beside its 'reg' on BOTH arches, and it is the allocator's own state rather than a snapshot — arch/amd64 bound NO cif-claim or cif-release at all until now, so every client allocation on the 64-bit firmware returned -1 and an 'available' there would have described memory nothing could take; the property is encoded with the ROOT's cell counts (per-arch since patch 43, and derived here rather than written down), claiming one page moves the free base up by exactly 0x1000 AND the size down by exactly 0x1000, a LIFO release puts both back, and — the control that makes those mean anything — a claim of 0xffffff000 bytes is REFUSED with -1 and leaves the property untouched, so a value that merely changes on every call cannot pass"
    ;;
  vga)
    # TODO 13.1's DRIVER_VGA half: PCI enumeration on amd64 (patch 17) and the
    # VGA FCode blob that had never been evaluated on EITHER arch (patch 18).
    #
    # WHAT THIS TRACK REFUSES TO ASSERT, and why. The obvious check is "the
    # boot log says vga-driver-fcode:" -- and that string is the FAILURE. It is
    # what forth/bootstrap/interpreter.fs:64 prints for a token it cannot
    # resolve: `type 3a emit`, the word then a colon, then throw -13, with no
    # newline and no "undefined word" because feval's caller prints no status.
    # It reads as a progress marker, and this lab believed it was one for long
    # enough to write it into drivers/floppy.c as a boot landmark. So the
    # assertion below is that the string is ABSENT, and it is scoped to the
    # boot output BEFORE the first prompt -- the probe's own command echo names
    # the same word, and a grep over the whole log would match that instead.
    #
    # The positive half cannot be a print either. `$find` returning -1 is the
    # outcome: the word is reachable from the vocabulary drivers/pci.c:1045
    # calls it from. Before patch 18 it was 0 on both arches and the same word
    # was sitting in ROOT's method list, where `dev / words` still prints it.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v qemu-system-i386 >/dev/null || skip "qemu-system-i386 not installed"
    AMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    ADICT="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    XMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    [[ -f "$AMB" && -f "$ADICT" ]] || skip "no amd64 image — run ./build-openbios.sh amd64 first"
    [[ -f "$XMB" && -f "$XDICT" ]] || skip "no x86 image — run ./build-openbios.sh x86 first"

    for A in amd64 x86; do
      case "$A" in
        amd64) Q=qemu-system-x86_64; VMB="$AMB"; VDICT="$ADICT" ;;
        x86)   Q=qemu-system-i386;   VMB="$XMB"; VDICT="$XDICT" ;;
      esac
      VLOG="$WORKDIR/vga-$A.log"; VSOCK="$WORKDIR/smoke-vga-$A.sock"
      rm -f "$VLOG" "$VSOCK"
      note "booting $A and asking whether the FCode blob is reachable → $VLOG"
      "$Q" -M "pc,accel=$ACCEL" -m 512 -kernel "$VMB" -initrd "$VDICT" \
        -display none -serial "unix:$VSOCK,server=on" -no-reboot >/dev/null 2>&1 &
      QPID=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$VSOCK" "$VLOG" --timeout 120 \
        --expect "0 > " \
        --send '." F=" " vga-driver-fcode" $find . cr\r'  --expect "> " \
        --send 'clear ." W=" openbios-video-width . cr\r' --expect "> " \
        --send 'clear ." S=" " screen" find-dev if ." FOUND " . else ." NONE" then cr\r' --expect "> " \
        --send 'clear dev /pci8086,1237@0/QEMU,VGA@2 ." AC=" my-#acells . cr\r' --expect "> " \
        --send 'clear device-end " screen" open-dev ." OD=" dup . cr\r' --expect "> " \
        --send '." FB=" frame-buffer-adr . cr\r' --expect "> " \
        --send 'clear dev /pci8086,1237@0 ls\r'           --expect "> "
      RC=$?
      kill "$QPID" 2>/dev/null   # by PID, never by pattern
      [[ $RC -eq 0 ]] || fail "the $A firmware did not finish the VGA probe (rc=$RC) — see $VLOG"
      VL="$(cat "$VLOG")"

      # Scoped to the boot output, so the probe's own echo cannot answer for it.
      BOOT="${VL%%0 > *}"
      grep -qF 'vga-driver-fcode:' <<<"$BOOT" \
        && fail "REGRESSION: $A printed 'vga-driver-fcode:' during boot — that is interpreter.fs:64 reporting an unresolvable token, not progress; the FCode blob is back in a vocabulary drivers/pci.c cannot see (patch 18) — see $VLOG"

      grep -q 'F=-1' <<<"$VL" \
        || fail "REGRESSION: \$find could not see vga-driver-fcode on $A — it is defined into whatever device context arch/$A/init.fs leaves open, and a bare \$find returns 0 while 'dev / words' still lists it (patch 18) — see $VLOG"

      VW="$(grep -oE 'W=[0-9a-f]+' <<<"$VL" | tail -1 | cut -d= -f2)"
      [[ -n "$VW" ]] \
        || fail "the $A probe printed no W= line — openbios-video-width did not resolve, so this track proved nothing about setup_video — see $VLOG"
      [[ "$VW" != 0 ]] \
        || fail "REGRESSION: openbios-video-width is 0 on $A — setup_video() never ran, which means PCI enumeration never reached a VGA-class device (patch 17 on amd64; it has always run on x86) — see $VLOG"

      note "$A: vga-driver-fcode FOUND, openbios-video-width=0x$VW, no undefined-token report during boot"

      if [[ "$A" == amd64 ]]; then
        # @2, NOT @0 — and the difference is TODO 13.3(D), patch 28. The unit
        # address is generated from the node's `reg`, which pci.c used to write
        # in HOST order while every reader decodes it big-endian; on this
        # little-endian arch that made every child of the bridge encode as `@0`,
        # so none of them could be reached by path. QEMU's VGA is at device 2.
        grep -q 'QEMU,VGA@2' <<<"$VL" \
          || fail "REGRESSION: amd64 has no QEMU,VGA@2 under /pci8086,1237@0 — either ob_pci_init() is not being called from arch_init so the bus does not exist (patch 17), or the reg cells are host-ordered again so every child encodes as @0 (patch 28): $(grep -ao 'QEMU,VGA@[0-9a-f,]*' <<<"$VL" | head -1) — see $VLOG"
      fi

      # UNKNOWN, said out loud rather than folded into the pass. A display node
      # exists and nothing points at it; that is a separate defect, not this one.
      # WAS AN UNKNOWN PRINTED ON EVERY RUN, now an assertion. The /aliases
      # entry always existed; it pointed at a path that could not resolve, so
      # `" screen" find-dev` answered 0 and this track could only say so. With
      # 13.3(D) fixed the alias resolves, and a 0 here means it has come undone.
      # find-dev returns ( phandle true | false ), so a bare `.` prints the FLAG
      # and -1 reads like a phandle. The probe now says FOUND/NONE outright —
      # the first version of this assertion accepted `S=-1` as "no phandle" and
      # failed a working firmware.
      grep -qF 'S=NONE' <<<"$VL" \
        && fail "REGRESSION: $A's '\" screen\" find-dev' found nothing — /aliases still carries screen, so this means the path it names cannot be resolved, and every child of the PCI bridge encoding as @0 is exactly what 13.3(D) was — see $VLOG"
      grep -qF 'S=FOUND' <<<"$VL" \
        || fail "$A: the screen-alias probe printed neither FOUND nor NONE, so it proved nothing about the alias either way — see $VLOG"

      # TODO 0.6c/0.6d. Resolving the alias was never the same as being able to
      # USE it: for as long as this track only checked find-dev, `open-dev` on
      # that same node faulted on both arches and nothing said so.
      #
      # AC is the cause and OD is the effect, asserted separately because they
      # were two bugs rather than one. #address-cells was never written on a PCI
      # bus (nothing in pci_database.c sets acells), so my-#acells fell back to
      # its no-property default of 2 and every Forth consumer of decode-phys read
      # one cell short. FB is patch 33's half: the framebuffer BAR was being
      # assigned address 0, so even a correct decode had nothing to map.
      grep -qE 'AC=[[:space:]]*3( |$)' <<<"$VL" \
        || fail "REGRESSION: $A: my-#acells under the VGA node is $(grep -aoE 'AC=[0-9a-f]+' <<<"$VL" | tail -1 | cut -d= -f2), not 3 — the PCI bus has stopped declaring #address-cells, so decode-phys returns fewer cells than pci_encode_phys_addr wrote and pci-bar>pci-addr shifts its stack (TODO 0.6d) — see $VLOG"
      grep -qE 'OD=[[:space:]]*[1-9a-f][0-9a-f]*( |$)' <<<"$VL" \
        || fail "REGRESSION: $A: '\" screen\" open-dev' did not return an ihandle ($(grep -aoE 'OD=[0-9a-f-]+' <<<"$VL" | tail -1)) — opening the display is what faulted before 0.6c/0.6d, with a general protection fault on amd64 and an invalid opcode on x86, both from the same stack underflow — see $VLOG"
      grep -qE 'FB=[[:space:]]*40000000( |$)' <<<"$VL" \
        || fail "REGRESSION: $A: frame-buffer-adr is $(grep -aoE 'FB=[0-9a-f]+' <<<"$VL" | tail -1 | cut -d= -f2), not 40000000 — either the BAR lost its address again (pci_mem_base, TODO 0.6c) or map-fb stopped reaching it — see $VLOG"
      grep -qaE 'Exception|general protection|invalid opcode' <<<"$VL" \
        && fail "REGRESSION: $A threw during the VGA probe — opening the display used to fault and the whole point of 0.6c/0.6d is that it no longer does: $(grep -aoE '(Unexpected Exception|Exception #)[^\n]{0,60}' <<<"$VL" | head -1) — see $VLOG"
    done

    pass "TODO 13.1 DRIVER_VGA + 13.3(D): amd64 enumerates PCI (QEMU,VGA@2 is under the i440FX bridge at its REAL device number, openbios-video-width=0x320), the VGA FCode blob is reachable from \$find on BOTH arches — the 'vga-driver-fcode:' undefined-token report that had been in every x86 boot log is gone — and '\" screen\" find-dev' now returns that node's phandle instead of 0, which it did on every run for as long as pci.c wrote its property cells in host byte order — and the node can now be OPENED as well as found: my-#acells is 3 where a PCI bus that declares nothing defaulted to 2, open-dev returns an ihandle where it used to fault on both arches, and frame-buffer-adr is 40000000 where the BAR used to be assigned address zero (TODO 0.6c/0.6d)"
    ;;
  diagnostics)
    # The Forth bindings report their own failures now (patch 20), and this
    # track is TWO-SIDED IN A SINGLE BOOT, on every arch this lab can drive.
    #
    #   (1) the boot region must be SILENT -- zero feval:/fword:/eword: lines
    #   (2) `test-feval-report` must produce EXACTLY ONE, naming a word that
    #       cannot exist and carrying its throw code
    #
    # Neither half is worth having alone. (1) by itself reads identically
    # whether the reporter works or was compiled out -- a scan that matches
    # nothing prints the same tick as one that is broken. (2) by itself would
    # pass a reporter that fires on everything, which is the failure mode that
    # actually destroys a diagnostic channel: people learn to ignore it. That
    # is not hypothetical here -- the first draft reported from feval() on the
    # interactive path too, so every mistyped word at the 0 > prompt printed a
    # C diagnostic under Forth's own " Aborted.", the same failure said twice.
    # packages/cmdline.c uses feval_quiet() for exactly that reason.
    #
    # test-feval-report is bound in libopenbios/init.c, one place for all three
    # arches, and it is the reporter's own must-catch fixture rather than a
    # real failure someone has to remember to keep broken.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v qemu-system-i386 >/dev/null || skip "qemu-system-i386 not installed"
    command -v qemu-system-ppc >/dev/null || skip "qemu-system-ppc not installed"
    AMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    ADICT="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    XMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    PELF="$WORKDIR/openbios/obj-ppc/openbios-qemu.elf"
    [[ -f "$AMB" && -f "$ADICT" ]] || skip "no amd64 image — run ./build-openbios.sh amd64 first"
    [[ -f "$XMB" && -f "$XDICT" ]] || skip "no x86 image — run ./build-openbios.sh x86 first"
    [[ -f "$PELF" ]] || skip "no ppc image — run ./build-openbios.sh ppc first"
    SELFW='openbios-feval-selftest-no-such-word'
    ESELFW='openbios-eword-selftest-no-such-word'
    for A in amd64 x86 ppc; do
      DLOG="$WORKDIR/diag-$A.log"; DSOCK="$WORKDIR/smoke-diag-$A.sock"
      rm -f "$DLOG" "$DSOCK"
      note "booting $A and firing the reporter's own fixture → $DLOG"
      if [[ "$A" == ppc ]]; then
        # ppc console input needs a muxed pty, as the ppc track documents.
        python3 "$REPO/tools/drive-pty-repl.py" "$DLOG" --timeout 120 \
          --expect "Welcome to OpenBIOS" --expect "0 > " \
          --send 'test-feval-report\r' --expect "> " \
          --send 'test-eword-report\r' --expect "> " \
          --send 'test-printf-precision\r' --expect "> " \
          --send 'test-printf-edges\r' --expect "> " \
          -- qemu-system-ppc -bios "$PELF" -nographic -vga none
        RC=$?
      else
        if [[ "$A" == amd64 ]]; then Q=qemu-system-x86_64; DMB="$AMB"; DDICT="$ADICT"
        else Q=qemu-system-i386; DMB="$XMB"; DDICT="$XDICT"; fi
        "$Q" -M "pc,accel=$ACCEL" -m 512 -kernel "$DMB" -initrd "$DDICT" \
          -display none -serial "unix:$DSOCK,server=on" -no-reboot >/dev/null 2>&1 &
        QPID=$!
        python3 "$REPO/tools/drive-serial-repl.py" "$DSOCK" "$DLOG" --timeout 120 \
          --expect "0 > " \
          --send 'test-feval-report\r' --expect "> " \
          --send 'test-eword-report\r' --expect "> " \
          --send 'test-printf-precision\r' --expect "> " \
          --send 'test-printf-edges\r' --expect "> "
        RC=$?
        kill "$QPID" 2>/dev/null   # by PID, never by pattern
      fi
      [[ $RC -eq 0 ]] || fail "the $A firmware did not reach the prompt for the diagnostics probe (rc=$RC) — see $DLOG"
      DL="$(cat "$DLOG")"

      # (1) SILENT ON A HEALTHY BOOT. Scoped to the output before the first
      # prompt so the fixture fired below cannot be counted as boot noise.
      BOOT="${DL%%0 > *}"
      # UNANCHORED, and the control is why. The first draft matched
      # '^(feval|fword|eword):' and missed the single most important case: for
      # an undefined word, forth/bootstrap/interpreter.fs has ALREADY printed
      # "<word>:" with no newline, so the diagnostic continues that line and
      # never starts one. Re-injecting patch 18's defect alongside a bogus
      # fword() reported 1 failure where there were 2 -- a line-anchored regex
      # standing in for a question about a MESSAGE, which is the mistake
      # tools/check-harness-net.sh made twice.
      NB="$(grep -acE '(feval|fword|eword): ' <<<"$BOOT" || true)"
      [[ "$NB" -eq 0 ]] \
        || fail "REGRESSION: $A printed $NB binding-failure line(s) during a CLEAN boot — something in the firmware is calling feval/fword on a word it cannot reach, which is the class of defect patches 14/16/18/19 each fixed once: $(grep -aoE '(feval|fword|eword): .{0,60}' <<<"$BOOT" | head -3 | tr '\n' '|') — see $DLOG"

      # (2) AND LOUD WHEN IT SHOULD BE. Exactly one line, naming the fixture.
      NF="$(grep -acF "feval: $SELFW" <<<"$DL" || true)"
      [[ "$NF" -eq 1 ]] \
        || fail "REGRESSION: test-feval-report produced $NF 'feval: $SELFW' line(s) on $A, expected exactly 1 — 0 means the reporter in libopenbios/bindings.c is not wired (and assertion 1 above would then pass over ANY silent failure); more than 1 means it fires repeatedly for one throw — see $DLOG"
      # -19 DECIMAL, and the hex is printed beside it on purpose. The Forth
      # sources spell this same code -13, because OpenBIOS's Forth runs in
      # base 16 -- which is why kernel/bootstrap.c says `case -19:` for
      # "undefined word." while forth/bootstrap/interpreter.fs says -13. The
      # first draft of this assertion looked for -13 and went red against a
      # working reporter.
      grep -aqF 'threw -19 (hex -13' <<<"$DL" \
        || fail "REGRESSION: the $A diagnostic did not carry 'threw -19 (hex -13' — the code is the half that says WHICH failure it was, and both bases are printed because the Forth sources and the C table spell the same undefined-word code differently — see $DLOG"

      # (3) libc/vsprintf.c's %s precision, seven fixtures inside the shipped
      # firmware. SIX of them were wrong before patch 21 -- precision was
      # treated as a MINIMUM, so `%.3s` on "abcdef" printed all six bytes and
      # `%.10s` on "abc" read ten. The seventh, bare `%s`, is the must-NOT-break
      # control: a "fix" that pushed the no-precision path through
      # strnlen(s, -1) would still pass the other six. Run here and not on the
      # host because kernel/bootstrap.c #defines printk to the HOST printf under
      # BOOTSTRAP -- a host harness would test glibc and report on OpenBIOS.
      # TODO 13.3(E): eword()'s "not in the dictionary" branch, which that entry
      # listed as unverified by construction — "reachable only if `evaluate`
      # itself is missing". True of the CALLERS, false of the branch: eword()
      # takes the word as an argument. It is a DIFFERENT failure from a throw
      # (nothing ran at all), and before the reporter existed both left ret==-1
      # and printed the same nothing.
      NE="$(grep -acF "eword: '$ESELFW'" <<<"$DL" || true)"
      [[ "$NE" -eq 1 ]] \
        || fail "REGRESSION: test-eword-report produced $NE \"eword: '$ESELFW'\" line(s) on $A, expected exactly 1 — 0 means _eword()'s not-found branch is unreachable or unwired, which is what made a missing word and a thrown -1 indistinguishable; more than 1 means it fires repeatedly for one lookup — see $DLOG"

      grep -aqF 'printf-precision: 7/7 ok' <<<"$DL" \
        || fail "REGRESSION: $A did not print 'printf-precision: 7/7 ok' — libc/vsprintf.c's %s precision is wrong again, or the fixture set changed size without this assertion: $(grep -aoE 'printf-precision: [^ ]+ .{0,44}BAD' <<<"$DL" | head -3 | tr '\n' '|') — see $DLOG"
      grep -aq 'printf-precision: .* BAD' <<<"$DL" \
        && fail "REGRESSION: $A reported a BAD printf-precision case even though the ratio line passed — the two disagree, which means the counter and the per-case verdict are out of step — see $DLOG"

      # (4) the two paths TODO 13.1c named and did not test: precision on an
      # INTEGER conversion, which is a MINIMUM digit count and runs through
      # number() rather than the %s case, and vsnprintf at the buffer edge.
      # Measured 2026-08-26: number() is right everywhere except `%.0d` of 0,
      # and vsnprintf is right in full -- it truncates, NUL-terminates, returns
      # the UNTRUNCATED length, and leaves the buffer untouched at size 0
      # (checked with a canary, because a correct return value says nothing
      # about whether it wrote).
      #
      # THE DIVERGENCE IS ASSERTED AS ITSELF, not as a failure and not hidden
      # in a pass. `%.0d` of 0 prints "0" where C99 says nothing, because
      # number() does `if (num == 0) tmp[i++] = '0';` unconditionally. Not
      # fixed: no in-tree caller (the only integer conversions with a precision
      # anywhere are ppc's two boot-path `%8.8lx`, asserted correct here), it
      # reads one extra character rather than over-reading like patch 21's bug,
      # and it sits in a boot path on the control arch. If someone fixes it the
      # fixture says DIVERGENCE-CLOSED and this assertion goes red on purpose.
      # TODO 17.4 CLOSED 2026-08-29: this was '14/14 ok, 2/2 recorded
      # divergence' for two months. Both C99 divergences are fixed, so they
      # moved from the divergence counter into the ordinary one, and the
      # previously-untestable LLONG_MIN case joined them: 14 + 2 + 1 = 17.
      #
      # THE '0/0 recorded divergence' HALF IS NOT VESTIGIAL. It is a positive
      # statement that somebody looked. Drop the phrase and a tree carrying a
      # NEW, unrecorded divergence prints exactly what a conformant one prints.
      grep -aqF 'printf-edges: 17/17 ok, 0/0 recorded divergence' <<<"$DL" \
        || fail "REGRESSION: $A did not print 'printf-edges: 17/17 ok, 0/0 recorded divergence' — number()/vsnprintf changed behaviour, or one of TODO 17.4's three fixes (%.0d of 0 producing nothing; the 0 flag ignored when a precision is given; LLONG_MIN negated through an unsigned accumulator) came undone: $(grep -aoE 'printf-edges: [^ ]+ .{0,52}(BAD|MISMATCH)' <<<"$DL" | head -3 | tr '\n' '|') — see $DLOG"

      # (5) THE d-zero LINE IS PINNED PER ARCH, because the two halves of it
      # move independently and a ratio cannot say which one did. All three
      # WRITE "0" where C99 says nothing -- that is the recorded divergence,
      # and it is stable. But the RETURN disagrees by arch:
      #
      #   x86, amd64   wrote=1 ret=1
      #   ppc          wrote=1 ret=0   <- writes a byte, reports writing none
      #
      # The ppc mechanism is NOT established: number() takes the `num == 0`
      # branch, emits one character, and vsnprintf returns str-buf; why that is
      # 0 there and 1 elsewhere has not been traced, and no guess is recorded
      # in place of tracing it. It has NO in-tree caller -- the only integer
      # conversions carrying a precision anywhere are ppc's own two %8.8lx,
      # asserted correct by the fixture -- so it is an UNKNOWN, named here so
      # that it cannot quietly become either a pass or a forgotten bug.
      # ONE EXPECTED LINE FOR ALL THREE ARCHES since 2026-08-27. ppc used to
      # print `ret=0 ... RET-DISAGREES` here and it was recorded as an untraced
      # UNKNOWN (TODO 13.3(C)). It was not the firmware: ppc32 was the only arch
      # in the tree built without -fno-builtin, so GCC treated snprintf as a
      # BUILTIN and computed the return value itself — per C99, where %.0d of 0
      # produces nothing — while leaving the call in place for its side effect,
      # which libc/vsprintf.c performed by writing "0". Two different printfs
      # answering one call. Fixed in config/scripts/switch-arch (patch 29).
      # SINCE TODO 17.4 THIS ASSERTS CONFORMANCE, not the divergence: C99
      # 7.19.6.1p8 says %.0d of 0 produces NO characters, and all three arches
      # now write none and return 0. The line stays pinned per arch for the
      # reason it always was -- wrote= and ret= move independently, and a ratio
      # cannot say which one did.
      DZ='d-zero want[](0) got[](0) ret=0 OK'
      grep -aqF "$DZ" <<<"$DL" \
        || fail "REGRESSION: $A's d-zero line is not '$DZ' — %.0d of 0 changed what it writes, or what it returns, and those are two different defects: $(grep -aoE 'd-zero.{0,72}' <<<"$DL" | head -1) — see $DLOG"
      # THE FIXTURE IS DELIBERATELY NOT MADE OPAQUE to the optimiser. Passing
      # the format through a volatile pointer would stop a compiler answering
      # for our libc — and would also hide the day a build flag lets one, which
      # is the regression this line exists to catch.
      grep -aq 'RET-DISAGREES' <<<"$DL" \
        && fail "REGRESSION: $A reports RET-DISAGREES on d-zero — the length written and the length returned disagree, which means something other than libc/vsprintf.c answered for the return. On ppc that was snprintf left as a GCC builtin; check -fno-builtin in config/scripts/switch-arch before looking at number() — see $DLOG"

      note "$A: 0 binding failures during boot, the two reporter fixtures produced exactly 1 line each naming '$SELFW' and '$ESELFW', 7/7 printf-precision and 17/17 printf-edges cases pass, with 0 recorded C99 divergences left to carry"
    done

    pass "the Forth bindings report their own failures on x86, amd64 and ppc: a clean boot prints ZERO feval/fword/eword lines on all three, and test-feval-report — the reporter's own must-catch fixture — prints exactly one, naming the unresolvable word and its throw code in both bases (-19 decimal, -13 hex — the Forth sources spell it the second way); and libc/vsprintf.c's %s precision now clips instead of over-reading (7/7), while number() precision and vsnprintf's buffer edge are correct on all three (12/12) with and TODO 17.4's two C99 divergences are CLOSED rather than carried — %.0d of 0 now produces no characters and the 0 flag is ignored when a precision is given, both watched to bite by re-injection, and number()'s undefined \`num = -num\` at LLONG_MIN is fixed through an unsigned accumulator, which is what made that case testable at all (17/17, 0/0 recorded divergence), and the ppc-only return-value anomaly that used to sit here as a named UNKNOWN is CLOSED: it was never number(), it was ppc32 being the one arch built without -fno-builtin, so GCC computed snprintf's return itself while our libc wrote the buffer — all three arches now print the same d-zero line. TODO 13.3(E) closes two of its three rows here: eword()'s not-found branch is watched to fire by name, and the untested printf surface it listed — %n and a long long wider than a cell — is now two cases that pass on every arch, including a 60-bit %llx on x86, whose stack cannot hold the value it prints"
    ;;
  client-forth)
    # TODO 13.3(A): x86's `go` reached the Forth trampoline and evaluated
    # NOTHING, and the reason was one mechanism wearing two faces.
    #
    # arch/x86/context.c handed the fcode/forth trampolines the CLIENT
    # program's FLAT segments. But their entry is not a client program -- it is
    # a firmware function (init_forth_context), and x86 relocates itself by
    # REBASING THE GDT, so every Forth address is segment-relative. Run flat,
    # the trampoline read each address at its link-time value, where the
    # original un-relocated copy of the image still sits: a byte-exact snapshot
    # frozen at the instant of relocation. Nothing faults. It is merely STALE.
    #
    # That single fact produced both rows 13.3(A) recorded and could not
    # reconcile: `load-base` "resolving to a different word" is the same $find
    # over an older chain (the stale head predates the `constant load-base`
    # arch_init defines), and `load-size` "fetching a different number" from an
    # identical xt is the same address read in the other window.
    #
    # THE THIRD ASSERTION IS THE ONE THAT MAKES THE OTHER TWO MEAN ANYTHING.
    # On an arch where the two windows are the same memory, running the
    # trampoline in the wrong one is undetectable -- which is exactly why amd64
    # passed throughout: it does not relocate, virt_offset is 0, flat IS
    # reloc. So x86 also proves the windows still DIFFER before its pass is
    # allowed to count. amd64 runs here as the positive control: the arch that
    # never had the bug must not acquire one.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v qemu-system-i386 >/dev/null || skip "qemu-system-i386 not installed"
    command -v genisoimage >/dev/null || skip "genisoimage not installed"
    CAMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    CADI="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    CXMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    [[ -f "$CAMB" && -f "$CADI" ]] || skip "no amd64 image — run ./build-openbios.sh amd64 first"
    [[ -f "$CXMB" && -f "$XDICT" ]] || skip "no x86 image — run ./build-openbios.sh x86 first"

    # Two payloads, one byte of difference that matters. GO.FTH opens with the
    # `\ ` that libopenbios/forth_load.c's is_forth() requires; NOGO.FTH does
    # not, and is otherwise the same program with the same shape of marker in
    # it. The marker being ABSENT from the second run is therefore an observed
    # difference and not an untested assumption -- without it, "the marker did
    # not appear" and "this track cannot see markers" print the same green.
    CST="$WORKDIR/cf-stage"; rm -rf "$CST"; mkdir -p "$CST"
    printf '\\ client-forth payload\n." CLIENT-FORTH-RAN" cr\n' > "$CST/GO.FTH"
    printf '." CLIENT-FORTH-NOGO-RAN" cr\n'                     > "$CST/NOGO.FTH"
    genisoimage -quiet -o "$WORKDIR/cf.iso" -V CFISO -r -J "$CST"

    cf_boot() {   # cf_boot <arch> <logsuffix> <send-steps...>
      local a="$1" tag="$2"; shift 2
      local mb di q sock log
      if [[ "$a" == amd64 ]]; then q=qemu-system-x86_64; mb="$CAMB"; di="$CADI"
      else q=qemu-system-i386; mb="$CXMB"; di="$XDICT"; fi
      sock="$WORKDIR/smoke-cf-$a-$tag.sock"; log="$WORKDIR/cf-$a-$tag.log"
      rm -f "$sock" "$log"
      "$q" -M "pc,accel=$ACCEL" -m 512 -kernel "$mb" -initrd "$di" \
        -cdrom "$WORKDIR/cf.iso" -display none -serial "unix:$sock,server=on" \
        -no-reboot >/dev/null 2>&1 &
      local qpid=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$sock" "$log" --timeout 150 "$@"
      local rc=$?
      kill "$qpid" 2>/dev/null   # by PID, never by pattern
      echo "$rc"
    }

    for A in x86 amd64; do
      note "$A: load + go on a Forth payload → $WORKDIR/cf-$A-run.log"
      RC="$(cf_boot "$A" run \
        --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\go.fth\r' --expect "0 > " \
        --send 'go\r' --expect "0 > " \
        --send '." SVL=" forth-wordlist dup @ swap 400000 load-base - - @ = . cr\r' \
        --expect "0 > " \
        --send '." SVLX=" forth-wordlist dup @ swap @ = . cr\r' --expect "0 > " \
        --send '." CF-END" cr\r' --expect "CF-END")"
      [[ "$RC" -eq 0 ]] || fail "the $A firmware did not finish the client-forth probe (rc=$RC) — see $WORKDIR/cf-$A-run.log"
      CL="$(tr -d '\r' < "$WORKDIR/cf-$A-run.log")"

      # (1) THE OUTCOME. Not "the segments are RELOC" -- whether the payload's
      # own words executed. Scoped past the `go` echo so the command line
      # cannot answer for the firmware.
      CAFTER="${CL#*$'\n'0 > go}"
      grep -aqF 'CLIENT-FORTH-RAN' <<<"$CAFTER" \
        || fail "REGRESSION: $A's \`go\` did not run the Forth payload — the trampoline reached init_forth_context and evaluated nothing (13.3(A)) — see $WORKDIR/cf-$A-run.log"

      # (2) THE NAMED REFUSAL MUST BE GONE. libopenbios/initprogram.c prints
      # this when the size it can see is 0; on x86 that was the stale window
      # answering, and its fingerprint was load-base reading the nvram config
      # word 4000000 on an arch whose shadow constant says otherwise.
      grep -aqF 'init-program: nothing to evaluate' <<<"$CL" \
        && fail "REGRESSION: $A still prints init-program's refusal after \`go\` — $(grep -aoE 'init-program: nothing to evaluate.{0,110}' <<<"$CL" | head -1) — see $WORKDIR/cf-$A-run.log"

      # (3) x86 ONLY: the two windows must still be DIFFERENT memory, or (1)
      # proves nothing about which one the trampoline used. `400000 load-base -`
      # recovers virt_offset from the shadow constant (phys LOAD_BASE_PHYS),
      # so this derives the offset from the running firmware rather than
      # carrying a number that would rot the next time relocation moves.
      if [[ "$A" == x86 ]]; then
        grep -aqE 'SVL=[[:space:]]*0( |$)' <<<"$CAFTER" \
          || fail "x86's live and stale dictionary heads compare EQUAL — either the firmware stopped relocating or the probe is not reading two windows, and until they differ this track cannot tell a fixed trampoline from a lucky one: $(grep -aoE 'SVL=.{0,20}' <<<"$CAFTER" | head -1) — see $WORKDIR/cf-$A-run.log"
        # ...and the same comparison WITHOUT the offset must print -1. A `=`
        # that answered 0 for every input would satisfy the line above while
        # measuring nothing; this is the tautology that says the instrument is
        # connected.
        grep -aqE 'SVLX=[[:space:]]*-1( |$)' <<<"$CAFTER" \
          || fail "x86's SVL comparison cannot report EQUAL even when handed one cell twice, so its 0 above is an artefact of the probe rather than a difference between the windows: $(grep -aoE 'SVLX=.{0,20}' <<<"$CAFTER" | head -1) — see $WORKDIR/cf-$A-run.log"
        note "x86: live head ≠ stale head (and the same probe DOES report -1 on a cell against itself), so the flat window is still a real, wrong place to read from"
      fi

      # (4) THE NEGATIVE CONTROL, in its own boot. Reusing the first would not
      # be one: a load that matches no loader leaves state-valid set from the
      # previous one, so `go` would re-enter the trampoline and evaluate the
      # new bytes anyway. A separate boot asks the question cleanly.
      note "$A: the same program without is_forth()'s magic must NOT run"
      RC="$(cf_boot "$A" ctl \
        --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\nogo.fth\r' --expect "0 > " \
        --send 'go\r' --expect "0 > " \
        --send '." CF-END" cr\r' --expect "CF-END")"
      [[ "$RC" -eq 0 ]] || fail "the $A control boot did not finish (rc=$RC) — see $WORKDIR/cf-$A-ctl.log"
      CC="$(tr -d '\r' < "$WORKDIR/cf-$A-ctl.log")"
      grep -aqF 'CLIENT-FORTH-NOGO-RAN' <<<"$CC" \
        && fail "the $A control RAN a payload libopenbios/forth_load.c's is_forth() must reject — either the magic check is gone or \`go\` is evaluating whatever is at load-base — see $WORKDIR/cf-$A-ctl.log"
      grep -aqF 'No valid state has been set' <<<"$CC" \
        || fail "the $A control neither ran the payload nor refused by name — \`go\` on an unrecognised file must say so (forth/debugging/client.fs:247), and silence here means this control cannot distinguish a refusal from a hang — see $WORKDIR/cf-$A-ctl.log"
    done

    pass "the Forth trampoline runs in the firmware's own segments on both arches: x86's \`go\` evaluates a Forth payload loaded off media (it printed init-program's 'nothing to evaluate' before, reading a stale pre-relocation copy of the dictionary that made \$find walk past the load-base shadow and load-size fetch 0), amd64 — which does not relocate, so the bug could not show — still passes, x86's live and stale dictionary heads are proven to DIFFER so its pass is about the right window, and in a separate boot both arches refuse a payload without is_forth()'s magic by name instead of evaluating it"
    ;;
  pmem-writer)
    # TODO 16's THIRD deliverable, and the one that makes the other two mean
    # something: a 1275-encoded structure written to storage THE FIRMWARE DOES
    # NOT OWN, and then found in the host's file after QEMU is gone.
    #
    # Patch 31 gave the writers a destination; patch 32 gave them a cursor. Both
    # were proven against a dictionary buffer, which is still the firmware's own
    # memory -- so `here` unchanged was the only thing separating them from the
    # arena words they replaced. This aims them at an NVDIMM mapped at
    # 0x100000000: above 4 GiB, reachable only in long mode, and backed by a file
    # on the host. If the bytes are in that file, they left the firmware.
    #
    # WHY THE HOST FILE IS THE ASSERTION AND THE PROMPT IS NOT. `decode-int`
    # reading back what `int!+` wrote proves the two words agree with each other;
    # it would pass just as happily if both were operating on RAM the firmware
    # allocated. Only a reader that is not the firmware can say where the bytes
    # went. This is the same reason the amd64-pmem track greps the image rather
    # than trusting `printenv`.
    #
    # The offset is 4 MiB into the region, well clear of /nvram's own partition
    # at the base: the point is to write beside the firmware's storage, not on
    # top of it.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v od >/dev/null || skip "od not installed — the host-side read is the assertion"
    WMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    WDI="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    [[ -f "$WMB" && -f "$WDI" ]] || skip "no amd64 image — run ./build-openbios.sh amd64 first"

    WNV="$WORKDIR/pmem-writer.img"
    rm -f "$WNV"; truncate -s 64M "$WNV"
    WOFF=$((0x400000))
    WANT="c0 ff ee 01 c0 ff ee 02 c0 ff ee 03"

    # THE BEFORE READING IS A CONTROL, not bookkeeping: a fresh sparse file reads
    # as zeros, so finding the pattern afterwards cannot be something that was
    # already there.
    HAD="$(od -An -tx1 -j "$WOFF" -N 12 "$WNV" | tr -s ' ' | sed 's/^ //;s/ $//')"
    [[ "$HAD" != "$WANT" ]] \
      || fail "the pattern was already at offset $WOFF in a freshly truncated file, so finding it after the write would prove nothing"
    note "before: offset $WOFF reads [$HAD]"

    WSOCK="$WORKDIR/smoke-pw.sock"; WLOG="$WORKDIR/pmem-writer.log"
    rm -f "$WSOCK" "$WLOG"
    qemu-system-x86_64 -M "pc,accel=$ACCEL,nvdimm=on" -m 512,slots=2,maxmem=2G \
      -kernel "$WMB" -initrd "$WDI" \
      -object "memory-backend-file,id=nv,share=on,mem-path=$WNV,size=64M" \
      -device nvdimm,id=nv1,memdev=nv \
      -display none -serial "unix:$WSOCK,server=on" -no-reboot >/dev/null 2>&1 &
    WQ=$!
    python3 "$REPO/tools/drive-serial-repl.py" "$WSOCK" "$WLOG" --timeout 120 \
      --expect "0 > " \
      `# the prompt PRINTS THE STACK DEPTH, and the cursor is deliberately on it` \
      `# between the writes: expecting "0 > " here waits forever, which it did.` \
      --send '." phere0=" here . cr\r' --expect "> " \
      --send '100400000 c0ffee01 swap int!+ c0ffee02 swap int!+\r' --expect "> " \
      --send 'c0ffee03 swap int!+ 100400000 - ." padv=" . cr\r' --expect "> " \
      --send '." phere1=" here . cr\r' --expect "> " \
      --send '100400000 c decode-int ." pi1=" . cr\r' --expect "> " \
      --send 'decode-int ." pi2=" . cr\r' --expect "> " \
      --send 'decode-int ." pi3=" . cr\r' --expect "> " \
      --send 'clear ." PWDONE" cr\r' --expect "PWDONE"
    WRC=$?
    kill "$WQ" 2>/dev/null   # by PID, never by pattern
    sleep 1
    [[ $WRC -eq 0 ]] || fail "the amd64 firmware did not finish the pmem-writer probe (rc=$WRC) — see $WLOG"
    WL="$(tr -d "\r" < "$WLOG")"

    # (1) the firmware's own view: the cursor advanced by three ints, and reading
    # back through the stock 1275 decoder returns what was written.
    grep -qE 'padv=[[:space:]]*c( |$)' <<<"$WL" \
      || fail "the cursor advanced by $(grep -aoE 'padv=[0-9a-f]+' <<<"$WL" | head -1 | cut -d= -f2) bytes across three int!+ calls, not c — see $WLOG"
    for f in 1:c0ffee01 2:c0ffee02 3:c0ffee03; do
      grep -qE "pi${f%%:*}=[[:space:]]*${f#*:}( |$)" <<<"$WL" \
        || fail "field ${f%%:*} read back from pmem as $(grep -aoE "pi${f%%:*}=[0-9a-f-]+" <<<"$WL" | head -1 | cut -d= -f2), not ${f#*:} — see $WLOG"
    done

    # (2) HERE unchanged, across writes to memory 4 GiB up. The whole storage
    # split is this line: a writer that bumped HERE would have put these bytes in
    # the dictionary and copied nothing to the NVDIMM.
    PH0="$(grep -aoE 'phere0=[0-9a-f]+' <<<"$WL" | head -1 | cut -d= -f2)"
    PH1="$(grep -aoE 'phere1=[0-9a-f]+' <<<"$WL" | head -1 | cut -d= -f2)"
    [[ -n "$PH0" && "$PH0" == "$PH1" ]] \
      || fail "HERE moved from ${PH0:-?} to ${PH1:-?} across the pmem writes — the writer allocated instead of writing where it was told, which is exactly what makes it unusable for storage the firmware does not own — see $WLOG"

    # (3) THE ASSERTION. QEMU is gone; this is the host reading its own file.
    GOT="$(od -An -tx1 -j "$WOFF" -N 12 "$WNV" | tr -s ' ' | sed 's/^ //;s/ $//')"
    [[ "$GOT" == "$WANT" ]] \
      || fail "the host image holds [$GOT] at offset $WOFF, not [$WANT] — the firmware read back its own three fields, so int!+ and decode-int agree with each other, but the bytes did not reach storage outside the firmware. That agreement is what this check exists to distrust — see $WLOG"
    note "after:  offset $WOFF reads [$GOT] — big-endian, written by int!+, read by od"

    pass "TODO 16 end to end: three 1275-encoded ints written by int!+ at 0x100400000 — an NVDIMM above 4 GiB, reachable only in long mode — read back through the stock decode-int with HERE unchanged, and found byte-for-byte at offset $WOFF of the host's backing file after QEMU exited, where a fresh file held [$HAD]. The write half is no longer arena-bound (F2 in REVIEW-preboot-forth-binary-structures.md)"
    ;;
  flash-writer)
    # TODO 16, and the answer is NO -- which is the point of measuring it.
    #
    # `pmem-writer` showed a 1275 structure written by int!+ reaching an NVDIMM
    # and surviving into the host's file. The obvious next question is whether
    # that generalizes to the other seam this lab already has: CFI flash. It does
    # not, and the reason is not a defect in the writer.
    #
    # A CFI part is not a store-to seam. arch/x86/openbios.c's lab_flash_write()
    # does the Intel sequence -- 0x20 setup, poll status, 0x40 program per byte,
    # 0xff back to read-array. A bare store into that window is a COMMAND, not
    # data. So the split's conclusion stands but its scope is narrower than the
    # NVDIMM result suggests: the writer produces bytes at an address; getting
    # those bytes into flash is the flash driver's job, above it.
    #
    # THREE THINGS ARE PINNED HERE, and the third is the trap.
    #
    #   1. the window really is the chip -- an erased part reads ff, and the
    #      no-drive control reads 0, so "ff" is a measurement and not a constant
    #   2. a bare store leaves both the array and the host file untouched
    #   3. AIMING AT THE UNCORRECTED ADDRESS LOOKS LIKE IT WORKED. x86 rebases
    #      the GDT, so a Forth address is not a physical one: storing at
    #      `ffbe0000` writes RAM, and reading `ffbe0000` back returns exactly
    #      what was written. Convincing, and nowhere near the flash. This is the
    #      same segment fact as TODO 13.3(A), met from the other side, and it
    #      cost this track two runs before the erased-flash read caught it.
    #
    # A NOTE ON READING THE VALUES BACK OUT. The console echoes the command, so
    # a log contains `r0=" fw @ c@ ...` before it contains `r0=ff ff ff` — a
    # pattern that allows a space right after the `=` matches the echo first and
    # reports an empty value. Every extraction below requires a hex digit
    # immediately after the `=` and takes the LAST match.
    command -v qemu-system-i386 >/dev/null || skip "qemu-system-i386 not installed"
    command -v od >/dev/null || skip "od not installed — the host-side read is an assertion"
    FXMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    [[ -f "$FXMB" && -f "$XDICT" ]] || skip "no x86 image — run ./build-openbios.sh x86 first"
    grep -q 'lab_flash_present' "$WORKDIR/openbios/arch/x86/openbios.c" 2>/dev/null \
      || skip "no CFI flash backing in arch/x86/openbios.c — this track measures that seam"
    FSEA=$(ls /usr/share/seabios/bios.bin /usr/share/qemu/bios.bin 2>/dev/null | head -1)
    [[ -n "$FSEA" ]] || skip "no seabios image found — pflash0 must hold a BIOS or nothing boots"

    FF0="$WORKDIR/fw-flash0.img"; FF1="$WORKDIR/fw-flash1.img"
    rm -f "$FF0" "$FF1"; truncate -s 4M "$FF0"
    dd if="$FSEA" of="$FF0" bs=1 seek=$(( 4*1024*1024 - $(stat -c%s "$FSEA") )) \
       conv=notrunc status=none
    # ERASED, not zeroed: a CFI part in read-array mode returns its contents, and
    # a zero-filled file would make "the store wrote nothing" indistinguishable
    # from "the store wrote zeros".
    head -c 131072 /dev/zero | tr '\000' '\377' > "$FF1"

    _fboot() {  # _fboot <log> <extra-qemu-args-array-name>
      local log="$1"; shift
      rm -f "$WORKDIR/smoke-fw.sock" "$log"
      qemu-system-i386 -M "pc,accel=$ACCEL" -m 512 \
        -kernel "$FXMB" -initrd "$XDICT" "$@" \
        -display none -serial "unix:$WORKDIR/smoke-fw.sock,server=on" \
        -no-reboot >/dev/null 2>&1 &
      local q=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$WORKDIR/smoke-fw.sock" "$log" --timeout 120 \
        --expect "0 > " \
        --send 'variable vo  400000 load-base - vo !\r' --expect "> " \
        --send 'variable fw  ffbe0000 vo @ - fw !\r' --expect "> " \
        --send '." r0=" fw @ c@ . fw @ 1+ c@ . fw @ 2 + c@ . cr\r' --expect "> " \
        --send 'fw @ c0ffee01 swap int!+ c0ffee02 swap int!+\r' --expect "> " \
        --send 'c0ffee03 swap int!+ drop\r' --expect "> " \
        --send '." r1=" fw @ c@ . fw @ 1+ c@ . fw @ 2 + c@ . cr\r' --expect "> " \
        --send 'ffbe0000 c0ffee01 swap int!+ drop\r' --expect "> " \
        --send '." r2=" ffbe0000 c@ . ffbe0001 c@ . ffbe0002 c@ . cr\r' --expect "> " \
        --send 'clear ." FWDONE" cr\r' --expect "FWDONE" >/dev/null 2>&1
      local rc=$?
      kill "$q" 2>/dev/null   # by PID, never by pattern
      sleep 1
      return $rc
    }

    FLOG="$WORKDIR/flash-writer.log"
    note "1/2 storing into the CFI window at 0xffbe0000 → $FLOG"
    _fboot "$FLOG" -drive "if=pflash,format=raw,file=$FF0,unit=0" \
                   -drive "if=pflash,format=raw,file=$FF1,unit=1" \
      || fail "the x86 firmware did not finish the flash-writer probe — see $FLOG"
    FL="$(tr -d "\r" < "$FLOG")"

    grep -qF 'nvram: backed by pflash@0xffbe0000' <<<"$FL" \
      || grep -qF 'pflash holds data that is not an nvram store' <<<"$FL" \
      || fail "the firmware's own CFI probe did not find a chip at 0xffbe0000, so nothing below is about flash — see $FLOG"
    grep -qE 'r0=[[:space:]]*ff ff ff' <<<"$FL" \
      || fail "the corrected window read $(grep -aoE 'r0=[0-9a-f]+( [0-9a-f]+)*' <<<"$FL" | tail -1) instead of an erased part's ff ff ff — the probe is not looking at the chip, and the two assertions after this would be about some other memory — see $FLOG"
    grep -qE 'r1=[[:space:]]*ff ff ff' <<<"$FL" \
      || fail "GOOD NEWS IF DELIBERATE: a bare store into the CFI window changed the array to $(grep -aoE 'r1=[0-9a-f]+( [0-9a-f]+)*' <<<"$FL" | tail -1). CFI parts take commands, not data, so this means something now sits between int! and the chip. Update this track and TODO 16 together — see $FLOG"
    grep -qE 'r2=[[:space:]]*c0 ff ee' <<<"$FL" \
      || fail "storing at the UNCORRECTED address ffbe0000 no longer reads back as c0 ff ee — either x86 stopped rebasing the GDT, or virt_offset stopped applying to Forth addresses. That trap is the reason this track corrects the address at all — see $FLOG"

    FGOT="$(od -An -tx1 -j 0 -N 3 "$FF1" | tr -s ' ' | sed 's/^ //;s/ $//')"
    [[ "$FGOT" == "ff ff ff" ]] \
      || fail "the host flash image now reads [$FGOT] at offset 0 — a bare store reached the part, which CFI says it should not — see $FLOG"

    note "2/2 control: the identical probe with NO flash attached → $FLOG.control"
    _fboot "$FLOG.control" >/dev/null 2>&1
    FC="$(tr -d "\r" < "$FLOG.control")"
    grep -qE 'r0=[[:space:]]*ff ff ff' <<<"$FC" \
      && fail "the no-flash control ALSO read ff ff ff at the window — then ff is a constant this probe would print with or without a chip, and assertion 1 proves nothing — see $FLOG.control"
    note "control read $(grep -aoE 'r0=[0-9a-f]+( [0-9a-f]+)*' <<<"$FC" | tail -1) with no chip attached, so ff ff ff was a measurement"

    pass "TODO 16, scope: a CFI part is NOT a store-to seam, measured rather than assumed. The writer can be AIMED at 0xffbe0000 — the corrected window reads an erased part's ff ff ff where the no-flash control reads something else — but three int!+ stores leave the array and the host image untouched, because a CFI write is a command sequence (0x20/0x40/0xff, arch/x86/openbios.c) and not a store. The split's conclusion holds and its scope is narrower than pmem-writer suggests: the writer produces bytes, the flash driver programs them. And storing at the UNCORRECTED ffbe0000 reads back convincingly as c0 ff ee — into RAM, nowhere near the chip, which is TODO 13.3(A)'s segment fact met from the other side"
    ;;
  mmio-writer)
    # TODO 16's third seam, and it gives a THIRD distinct answer -- which is why
    # it was worth doing rather than assuming it would repeat one of the others.
    #
    #   NVDIMM (pmem-writer)   stores land; the observer is a FILE
    #   CFI flash (flash-writer)  stores are COMMANDS; the array is untouched
    #   VGA text buffer (here)    stores land; the observer is a DEVICE
    #
    # The observer is the point. A backing file can be read after QEMU exits; a
    # display cannot. This asks QEMU's own monitor for a `screendump`, which is
    # outside the firmware in exactly the sense that matters: the firmware
    # cannot fake it, and `decode-int` agreeing with `int!` says nothing about
    # what the hardware did.
    #
    # THIS IS THE LEGACY APERTURE AT 0xB8000, NOT A PCI BAR, and that distinction
    # is a finding rather than a shortcut. Measured 2026-08-27, QEMU's own
    # `info pci` reports the VGA framebuffer as
    #
    #     Bus 0, device 2: BAR0: 32 bit prefetchable memory at 0xffffffffffffffff
    #
    # i.e. UNASSIGNED -- the firmware's PCI allocator gives BAR2 and BAR6
    # addresses inside a ~1 MiB window and never places the 16 MiB BAR0. So the
    # device tree's `assigned-addresses` carries phys.lo = 0 for it, and
    # `" screen" open-dev` faults (general protection fault, dstackcnt=-3)
    # downstream of that same zero. Both are recorded in TODO 16; neither is
    # something this track can route around, because there is no mapped BAR to
    # aim at. The property under test -- a window whose observer is a device --
    # is what 0xB8000 provides.
    #
    # WHY THE WHOLE BUFFER AND NOT FOUR CHARACTERS. The firmware's console paints
    # this same screen, so it scrolls: a four-character write at row 0 is gone
    # by the time the next prompt is drawn, and the first version of this probe
    # duly reported no change at all. Filling all 80x25 cells is scroll-proof.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    MMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    MDI="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    [[ -f "$MMB" && -f "$MDI" ]] || skip "no amd64 image — run ./build-openbios.sh amd64 first"

    MSOCK="$WORKDIR/smoke-mw.sock"; MMON="$WORKDIR/smoke-mw.mon"
    # _count_blue is defined once, above the case — mmio-writer and struct-device
    # both grade a screendump with it, and a second copy would drift.
    # xp reads GUEST PHYSICAL memory from QEMU's monitor. Like screendump it is
    # outside the firmware, but it does not need the device to render anything —
    # which the BAR case below requires, because the VGA is left in 640x480
    # compat mode and scans the LEGACY aperture, not the linear framebuffer. So
    # a store into BAR0 is real and invisible at the same time, and screendump
    # cannot tell it from a store that never happened.
    _xp() {
      MONSOCK="$MMON" python3 - "$1" <<'PYX'
import socket,sys,time,os
s=socket.socket(socket.AF_UNIX); s.connect(os.environ["MONSOCK"]); time.sleep(0.3)
try: s.recv(65536)
except Exception: pass
s.sendall((sys.argv[1]+"\n").encode()); time.sleep(1.2)
out=s.recv(65536).decode(errors="replace")
print(" ".join(l.split(": ",1)[1].strip() for l in out.splitlines() if ": 0x" in l))
PYX
    }
    _shot() {
      python3 - "$1" <<'PYS'
import socket,sys,time,os
s=socket.socket(socket.AF_UNIX); s.connect(os.environ["MMON"]); time.sleep(0.3)
try: s.recv(65536)
except Exception: pass
s.sendall(("screendump "+sys.argv[1]+"\n").encode()); time.sleep(1.5)
PYS
    }
    export MMON

    # _mrun <tag> <write?> — boot, shoot, optionally write, shoot again.
    _mrun() {
      local tag="$1" dowrite="$2"
      rm -f "$MSOCK" "$MMON" "$WORKDIR/mw-$tag".{pre,post}.ppm "$WORKDIR/mw-$tag.log"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 \
        -kernel "$MMB" -initrd "$MDI" \
        -serial "unix:$MSOCK,server=on" -monitor "unix:$MMON,server=on,nowait" \
        -display none -no-reboot >/dev/null 2>&1 &
      local q=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$MSOCK" "$WORKDIR/mw-$tag.log" \
        --timeout 90 --expect "0 > " >/dev/null 2>&1
      local rc=$?
      if [[ $rc -eq 0 ]]; then
        _shot "$WORKDIR/mw-$tag.pre.ppm"
        local args=(--send '." h0=" here . cr\r' --expect "> ")
        [[ "$dowrite" == write ]] && args+=(--send 'b8000 3e8 0 do 411f411f over int! 4 + loop drop\r' --expect "> ")
        args+=(--send '." h1=" here . cr\r' --expect "> " --send 'clear ." MWDONE" cr\r' --expect "MWDONE")
        python3 "$REPO/tools/drive-serial-repl.py" "$MSOCK" "$WORKDIR/mw-$tag.log.w" \
          --timeout 90 "${args[@]}" >/dev/null 2>&1
        rc=$?
        _shot "$WORKDIR/mw-$tag.post.ppm"

        # THE SECOND CASE: a live PCI BAR. Only reachable since TODO 0.6c/0.6d —
        # the framebuffer BAR was assigned address 0 and the display node
        # faulted when opened, so `frame-buffer-adr` was 0 and there was nothing
        # to aim at.
        local bargs=(--send 'clear " screen" open-dev drop\r' --expect "> "
                     --send '." fb=" frame-buffer-adr . cr\r' --expect "> ")
        python3 "$REPO/tools/drive-serial-repl.py" "$MSOCK" "$WORKDIR/mw-$tag.log.b" \
          --timeout 90 "${bargs[@]}" >/dev/null 2>&1
        _xp "xp /8xb 0x40000000" > "$WORKDIR/mw-$tag.bar.pre"
        local wargs=()
        [[ "$dowrite" == write ]] && wargs+=(--send 'frame-buffer-adr 8 0 do c0ffee01 over int! 4 + loop drop\r' --expect "> ")
        wargs+=(--send 'clear ." MWBDONE" cr\r' --expect "MWBDONE")
        python3 "$REPO/tools/drive-serial-repl.py" "$MSOCK" "$WORKDIR/mw-$tag.log.b2" \
          --timeout 90 "${wargs[@]}" >/dev/null 2>&1
        _xp "xp /8xb 0x40000000" > "$WORKDIR/mw-$tag.bar.post"
      fi
      kill "$q" 2>/dev/null   # by PID, never by pattern
      sleep 1
      return $rc
    }

    note "1/2 filling the text buffer at 0xb8000 with int! → $WORKDIR/mw-write.post.ppm"
    _mrun write write || fail "the amd64 firmware did not finish the mmio-writer probe — see $WORKDIR/mw-write.log.w"
    MPRE=$(_count_blue "$WORKDIR/mw-write.pre.ppm")
    MPOST=$(_count_blue "$WORKDIR/mw-write.post.ppm")
    MW="$(tr -d "\r" < "$WORKDIR/mw-write.log.w")"
    MH0="$(grep -aoE 'h0=[0-9a-f]+' <<<"$MW" | tail -1 | cut -d= -f2)"
    MH1="$(grep -aoE 'h1=[0-9a-f]+' <<<"$MW" | tail -1 | cut -d= -f2)"

    [[ "$MPRE" -eq 0 ]] \
      || fail "the display already held $MPRE blue pixels BEFORE the write, so finding them afterwards would prove nothing — the console paints grey on black and should never produce attribute 1f — see $WORKDIR/mw-write.pre.ppm"
    [[ "$MPOST" -gt 50000 ]] \
      || fail "after filling 80x25 cells with attribute 1f the display holds only $MPOST blue pixels — the stores did not reach the aperture, or the screen was repainted before the dump — see $WORKDIR/mw-write.post.ppm"
    [[ -n "$MH0" && "$MH0" == "$MH1" ]] \
      || fail "HERE moved from ${MH0:-?} to ${MH1:-?} across 1000 int! stores into MMIO — the writer allocated instead of writing where it was told — see $WORKDIR/mw-write.log.w"

    # THE BAR CASE. `frame-buffer-adr` is the address patch 33 gave BAR0, and
    # 0.6d made the node openable enough to read it; both had to be true before
    # a single byte could be aimed here.
    MFB="$(grep -aoE 'fb=[0-9a-f]+' "$WORKDIR/mw-write.log.b" | tail -1 | cut -d= -f2)"
    [[ "$MFB" == 40000000 ]] \
      || fail "frame-buffer-adr is ${MFB:-absent}, not 40000000 — the display did not map its BAR, so the write below had no live BAR to aim at (TODO 0.6c/0.6d) — see $WORKDIR/mw-write.log.b"
    MBPRE="$(cat "$WORKDIR/mw-write.bar.pre")"
    MBPOST="$(cat "$WORKDIR/mw-write.bar.post")"
    [[ "$MBPRE" == "0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00" ]] \
      || fail "the BAR already held [$MBPRE] before the write, so finding a pattern there afterwards would prove nothing"
    [[ "$MBPOST" == "0xc0 0xff 0xee 0x01 0xc0 0xff 0xee 0x01" ]] \
      || fail "after two int! stores into BAR0 the monitor reads [$MBPOST] at 0x40000000, not the pattern — the stores did not reach the BAR. Note the display cannot answer this: the VGA is in 640x480 compat mode scanning the LEGACY aperture, so a real store into the linear framebuffer is invisible on screen"
    note "BAR0 at 0x40000000: [$MBPRE] → [$MBPOST], read by the monitor's xp"

    note "2/2 control: the identical boot and dumps with NO write → $WORKDIR/mw-ctl.post.ppm"
    _mrun ctl nowrite || fail "the no-write control did not finish — see $WORKDIR/mw-ctl.log.w"
    MCTL=$(_count_blue "$WORKDIR/mw-ctl.post.ppm")
    [[ "$MCTL" -eq 0 ]] \
      || fail "the no-write control ALSO ended with $MCTL blue pixels, so the colour arrives from booting rather than from int! and the assertion above measures nothing — see $WORKDIR/mw-ctl.post.ppm"
    MCB="$(cat "$WORKDIR/mw-ctl.bar.post")"
    [[ "$MCB" == "0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00" ]] \
      || fail "the no-write control ALSO ended with [$MCB] in BAR0, so those bytes arrive from opening the display rather than from int! — see $WORKDIR/mw-ctl.bar.post"

    pass "TODO 16, the third seam, at BOTH of its addresses: 1000 int! stores into the legacy VGA aperture at 0xb8000 put $MPOST blue pixels on the display where the pre-write dump and the no-write control each hold 0, with HERE unchanged at $MH0 — read by QEMU's screendump, an observer the firmware cannot fake. Stores LAND here (unlike CFI flash, where they are commands) and the observer is a DEVICE (unlike the NVDIMM, where it is a file), which is the third distinct answer. AND at a LIVE PCI BAR since TODO 0.6c/0.6d: two int! stores into the framebuffer at 0x40000000 read back through QEMU's monitor as c0 ff ee 01 c0 ff ee 01 where the pre-write read and the no-write control each hold zeros. That one needs the monitor rather than the display, because the VGA sits in 640x480 compat mode scanning the legacy aperture — a real store into the linear framebuffer is invisible on screen, and screendump cannot tell it from a store that never happened"
    ;;
  struct-layer)
    # REVIEW-preboot-forth-as-a-poke-engine.md G2: the TYPE layer, and its two
    # named checkpoints.
    #
    # WHAT G2 GOT WRONG ABOUT ITS OWN STARTING POINT, found by measuring before
    # writing: it says `create ... does>` is "sitting unused" and the definer is
    # the work. OpenBIOS ALREADY SHIPS the definer --
    # forth/bootstrap/bootstrap.fs:1570 has `0 constant struct` and
    # `: field create over , + does> @ + ;` -- and it works at the prompt
    # untouched (measured 2026-08-29: `struct 4 field a 2 field b 1 field c
    # constant size` gives size=7, offsets 0/4/6). So the ADDRESS half of the
    # type layer has been in the firmware the whole time. What is missing is the
    # TYPE: `field` carries an offset and nothing else, so every read restates
    # the width and the byte order by hand, which is where a binary-structure
    # parser goes wrong.
    #
    # THE TWO CHECKPOINTS, from the review, and they are different questions:
    #   1. a named field of a structure mapped at a chosen address reads back
    #      what a DIFFERENT word wrote there  -- here `int!` (the 1275 encoder,
    #      forth/device/property.fs:353) and `le-l!` (a C binding), neither of
    #      which knows this layer exists;
    #   2. storing THROUGH a field changes the bytes at that address with no
    #      explicit write-back step -- which is what makes it poke's model
    #      rather than an accessor library. GNU poke's manual specifies a
    #      three-step map/modify/poke-back for a scalar because `n` is a copy;
    #      a field here yields the address of the bytes themselves, so there is
    #      no copy to write back from (review §P1).
    #
    # AND THE CONTROLS, because "it read back what was written" is satisfied by
    # a layer that ignores byte order entirely -- a value written and read by
    # one convention round-trips under any convention:
    #   * the ORDER control: the same four bytes read through the other order
    #     must come back byte-REVERSED, in both directions;
    #   * the RAW BYTES beside every store, so the claim is about memory rather
    #     than about a round trip through one accessor pair;
    #   * a POISON byte past the layout: ff before, ff after, so no store ran
    #     long -- and ff first so an inherited zero can never pass for a write;
    #   * TWO VIEWS of one ELF header (e_entry as 4+4 halves, and as one 8-byte
    #     little-endian field at 0x18) which must agree, so the offsets are not
    #     arithmetic nobody checked;
    #   * THREE REFUSALS by name -- an unsupported width, big-endian 64, and an
    #     8-byte field on a 32-bit cell -- because returning a plausible number
    #     for a width nobody implemented is the LIED rung;
    #   * the arch split IS a control: x86's 32-bit cell must refuse the 8-byte
    #     field where amd64 answers it, and every other row must be identical.
    #
    # THE SUBJECT IS A REAL ELF64 and it is the amd64 firmware's own boot image,
    # on BOTH arches, so one host-side ground truth covers both runs. Ground
    # truth is computed from the bytes with struct.unpack, not read off
    # `readelf`'s prose.
    #
    # THE LOADING ORDER IS LOAD-BEARING. `load` always lands at `load-base`, so
    # loading the parser after the subject would overwrite the parser. Define
    # first, load the subject under it, then type ONE SHORT WORD to invoke the
    # parse -- long lines are what a serial console with no flow control drops.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v genisoimage >/dev/null || skip "genisoimage not installed"
    GAMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    GADI="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    GXMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    GXDI="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
    for f in "$GAMB" "$GADI" "$GXMB" "$GXDI"; do
      [[ -f "$f" ]] || skip "missing $f — run ./build-openbios.sh amd64 and x86 first"
    done
    GDSL="$HERE/dsl/struct.fth"
    [[ -f "$GDSL" ]] || fail "the type layer is missing at $GDSL — this track stages the SHIPPED file rather than re-implementing it, so there is nothing to measure"
    GST="$WORKDIR/g2-stage"; rm -rf "$GST"; mkdir -p "$GST"
    cp "$GDSL" "$GST/STRUCT.FTH"
    cp "$HERE/dsl/elf.fth" "$GST/ELF.FTH"          # the shipped artifact, copied not re-typed
    cp "$GAMB" "$GST/SUBJ.ELF"
    cat > "$GST/G2CHK.FTH" <<'FTH'
\ G2 checkpoints. Base is HEX. struct.fth must already be evaluated.
hex
." G2-START" cr

\ Every order/width combination the layer claims, plus one width it does NOT,
\ so the refusal is exercised beside the successes.
struct
  4    field: p-be
  4 le-field: p-le
  2    field: p-bew
  2 le-field: p-lew
  1    field: p-b
  3 le-field: p-odd            \ unsupported width, on purpose
  8    field: p-be8            \ 8-byte BIG-endian: no x@-be exists, on purpose
constant /pat

40 alloc-mem value tb
: poison  40 0 do ff tb i + c! loop ;
poison
." g2-tb=" tb u. cr
." g2-patsize=" /pat . cr

." g2-off-be="  tb p-be  t-adr tb - . cr
." g2-off-le="  tb p-le  t-adr tb - . cr
." g2-off-bew=" tb p-bew t-adr tb - . cr
." g2-off-lew=" tb p-lew t-adr tb - . cr
." g2-off-b="   tb p-b   t-adr tb - . cr

\ CHECKPOINT 1 -- written by int! and le-l!, read by the type layer.
deadbeef tb p-be t-adr int!
cafebabe tb p-le t-adr le-l!
." g2-r-be=" tb p-be t@ u. cr
." g2-r-le=" tb p-le t@ u. cr

\ THE ORDER CONTROL -- the same bytes through the other order.
." g2-x-le-as-be=" tb p-le t-adr l@-be u. cr
." g2-x-be-as-le=" tb p-be t-adr le-l@ u. cr

\ CHECKPOINT 2 -- two immediate forms: the typed store, and a bare store
\ through the field's own address. Neither has a write-back step.
11223344 tb p-le t!
." g2-w-t=" tb p-le t@ u. cr
." g2-w-bytes=" tb p-le t-adr dup c@ u. 1+ dup c@ u. 1+ dup c@ u. 1+ c@ u. cr
55667788 tb p-le t-adr le-l!
." g2-w-adr=" tb p-le t@ u. cr

aabbccdd tb p-be t!
." g2-w-be=" tb p-be t@ u. cr
." g2-w-be-bytes=" tb p-be t-adr dup c@ u. 1+ dup c@ u. 1+ dup c@ u. 1+ c@ u. cr

1234 tb p-bew t!   5678 tb p-lew t!   9a tb p-b t!
." g2-w-bew=" tb p-bew t@ u. cr
." g2-w-bew-bytes=" tb p-bew t-adr dup c@ u. 1+ c@ u. cr
." g2-w-lew=" tb p-lew t@ u. cr
." g2-w-lew-bytes=" tb p-lew t-adr dup c@ u. 1+ c@ u. cr
." g2-w-b=" tb p-b t@ u. cr

." g2-iso-be=" tb p-be t@ u. cr
." g2-iso-le=" tb p-le t@ u. cr
." g2-poison=" tb 10 + c@ u. cr

\ The parse is COMPILED IN so one short word invokes it after the subject is
\ loaded over load-base -- a long line at a console with no flow control drops
\ characters silently.
: g2-elf
  ." g2e-magic="   load-base e_magic    t@ u. cr
  ." g2e-class="   load-base e_class    t@ u. cr
  ." g2e-data="    load-base e_data     t@ u. cr
  ." g2e-type="    load-base e_type     t@ u. cr
  ." g2e-machine=" load-base e_machine  t@ u. cr
  ." g2e-entryhi=" load-base e_entry-hi t@ u. cr
  ." g2e-entrylo=" load-base e_entry-lo t@ u. cr
  ." g2e-size="    load-size u. cr
  ." G2E-END" cr ;

\ Each refusal is its OWN word, so an abort cannot cut the run short.
: g2-x64   ." g2x-entry=" load-base x-entry t@ u. cr ." G2X-END" cr ;
: g2-odd   ." g2o=" tb p-odd t@ u. cr ." G2O-END" cr ;
\ The 8-byte BIG-endian refusal uses a field THIS PROBE declares, not one
\ borrowed from the ELF layout. It borrowed e_pad until 2026-08-30, when
\ dsl/elf.fth split e_abiversion out of the pad and e_pad became 7 bytes — so
\ the fixture started reporting T-ERR-width instead of T-ERR-be64 and the suite
\ caught it. A fixture that depends on an unrelated declaration is a fixture
\ that moves when that declaration does.
: g2-blob  ." g2b=" tb p-be8 t@ u. cr ." G2B-END" cr ;

." G2-END" cr
FTH
    genisoimage -quiet -o "$WORKDIR/g2.iso" -V G2 -r -J "$GST"

    # Ground truth from the SUBJECT'S BYTES, not from readelf's prose: a version
    # string is not an identity and neither is a formatter's line.
    read -r GT_MAGIC GT_CLASS GT_DATA GT_TYPE GT_MACH GT_ENTRY GT_SIZE < <(
      python3 - "$GAMB" <<'PY'
import sys, struct
raw = open(sys.argv[1], 'rb').read()
b = raw[:64]
print("%x %x %x %x %x %x %x" % (
    struct.unpack_from("<I", b, 0)[0], b[4], b[5],
    struct.unpack_from('<H', b, 16)[0], struct.unpack_from('<H', b, 18)[0],
    struct.unpack_from('<Q', b, 24)[0], len(raw)))
PY
    )
    note "subject: $(basename "$GAMB") — ELF64 magic=$GT_MAGIC class=$GT_CLASS type=$GT_TYPE machine=$GT_MACH entry=$GT_ENTRY size=$GT_SIZE (host, from the bytes)"

    # zero-padded hex, so a byte split of a value the firmware printed minimally
    # is a relation to that value rather than a constant written down twice
    g2_le_bytes() { local v; v="$(printf '%08x' $(( 0x$1 )))"; echo "${v:6:2} ${v:4:2} ${v:2:2} ${v:0:2}"; }
    g2_be_bytes() { local v; v="$(printf '%08x' $(( 0x$1 )))"; echo "${v:0:2} ${v:2:2} ${v:4:2} ${v:6:2}"; }
    g2_rev4()     { local v; v="$(printf '%08x' $(( 0x$1 )))"; echo "${v:6:2}${v:4:2}${v:2:2}${v:0:2}"; }

    for A in amd64 x86; do
      if [[ "$A" == amd64 ]]; then MB="$GAMB"; DI="$GADI"; else MB="$GXMB"; DI="$GXDI"; fi
      GSOCK="$WORKDIR/g2-$A.sock"; GLOG="$WORKDIR/g2-$A.log"; rm -f "$GSOCK" "$GLOG"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DI" \
        -cdrom "$WORKDIR/g2.iso" -display none -serial "unix:$GSOCK,server=on" \
        -no-reboot >/dev/null 2>&1 &
      GQ=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$GSOCK" "$GLOG" --timeout 240 \
        --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\struct.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\elf.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\g2chk.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "G2-END" \
        --send 'load /ide@1/cdrom@0:\\subj.elf\r' --expect "0 > " \
        --send 'g2-elf\r' --expect "G2E-END" \
        --send 'g2-x64\r' --expect "0 > " \
        --send 'g2-odd\r' --expect "0 > " \
        --send 'g2-blob\r' --expect "0 > "
      GRC=$?
      kill "$GQ" 2>/dev/null   # by PID, never by pattern
      GL="$(tr -d "\r" < "$GLOG")"

      # UNANCHORED on purpose. The console echoes the command, so `g2o=...`
      # continues the line that echoed `g2-odd`; a `^g2o` pattern reports a
      # present field as missing. That is this repo's line-anchored-regex trap,
      # and it has now been met five times.
      g2v() { grep -aoE "$1=[0-9a-f]+" <<<"$GL" | head -1 | cut -d= -f2; }
      g2b() { sed -n "s/.*$1=\([0-9a-f]\{2\}\( [0-9a-f]\{2\}\)*\).*/\1/p" <<<"$GL" | head -1; }
      g2e() { grep -aoE "$1=[A-Za-z0-9-]+" <<<"$GL" | head -1 | cut -d= -f2; }

      [[ $GRC -eq 0 ]] \
        || fail "G2 on $A: the type-layer probe did not complete (rc=$GRC) — see $GLOG"

      # The layout itself. If `field:` mis-accumulates, every address below is
      # wrong and every value still round-trips through its own error.
      GPS="$(g2v g2-patsize)"
      [[ "$GPS" == 18 ]] \
        || fail "G2 on $A: the pattern layout is 0x${GPS:-absent} bytes, not 0x18 — 4+4+2+2+1+3+8 — so field: is not accumulating widths and every offset below is derived from a broken sum — see $GLOG"
      for pair in be:0 le:4 bew:8 lew:a b:c; do
        GN="${pair%%:*}"; GW="${pair##*:}"
        GO="$(g2v "g2-off-$GN")"
        [[ "$GO" == "$GW" ]] \
          || fail "G2 on $A: field p-$GN sits at offset ${GO:-absent}, not $GW — the definer's running offset is wrong, so 'it read back what was written' would be a statement about the wrong bytes — see $GLOG"
      done

      # CHECKPOINT 1 — a different word wrote it.
      GRBE="$(g2v g2-r-be)"; GRLE="$(g2v g2-r-le)"
      [[ "$GRBE" == deadbeef ]] \
        || fail "G2 checkpoint 1 on $A: a big-endian field over bytes written by int! reads ${GRBE:-absent}, not deadbeef — int! is the 1275 encoder and knows nothing about this layer, which is the whole point of using it to write — see $GLOG"
      [[ "$GRLE" == cafebabe ]] \
        || fail "G2 checkpoint 1 on $A: a little-endian field over bytes written by le-l! reads ${GRLE:-absent}, not cafebabe — see $GLOG"

      # THE ORDER CONTROL — without it checkpoint 1 passes a layer that ignores
      # byte order, because one convention round-trips under any convention.
      GXLB="$(g2v g2-x-le-as-be)"; GXBL="$(g2v g2-x-be-as-le)"
      [[ "$GXLB" == "$(g2_rev4 "$GRLE")" && "$GXLB" != "$GRLE" ]] \
        || fail "G2 order control on $A: the little-endian field's bytes read big-endian give ${GXLB:-absent}, not the reversal $(g2_rev4 "$GRLE") of $GRLE — the order bit is not selecting an accessor, so every round trip above proves only that one accessor is its own inverse — see $GLOG"
      [[ "$GXBL" == "$(g2_rev4 "$GRBE")" && "$GXBL" != "$GRBE" ]] \
        || fail "G2 order control on $A: the big-endian field's bytes read little-endian give ${GXBL:-absent}, not the reversal $(g2_rev4 "$GRBE") of $GRBE — see $GLOG"

      # CHECKPOINT 2 — the store IS the write, and the bytes say so.
      GWT="$(g2v g2-w-t)"; GWB="$(g2b g2-w-bytes)"
      [[ "$GWT" == 11223344 ]] \
        || fail "G2 checkpoint 2 on $A: after storing 11223344 through a little-endian field it reads back ${GWT:-absent} — see $GLOG"
      [[ "$GWB" == "$(g2_le_bytes "$GWT")" ]] \
        || fail "G2 checkpoint 2 on $A: the four bytes at the field are [$GWB], not [$(g2_le_bytes "$GWT")] — the value round-trips through the accessor pair but MEMORY does not hold it in that order, so the type is decorating a copy — see $GLOG"
      GWA="$(g2v g2-w-adr)"
      [[ "$GWA" == 55667788 ]] \
        || fail "G2 §P1 on $A: a bare le-l! through the field's own address (t-adr) then reads back ${GWA:-absent}, not 55667788 — the field does not yield an address into the mapped region, so a store through it is not the write and the layer needs poke's write-back step after all — see $GLOG"
      GWBE="$(g2v g2-w-be)"; GWBB="$(g2b g2-w-be-bytes)"
      [[ "$GWBE" == aabbccdd && "$GWBB" == "$(g2_be_bytes "$GWBE")" ]] \
        || fail "G2 checkpoint 2 on $A: a big-endian typed store reads back ${GWBE:-absent} with bytes [$GWBB] — expected aabbccdd as [$(g2_be_bytes aabbccdd)] — see $GLOG"

      # widths 2 and 1, both orders, with their bytes
      GBEW="$(g2v g2-w-bew)"; GBEWB="$(g2b g2-w-bew-bytes)"
      GLEW="$(g2v g2-w-lew)"; GLEWB="$(g2b g2-w-lew-bytes)"
      GB1="$(g2v g2-w-b)"
      [[ "$GBEW" == 1234 && "$GBEWB" == "12 34" ]] \
        || fail "G2 on $A: the 2-byte big-endian field reads ${GBEW:-absent} with bytes [$GBEWB], not 1234 as [12 34] — see $GLOG"
      [[ "$GLEW" == 5678 && "$GLEWB" == "78 56" ]] \
        || fail "G2 on $A: the 2-byte little-endian field reads ${GLEW:-absent} with bytes [$GLEWB], not 5678 as [78 56] — w@-be and le-w@ are not distinguished at width 2 — see $GLOG"
      [[ "$GB1" == 9a ]] \
        || fail "G2 on $A: the 1-byte field reads ${GB1:-absent}, not 9a — see $GLOG"

      # ISOLATION — a store at one field must not disturb its neighbours, and
      # nothing may run past the layout. The poison is ff so an inherited zero
      # cannot pass for a written byte.
      GIBE="$(g2v g2-iso-be)"; GILE="$(g2v g2-iso-le)"; GPOI="$(g2v g2-poison)"
      [[ "$GIBE" == aabbccdd && "$GILE" == 55667788 ]] \
        || fail "G2 isolation on $A: after writing the 2- and 1-byte fields the 4-byte fields read $GIBE/$GILE instead of aabbccdd/55667788 — a store overran its own width — see $GLOG"
      [[ "$GPOI" == ff ]] \
        || fail "G2 isolation on $A: the poison byte past the layout reads ${GPOI:-absent}, not ff — something wrote beyond the last field — see $GLOG"

      # THE ELF, against ground truth computed from the subject's own bytes.
      for pair in magic:$GT_MAGIC class:$GT_CLASS data:$GT_DATA type:$GT_TYPE machine:$GT_MACH size:$GT_SIZE; do
        GN="${pair%%:*}"; GW="${pair##*:}"
        GV="$(g2v "g2e-$GN")"
        [[ "$GV" == "$GW" ]] \
          || fail "G2/G7 on $A: the firmware parsed e_$GN as ${GV:-absent} where the host reads $GW from the same bytes — the layout's offsets or its byte order disagree with ELF64 — see $GLOG"
      done
      GEHI="$(g2v g2e-entryhi)"; GELO="$(g2v g2e-entrylo)"
      GECOMB="$(printf '%x' $(( (0x$GEHI << 32) | 0x$GELO )))"
      [[ "$GECOMB" == "$GT_ENTRY" ]] \
        || fail "G2/G7 on $A: e_entry read as two 4-byte halves is $GEHI:$GELO = $GECOMB where the host reads $GT_ENTRY — see $GLOG"

      # THE SECOND VIEW, and the arch split. One 8-byte little-endian field at
      # 0x18 must AGREE with the two halves on a 64-bit cell, and must REFUSE by
      # name on a 32-bit one. A layer that truncated instead would print a
      # number that is right in its low half and silently wrong above it — the
      # LIED rung, and exactly the defect TODO 13.2(b) found in l!-be.
      # A REFUSAL IS MEASURED BY WHAT DID NOT HAPPEN, not by what was printed.
      # Each refusing word ends on its own `G2?-END` marker, so an abort is
      # observable as that marker's ABSENCE. Asserting only the printed name
      # would pass a t-width-err that names the width and then returns a number
      # anyway — the message would be right and the operation would have
      # completed, which is the LIED rung wearing an honest label.
      GXE="$(g2e g2x-entry)"
      if [[ "$A" == amd64 ]]; then
        [[ "$GXE" == "$GT_ENTRY" ]] \
          || fail "G2 on amd64: e_entry declared as ONE 8-byte little-endian field at 0x18 reads ${GXE:-absent} where the same bytes read as two halves give $GT_ENTRY — two views of one region disagree, so the offsets are arithmetic nobody checked — see $GLOG"
        grep -qF 'G2X-END' <<<"$GL" \
          || fail "G2 on amd64: the 8-byte field printed a value but its word never reached G2X-END — it aborted after answering, so the answer is not one a caller could have used — see $GLOG"
      else
        [[ "$GXE" == "T-ERR-narrow-cell" ]] \
          || fail "G2 on x86: an 8-byte field on a 32-bit cell returned '${GXE:-absent}' instead of refusing with T-ERR-narrow-cell — if that is a number it is wrong above bit 31 and nothing said so, which is the LIED rung — see $GLOG"
        grep -qF 'G2X-END' <<<"$GL" \
          && fail "G2 on x86: the 8-byte field NAMED the narrow cell and then ran to G2X-END anyway — printing a refusal is not refusing, and whatever it left on the stack is a truncated address — see $GLOG"
      fi

      # THE OTHER TWO REFUSALS, name AND non-completion.
      GODD="$(g2e g2o)"; GBLOB="$(g2e g2b)"
      [[ "$GODD" == "T-ERR-width" ]] \
        || fail "G2 on $A: a 3-byte field — a width the layer does not implement — returned '${GODD:-absent}' instead of refusing by name. A plausible number for an unimplemented width is how a parser reports success while reading the wrong bytes — see $GLOG"
      grep -qF 'G2O-END' <<<"$GL" \
        && fail "G2 on $A: the unimplemented width printed T-ERR-width and then ran to G2O-END — the message is right and the operation completed anyway, so a caller gets a number for a width nobody implemented — see $GLOG"
      [[ "$GBLOB" == "T-ERR-be64" ]] \
        || fail "G2 on $A: an 8-byte BIG-endian field returned '${GBLOB:-absent}' instead of refusing by name — no x@-be exists and inventing one silently is worse than saying so — see $GLOG"
      grep -qF 'G2B-END' <<<"$GL" \
        && fail "G2 on $A: the 8-byte big-endian field printed T-ERR-be64 and then ran to G2B-END — see $GLOG"

      note "$A: layout 0x$GPS, offsets 0/4/8/a/c; int!→BE field $GRBE, le-l!→LE field $GRLE, cross-read $GXLB/$GXBL; t! 11223344 → memory [$GWB]; t-adr le-l! → $GWA; ELF64 magic=$GT_MAGIC type=$GT_TYPE machine=$GT_MACH entry=$GECOMB size=$GT_SIZE; 8-byte view → $GXE"
    done
    pass "REVIEW G2: a TYPE layer over OpenBIOS Forth, both checkpoints met on BOTH arches. The definer was NOT the work — bootstrap.fs:1570 already ships 'struct'/'field' and it works untouched, which the review had wrong; what was missing is width and byte order, and dsl/struct.fth adds exactly that in ~60 lines over accessors that were already there. Checkpoint 1: a named field reads back deadbeef/cafebabe written by int! and le-l!, words that know nothing about the layer. Checkpoint 2: a typed store puts 11223344 into memory as 44 33 22 11 and a BARE le-l! through the field's own address is equally the write — no map/modify/poke-back, because a field yields the bytes rather than a copy of them (§P1). The controls are what make those mean anything: each field read through the OTHER byte order comes back exactly reversed (so 'it round-tripped' is not one accessor being its own inverse), the raw bytes are asserted beside every store, a poison byte past the layout is still ff, and THREE refusals fire by name — an unimplemented width, big-endian 64, and an 8-byte field on x86's 32-bit cell, where truncating would have been the LIED rung. Finally the layer is pointed at a real ELF64 — the amd64 firmware's own boot image, loaded off ISO9660 — and re-derives magic/class/type/machine/entry/size matching ground truth unpacked from the same bytes on the host, with e_entry read BOTH as two 4-byte halves and as one 8-byte field, agreeing"
    ;;
  struct-array)
    # REVIEW G2, second half: ARRAYS of a type — the part of GNU poke's
    # composite model a single mapped struct does not reach. poke writes
    # `Elf64_Phdr[ehdr.e_phnum] @ ehdr.e_phoff`; the Forth equivalent is a
    # stride and an index, which is what dsl/struct.fth's `array:` is.
    #
    # THE SUBJECT STATES ITS OWN LAYOUT, and that is what makes this more than a
    # table of constants. An ELF64 header carries e_ehsize, e_phentsize and
    # e_phnum, so the file says how big its own header is, how big a program
    # header is, and how many there are. Three assertions therefore compare the
    # DECLARATION against the SUBJECT rather than against a number written down
    # here: /elf64-ehdr must equal e_ehsize, /elf64-phdr must equal e_phentsize.
    # An offset that drifted anywhere in the header layout moves the field that
    # would have caught it, which is a self-check no constant can give.
    #
    # AND THE RESULT IS DERIVED, NOT READ. The firmware sums p_filesz across the
    # PT_LOAD segments and prints one number. A walk that gets a single element
    # wrong changes it, so the sum is an assertion about the whole traversal
    # rather than about whichever entry happened to be looked at.
    #
    # THE CONTROL IS THE STRIDE. Walking N elements at the WRONG stride reads N
    # plausible structures out of the middle of somebody else's bytes and every
    # field "succeeds" — nothing errors, the numbers are just from the wrong
    # place. So the probe also walks with a deliberately wrong stride and the
    # values MUST differ; without that row, "the walk worked" is satisfied by an
    # array whose index does nothing.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v genisoimage >/dev/null || skip "genisoimage not installed"
    AAMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    AADI="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    AXMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    AXDI="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
    for f in "$AAMB" "$AADI" "$AXMB" "$AXDI"; do
      [[ -f "$f" ]] || skip "missing $f — run ./build-openbios.sh amd64 and x86 first"
    done
    ADSL="$HERE/dsl/struct.fth"
    [[ -f "$ADSL" ]] || fail "the type layer is missing at $ADSL — this track stages the SHIPPED file rather than re-implementing it"
    AST="$WORKDIR/ga-stage"; rm -rf "$AST"; mkdir -p "$AST"
    cp "$ADSL" "$AST/STRUCT.FTH"
    cp "$HERE/dsl/elf.fth" "$AST/ELF.FTH"
    cp "$AAMB" "$AST/SUBJ.ELF"
    cat > "$AST/GA.FTH" <<'FTH'
hex
." GA-START" cr
." ga-ehsize-decl=" /elf64-ehdr . cr
." ga-phsize-decl=" /elf64-phdr . cr
\ THE STRIDE CONTROL: the same element type at a stride that is wrong by 8.
/elf64-phdr 8 + array: badphdr[]
0 value phtab
0 value nph
: ga-walk
  load-base load-base e_phoff-lo t@ + to phtab
  load-base e_phnum t@ to nph
  ." ga-ehsize="    load-base e_ehsize    t@ u. cr
  ." ga-phentsize=" load-base e_phentsize t@ u. cr
  ." ga-phnum="     nph u. cr
  ." ga-phoffhi="   load-base e_phoff-hi  t@ u. cr
  ." ga-phrel="     phtab load-base - u. cr
  nph 0 do
    phtab i phdr[]
    ." ga-elem=" i .
    ." type=" dup p_type      t@ u.
    ." off="  dup p_offset-lo t@ u.
    ." fsz="  dup p_filesz-lo t@ u.
    ." msz="      p_memsz-lo  t@ u. cr
  loop
  \ ONE DERIVED NUMBER over the whole traversal.
  0 nph 0 do
    phtab i phdr[] dup p_type t@ 1 = if p_filesz-lo t@ + else drop then
  loop
  ." ga-loadsum=" u. cr
  \ the wrong-stride control, at an index where it can actually differ
  ." ga-bad1type=" phtab 1 badphdr[] p_type t@ u. cr
  ." ga-bad1off="  phtab 1 badphdr[] p_offset-lo t@ u. cr
  ." GA-END" cr ;
." GA-READY" cr
FTH
    genisoimage -quiet -o "$WORKDIR/ga.iso" -V GA -r -J "$AST"

    read -r AT_EHSIZE AT_PHENT AT_PHNUM AT_PHOFF AT_SUM AT_BADT AT_BADO < <(
      python3 - "$AAMB" <<'PY'
import sys, struct
b = open(sys.argv[1], 'rb').read()
phoff, = struct.unpack_from('<Q', b, 32)
ehsize, phent, phnum = struct.unpack_from('<HHH', b, 52)
tot = 0
for i in range(phnum):
    t, = struct.unpack_from('<I', b, phoff + i * phent)
    if t == 1:
        fsz, = struct.unpack_from('<Q', b, phoff + i * phent + 32)
        tot += fsz
# what a walk at a stride wrong by 8 would read at index 1
bt, = struct.unpack_from('<I', b, phoff + 1 * (phent + 8))
bo, = struct.unpack_from('<Q', b, phoff + 1 * (phent + 8) + 8)
print("%x %x %x %x %x %x %x" % (ehsize, phent, phnum, phoff, tot, bt, bo & 0xffffffff))
PY
    )
    ARROWS="$(python3 - "$AAMB" <<'PY'
import sys, struct
b = open(sys.argv[1], 'rb').read()
phoff, = struct.unpack_from('<Q', b, 32)
_, phent, phnum = struct.unpack_from('<HHH', b, 52)
for i in range(phnum):
    o = phoff + i * phent
    t, = struct.unpack_from('<I', b, o)
    off, = struct.unpack_from('<Q', b, o + 8)
    fsz, = struct.unpack_from('<Q', b, o + 32)
    msz, = struct.unpack_from('<Q', b, o + 40)
    print("%x %x %x %x %x" % (i, t, off & 0xffffffff, fsz & 0xffffffff, msz & 0xffffffff))
PY
    )"
    note "subject: $(basename "$AAMB") — e_ehsize=$AT_EHSIZE e_phentsize=$AT_PHENT e_phnum=$AT_PHNUM e_phoff=$AT_PHOFF, PT_LOAD filesz sum=$AT_SUM (host, from the bytes)"

    for A in amd64 x86; do
      if [[ "$A" == amd64 ]]; then MB="$AAMB"; DI="$AADI"; else MB="$AXMB"; DI="$AXDI"; fi
      ASOCK="$WORKDIR/ga-$A.sock"; ALOG="$WORKDIR/ga-$A.log"; rm -f "$ASOCK" "$ALOG"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DI" \
        -cdrom "$WORKDIR/ga.iso" -display none -serial "unix:$ASOCK,server=on" \
        -no-reboot >/dev/null 2>&1 &
      AQ=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$ASOCK" "$ALOG" --timeout 240 \
        --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\struct.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\elf.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\ga.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "GA-READY" \
        --send 'load /ide@1/cdrom@0:\\subj.elf\r' --expect "0 > " \
        --send 'ga-walk\r' --expect "GA-END"
      ARC=$?
      kill "$AQ" 2>/dev/null   # by PID, never by pattern
      AL="$(tr -d "\r" < "$ALOG")"
      # UNANCHORED: the console echoes the command, so the first output line
      # continues the echo of `ga-walk`.
      av() { grep -aoE "$1=[0-9a-f]+" <<<"$AL" | head -1 | cut -d= -f2; }

      [[ $ARC -eq 0 ]] \
        || fail "G2/arrays on $A: the walk did not complete (rc=$ARC) — see $ALOG"

      # THE DECLARATION AGAINST THE SUBJECT — three ways, all from the file.
      AED="$(av ga-ehsize-decl)"; AEF="$(av ga-ehsize)"
      [[ "$AED" == "$AT_EHSIZE" && "$AEF" == "$AT_EHSIZE" ]] \
        || fail "G2/arrays on $A: the ehdr layout declares 0x${AED:-absent} bytes and the file's own e_ehsize reads 0x${AEF:-absent}, where the host reads 0x$AT_EHSIZE — a header layout that disagrees with the header it is mapped over means every offset below is describing a different file — see $ALOG"
      APD="$(av ga-phsize-decl)"; APF="$(av ga-phentsize)"
      [[ "$APD" == "$AT_PHENT" && "$APF" == "$AT_PHENT" ]] \
        || fail "G2/arrays on $A: the phdr layout declares 0x${APD:-absent} bytes and the file's e_phentsize reads 0x${APF:-absent}, where the host reads 0x$AT_PHENT — the array's STRIDE and the subject's stride are not the same number, so the walk below steps through the wrong bytes — see $ALOG"
      AN="$(av ga-phnum)"; AOFF="$(av ga-phrel)"; AOHI="$(av ga-phoffhi)"
      [[ "$AN" == "$AT_PHNUM" && "$AOFF" == "$AT_PHOFF" && "$AOHI" == 0 ]] \
        || fail "G2/arrays on $A: phnum=${AN:-absent} phoff=${AOFF:-absent} (hi=${AOHI:-absent}) where the host reads $AT_PHNUM / $AT_PHOFF / 0 — see $ALOG"

      # EVERY ELEMENT, against ground truth.
      while read -r ei et eo ef em; do
        [[ -z "$ei" ]] && continue
        AROW="$(grep -aoE "ga-elem=$ei type=[0-9a-f]+ off=[0-9a-f]+ fsz=[0-9a-f]+ msz=[0-9a-f]+" <<<"$AL" | head -1)"
        AWANT="ga-elem=$ei type=$et off=$eo fsz=$ef msz=$em"
        [[ "$AROW" == "$AWANT" ]] \
          || fail "G2/arrays on $A: program header $ei reads '${AROW:-absent}' where the host reads '$AWANT' — the array is indexing to the wrong element, or a field inside it is at the wrong offset — see $ALOG"
      done <<< "$ARROWS"

      # THE DERIVED NUMBER — one value over the whole traversal.
      ASUM="$(av ga-loadsum)"
      [[ "$ASUM" == "$AT_SUM" ]] \
        || fail "G2/arrays on $A: the firmware summed PT_LOAD p_filesz to 0x${ASUM:-absent} where the host sums 0x$AT_SUM — a single mis-stepped element changes this, which is why it is asserted separately from the per-element rows — see $ALOG"

      # THE STRIDE CONTROL. A stride wrong by 8 must read DIFFERENT bytes; if it
      # does not, the index is not reaching the element and every row above is
      # a statement about element 0 repeated.
      ABT="$(av ga-bad1type)"; ABO="$(av ga-bad1off)"
      [[ "$ABT" == "$AT_BADT" && "$ABO" == "$AT_BADO" ]] \
        || fail "G2/arrays on $A: at a stride wrong by 8, element 1 reads type=${ABT:-absent} off=${ABO:-absent} where the host reads type=$AT_BADT off=$AT_BADO from that same wrong place — the wrong-stride walk is not landing where the arithmetic says, so it cannot serve as the control — see $ALOG"
      AGOODT="$(grep -aoE "ga-elem=1 type=[0-9a-f]+" <<<"$AL" | head -1 | sed 's/.*type=//')"
      [[ -n "$AGOODT" && "$ABT" != "$AGOODT" ]] \
        || fail "G2/arrays on $A: the wrong-stride walk read the SAME type ($ABT) as the correct one at index 1 — the stride is not load-bearing, so 'the walk worked' would pass an array whose index does nothing — see $ALOG"

      note "$A: ehdr decl 0x$AED == file e_ehsize 0x$AEF; phdr decl 0x$APD == e_phentsize 0x$APF; $AN headers at +0x$AOFF walked, PT_LOAD filesz sum 0x$ASUM; wrong stride reads type=$ABT where the right one reads $AGOODT"
    done
    pass "REVIEW G2, arrays: dsl/struct.fth's 'array:' walks the ELF64 program-header table of a real image — the amd64 firmware's own boot image, loaded off ISO9660 — on BOTH arches, and every element matches ground truth unpacked from the same bytes on the host. The layout is checked against the SUBJECT rather than against constants: /elf64-ehdr equals the file's own e_ehsize and /elf64-phdr equals its e_phentsize, so a drifted offset is caught by the field the drift itself moved. The traversal is graded by a DERIVED number — the firmware's own sum of p_filesz across PT_LOAD — which a single mis-stepped element changes. And the control is the stride: the same element type walked at a stride wrong by 8 reads exactly the bytes the host says live at that wrong place, and a DIFFERENT type from the correct walk, so 'the walk worked' cannot be satisfied by an array whose index does nothing"
    ;;
  struct-device)
    # REVIEW G2's last named gap: map a layout over a LIVE DEVICE's registers
    # rather than over RAM, a buffer or a loaded file — and patch 49, which is
    # what asking that question turned up.
    #
    # THE FINDING CAME FIRST AND IT IS THE BIGGER HALF. IEEE 1275 5.3.7.2's six
    # device-register words — rb@ rw@ rl@ rb! rw! rl! — were defined in
    # forth/device/other.fs with bodies containing NO WORDS AT ALL. Measured at
    # the amd64 prompt before anything was written:
    #
    #     b8000 c@   -> 41       (the byte just written there)
    #     b8000 rb@  -> b8000    at depth 1
    #     42 b8002 rb!           left depth 2 having stored nothing
    #
    # forth/device/table.fs:390-395 binds FCode tokens 0x230-0x235 to exactly
    # these words, so the presenting symptom is not a wrong value — it is a
    # STACK SHIFT inside an FCode driver, surfacing somewhere else entirely.
    # Same shape as patch 34 and patch 25.
    #
    # SO THE FIRST ASSERTION IS THE REGRESSION: rb@ must NOT return the address
    # it was given. That is the defect stated as itself, and it is the row that
    # would go red the day someone reverts the patch.
    #
    # WHY THIS IS THE RIGHT SECOND BACKEND. poke's IO spaces are seven function
    # pointers and eight backends (REVIEW §P2) — the same type over a file, over
    # memory, or over a device. 1275 had already made that split; this lab found
    # one side of it unimplemented. dsl/struct.fth's dev-field:/le-dev-field:
    # are the type layer's second backend, built from rb@/rb! ALONE, a byte at a
    # time, so byte order is explicit rather than inherited from the host CPU —
    # which is why a device field reads identically on x86 and amd64 and the
    # arch comparison below means something.
    #
    # WHAT IS DELIBERATELY NOT CLAIMED: nothing here has a read with SIDE
    # EFFECTS. That was the review's actual wording and it is not reachable in
    # this firmware — there are no port-I/O words on x86/amd64 (measured: no
    # bind_func for in/out anywhere) and no config-space accessors either, so
    # the only device seam Forth can reach is MMIO, whose reads are idempotent.
    # An UNKNOWN, said out loud, rather than a pass.
    #
    # AND THE TWO ARCHES ANSWER DIFFERENTLY, which was not the plan. On x86 the
    # typed device write to b8000 reads back perfectly and NEVER REACHES THE
    # DEVICE: arch/x86 relocates by rebasing the GDT, so a Forth address is not
    # a physical one. That row is kept as a POSITIVE assertion rather than a
    # skip — it is the cheap check lying, measured, in the same run as the arch
    # where it tells the truth.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v genisoimage >/dev/null || skip "genisoimage not installed"
    DAMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    DADI="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    DXMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    DXDI="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
    for f in "$DAMB" "$DADI" "$DXMB" "$DXDI"; do
      [[ -f "$f" ]] || skip "missing $f — run ./build-openbios.sh amd64 and x86 first"
    done
    DDSL="$HERE/dsl/struct.fth"
    [[ -f "$DDSL" ]] || fail "the type layer is missing at $DDSL"
    DST="$WORKDIR/gd-stage"; rm -rf "$DST"; mkdir -p "$DST"
    cp "$DDSL" "$DST/STRUCT.FTH"
    cp "$HERE/dsl/elf.fth" "$DST/ELF.FTH"
    cat > "$DST/GD.FTH" <<'FTH'
hex
." GD-START" cr
40 alloc-mem value db
\ ff first, so an inherited zero can never pass for a byte something wrote.
: dpoison  40 0 do ff db i + c! loop ;
dpoison
." gd-addr=" db u. cr
5a db c!
." gd-rb=" db rb@ u. cr
." gd-c="  db c@  u. cr
clear
1234 db 4 + w!
." gd-rw=" db 4 + rw@ u. cr
." gd-w="  db 4 + w@  u. cr
clear
deadbeef db 8 + l!
." gd-rl=" db 8 + rl@ u. cr
." gd-l="  db 8 + l@  u. cr
clear
\ The store half. The DEPTH is the assertion as much as the value: an empty
\ rb! consumed neither operand and left both behind.
0 db c + c!
a5 db c + rb!
." gd-rbdepth=" depth . cr
." gd-rbstore=" db c + c@ u. cr
clear
0 db 10 + w!   5678 db 10 + rw!
." gd-rwdepth=" depth . cr
." gd-rwstore=" db 10 + w@ u. cr
clear
0 db 14 + l!   cafebabe db 14 + rl!
." gd-rldepth=" depth . cr
." gd-rlstore=" db 14 + l@ u. cr
clear
\ A TYPED layout over the live VGA text buffer, through the device backend.
\ The BASE is a value, so the identical painting code can be aimed at the naive
\ address and at the translated one in the same firmware -- which is what makes
\ the x86 comparison a measurement rather than two different programs.
0 value vbase
struct
  1 dev-field: vc-ch
  1 dev-field: vc-attr
constant /vga-cell
/vga-cell array: vcell[]
\ The SAME two bytes as one 2-byte little-endian device field: two views of one
\ region, so the byte-wise assembly is checked against the byte-wise stores.
struct
  2 le-dev-field: vw-cell
constant /vga-word
." gd-cellsize=" /vga-cell . cr
: paint ( ch attr -- )
  7d0 0 do
    over vbase i vcell[] vc-ch   t!
    dup  vbase i vcell[] vc-attr t!
  loop 2drop ;
: report
  ." gd-vw=" vbase vw-cell t@ u. cr
  ." gd-back=" vbase 3e8 vcell[] vc-ch t@ u. cr ;
\ ONE SHORT WORD each, because a long line at a console with no flow control
\ drops characters silently.
\ gd-paint  aims at b8000 RAW -- correct on amd64, a false positive on x86.
\ gd-vpaint aims at b8000 >virt -- correct on BOTH, and the identity on amd64.
: gd-paint   b8000       to vbase  41 1f paint report ." GD-PAINTED" cr ;
: gd-vpaint  b8000 >virt to vbase  41 1f paint report ." GD-PAINTED" cr ;
: gd-addr
  ." gd-lb=" load-base u. cr
  ." gd-voff=" load-base-phys load-base - u. cr
  ." gd-vga=" b8000 >virt u. cr
  ." gd-rt=" b8000 >virt >phys u. cr
  ." GD-ADDR-END" cr ;
\ An 8-byte DEVICE field must refuse: a 64-bit register is not one access on a
\ 32-bit bus, and splitting it silently is the bug nobody sees until the device
\ latches half of it.
struct  8 le-dev-field: vx-wide  constant /vga-wide
: gd-wide  ." gd-wide=" b8000 vx-wide t@ u. cr ." GD-WIDE-END" cr ;
." GD-READY" cr
FTH
    genisoimage -quiet -o "$WORKDIR/gd.iso" -V GD -r -J "$DST"

    # _dshot <monsock> <ppm> — ask QEMU's own monitor for a screendump. The
    # observer is outside the firmware, which is the whole point: the firmware
    # cannot fake what the emulated CRTC scanned out.
    _dshot() {
      DMON="$1" python3 - "$2" <<'PYS'
import socket, sys, time, os
s = socket.socket(socket.AF_UNIX); s.connect(os.environ["DMON"]); time.sleep(0.3)
try: s.recv(65536)
except Exception: pass
s.sendall(("screendump " + sys.argv[1] + "\n").encode()); time.sleep(1.5)
PYS
    }

    # _dxp <monsock> <cmd> — read GUEST PHYSICAL memory through QEMU's monitor.
    # This is the observer that settles the x86 row below, and screendump cannot
    # do it: a store that lands in RAM instead of the aperture leaves the screen
    # exactly as a store that never happened would.
    _dxp() {
      DMON="$1" python3 - "$2" <<'PYX'
import socket, sys, time, os
s = socket.socket(socket.AF_UNIX); s.connect(os.environ["DMON"]); time.sleep(0.3)
try: s.recv(65536)
except Exception: pass
s.sendall((sys.argv[1] + "\n").encode()); time.sleep(1.2)
out = s.recv(65536).decode(errors="replace")
print(" ".join(l.split(": ", 1)[1].strip() for l in out.splitlines() if ": 0x" in l))
PYX
    }

    # _drun <arch> <paint|nopaint> — boot, run the probe, optionally paint, then
    # read the aperture PHYSICALLY and shoot the screen.
    _drun() {
      local A="$1" mode="$2" mb di
      if [[ "$A" == amd64 ]]; then mb="$DAMB"; di="$DADI"; else mb="$DXMB"; di="$DXDI"; fi
      local sock="$WORKDIR/gd-$A-$mode.sock" mon="$WORKDIR/gd-$A-$mode.mon"
      local log="$WORKDIR/gd-$A-$mode.log" ppm="$WORKDIR/gd-$A-$mode.ppm"
      rm -f "$sock" "$mon" "$log" "$ppm"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$mb" -initrd "$di" \
        -cdrom "$WORKDIR/gd.iso" -display none -serial "unix:$sock,server=on" \
        -monitor "unix:$mon,server=on,nowait" -no-reboot >/dev/null 2>&1 &
      local q=$!
      local args=(--expect "0 > "
                  --send 'load /ide@1/cdrom@0:\\struct.fth\r' --expect "0 > "
                  --send 'load-base load-size evaluate\r' --expect "0 > "
                  --send 'load /ide@1/cdrom@0:\\elf.fth\r' --expect "0 > "
                  --send 'load-base load-size evaluate\r' --expect "0 > "
                  --send 'load /ide@1/cdrom@0:\\gd.fth\r' --expect "0 > "
                  --send 'load-base load-size evaluate\r' --expect "GD-READY")
      args+=(--send 'gd-addr\r' --expect "GD-ADDR-END")
      [[ "$mode" == paint  ]] && args+=(--send 'gd-paint\r'  --expect "GD-PAINTED")
      [[ "$mode" == vpaint ]] && args+=(--send 'gd-vpaint\r' --expect "GD-PAINTED")
      args+=(--send 'gd-wide\r' --expect "0 > ")
      python3 "$REPO/tools/drive-serial-repl.py" "$sock" "$log" --timeout 240 "${args[@]}"
      local rc=$?
      _dxp "$mon" "xp /8xb 0xb8000" > "$WORKDIR/gd-$A-$mode.phys"
      _dshot "$mon" "$ppm"
      kill "$q" 2>/dev/null   # by PID, never by pattern
      return $rc
    }

    for A in amd64 x86; do
      _drun "$A" paint
      DRC=$?
      DL="$(tr -d "\r" < "$WORKDIR/gd-$A-paint.log")"
      dv() { grep -aoE "$1=[0-9a-f]+" <<<"$DL" | head -1 | cut -d= -f2; }
      de() { grep -aoE "$1=[A-Za-z0-9-]+" <<<"$DL" | head -1 | cut -d= -f2; }

      [[ $DRC -eq 0 ]] \
        || fail "G2/devices on $A: the probe did not complete (rc=$DRC) — see $WORKDIR/gd-$A-paint.log"

      # THE REGRESSION, stated as the defect itself.
      DADDR="$(dv gd-addr)"; DRB="$(dv gd-rb)"; DC="$(dv gd-c)"
      [[ -n "$DADDR" && "$DRB" != "$DADDR" ]] \
        || fail "REGRESSION on $A: 'addr rb@' returned ${DRB:-absent}, which is the ADDRESS it was given ($DADDR) — IEEE 1275 5.3.7.2's device-register words are empty again (patch 49), so FCode tokens 0x230-0x235 hand a driver an address where a register value belongs — see $WORKDIR/gd-$A-paint.log"
      [[ "$DRB" == "$DC" && "$DRB" == 5a ]] \
        || fail "REGRESSION on $A: rb@ reads ${DRB:-absent} where c@ reads ${DC:-absent} at the same address, and 5a was written there — see $WORKDIR/gd-$A-paint.log"
      DRW="$(dv gd-rw)"; DW="$(dv gd-w)"; DRL="$(dv gd-rl)"; DLL="$(dv gd-l)"
      [[ "$DRW" == "$DW" && "$DRW" == 1234 ]] \
        || fail "REGRESSION on $A: rw@ reads ${DRW:-absent} where w@ reads ${DW:-absent}; 1234 was written there — see $WORKDIR/gd-$A-paint.log"
      [[ "$DRL" == "$DLL" && "$DRL" == deadbeef ]] \
        || fail "REGRESSION on $A: rl@ reads ${DRL:-absent} where l@ reads ${DLL:-absent}; deadbeef was written there — see $WORKDIR/gd-$A-paint.log"

      # THE STORE HALF, and the DEPTH is half the assertion: an empty rb!
      # consumed neither operand, so a driver's stack drifted by two per write.
      for trip in rb:a5 rw:5678 rl:cafebabe; do
        DN="${trip%%:*}"; DV="${trip##*:}"
        DS="$(dv "gd-${DN}store")"; DD="$(dv "gd-${DN}depth")"
        [[ "$DS" == "$DV" ]] \
          || fail "REGRESSION on $A: $DN! stored ${DS:-nothing} where $DV was written — a register write that does nothing is the half of patch 49 that loses data rather than returning the wrong value — see $WORKDIR/gd-$A-paint.log"
        [[ "$DD" == 0 ]] \
          || fail "REGRESSION on $A: after $DN! the stack was ${DD:-absent} deep, not 0 — the word did not consume its operands, which desynchronises every operation after it in an FCode driver. That stack shift, not a wrong value, is how this defect actually presents — see $WORKDIR/gd-$A-paint.log"
      done

      # THE TYPED LAYOUT OVER THE DEVICE, and two views of the same two bytes.
      DCS="$(dv gd-cellsize)"; DVW="$(dv gd-vw)"; DBACK="$(dv gd-back)"
      [[ "$DCS" == 2 ]] \
        || fail "G2/devices on $A: the VGA cell layout is ${DCS:-absent} bytes, not 2 — see $WORKDIR/gd-$A-paint.log"
      [[ "$DVW" == 1f41 ]] \
        || fail "G2/devices on $A: the 2-byte little-endian DEVICE field over the first cell reads ${DVW:-absent}, not 1f41 — the two 1-byte device fields wrote 41 and 1f into those bytes, so a disagreement means the byte-wise assembly in rw@-le and the byte-wise stores in rb! do not describe the same region — see $WORKDIR/gd-$A-paint.log"
      [[ "$DBACK" == 41 ]] \
        || fail "G2/devices on $A: the LAST cell of the array (index 0x3e8) holds ch=${DBACK:-absent}, not 41 — the array reached the first cell and not the last, so the paint below is a statement about one cell — see $WORKDIR/gd-$A-paint.log"

      # THE REFUSAL: no 8-byte device field.
      DWIDE="$(de gd-wide)"
      [[ "$DWIDE" == "T-ERR-devwidth" ]] \
        || fail "G2/devices on $A: an 8-byte device field returned '${DWIDE:-absent}' instead of refusing by name — a 64-bit register is not one access on a 32-bit bus, and splitting it silently is the bug that shows up as the device latching half a value — see $WORKDIR/gd-$A-paint.log"
      grep -qF 'GD-WIDE-END' <<<"$DL" \
        && fail "G2/devices on $A: the 8-byte device field named the refusal and then ran to GD-WIDE-END — printing a refusal is not refusing — see $WORKDIR/gd-$A-paint.log"

      # THE OBSERVERS OUTSIDE THE FIRMWARE, and the address question the type
      # layer does NOT answer.
      #
      # `vbase vw-cell t@` reading back 1f41 is the CHEAP CHECK, and at the RAW
      # b8000 on x86 it is a LIAR: arch/x86 relocates by rebasing the GDT, so a
      # Forth address is not a physical one, the store lands in ordinary RAM and
      # reads back perfectly through the accessor that wrote it.
      #
      # BUT THAT IS A TRANSLATION PROBLEM, NOT A LIMIT, and this track asserts
      # both halves in the same run: the raw address lies on x86, and
      # `b8000 >virt` reaches the real aperture on BOTH arches. virt_offset is
      # DERIVED at the prompt rather than written down — load-base is defined as
      # phys_to_virt(LOAD_BASE_PHYS), so virt_offset = LOAD_BASE_PHYS - load-base
      # — and the derivation is graded by physical memory read from outside.
      DPHYS="$(cat "$WORKDIR/gd-$A-paint.phys")"
      DPIX="$(_count_blue "$WORKDIR/gd-$A-paint.ppm")"
      DLB="$(dv gd-lb)"; DVOFF="$(dv gd-voff)"; DVGA="$(dv gd-vga)"; DRT="$(dv gd-rt)"
      DPAT="0x41 0x1f 0x41 0x1f 0x41 0x1f 0x41 0x1f"

      # The translation must ROUND TRIP, on both arches, or it is arithmetic
      # nobody checked rather than an address map.
      [[ "$DRT" == b8000 ]] \
        || fail "G2/devices on $A: b8000 >virt >phys is ${DRT:-absent}, not b8000 — the address translation does not round trip, so neither direction can be trusted — see $WORKDIR/gd-$A-paint.log"

      if [[ "$A" == amd64 ]]; then
        # amd64 does not relocate, so >virt MUST be the identity. That is the
        # control on the translation itself: a formula that "worked" by shifting
        # everything would show up here as a non-zero offset on the arch whose
        # offset is known to be zero.
        [[ "$DVOFF" == 0 && "$DVGA" == b8000 ]] \
          || fail "G2/devices on amd64: virt_offset came out ${DVOFF:-absent} and b8000 >virt = ${DVGA:-absent}, where amd64 does not relocate at all (arch/amd64/segment.c sets virt_offset = 0) — the translation is inventing an offset on the arch that has none — see $WORKDIR/gd-amd64-paint.log"
        [[ "$DPHYS" == "$DPAT" ]] \
          || fail "G2/devices on amd64: physical 0xb8000 reads [$DPHYS], not the painted 41 1f pattern — the typed device stores did not reach the aperture, and the Forth read-back of $DVW cannot tell you that because it goes through the same translation the store did — see $WORKDIR/gd-amd64-paint.phys"
        [[ "$DPIX" -gt 50000 ]] \
          || fail "G2/devices on amd64: after painting 2000 cells THROUGH THE TYPE LAYER the display holds only $DPIX blue pixels — see $WORKDIR/gd-amd64-paint.ppm"
      else
        # THE FALSE POSITIVE, asserted positively. Without this row the x86 arm
        # would just be "skipped because it does not work", which is the shape
        # that hides a translation bug rather than naming one.
        (( 0x$DVOFF != 0 )) \
          || fail "G2/devices on x86: virt_offset came out 0, so arch/x86 has stopped rebasing the GDT and the false positive below can no longer be demonstrated. That is good news and it invalidates this control — re-derive TODO 13.3(A) — see $WORKDIR/gd-x86-paint.log"
        [[ "$DVW" == 1f41 ]] \
          || fail "G2/devices on x86: the Forth read-back at the RAW b8000 is ${DVW:-absent}, so the false positive this row exists to demonstrate did not occur — see $WORKDIR/gd-x86-paint.log"
        [[ "$DPHYS" != "$DPAT" ]] \
          || fail "G2/devices on x86: physical 0xb8000 DOES hold the pattern written to the raw address — arch/x86 has stopped rebasing, and this row no longer demonstrates the false positive it exists for — see $WORKDIR/gd-x86-paint.phys"
        [[ "$DPIX" -eq 0 ]] \
          || fail "G2/devices on x86: the display holds $DPIX blue pixels although physical 0xb8000 does not hold the pattern — two observers disagree, so one is measuring something other than what it is named for — see $WORKDIR/gd-x86-paint.ppm"
      fi

      # AND THE FIX, on BOTH arches: the same painting code aimed at
      # `b8000 >virt` must reach the real aperture. On amd64 that is the
      # identity and must not regress; on x86 it is the whole point.
      _drun "$A" vpaint
      DVPHYS="$(cat "$WORKDIR/gd-$A-vpaint.phys")"
      DVPIX="$(_count_blue "$WORKDIR/gd-$A-vpaint.ppm")"
      [[ "$DVPHYS" == "$DPAT" ]] \
        || fail "G2/devices on $A: painting through 'b8000 >virt' (= $DVGA) left physical 0xb8000 reading [$DVPHYS], not the 41 1f pattern — the derived virt_offset $DVOFF is wrong, and no Forth-side read can tell you so because it would use the same translation — see $WORKDIR/gd-$A-vpaint.phys"
      [[ "$DVPIX" -gt 50000 ]] \
        || fail "G2/devices on $A: painting through 'b8000 >virt' put only $DVPIX blue pixels on the display — the bytes reached the aperture but the device did not scan them out — see $WORKDIR/gd-$A-vpaint.ppm"

      # THE NO-PAINT CONTROL. Without it, "the screen is blue" is
      # indistinguishable from a firmware that boots blue.
      _drun "$A" nopaint
      DCPIX="$(_count_blue "$WORKDIR/gd-$A-nopaint.ppm")"
      DCPHYS="$(cat "$WORKDIR/gd-$A-nopaint.phys")"
      [[ "$DCPIX" -eq 0 ]] \
        || fail "G2/devices on $A: the identical boot with NO paint ALSO ended with $DCPIX blue pixels, so the colour arrives from booting rather than from the typed device stores — see $WORKDIR/gd-$A-nopaint.ppm"
      [[ "$DCPHYS" != "$DPAT" ]] \
        || fail "G2/devices on $A: the no-paint control ALSO left the 41 1f pattern at physical 0xb8000, so those bytes arrive from booting — see $WORKDIR/gd-$A-nopaint.phys"

      if [[ "$A" == amd64 ]]; then
        note "amd64: rb@/rw@/rl@ = $DRB/$DRW/$DRL, matching c@/w@/l@ and NOT the address $DADDR; rb!/rw!/rl! store at depth 0; load-base=$DLB so virt_offset=$DVOFF and >virt is the IDENTITY (b8000 -> $DVGA); painting raw and translated both reach physical 0xb8000 and put $DPIX/$DVPIX blue pixels up against $DCPIX with no paint"
      else
        note "x86: rb@/rw@/rl@ = $DRB/$DRW/$DRL, matching c@/w@/l@ and NOT the address $DADDR; rb!/rw!/rl! store at depth 0; the RAW b8000 write is a FALSE POSITIVE — Forth reads back $DVW while physical 0xb8000 holds [$DPHYS] and the screen shows $DPIX blue — but load-base=$DLB gives virt_offset=$DVOFF, and painting through b8000 >virt = $DVGA reaches physical 0xb8000 and puts $DVPIX blue pixels up"
      fi
    done
    pass "REVIEW G2's last gap — a layout over a LIVE DEVICE's registers — and the patch that asking it produced. IEEE 1275 5.3.7.2's six device-register words (rb@ rw@ rl@ rb! rw! rl!) had bodies containing NO WORDS AT ALL: a read returned the ADDRESS it was given and a write stored nothing while leaving both operands on the stack. table.fs binds FCode tokens 0x230-0x235 to exactly these, so the defect presents as a STACK SHIFT inside a driver rather than a wrong value — the same shape as patches 25 and 34. Patch 49 gives them their memory-mapped-I/O bodies and this track asserts the defect as itself: rb@ must not return its own argument, all three reads must agree with c@/w@/l@, and all three writes must store AND leave depth 0. On top of that dsl/struct.fth gains dev-field:/le-dev-field: — the type layer's SECOND BACKEND, which is what poke's IO spaces are (§P2) — built from rb@/rb! a byte at a time so byte order is explicit and a device field reads identically on both arches. A typed array of VGA text cells mapped over 0xb8000 paints 2000 cells through the layer and QEMU's screendump, an observer outside the firmware, counts the blue where an identical no-paint boot counts ZERO; the last cell of the array is checked as well as the first; the same two bytes read as one 2-byte little-endian device field agree with the two 1-byte fields that wrote them; and an 8-byte device field REFUSES by name, because a 64-bit register is not one access on a 32-bit bus. AND THE ADDRESS IS A SEPARATE QUESTION FROM THE TYPE, which this track now asserts from both sides in one run. At the RAW b8000 on x86 the typed write is a FALSE POSITIVE: Forth reads back 1f41 while physical 0xb8000 still holds the console's own '0 > ' prompt and the screen shows zero blue, because arch/x86 rebases the GDT and a Forth address is not a physical one. That is asserted positively rather than skipped — the cheap check lying, in the same run as the arch where it tells the truth. AND THEN IT IS FIXED: virt_offset is DERIVED at the prompt (load-base is defined as phys_to_virt(LOAD_BASE_PHYS), so virt_offset = LOAD_BASE_PHYS - load-base, measured 1fd8f430 on x86 and 0 on amd64), and the identical painting code aimed at 'b8000 >virt' reaches physical 0xb8000 and lights the screen on BOTH arches. The translation round-trips, and on amd64 — which does not relocate — it must come out as the exact IDENTITY, which is the control on the formula itself. NOT CLAIMED, and said out loud: no read here has side effects — this firmware exposes no port-I/O and no config-space words, so MMIO is the only device seam Forth can reach and its reads are idempotent. That remains an UNKNOWN"
    ;;
  elf-methods)
    # REVIEW §E1 and §E4, built: constraints that REFUSE a file, and methods
    # that answer semantic questions rather than layout ones.
    #
    # WHY THESE TWO AND NOT THE OTHER FIVE. §E graded eight poke-elf constructs
    # by value-per-line in Forth. E1 is the one this repo was already half
    # doing -- dsl/struct.fth refuses widths it CANNOT represent (T-ERR-*) and
    # said nothing about values it SHOULD NOT accept -- and E4 is the one §G6
    # says the single uniquely-licensed application needs: "which bytes become
    # that address at run time" is the question boot forensics asks.
    #
    # THE FORMAT IS NOW A SEPARATE FILE. dsl/elf.fth sits on dsl/struct.fth,
    # which is poke's own split (elf-64.pk is not libpoke) and §E6's lesson
    # applied to ourselves. The engine no longer mentions ELF at all.
    #
    # A VALIDATOR THAT HAS NEVER REJECTED ANYTHING IS A SCAN THAT MATCHES
    # NOTHING, so three corruptions are injected in the same boot and each must
    # abort BY NAME with both values -- and must not reach the marker after it.
    # That last clause is the lesson struct-layer already paid for: printing a
    # refusal is not refusing.
    #
    # AND THE LOOP CLOSES: elf-new authors a header field-by-field with t!, and
    # the SAME ?elf64 that rejects the corrupted image accepts it. A fixture the
    # code must reject cannot also be its happy path; here they are the same
    # predicate over two different subjects, which is the point.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v genisoimage >/dev/null || skip "genisoimage not installed"
    EAMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    EADI="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    EXMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    EXDI="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
    for f in "$EAMB" "$EADI" "$EXMB" "$EXDI"; do
      [[ -f "$f" ]] || skip "missing $f — run ./build-openbios.sh amd64 and x86 first"
    done
    for f in "$HERE/dsl/struct.fth" "$HERE/dsl/elf.fth"; do
      [[ -f "$f" ]] || fail "missing $f — this track stages the SHIPPED files rather than re-implementing them"
    done
    EST="$WORKDIR/elf-stage"; rm -rf "$EST"; mkdir -p "$EST"
    cp "$HERE/dsl/struct.fth" "$EST/STRUCT.FTH"
    cp "$HERE/dsl/elf.fth"    "$EST/ELF.FTH"
    cp "$HERE/dsl/elf32.fth"  "$EST/ELF32.FTH"
    cp "$EAMB" "$EST/SUBJ.ELF"
    # The ELF32 subject is the firmware's OWN 32-bit payload, padded so the
    # firmware's loader cannot recognise it — see the probe's comment.
    E32SRC="$WORKDIR/openbios/obj-amd64/openbios-builtin.elf32"
    [[ -f "$E32SRC" ]] || skip "missing $E32SRC — run ./build-openbios.sh amd64 first"
    python3 - "$E32SRC" "$EST/EMBED32.BIN" <<'PY'
import sys
open(sys.argv[2], 'wb').write(b'\0' * 512 + open(sys.argv[1], 'rb').read())
PY
    cat > "$EST/EM.FTH" <<'FTH'
hex
." EM-START" cr
\ Each corruption is its OWN word: an abort ends the word, and putting two in
\ one would mean the second never ran. Each ends on a marker whose ABSENCE is
\ the assertion -- printing a refusal is not refusing.
\
\ AND EACH GETS A FRESH COPY. The first draft corrupted load-base in place, so
\ c-class's e_class=0 was still there when c-endian ran and ?elf64 aborted on
\ the CLASS check -- three controls all firing on the first corruption while
\ appearing to test three different fields. A control that is contaminated by
\ the previous control tests nothing, and it looked exactly like a pass.
40 alloc-mem value cpy
: fresh ( -- )  load-base cpy 40 move  cpy elf-at ;
: c-class  ." c1:" fresh 0  @elf e_class  t! ?elf64 ." C1-END" cr ;
: c-ehsize ." c2:" fresh 99 @elf e_ehsize t! ?elf64 ." C2-END" cr ;
: c-endian ." c3:" fresh 2  @elf e_data   t! ?elf64 ." C3-END" cr ;
: c-magic  ." c4:" fresh 0  @elf e_magic  t! ?elf64 ." C4-END" cr ;
: em-good
  load-base elf-at ?elf64 load-size ?phdrs
  ." em-shnum=" elf-shnum u. cr
  ." em-phnum=" elf-phnum u. cr
  ." em-loadbase=" elf-load-base u. cr
  ." em-entry=" @elf e_entry-lo t@ u. cr
  ." em-entryoff=" @elf e_entry-lo t@ vaddr>off u. cr
  ." em-noseg=" 7fff0000 vaddr>off u. cr
  ." EM-GOOD-END" cr ;
: em-names
  elf-shnum 0 ?do ." em-sh=" i u. i sh-name .cstr cr loop
  ." EM-NAMES-END" cr ;
\ Authoring: build a header, then validate it with the predicate that rejects
\ the corrupted one above.
40 alloc-mem value hdr
: em-author
  hdr elf64-new ?elf64
  ." em-a-magic=" @elf e_magic t@ u. cr
  ." em-a-class=" @elf e_class t@ u. cr
  ." em-a-mach=" @elf e_machine t@ u. cr
  ." em-a-ehsize=" @elf e_ehsize t@ u. cr
  ." em-a-phent=" @elf e_phentsize t@ u. cr
  ." em-a-shent=" @elf e_shentsize t@ u. cr
  ." em-hdr=" hdr u. cr
  ." EM-AUTHOR-END" cr ;
\ ── the ELF32 half ─────────────────────────────────────────────────
\ The subject is EMBEDDED AT OFFSET 0x200 of a padded file, for a reason worth
\ recording: `load` of a bare ELF32 never returns, because the firmware's OWN
\ loader recognises it and takes over. Padding puts a non-ELF at offset 0, and
\ binding at 200 is poke's `Elf32_File @ 512#B` -- inspecting a payload inside a
\ container, which is the realistic case anyway.
: em32
  load-base 200 + elf-at
  ?elf  load-size 200 - ?phdrs
  ." em32-class=" elf-class u. cr
  ." em32-ehsize=" @elf e32-ehsize t@ u. cr
  ." em32-phnum=" elf-phnum u. cr
  ." em32-shnum=" elf-shnum u. cr
  ." em32-loadbase=" elf-load-base u. cr
  ." em32-entry=" @elf e32-entry t@ u. cr
  ." em32-entryoff=" @elf e32-entry t@ vaddr>off u. cr
  ." EM32-END" cr ;
\ p32-flags is the SEVENTH member in ELF32 and the SECOND in ELF64. Asserting it
\ per segment is what proves the reorder was honoured rather than the widths
\ merely narrowed -- a wrong order here would print plausible permissions.
: em32-ph
  elf-phnum 0 ?do
    ." em32-ph=" i u.
    i elf32-ph
    ." t=" dup p32-type   t@ u.
    ." f=" dup p32-flags  t@ u.
    ." o=" dup p32-offset t@ u.
    ." z="     p32-filesz t@ u. cr
  loop ." EM32-PH-END" cr ;
: em32-names
  elf-shnum 0 ?do ." em32-sh=" i u. i sh-name .cstr cr loop
  ." EM32-NAMES-END" cr ;
\ CROSS-CLASS CONTROLS: each validator must refuse the other class, or the
\ dispatch is decorative and either would "work" on both.
\ x32on64 needs an ELF64 to point at, and by the time it runs load-base holds
\ the padded ELF32 -- the first draft bound offset 0 of THAT and refused on
\ magic (512 zero bytes) instead of on class, which is a pass for the wrong
\ reason. Keep a pristine copy while the ELF64 is still loaded.
40 alloc-mem value keep64
: keep64! load-base keep64 40 move ." KEPT" cr ;
: x64on32 ." x1:" ?elf64 ." X1-END" cr ;
: x32on64 ." x2:" keep64 elf-at ?elf32 ." X2-END" cr ;
\ ...and the OPTIONAL-FILE claim, tested by taking the hook away again.
: nohook  ." x3:" 0 'x?elf ! ?elf ." X3-END" cr ;
." EM-READY" cr
FTH
    genisoimage -quiet -o "$WORKDIR/elfm.iso" -V ELFM -r -J "$EST"

    read -r ET_SHNUM ET_PHNUM ET_LOADBASE ET_ENTRY ET_ENTRYOFF ET_EHSIZE_64 < <(
      python3 - "$EAMB" <<'PY'
import sys, struct
b = open(sys.argv[1], 'rb').read()
phoff, shoff = struct.unpack_from('<QQ', b, 32)
ehsize, phent, phnum, _, shnum, _ = struct.unpack_from('<HHHHHH', b, 52)
entry, = struct.unpack_from('<Q', b, 24)
base, off = None, -1
for i in range(phnum):
    o = phoff + i * phent
    t, = struct.unpack_from('<I', b, o)
    if t != 1: continue
    va, = struct.unpack_from('<Q', b, o + 16)
    fo, = struct.unpack_from('<Q', b, o + 8)
    msz, = struct.unpack_from('<Q', b, o + 32 + 8)
    base = va if base is None else min(base, va)
    if va <= entry < va + msz and off == -1:
        off = fo + (entry - va)
print("%x %x %x %x %x %x" % (shnum, phnum, base, entry, off, ehsize))
PY
    )
    ET_NAMES="$(python3 - "$EAMB" <<'PY'
import sys, struct
b = open(sys.argv[1], 'rb').read()
shoff, = struct.unpack_from('<Q', b, 40)
shent, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
stroff, = struct.unpack_from('<Q', b, shoff + shstrndx * shent + 24)
for i in range(shnum):
    n, = struct.unpack_from('<I', b, shoff + i * shent)
    e = b.index(b'\0', stroff + n)
    print("%x %s" % (i, b[stroff + n:e].decode()))
PY
    )"
    read -r E3_SHNUM E3_PHNUM E3_LOADBASE E3_ENTRY E3_ENTRYOFF E3_EHSIZE < <(
      python3 - "$E32SRC" <<'P3'
import sys, struct
b = open(sys.argv[1], 'rb').read()
entry, phoff, shoff, _f, ehsize, phent, phnum, _se, shnum, _sx = struct.unpack_from('<IIIIHHHHHH', b, 24)
base, off = None, -1
for i in range(phnum):
    t, o, va, _pa, fsz, msz, _fl, _al = struct.unpack_from('<8I', b, phoff + i * phent)
    if t != 1: continue
    base = va if base is None else min(base, va)
    if va <= entry < va + msz and off == -1: off = o + (entry - va)
print("%x %x %x %x %x %x" % (shnum, phnum, base, entry, off, ehsize))
P3
    )
    E3_PH="$(python3 - "$E32SRC" <<'P3'
import sys, struct
b = open(sys.argv[1], 'rb').read()
phoff, = struct.unpack_from('<I', b, 28)
phent, phnum = struct.unpack_from('<HH', b, 42)
for i in range(phnum):
    t, o, _va, _pa, fsz, _msz, fl, _al = struct.unpack_from('<8I', b, phoff + i * phent)
    print("%x %x %x %x %x" % (i, t, fl, o, fsz))
P3
    )"
    E3_NAMES="$(python3 - "$E32SRC" <<'P3'
import sys, struct
b = open(sys.argv[1], 'rb').read()
shoff, = struct.unpack_from('<I', b, 32)
shent, shnum, shstrndx = struct.unpack_from('<HHH', b, 46)
stroff, = struct.unpack_from('<I', b, shoff + shstrndx * shent + 16)
for i in range(shnum):
    n, = struct.unpack_from('<I', b, shoff + i * shent)
    e = b.index(b'\0', stroff + n)
    print("%x %s" % (i, b[stroff + n:e].decode()))
P3
    )"
    note "ELF64 subject: $(basename "$EAMB") — shnum=$ET_SHNUM phnum=$ET_PHNUM load-base=$ET_LOADBASE entry=$ET_ENTRY → file offset $ET_ENTRYOFF (host, from the bytes)"
    note "ELF32 subject: $(basename "$E32SRC") — shnum=$E3_SHNUM phnum=$E3_PHNUM ehsize=$E3_EHSIZE load-base=$E3_LOADBASE entry=$E3_ENTRY → file offset $E3_ENTRYOFF"

    for A in amd64 x86; do
      if [[ "$A" == amd64 ]]; then MB="$EAMB"; DI="$EADI"; else MB="$EXMB"; DI="$EXDI"; fi
      ESOCK="$WORKDIR/em-$A.sock"; ELOG="$WORKDIR/em-$A.log"; rm -f "$ESOCK" "$ELOG"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DI" \
        -cdrom "$WORKDIR/elfm.iso" -display none -serial "unix:$ESOCK,server=on" \
        -no-reboot >/dev/null 2>&1 &
      EQ=$!
      # Every typed line is kept SHORT on purpose: the console has no flow
      # control, and an over-long line silently loses its tail. Measured while
      # building this: a 100-character control line arrived as `?e` and the
      # firmware answered `?e: undefined word.`
      python3 "$REPO/tools/drive-serial-repl.py" "$ESOCK" "$ELOG" --timeout 240 \
        --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\struct.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\elf.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\elf32.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\em.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "EM-READY" \
        --send 'load /ide@1/cdrom@0:\\subj.elf\r' --expect "0 > " \
        --send 'em-good\r' --expect "EM-GOOD-END" \
        --send 'em-names\r' --expect "EM-NAMES-END" \
        --send 'em-author\r' --expect "EM-AUTHOR-END" \
        --send 'c-class\r'  --expect "0 > " \
        --send 'c-ehsize\r' --expect "0 > " \
        --send 'c-endian\r' --expect "0 > " \
        --send 'c-magic\r'  --expect "0 > " \
        --send 'load-base elf-at keep64!\r' --expect "KEPT" \
        --send 'load /ide@1/cdrom@0:\\embed32.bin\r' --expect "0 > " \
        --send 'em32\r' --expect "EM32-END" \
        --send 'em32-ph\r' --expect "EM32-PH-END" \
        --send 'em32-names\r' --expect "EM32-NAMES-END" \
        --send 'x64on32\r' --expect "0 > " \
        --send 'x32on64\r' --expect "0 > " \
        --send 'load-base 200 + elf-at nohook\r' --expect "0 > "
      ERC=$?
      kill "$EQ" 2>/dev/null   # by PID, never by pattern
      EL="$(tr -d "\r" < "$ELOG")"
      ev() { grep -aoE "$1=[0-9a-f]+" <<<"$EL" | head -1 | cut -d= -f2; }

      [[ $ERC -eq 0 ]] \
        || fail "§E on $A: the probe did not complete (rc=$ERC) — see $ELOG"

      # ── §E1: the constraint ACCEPTS a real file ──────────────────
      grep -qF 'EM-GOOD-END' <<<"$EL" \
        || fail "§E1 on $A: ?elf64 or ?phdrs rejected the firmware's own boot image, which is a valid ELF64 — a constraint that refuses everything is as useless as one that refuses nothing — see $ELOG"

      # ── §E4: the methods, against ground truth from the bytes ────
      for pair in shnum:$ET_SHNUM phnum:$ET_PHNUM loadbase:$ET_LOADBASE entry:$ET_ENTRY entryoff:$ET_ENTRYOFF; do
        EN="${pair%%:*}"; EW="${pair##*:}"
        EV="$(ev "em-$EN")"
        [[ "$EV" == "$EW" ]] \
          || fail "§E4 on $A: $EN reads ${EV:-absent} where the host computes $EW from the same bytes — see $ELOG"
      done
      ENOSEG="$(ev em-noseg)"
      [[ "$ENOSEG" =~ ^f+$ ]] \
        || fail "§E4 on $A: vaddr>off of an address in no PT_LOAD returned ${ENOSEG:-absent} instead of -1 — a lookup that answers for an address it cannot map is the LIED rung — see $ELOG"

      # ── the string table: every section name, in order ───────────
      while read -r si sname; do
        [[ -z "$si" ]] && continue
        EGOT="$(grep -aoE "em-sh=$si [^ ]*" <<<"$EL" | head -1 | sed "s/^em-sh=$si //")"
        [[ "$EGOT" == "$sname" ]] \
          || fail "§E4 on $A: section $si is named '${EGOT:-absent}' where the host reads '$sname' — the string-table read is landing at the wrong offset, or shstrndx is wrong — see $ELOG"
      done <<< "$ET_NAMES"
      ENAMES="$(grep -ac 'em-sh=' <<<"$EL" || true)"
      (( ENAMES == 0x$ET_SHNUM )) \
        || fail "§E4 on $A: $ENAMES section names were printed where the file has 0x$ET_SHNUM sections — the walk stopped early, and a per-name comparison cannot see that — see $ELOG"

      # ── the loop closes: authored, then validated by the SAME word ─
      grep -qF 'EM-AUTHOR-END' <<<"$EL" \
        || fail "§E1 on $A: ?elf64 REJECTED the header elf-new had just authored — the writer and the validator disagree about the format they share, which is worse than either being wrong alone — see $ELOG"
      for pair in magic:464c457f class:2 mach:3e ehsize:40 phent:38 shent:40; do
        EN="${pair%%:*}"; EW="${pair##*:}"
        EV="$(ev "em-a-$EN")"
        [[ "$EV" == "$EW" ]] \
          || fail "§E1 on $A: the authored header's $EN reads ${EV:-absent}, not $EW — see $ELOG"
      done

      # ── THE CONTROLS. Each corruption must abort BY NAME and must
      # ── NOT reach the marker after it.
      for trip in c1:CONSTRAINT c2:CONSTRAINT c3:CONSTRAINT c4:CONSTRAINT; do
        ECN="${trip%%:*}"
        grep -qE "${ECN}:.*CONSTRAINT|${ECN}:" <<<"$EL" \
          || fail "§E1 on $A: control $ECN never ran — see $ELOG"
        grep -qF "${ECN^^}-END" <<<"$EL" \
          && fail "§E1 on $A: a corrupted header reached ${ECN^^}-END, so ?elf64 printed a complaint and RETURNED — printing a refusal is not refusing, and every 'valid' above means nothing — see $ELOG"
      done
      # SIX, not four: the four corruptions above plus the two cross-class
      # controls below (?elf64 on an ELF32, ?elf32 on an ELF64), which are
      # refusals by the same mechanism. Counting them together is deliberate —
      # a constraint that fired twice, or a control that quietly stopped firing,
      # changes this number and nothing else would notice.
      ECOUNT="$(grep -ac 'CONSTRAINT:' <<<"$EL" || true)"
      (( ECOUNT == 6 )) \
        || fail "§E1 on $A: $ECOUNT constraint failures fired where 6 are expected — 4 injected corruptions plus 2 cross-class refusals — see $ELOG"
      grep -qF 'want=2  got=0' <<<"$EL" \
        || fail "§E1 on $A: the e_class failure did not report both values (want=2 got=0). A constraint that says only 'failed' sends the reader back to the prompt to find out which — see $ELOG"
      # The big-endian row is the E2 LIMIT asserted as a refusal: this layer
      # declares byte order per field, so a BE ELF64 would be misread. It says
      # so instead.
      grep -qF 'big-endian ELF' <<<"$EL" \
        || fail "§E2 on $A: e_data=2 (big-endian) was not refused by name — this layer fixes byte order at declaration time and would MISREAD such a file, so passing it silently is the exact defect §E2 records — see $ELOG"

      # ── THE ELF32 HALF ──────────────────────────────────────────
      # Same questions, the other class, through the SAME generic words —
      # which is the whole point of dispatching on e_class.
      grep -qF 'EM32-END' <<<"$EL" \
        || fail "ELF32 on $A: ?elf or ?phdrs rejected the firmware's own 32-bit payload — see $ELOG"
      E3C="$(ev em32-class)"
      [[ "$E3C" == 1 ]] \
        || fail "ELF32 on $A: elf-class reads ${E3C:-absent}, not 1 — the dispatcher is not seeing an ELF32, so every generic below went to the 64-bit half — see $ELOG"
      for pair in ehsize:$E3_EHSIZE phnum:$E3_PHNUM shnum:$E3_SHNUM loadbase:$E3_LOADBASE entry:$E3_ENTRY entryoff:$E3_ENTRYOFF; do
        EN="${pair%%:*}"; EW="${pair##*:}"
        EV="$(ev "em32-$EN")"
        [[ "$EV" == "$EW" ]] \
          || fail "ELF32 on $A: $EN reads ${EV:-absent} where the host computes $EW from the same bytes — see $ELOG"
      done
      # e32-ehsize must be 0x34, and the ELF64 answer 0x40 — if they were equal
      # this row could not tell the two layouts apart at all.
      [[ "$E3_EHSIZE" == 34 && "$ET_EHSIZE_64" == 40 ]] \
        || fail "ELF32 on $A: the two classes report header sizes $E3_EHSIZE and $ET_EHSIZE_64; they must be 34 and 40 or this comparison proves nothing"

      # p32-flags is the SEVENTH member in ELF32 and the SECOND in ELF64. A port
      # that narrowed the widths and kept the order would read p_flags out of
      # p_offset and print plausible permissions. This is the row that catches it.
      while read -r pi pt pf po pz; do
        [[ -z "$pi" ]] && continue
        PROW="$(grep -aoE "em32-ph=$pi t=[0-9a-f]+ f=[0-9a-f]+ o=[0-9a-f]+ z=[0-9a-f]+" <<<"$EL" | head -1)"
        PWANT="em32-ph=$pi t=$pt f=$pf o=$po z=$pz"
        [[ "$PROW" == "$PWANT" ]] \
          || fail "ELF32 on $A: program header $pi reads '${PROW:-absent}' where the host reads '$PWANT' — if only the f= field differs, the ELF64 field ORDER was used for an ELF32 phdr — see $ELOG"
      done <<< "$E3_PH"

      while read -r si sname; do
        [[ -z "$si" ]] && continue
        EGOT="$(grep -aoE "em32-sh=$si [^ ]*" <<<"$EL" | head -1 | sed "s/^em32-sh=$si //")"
        [[ "$EGOT" == "$sname" ]] \
          || fail "ELF32 on $A: section $si is named '${EGOT:-absent}' where the host reads '$sname' — see $ELOG"
      done <<< "$E3_NAMES"

      # ── CROSS-CLASS CONTROLS. Each validator must refuse the other
      # ── class, or the dispatch is decorative.
      grep -qF 'X1-END' <<<"$EL" \
        && fail "ELF32 on $A: ?elf64 ACCEPTED an ELF32 — the class check is not doing anything and either validator would 'work' on either file — see $ELOG"
      grep -qF 'X2-END' <<<"$EL" \
        && fail "ELF32 on $A: ?elf32 ACCEPTED an ELF64 — see $ELOG"
      grep -qF 'not ELF32 (e_class)' <<<"$EL" \
        || fail "ELF32 on $A: ?elf32 did not refuse the ELF64 by name — see $ELOG"
      # ── and the OPTIONAL-FILE claim: with the hook cleared, an ELF32 must
      # ── say which file is missing rather than misreading it as ELF64.
      grep -qF 'X3-END' <<<"$EL" \
        && fail "ELF32 on $A: with the ELF32 hook cleared, ?elf still completed — so an ELF32 would be handled by the 64-bit half when dsl/elf32.fth is absent, which is the silent misread the hook exists to prevent — see $ELOG"
      grep -qF 'dsl/elf32.fth is not loaded' <<<"$EL" \
        || fail "ELF32 on $A: the missing-hook path did not name dsl/elf32.fth — see $ELOG"

      note "$A/ELF32: class=$E3C ehsize=$E3_EHSIZE (vs 40 for ELF64), $E3_PHNUM phdrs with p32-flags read from the SEVENTH member, $E3_SHNUM section names, load-base=$(ev em32-loadbase), entry $(ev em32-entry) → file offset $(ev em32-entryoff); ?elf64 and ?elf32 each refuse the other class, and a cleared hook names the missing file"
      note "$A: ?elf64+?phdrs accept the real image; load-base=$(ev em-loadbase), entry $(ev em-entry) → file offset $(ev em-entryoff), unmapped → -1; $ENAMES section names match the host; elf-new authored a header the same ?elf64 accepts; 4/4 corruptions refused by name and none returned"
    done
    pass "REVIEW §E1 and §E4, built and measured on BOTH arches. The format moved into dsl/elf.fth on top of dsl/struct.fth — poke's own split (elf-64.pk is not libpoke), §E6's lesson applied to ourselves — and the engine no longer mentions ELF. §E1: ?elf64 carries poke-elf's constraints as predicates that ABORT with what they wanted and what they got, including its implication (e_osabi == NONE => e_abiversion == 0) which is just 'a 0= b or'; ?phdrs refuses a PT_LOAD running past EOF. §E4: elf-load-base is poke's get_load_base (min p_vaddr over PT_LOAD = $ET_LOADBASE), vaddr>off is vaddr_to_file_offset (entry $ET_ENTRY lives at file offset $ET_ENTRYOFF, and an address in no segment returns -1 rather than a plausible number), and sh-name reads the section-name STRING TABLE — all 0x$ET_SHNUM names match the host, in order. The controls are what make those mean anything: four corruptions injected into a real header — class, ehsize, byte order, magic — each aborts BY NAME with both values and NONE reaches the marker after it, because printing a refusal is not refusing. And the loop closes: elf-new authors a header field-by-field with t! and the SAME ?elf64 that rejects the corrupted image accepts it. The big-endian row is §E2's limit stated as a refusal rather than hidden: this layer declares byte order per field, so it says so instead of misreading the file. AND BOTH CLASSES: dsl/elf32.fth adds ELF32 and the generic words dispatch on e_class, measured against the firmware's OWN 32-bit payload — ehsize 0x34 against ELF64's 0x40, all three program headers including p32-flags read from the SEVENTH member where ELF64 puts it SECOND (a port that narrowed the widths and kept the order would print plausible permissions out of p_offset), all ten section names, load base and vaddr-to-file-offset. Its controls are the ones that make the dispatch mean anything: ?elf64 refuses the ELF32 and ?elf32 refuses the ELF64, each by name, and clearing the hook makes an ELF32 report WHICH FILE IS MISSING instead of silently going to the 64-bit half. The ELF32 subject is embedded at offset 0x200 of a padded file because `load` of a bare ELF32 never returns — the firmware's own loader recognises it and takes over"
    ;;
  rmw-fields)
    # mudge, "FORTH Hacking on Sparc Hardware", Phrack 53:9 (1998) --
    # upstream-tutorial/. His headline example is a READ-MODIFY-WRITE on a device
    # register: `:light-on 1 aux@ or aux! ;`. dsl/struct.fth generalises that to
    # t-set / t-clr / t-tog over a TYPED field -- NOT named for an LED, because
    # the point is that the width, byte order and address space ride along and
    # the same word works on a scratch byte and on a device register.
    #
    # THE PROPERTY THAT MAKES RMW != A PLAIN WRITE is that it preserves the OTHER
    # bits, which is the whole reason mudge wrote `aux@ or aux!` and not `1 aux!`.
    # On a device register those neighbouring bits belong to other functions, so
    # this is correctness, not tidiness. Every positive row here is paired with a
    # bare `t!` control that DESTROYS the neighbour, so "it set the bit" cannot be
    # satisfied by a word that also clobbered everything else.
    #
    # TWO PHASES: a memory field (deterministic, read back over serial) and a
    # DEVICE register (through rb@/rb! over the VGA aperture, read back as
    # physical memory by QEMU's monitor -- an observer outside the firmware,
    # because a store that went nowhere reads back perfectly through the same
    # accessor). Both on both arches.
    command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v genisoimage >/dev/null || skip "genisoimage not installed"
    RAMB="$WORKDIR/openbios/obj-amd64/openbios.multiboot"
    RADI="$WORKDIR/openbios/obj-amd64/openbios-amd64.dict"
    RXMB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
    RXDI="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
    for f in "$RAMB" "$RADI" "$RXMB" "$RXDI"; do
      [[ -f "$f" ]] || skip "missing $f — run ./build-openbios.sh amd64 and x86 first"
    done
    [[ -f "$HERE/dsl/struct.fth" ]] || fail "the engine is missing at $HERE/dsl/struct.fth"
    RST="$WORKDIR/rmw-stage"; rm -rf "$RST"; mkdir -p "$RST"
    cp "$HERE/dsl/struct.fth" "$RST/STRUCT.FTH"
    cat > "$RST/RMW.FTH" <<'FTH'
hex
." RMW-START" cr
struct  1    field: st  constant /reg
struct  4 le-field: w   constant /wreg
struct  4    field: bw  constant /bwreg
struct  1 dev-field: d-ch  1 dev-field: d-at  constant /dc
/dc array: dcell[]
40 alloc-mem value r

\ ── memory field: set / clear / toggle, each beside its naive control ──
: rmw-mem
  80 r st t!                    ." rm-init="  r st t@ u. cr   \ a neighbour bit
  1  r st t-set                 ." rm-set="   r st t@ u. cr   \ 81  bit 7 SURVIVES
  1  r st t-clr                 ." rm-clr="   r st t@ u. cr   \ 80  bit 7 still there
  80 r st t!  1 r st t!         ." rm-naive="  r st t@ u. cr  \ 01  bit 7 DESTROYED
  80 r st t!  1 r st t-tog  1 r st t-tog
                                ." rm-xor2="  r st t@ u. cr   \ 80  xor round-trips
  0  r st t!  f0 r st t-set  0f r st t-set
                                ." rm-full="  r st t@ u. cr   \ ff  two sets compose
  aa r st t!  0f r st t-clr     ." rm-clrlow=" r st t@ u. cr  \ a0  low nibble gone
  ." RMW-MEM-END" cr ;

\ ── the mask is applied to the VALUE, so byte order is honoured ────────
: rmw-le
  ff000000 r w t!              ." rl-init=" r w t@ u. cr      \ ff000000
  1 r w t-set                  ." rl-set="  r w t@ u. cr      \ ff000001
  ." rl-bytes=" r w t-adr dup c@ u. 1+ dup c@ u. 1+ dup c@ u. 1+ c@ u. cr  \ 01 00 00 ff
  ." RMW-LE-END" cr ;

\ ── AND THE OTHER ORDER, which is the DEFAULT one ──────────────────────
\ `field:` is BIG-endian -- the 1275-native order (dsl/struct.fth:117) -- and
\ without this word it was exercised in this track only at WIDTH 1, where byte
\ order is a no-op. So l!-be/l@-be never ran under t-set at all: the LE row
\ above proved "the mask applies to the decoded value" for one order and the
\ track's claim that byte order rides along rested on the untested half. The
\ mirror image of rmw-le, and the bytes must come out reversed from it.
: rmw-be
  ff000000 r bw t!             ." rb-init=" r bw t@ u. cr      \ ff000000
  1 r bw t-set                 ." rb-set="  r bw t@ u. cr      \ ff000001
  ." rb-bytes=" r bw t-adr dup c@ u. 1+ dup c@ u. 1+ dup c@ u. 1+ c@ u. cr  \ ff 00 00 01
  ." RMW-BE-END" cr ;

\ ── device register: the same idiom over the VGA aperture ──────────────
\ b8000 >virt reaches the aperture on BOTH arches (identity on amd64). The
\ attribute byte packs bg<<4|fg; setting an fg bit must leave the bg nibble.
\ Fill the WHOLE screen, not one cell: the console scrolls on the cr below, and
\ after a scroll row 0 (which xp reads at b8000) becomes old row 1 -- so it only
\ survives if every row holds the same bytes. This is the trap the mmio-writer
\ track documents, met again.
: dev-set
  7d0 0 do
    41 b8000 >virt i dcell[] d-ch t!    \ 'A'
    10 b8000 >virt i dcell[] d-at t!    \ bg=1 (blue), fg=0
    01 b8000 >virt i dcell[] d-at t-set \ set fg bit 0 -> 11, bg preserved
  loop ." DEV-SET-END" cr ;
: dev-naive
  7d0 0 do
    41 b8000 >virt i dcell[] d-ch t!
    10 b8000 >virt i dcell[] d-at t!
    01 b8000 >virt i dcell[] d-at t!    \ naive store -> 01, bg destroyed
  loop ." DEV-NAIVE-END" cr ;
\ ── named controls: the light-on flavour, verbose and backend-hidden ──
\ A control bakes (address, field, mask) behind a name; the verbs read as
\ English. Two controls on the SAME field must not disturb each other -- which
\ is the RMW property, reached through the friendly layer.
r st 80 control: guard        \ bit 7, a neighbour
r st 01 control: led          \ bit 0
: rmw-ctl
  0 r st t!
  guard enable                 ." rc-guard=" r st t@ u. cr   \ 80
  led enable                   ." rc-both="  r st t@ u. cr   \ 81  neighbour kept
  ." rc-led?="   led   enabled? . cr                          \ -1
  ." rc-guard?=" guard enabled? . cr                          \ -1
  led disable                  ." rc-off="   r st t@ u. cr   \ 80
  ." rc-led2?="  led   enabled? . cr                          \ 0
  led toggle                   ." rc-tog="   r st t@ u. cr   \ 81
  ." RMW-CTL-END" cr ;
\ mudge's exact words, re-expressed as thin aliases over the control
: light-on   led enable ;
: light-off  led disable ;
: rmw-mudge
  0 r st t!  80 r st t!
  light-on   ." rc-lighton="  r st t@ u. cr                  \ 81
  light-off  ." rc-lightoff=" r st t@ u. cr                  \ 80
  ." RMW-MUDGE-END" cr ;
." RMW-READY" cr
FTH
    genisoimage -quiet -o "$WORKDIR/rmw.iso" -V RMW -r -J "$RST"

    _rxp() {  # _rxp <monsock> — read 8 bytes of physical 0xb8000
      RMON="$1" python3 - <<'PYX'
import socket, os, time
s = socket.socket(socket.AF_UNIX); s.connect(os.environ["RMON"]); time.sleep(0.3)
try: s.recv(65536)
except Exception: pass
s.sendall(b"xp /8xb 0xb8000\n"); time.sleep(1.2)
out = s.recv(65536).decode(errors="replace")
print(" ".join(l.split(": ", 1)[1].strip() for l in out.splitlines() if ": 0x" in l))
PYX
    }

    for A in amd64 x86; do
      if [[ "$A" == amd64 ]]; then MB="$RAMB"; DI="$RADI"; else MB="$RXMB"; DI="$RXDI"; fi
      RSOCK="$WORKDIR/rmw-$A.sock"; RMON="$WORKDIR/rmw-$A.mon"; RLOG="$WORKDIR/rmw-$A.log"
      rm -f "$RSOCK" "$RMON" "$RLOG"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DI" \
        -cdrom "$WORKDIR/rmw.iso" -display none -serial "unix:$RSOCK,server=on" \
        -monitor "unix:$RMON,server=on,nowait" -no-reboot >/dev/null 2>&1 &
      RQ=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$RSOCK" "$RLOG" --timeout 200 \
        --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\struct.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\rmw.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "RMW-READY" \
        --send 'rmw-mem\r' --expect "RMW-MEM-END" \
        --send 'rmw-le\r' --expect "RMW-LE-END" \
        --send 'rmw-be\r' --expect "RMW-BE-END" \
        --send 'rmw-ctl\r' --expect "RMW-CTL-END" \
        --send 'rmw-mudge\r' --expect "RMW-MUDGE-END" \
        --send 'dev-set\r' --expect "DEV-SET-END"
      RRC=$?
      RSET_PHYS="$(_rxp "$RMON")"
      # second boot for the device control, so the two runs cannot share state
      kill "$RQ" 2>/dev/null; wait "$RQ" 2>/dev/null; rm -f "$RSOCK" "$RMON"
      qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$MB" -initrd "$DI" \
        -cdrom "$WORKDIR/rmw.iso" -display none -serial "unix:$RSOCK,server=on" \
        -monitor "unix:$RMON,server=on,nowait" -no-reboot >/dev/null 2>&1 &
      RQ2=$!
      python3 "$REPO/tools/drive-serial-repl.py" "$RSOCK" "$WORKDIR/rmw-$A-ctl.log" --timeout 200 \
        --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\struct.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "0 > " \
        --send 'load /ide@1/cdrom@0:\\rmw.fth\r' --expect "0 > " \
        --send 'load-base load-size evaluate\r' --expect "RMW-READY" \
        --send 'dev-naive\r' --expect "DEV-NAIVE-END"
      RRC2=$?
      RNAIVE_PHYS="$(_rxp "$RMON")"
      kill "$RQ2" 2>/dev/null; wait "$RQ2" 2>/dev/null   # by PID, never by pattern
      RL="$(tr -d "\r" < "$RLOG")"
      rv() { grep -aoE "$1=[0-9a-f]+" <<<"$RL" | head -1 | cut -d= -f2; }

      [[ $RRC -eq 0 ]] \
        || fail "rmw-fields on $A: the probe did not complete (rc=$RRC) — see $RLOG"
      # The CONTROL boot gets its own named check. Its outcome assertion below
      # would catch a boot that never ran -- RNAIVE_PHYS cannot match -- but it
      # would blame the bg nibble for it, which is an honest failure wearing
      # someone else's clothes.
      [[ $RRC2 -eq 0 ]] \
        || fail "rmw-fields on $A: the CONTROL probe (dev-naive, second boot) did not complete (rc=$RRC2), so the bare-store comparison below never ran — see $WORKDIR/rmw-$A-ctl.log"

      # ── MEMORY: the three ops, and the control that earns them ──
      [[ "$(rv rm-init)" == 80 ]] \
        || fail "rmw-fields on $A: the field did not initialise to 80 — see $RLOG"
      [[ "$(rv rm-set)" == 81 ]] \
        || fail "rmw-fields on $A: t-set of bit 0 over a field holding 80 gave $(rv rm-set), not 81 — the read-modify-write did not preserve bit 7, which is the whole reason t-set exists rather than a bare store — see $RLOG"
      [[ "$(rv rm-clr)" == 80 ]] \
        || fail "rmw-fields on $A: t-clr of bit 0 gave $(rv rm-clr), not 80 — it cleared the wrong bits (a missing 'invert' ANDs with the raw mask and clears everything else) — see $RLOG"
      # THE CONTROL. Without this row, "t-set set the bit" is satisfied by a bare
      # store, which is exactly the bug the words exist to avoid.
      [[ "$(rv rm-naive)" == 1 ]] \
        || fail "rmw-fields on $A: a bare 't!' of 1 over a field holding 80 gave $(rv rm-naive), not 1 — if this is 81 then t! is somehow preserving neighbours and the contrast with t-set proves nothing — see $RLOG"
      [[ "$(rv rm-xor2)" == 80 ]] \
        || fail "rmw-fields on $A: two t-tog of the same bit did not round-trip (got $(rv rm-xor2), want 80) — see $RLOG"
      [[ "$(rv rm-full)" == ff ]] \
        || fail "rmw-fields on $A: t-set f0 then t-set 0f gave $(rv rm-full), not ff — successive sets do not compose — see $RLOG"
      [[ "$(rv rm-clrlow)" == a0 ]] \
        || fail "rmw-fields on $A: t-clr of 0f over aa gave $(rv rm-clrlow), not a0 — see $RLOG"

      # ── ORDER: the mask is applied to the value, not to raw bytes ──
      [[ "$(rv rl-init)" == ff000000 && "$(rv rl-set)" == ff000001 ]] \
        || fail "rmw-fields on $A: t-set on a LITTLE-ENDIAN field gave $(rv rl-set) over $(rv rl-init) — expected ff000001 — the mask must apply to the decoded value, so the high byte survives — see $RLOG"
      # rv() stops at the first token, so the byte LIST needs its own extraction.
      RLB="$(grep -aoE 'rl-bytes=[0-9a-f ]+' <<<"$RL" | head -1 | cut -d= -f2 | tr -s ' ' | sed 's/ *$//')"
      [[ "$RLB" == "1 0 0 ff" ]] \
        || fail "rmw-fields on $A: after t-set on the LE field the bytes are [$RLB], not [1 0 0 ff] — the value round-trips but memory does not hold it little-endian, so t-set is bypassing the field's byte order — see $RLOG"
      # AND THE DEFAULT ORDER. `field:` is big-endian; before this row it was
      # exercised here only at width 1, where order is a no-op, so l@-be/l!-be
      # never ran under t-set and half of "byte order rides along" was an UNKNOWN
      # sitting inside the track that advertises it.
      [[ "$(rv rb-init)" == ff000000 && "$(rv rb-set)" == ff000001 ]] \
        || fail "rmw-fields on $A: t-set on a BIG-ENDIAN field gave $(rv rb-set) over $(rv rb-init) — expected ff000001 — the mask must apply to the decoded value in the 1275-native order too, not just the little-endian one — see $RLOG"
      RBB="$(grep -aoE 'rb-bytes=[0-9a-f ]+' <<<"$RL" | head -1 | cut -d= -f2 | tr -s ' ' | sed 's/ *$//')"
      [[ "$RBB" == "ff 0 0 1" ]] \
        || fail "rmw-fields on $A: after t-set on the BIG-ENDIAN field the bytes are [$RBB], not [ff 0 0 1] — they must be the exact REVERSE of the little-endian row's [1 0 0 ff]; if they match it, t-set wrote through the wrong accessor and both orders would 'pass' identically — see $RLOG"

      # ── NAMED CONTROLS: the verbose, backend-hidden layer ──
      # Same RMW property, reached through enable/disable/toggle/enabled? on a
      # named control. Two controls on one field must not disturb each other.
      [[ "$(rv rc-guard)" == 80 && "$(rv rc-both)" == 81 ]] \
        || fail "rmw-fields on $A: two controls on one field gave guard=$(rv rc-guard) both=$(rv rc-both), not 80/81 — 'led enable' disturbed the 'guard' bit, so the friendly layer lost the read-modify-write property the raw words have — see $RLOG"
      RLED="$(grep -aoE 'rc-led\?=-?[0-9]+' <<<"$RL" | head -1 | cut -d= -f2)"
      RGRD="$(grep -aoE 'rc-guard\?=-?[0-9]+' <<<"$RL" | head -1 | cut -d= -f2)"
      [[ "$RLED" == -1 && "$RGRD" == -1 ]] \
        || fail "rmw-fields on $A: enabled? read led=$RLED guard=$RGRD, not -1/-1 — the query does not agree with the bits that were set — see $RLOG"
      RLED2="$(grep -aoE 'rc-led2\?=-?[0-9]+' <<<"$RL" | head -1 | cut -d= -f2)"
      [[ "$(rv rc-off)" == 80 && "$RLED2" == 0 ]] \
        || fail "rmw-fields on $A: after 'led disable' the field is $(rv rc-off) and enabled? is $RLED2, not 80/0 — disable did not clear exactly the led bit — see $RLOG"
      [[ "$(rv rc-tog)" == 81 ]] \
        || fail "rmw-fields on $A: 'led toggle' over 80 gave $(rv rc-tog), not 81 — see $RLOG"
      # mudge's exact words, re-expressed as aliases, still behave
      [[ "$(rv rc-lighton)" == 81 && "$(rv rc-lightoff)" == 80 ]] \
        || fail "rmw-fields on $A: light-on/light-off rebuilt over the control gave $(rv rc-lighton)/$(rv rc-lightoff), not 81/80 — the mudge aliases do not match the words they wrap — see $RLOG"

      # ── DEVICE: RMW through rb@/rb!, seen as PHYSICAL memory ──
      # cell 0 = char 'A' (41), attr. RMW set fg keeping bg -> attr 11.
      [[ "$RSET_PHYS" == "0x41 0x11"* ]] \
        || fail "rmw-fields on $A: after t-set through a dev-field, physical 0xb8000 reads [$RSET_PHYS], not starting 0x41 0x11 — the read-modify-write did not reach the aperture (or did not preserve the bg nibble) — see $RLOG. Note the Forth read-back cannot tell you this, because it uses the same rb@ path the store did"
      # THE DEVICE CONTROL, physically observed: the bare store destroys bg.
      [[ "$RNAIVE_PHYS" == "0x41 0x01"* ]] \
        || fail "rmw-fields on $A: after a bare 't!' the attribute at physical 0xb8000 reads [$RNAIVE_PHYS], not 0x41 0x01 — if the bg nibble survived a plain store then the device control does not demonstrate what t-set is for — see $WORKDIR/rmw-$A-ctl.log"

      note "$A: t-set/t-clr preserve bit 7 (81/80) where a bare t! destroys it (01); t-tog round-trips; BOTH byte orders keep the high byte and lay it down reversed from each other (LE bytes [1 0 0 ff], BE bytes [ff 0 0 1]); and through a dev-field over the VGA aperture the RMW leaves attr 0x11 at physical 0xb8000 where a bare store leaves 0x01 — bg nibble preserved vs destroyed, read by the monitor"
    done
    pass "mudge's read-modify-write idiom (Phrack 53:9, 1998 — upstream-tutorial/), generalised to t-set/t-clr/t-tog over a TYPED field and NOT named for an LED, measured on BOTH arches. The property that makes RMW different from a store is that it PRESERVES THE OTHER BITS — which is why mudge wrote 'aux@ or aux!' and not '1 aux!' — so every positive row is paired with a bare 't!' control that destroys the neighbour: t-set/t-clr hold bit 7 at 81/80 where t! clobbers it to 01, t-tog round-trips, and the mask applies to the DECODED value in BOTH byte orders — a little-endian field keeps its high byte (bytes [1 0 0 ff]) and the 1275-native big-endian field lays the same value down exactly reversed (bytes [ff 0 0 1]), which is the row that makes 'the byte order rides along' a measurement rather than a claim: before it, field: was exercised here only at width 1, where order is a no-op, so l@-be/l!-be never ran under t-set at all. And it works on a real DEVICE register: through a dev-field over the VGA aperture at b8000 >virt, setting an fg bit leaves attr 0x11 at PHYSICAL 0xb8000 — read by QEMU's monitor, an observer outside the firmware — where a bare store leaves 0x01, the bg nibble preserved versus destroyed. The Forth read-back cannot see that difference because it uses the same rb@ path the store did"
    ;;
  *) echo "usage: $0 [multiboot|coreboot|coreboot-amd64|ppc|nvram|persist|persist-flash|floppy|persist-os|persist-os-flash|dict-identity|amd64|amd64-fault|amd64-ctx|amd64-pmem|amd64-linux|property-abi|memory-available|vga|diagnostics|client-forth|pmem-writer|flash-writer|mmio-writer|struct-layer|struct-array|struct-device|elf-methods|rmw-fields]" >&2; exit 1 ;;
esac
