#!/usr/bin/env bash
# smoke-uki-rescue.sh — the UKI Workbench rescue arc, IN-RAM half: mutate a boot
# artifact through the contract's WRITER surface (NAME-write), at the firmware
# prompt, without a USB stick or a chroot — and grade the DELTA.
#
# Two edits a rescue operator actually makes, each a contract NAME-write:
#   pe-write   grow a UKI's .cmdline to a rescue line (add rd.break init=/bin/bash)
#   cpio-write flip a boot-blocking value in a config INSIDE the .initrd, in place
#
# HOW IT IS GRADED (honest about the seam):
#   * FOREIGN AGREEMENT, pre-edit — the firmware's read of the ORIGINAL .cmdline
#     and of etc/conf equals objcopy's / cpio's, so the reader is cross-checked
#     against a foreign tool BEFORE the edit (this is what stops a symmetric
#     read+write error passing: the pre-edit anchor is independent).
#   * DELTA, post-edit — after NAME-write, the firmware re-reads the target and it
#     holds the NEW value, and a NEIGHBOUR (.uname / greet.txt) is UNCHANGED: the
#     edit, and ONLY the edit (the contract checker's PART-3 writer grade).
#   * REFUSE-BEFORE-WRITE control — an oversize .cmdline is refused `edit| TOO-BIG`
#     and a length-changing config edit `cpio| LEN-CHANGE`, each writing NOTHING
#     (the bytes are unchanged after the refusal).
#
# This is the IN-RAM, one-shot edit (the OpenFirmware/OpenBoot form). The FOREIGN-
# ORACLE grade of a PERSISTED artifact — uki-edit.sh re-emitting a patched UKI that
# objcopy/ukify read back — is the workbench's next increment (PLAN.md), not this
# track: a firmware RAM edit is not visible to a host tool, so it is graded by the
# firmware's own re-read + the pre-edit foreign anchor, and said so.
#
# Consumes {pe, cpio} at contract v1 via NAME-write (dsl/{pe,cpio}-write-conform.fth).
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR, BZIMAGE.
set -u
usage() {
    cat <<'USAGE'
smoke-uki-rescue.sh   in-RAM rescue edits via the contract's NAME-write surface

Builds a faithful UKI (rival lab's fixture), then drives openbios-unix loading
struct + pe + pe-edit + pe-write-conform + cpio + cpio-edit + cpio-write-conform,
and asserts:
  pe-write   .cmdline read pre-edit == objcopy's; grown to a rescue line and
             re-read == the rescue line; .uname (neighbour) unchanged.
             CONTROL an oversize edit -> edit| TOO-BIG, .cmdline unchanged.
  cpio-write etc/conf inside .initrd read pre-edit == cpio's; flipped x=1 -> x=0
             (same length) and re-read == x=0; greet.txt (neighbour) unchanged.
             CONTROL a length-changing edit -> cpio| LEN-CHANGE, etc/conf unchanged.
SKIPs by name without ukify/binutils/cpio/genisoimage/the built firmware/a bzImage.
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
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-uki-rescue.sh exited early (rc=$rc)"' EXIT

# ── guards (SKIP by name) ─────────────────────────────────────────────────────
for t in ukify objdump objcopy cpio genisoimage; do
    command -v "$t" >/dev/null || skip "$t not installed — needed to author/oracle the UKI"
done
[[ -f "$UB" && -f "$UD" ]] || skip "no openbios-unix at $UB — run openbios-the-rival-that-shipped/build-openbios.sh unix first"
BLD="$RIVAL/fixtures/uki/build-uki-fixture.sh"
[[ -x "$BLD" ]] || fail "missing $BLD (the rival lab's UKI fixture builder)"
for f in struct.fth pe.fth pe-edit.fth pe-write-conform.fth cpio.fth cpio-edit.fth cpio-write-conform.fth; do
    [[ -f "$DSL/$f" ]] || fail "missing $DSL/$f — this lab consumes the shipped writer modules"
done

WD="$(mktemp -d)"; ST="$WD/stage"; mkdir -p "$ST"

# ── the subject + FOREIGN pre-edit oracles ────────────────────────────────────
bash "$BLD" "$WD/uki.efi" 2> "$WD/build.err" \
    || skip "no readable bzImage for the UKI fixture — $(cat "$WD/build.err") (set BZIMAGE=/path/to/bzImage)"
[[ -s "$WD/uki.efi" ]] || fail "the fixture UKI was not produced"
objcopy -O binary --only-section=.cmdline "$WD/uki.efi" "$WD/cmdline.bin" 2>/dev/null || fail "objcopy could not extract .cmdline"
OCMD="$(tr -d '\000\n' < "$WD/cmdline.bin")"
objcopy -O binary --only-section=.uname "$WD/uki.efi" "$WD/uname.bin" 2>/dev/null || fail "objcopy could not extract .uname"
OUNAME="$(tr -d '\000\n' < "$WD/uname.bin")"
objcopy -O binary --only-section=.initrd "$WD/uki.efi" "$WD/initrd.bin" 2>/dev/null || fail "objcopy could not extract .initrd"
( cd "$WD" && cpio -idm --quiet < initrd.bin 2>/dev/null )   # extracts ./etc/conf, ./greet.txt
[[ -f "$WD/etc/conf" ]] || fail "the fixture .initrd lacks etc/conf — the config-fix subject"
OCONF="$(tr -d '\n' < "$WD/etc/conf")"                       # "x=1"
[[ "$OCONF" == "x=1" ]] || fail "the fixture etc/conf is '$OCONF', expected 'x=1' — the same-length flip x=1->x=0 assumes it"
note "subject: .cmdline='$OCMD' .uname='$OUNAME' .initrd:etc/conf='$OCONF' (foreign pre-edit oracles: objcopy, cpio)"

# ── stage the shipped writer modules + the UKI ────────────────────────────────
cp "$DSL/struct.fth" "$ST/STRUCT.FTH"
cp "$DSL/pe.fth" "$ST/PE.FTH"; cp "$DSL/pe-edit.fth" "$ST/PEEDIT.FTH"; cp "$DSL/pe-write-conform.fth" "$ST/PEW.FTH"
cp "$DSL/cpio.fth" "$ST/CPIO.FTH"; cp "$DSL/cpio-edit.fth" "$ST/CPIOEDIT.FTH"; cp "$DSL/cpio-write-conform.fth" "$ST/CPIOW.FTH"
cp "$WD/uki.efi" "$ST/UKI.EFI"
ISO="$WD/uki.iso"
genisoimage -quiet -o "$ISO" -V UKI -r -J "$ST" 2>/dev/null || fail "genisoimage failed to build the staging ISO"

RESCUE_CMD='root=/dev/sda1 rd.break rw'   # 26 chars: GROWS the 23-char original in place
# the one Forth line that carries a typed string (built here to keep the quoting sane,
# and kept <= 80 columns — openbios-unix's stdin truncates a longer line silently):
PE_WRITE_LINE="ua @ ul @ s\" .cmdline\" s\" $RESCUE_CMD\" pe-write .\" cw=\" . cr"

# ── drive: load the writer profile, do the edits + controls ───────────────────
lev() { printf 'load hd:\\%s\nload-base load-size evaluate\n' "$1"; }
LOG="$WD/drive.log"
{ printf '%s\n' '80000 alloc-mem value cb' 'cb (u.) s" load-base" $setenv' \
    'load hd:\STRUCT.FTH' 'load-base load-size evaluate'
  lev PE.FTH; lev PEEDIT.FTH; lev PEW.FTH; lev CPIO.FTH; lev CPIOEDIT.FTH; lev CPIOW.FTH
  printf '%s\n' \
    'variable ua variable ul variable ia variable il' \
    'load hd:\UKI.EFI' \
    'load-base load-size ul ! ua !' \
    'ua @ ul @ pe-walk drop' \
    'cr ." cmd-pre=" ua @ ul @ s" .cmdline" pe-find type cr' \
    'cr ." uname-pre=" ua @ ul @ s" .uname" pe-find type cr' \
    "$PE_WRITE_LINE" \
    'ua @ ul @ pe-walk drop' \
    'cr ." cmd-post=" ua @ ul @ s" .cmdline" pe-find type cr' \
    'cr ." uname-post=" ua @ ul @ s" .uname" pe-find type cr' \
    'ua @ ul @ s" .cmdline" cb 400 pe-write ." cmd-oversize=" . cr' \
    'ua @ ul @ pe-walk drop' \
    'cr ." cmd-after-refuse=" ua @ ul @ s" .cmdline" pe-find type cr'
  # cpio: operate INSIDE the .initrd section (extract it via pe-find first)
  printf '%s\n' \
    'ua @ ul @ s" .initrd" pe-find il ! ia !' \
    'cr ." conf-pre=" ia @ il @ 40 s" etc/conf" cpio-find type cr' \
    'create rc  78 c, 3d c, 30 c, 0a c,' \
    'ia @ il @ 40 s" etc/conf" rc 4 cpio-write ." cpiow=" . cr' \
    'cr ." conf-post=" ia @ il @ 40 s" etc/conf" cpio-find type cr' \
    'cr ." greet-neighbor=" ia @ il @ 40 s" greet.txt" cpio-find type cr' \
    'ia @ il @ 40 s" etc/conf" s" TOOLONG" cpio-write ." conf-lenchg=" . cr' \
    'cr ." conf-after-refuse=" ia @ il @ 40 s" etc/conf" cpio-find type cr'
  printf 'bye\n'
} | "$UB" -f "$ISO" "$UD" >"$LOG" 2>&1 || true
OUT="$(tr -d '\r' < "$LOG")"
grep -qa 'Welcome to OpenBIOS' <<<"$OUT" || fail "the firmware did not boot to a prompt — see $LOG"
grep -qa 'undefined word' <<<"$OUT" && fail "a word was undefined in the drive — see $LOG"

# helper: value of a `marker=...` line, trimmed
mval() { grep -aE "^$1=" <<<"$OUT" | head -1 | sed "s/^$1=//"; }

# ── pe-write .cmdline: foreign agreement, delta, neighbour, refuse control ────
[[ "$(mval cmd-pre)" == "$OCMD" ]] \
    || fail "pe: firmware read .cmdline as '$(mval cmd-pre)' but objcopy says '$OCMD' — reader/oracle disagree pre-edit — see $LOG"
grep -qa 'cw=-1' <<<"$OUT" || fail "pe-write did not report success (cw=-1) — see $LOG"
[[ "$(mval cmd-post)" == "$RESCUE_CMD" ]] \
    || fail "pe-write DELTA failed: .cmdline re-read as '$(mval cmd-post)', expected the grown rescue line '$RESCUE_CMD' — see $LOG"
[[ "$(mval uname-post)" == "$(mval uname-pre)" && "$(mval uname-post)" == "$OUNAME" ]] \
    || fail "pe-write touched a NEIGHBOUR: .uname was '$(mval uname-pre)'/'$OUNAME', now '$(mval uname-post)' — the edit was not scoped — see $LOG"
grep -qa 'edit| TOO-BIG' <<<"$OUT" || fail "CONTROL did NOT bite: an oversize .cmdline edit was not refused edit| TOO-BIG — see $LOG"
grep -qa 'cmd-oversize=0' <<<"$OUT" || fail "CONTROL: the oversize pe-write returned success — refuse-before-write broken — see $LOG"
[[ "$(mval cmd-after-refuse)" == "$RESCUE_CMD" ]] \
    || fail "CONTROL: the refused oversize edit still changed .cmdline (now '$(mval cmd-after-refuse)') — a partial write — see $LOG"
note "pe-write: .cmdline grown 23->26 to the rescue line, re-read == it, .uname intact; oversize refused edit| TOO-BIG with the bytes unchanged"

# ── cpio-write etc/conf: foreign agreement, delta, neighbour, refuse control ──
[[ "$(mval conf-pre)" == "$OCONF" ]] \
    || fail "cpio: firmware read etc/conf as '$(mval conf-pre)' but cpio says '$OCONF' — reader/oracle disagree pre-edit — see $LOG"
grep -qa 'cpiow=-1' <<<"$OUT" || fail "cpio-write did not report success (cpiow=-1) — see $LOG"
[[ "$(mval conf-post)" == "x=0" ]] \
    || fail "cpio-write DELTA failed: etc/conf re-read as '$(mval conf-post)', expected the flipped 'x=0' — see $LOG"
[[ "$(mval greet-neighbor)" == "hello" ]] \
    || fail "cpio-write touched a NEIGHBOUR: greet.txt is '$(mval greet-neighbor)', expected 'hello' — the edit was not scoped — see $LOG"
grep -qa 'cpio| LEN-CHANGE' <<<"$OUT" || fail "CONTROL did NOT bite: a length-changing config edit was not refused cpio| LEN-CHANGE — see $LOG"
grep -qa 'conf-lenchg=0' <<<"$OUT" || fail "CONTROL: the length-changing cpio-write returned success — refuse-before-write broken — see $LOG"
[[ "$(mval conf-after-refuse)" == "x=0" ]] \
    || fail "CONTROL: the refused length-changing edit still changed etc/conf (now '$(mval conf-after-refuse)') — a partial write — see $LOG"
note "cpio-write: etc/conf flipped x=1->x=0 in place inside .initrd, re-read == it, greet.txt intact; length-change refused cpio| LEN-CHANGE with the bytes unchanged"

pass "the contract's NAME-write surface performs both in-RAM rescue edits on a real UKI — pe-write grows .cmdline to a rescue line, cpio-write flips a config value inside the .initrd — each a scoped DELTA agreeing with a foreign pre-edit oracle, and each refusing an out-of-bounds edit BY NAME while writing nothing"
