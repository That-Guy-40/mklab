#!/usr/bin/env bash
# smoke-uki-dissect.sh — the UKI Workbench capstone: one-verdict proof that the
# conformance contract's registry-driven `identify` NAMES every typed artifact a
# real UKI carries, with NO per-format code in the consumer (dsl/uki-dissect.fth).
#
# A UKI is one PE/COFF file that CONTAINS a bzImage (.linux), a newc cpio (.initrd)
# and string sections. The foreign oracles (objdump/objcopy/file/cpio) establish
# what the artifact IS; then the firmware — loading only struct + contract + the
# pe/bootparams/cpio readers with their -conform sidecars + identify.fth — hands
# each contained blob to `identify` and must name it the SAME way:
#     the container itself   -> pe
#     .linux (a kernel)      -> bootparams   (the meaningful identity of a
#                                             polymorphic EFI-stub kernel, which is
#                                             ALSO a valid PE; bootparams registers
#                                             first, so identify's first-match names
#                                             the kernel, not the PE wrapper)
#     .initrd                -> cpio
#
# THE NEGATIVE CONTROLS ARE THE POINT (the repo's rule):
#   (a) a garbage buffer -> IDENTIFY: unrecognised — identify does not rubber-stamp.
#   (b) drop the cpio-conform sidecar and re-run: .initrd is NO LONGER named cpio,
#       and `need-module cpio` reports it absent BY NAME. If cpio were still claimed
#       without its sidecar, the federation claim ("drop a module and its kind stops
#       being named") would be empty — so that case must FAIL the test.
#
# Consumes {pe, bootparams, cpio} at contract v1 (dsl/CONTRACT.md), driven through
# identify. The readers' four-arch/big-endian correctness is graded upstream by the
# rival lab's uki/pe/bootparams/cpio tracks; this capstone proves the DISPATCH on
# the unix door, which is arch-independent Forth over those same readers.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR (default ~/openbios-lab),
#       BZIMAGE (a readable bzImage for the .linux subject).
set -u
usage() {
    cat <<'USAGE'
smoke-uki-dissect.sh   the capstone: identify NAMES a real UKI's typed contents

Builds a faithful UKI with the host's own `ukify` (via the rival lab's
fixtures/uki/build-uki-fixture.sh), derives its structure with foreign oracles
(objdump/objcopy/file/cpio), then drives openbios-unix loading struct + contract +
the pe/bootparams/cpio readers + their -conform sidecars + identify.fth +
dsl/uki-dissect.fth, and asserts:
  POSITIVE  identify names the container `pe`, .linux `bootparams`, .initrd `cpio`
            — matching what the foreign oracles say each blob IS.
  CONTROL a  a garbage buffer -> IDENTIFY: unrecognised.
  CONTROL b  with cpio-conform NOT loaded, .initrd is no longer named cpio and
             `need-module cpio` names it absent — the federation/prunability proof.
SKIPs by name without ukify/binutils/file/cpio/genisoimage/the built firmware/a
readable bzImage.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
RIVAL="$(cd "$HERE/../openbios-the-rival-that-shipped" && pwd)"
DSL="$RIVAL/dsl"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
UB="$WORKDIR/openbios/obj-amd64/openbios-unix"; UD="$UB.dict"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
WD=""
# shellcheck disable=SC2154  # rc IS set by rc=$? at the head of this same trap body
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-uki-dissect.sh exited early (rc=$rc)"' EXIT

# ── guards (SKIP by name) ─────────────────────────────────────────────────────
for t in ukify objdump objcopy file cpio genisoimage; do
    command -v "$t" >/dev/null || skip "$t not installed — needed to author/oracle the UKI"
done
[[ -f "$UB" && -f "$UD" ]] || skip "no openbios-unix at $UB — run openbios-the-rival-that-shipped/build-openbios.sh unix first"
BLD="$RIVAL/fixtures/uki/build-uki-fixture.sh"
[[ -x "$BLD" ]] || fail "missing $BLD (the rival lab's UKI fixture builder this lab consumes)"
for f in struct.fth contract.fth bootparams.fth bootparams-conform.fth \
         pe.fth pe-conform.fth cpio.fth cpio-conform.fth identify.fth; do
    [[ -f "$DSL/$f" ]] || fail "missing $DSL/$f — this lab consumes the shipped contract modules"
done
[[ -f "$HERE/uki-dissect.fth" ]] || fail "missing $HERE/uki-dissect.fth — the capstone consumer"

WD="$(mktemp -d)"; ST="$WD/stage"; mkdir -p "$ST"

# ── the subject: a real UKI (never cached), and its FOREIGN-oracle structure ──
bash "$BLD" "$WD/uki.efi" 2> "$WD/build.err" \
    || skip "no readable bzImage for the UKI fixture — $(cat "$WD/build.err") (set BZIMAGE=/path/to/bzImage)"
[[ -s "$WD/uki.efi" ]] || fail "the fixture UKI was not produced"
# objdump names it a PE and lists .linux/.initrd; file names .linux a bzImage;
# cpio reads members from .initrd — the independent ground truth identify must match.
objdump -f "$WD/uki.efi" 2>/dev/null | grep -q 'pei-' || fail "objdump does not see the fixture as a PE — the oracle disagrees with the premise"
for s in .linux .initrd .cmdline; do
    objdump -h "$WD/uki.efi" | grep -qE "[[:space:]]${s}[[:space:]]" || fail "objdump -h: the UKI lacks a $s section"
done
objcopy -O binary --only-section=.linux "$WD/uki.efi" "$WD/linux.bin" 2>/dev/null || fail "objcopy could not extract .linux"
file -b "$WD/linux.bin" | grep -q 'Linux kernel x86 boot executable bzImage' \
    || fail "file(1): .linux is not a bzImage — the kernel oracle disagrees"
objcopy -O binary --only-section=.initrd "$WD/uki.efi" "$WD/initrd.bin" 2>/dev/null || fail "objcopy could not extract .initrd"
mapfile -t IMEM < <(cpio -itv < "$WD/initrd.bin" 2>/dev/null | awk '{print $NF}')
(( ${#IMEM[@]} >= 1 )) || fail "cpio -itv read no members from .initrd — the initrd oracle is empty"
note "subject: $(stat -c%s "$WD/uki.efi")-byte UKI; objdump says PE, file says .linux is a bzImage, cpio says .initrd has ${#IMEM[@]} members (${IMEM[*]})"

# ── stage the shipped contract modules + the capstone consumer + the UKI ──────
cp "$DSL/struct.fth" "$ST/STRUCT.FTH"; cp "$DSL/contract.fth" "$ST/CONTRACT.FTH"
cp "$DSL/bootparams.fth" "$ST/BP.FTH"; cp "$DSL/bootparams-conform.fth" "$ST/BPC.FTH"
cp "$DSL/pe.fth" "$ST/PE.FTH"; cp "$DSL/pe-conform.fth" "$ST/PEC.FTH"
cp "$DSL/cpio.fth" "$ST/CPIO.FTH"; cp "$DSL/cpio-conform.fth" "$ST/CPIOC.FTH"
cp "$DSL/identify.fth" "$ST/IDENT.FTH"; cp "$HERE/uki-dissect.fth" "$ST/UDISSECT.FTH"
cp "$WD/uki.efi" "$ST/UKI.EFI"
# a garbage buffer no module claims (not MZ, not 070701, not 0xAA55 @ 0x1fe)
head -c 600 /dev/zero | tr '\0' 'Z' > "$ST/GARB.BIN"
ISO="$WD/uki.iso"
genisoimage -quiet -o "$ISO" -V UKI -r -J "$ST" 2>/dev/null || fail "genisoimage failed to build the staging ISO"

# ── drive openbios-unix with a body; capture output; require a booted prompt ──
OUT=""
lev() { printf 'load hd:\\%s\nload-base load-size evaluate\n' "$1"; }
drive() {
    local body="$1" log="$WD/drive.log"
    { printf '%s\n' '80000 alloc-mem value cb' 'cb (u.) s" load-base" $setenv' \
        'load hd:\STRUCT.FTH'   'load-base load-size evaluate' \
        'load hd:\CONTRACT.FTH' 'load-base load-size evaluate'
      printf '%s\n' "$body"
      printf 'bye\n'
    } | "$UB" -f "$ISO" "$UD" >"$log" 2>&1 || true
    OUT="$(tr -d '\r' < "$log")"
    grep -qa 'Welcome to OpenBIOS' <<<"$OUT" || fail "the firmware did not boot to a prompt — see $log"
    grep -qa 'undefined word' <<<"$OUT" && fail "a word was undefined in the drive — see $log"
    return 0
}

# ── POSITIVE + CONTROL a: full profile (bootparams, pe, cpio all registered) ──
full="$(lev BP.FTH)"$'\n'"$(lev BPC.FTH)"$'\n'"$(lev PE.FTH)"$'\n'"$(lev PEC.FTH)"
full+=$'\n'"$(lev CPIO.FTH)"$'\n'"$(lev CPIOC.FTH)"$'\n'"$(lev IDENT.FTH)"$'\n'"$(lev UDISSECT.FTH)"
full+=$'\n''load hd:\UKI.EFI'$'\n''load-base load-size uki-dissect'
full+=$'\n''load hd:\GARB.BIN'$'\n''cr ." id-garb=" load-base load-size identify'
drive "$full"

grep -qa 'UKI| the container itself: IDENTIFY: pe ' <<<"$OUT" \
    || fail "identify did not name the UKI container 'pe' — see $WD/drive.log"
grep -qa 'UKI| .linux  -> IDENTIFY: bootparams ' <<<"$OUT" \
    || fail "identify did not name .linux 'bootparams' (a kernel) — see $WD/drive.log"
grep -qa 'UKI| .initrd -> IDENTIFY: cpio ' <<<"$OUT" \
    || fail "identify did not name .initrd 'cpio' — see $WD/drive.log"
grep -qa 'MODULES-BEGIN #=3' <<<"$OUT" \
    || fail "the dispatcher did not list all three registered modules — see $WD/drive.log"
grep -qa 'id-garb=IDENTIFY: unrecognised' <<<"$OUT" \
    || fail "CONTROL a did NOT bite: identify claimed a garbage buffer instead of 'unrecognised' — see $WD/drive.log"
note "positive: identify named container=pe, .linux=bootparams, .initrd=cpio (matching objdump/file/cpio); garbage -> unrecognised"

# ── CONTROL b: drop cpio-conform — cpio must NO LONGER be claimed ─────────────
nocpio="$(lev BP.FTH)"$'\n'"$(lev BPC.FTH)"$'\n'"$(lev PE.FTH)"$'\n'"$(lev PEC.FTH)"
nocpio+=$'\n'"$(lev CPIO.FTH)"$'\n'"$(lev IDENT.FTH)"        # CPIO.FTH loaded, CPIOC.FTH NOT
nocpio+=$'\n''load hd:\UKI.EFI'$'\n''load-base load-size pe-walk drop'
nocpio+=$'\n''cr ." id-initrd-nocpio=" load-base load-size s" .initrd" pe-find identify'
nocpio+=$'\n''cr ." need=" s" cpio" need-module'
drive "$nocpio"

grep -qa 'id-initrd-nocpio=IDENTIFY: cpio ' <<<"$OUT" \
    && fail "CONTROL b did NOT bite: .initrd was still named 'cpio' with cpio-conform UNLOADED — the federation claim is empty — see $WD/drive.log"
grep -qa 'id-initrd-nocpio=IDENTIFY: unrecognised' <<<"$OUT" \
    || fail "CONTROL b: with cpio-conform dropped, .initrd should be 'unrecognised' — see $WD/drive.log"
grep -qa 'MODULE cpio: not loaded' <<<"$OUT" \
    || fail "CONTROL b: need-module cpio did not name the dropped module absent — see $WD/drive.log"
note "control b: dropping cpio-conform makes .initrd 'unrecognised' and need-module names cpio absent — prunability, checked"

pass "the contract's identify NAMES every typed artifact a real UKI carries (container=pe, .linux=bootparams, .initrd=cpio) with no per-format code in the consumer, matching the foreign oracles; garbage is unrecognised, and dropping a module's sidecar stops its kind being claimed — federation, not fusion"
