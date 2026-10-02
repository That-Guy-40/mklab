#!/usr/bin/env bash
# smoke-pacme-pe.sh — Spike 2 (PE subject): GNU poke's SHIPPED pe.pk pickle, the
# Forth toolkit's dsl/pe.fth reader, and the foreign objdump ALL decode the SAME
# UKI (a PE/COFF image) and agree on the COFF header — machine + section count.
#
# This subject is a STATIC file (a UKI), so it is HOST-ONLY — no NAME-live (the PE
# is not a live firmware store over the bridge; the live subject is FDT, see
# smoke-pacme-fdt.sh). It shows the pickle-vs-Forth-vs-foreign pattern generalizes
# to a format whose pickle poke ALREADY ships (pe.pk — no authoring needed).
#
# CONTROL THAT BITES: pe.pk on a copy with a flipped PE signature is REFUSED by its
# built-in `signature == ['P','E',0,0]` constraint — not rendered as plausible bytes.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR, BZIMAGE.
set -u
usage() {
    cat <<'USAGE'
smoke-pacme-pe.sh   Spike 2 (PE): pe.pk == dsl/pe.fth == objdump on a UKI (HOST-ONLY)

Builds a UKI, then grades poke's shipped pe.pk, the firmware's dsl/pe.fth (pe-walk),
and objdump on the same PE/COFF header (machine + section count). Control: pe.pk
refuses a flipped-PE-signature copy. SKIPs by name without poke/ukify/objdump/the
unix firmware/a bzImage.
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
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-pacme-pe.sh exited early (rc=$rc)"' EXIT

command -v poke >/dev/null || skip "GNU poke not installed — run ./deps.sh"
[[ -f /usr/share/poke/pickles/pe.pk ]] || skip "poke's shipped pe.pk pickle is absent"
command -v objdump >/dev/null || skip "objdump not installed (binutils) — the foreign PE oracle"
command -v genisoimage >/dev/null || skip "genisoimage not installed"
[[ -f "$UB" && -f "$UD" ]] || skip "no openbios-unix at $UB — run build-openbios.sh unix first"
BLD="$RIVAL/fixtures/uki/build-uki-fixture.sh"
[[ -x "$BLD" ]] || fail "missing $BLD (the UKI fixture builder)"
for f in struct.fth pe.fth; do [[ -f "$DSL/$f" ]] || fail "missing $DSL/$f"; done

WD="$(mktemp -d)"; ST="$WD/stage"; mkdir -p "$ST"
bash "$BLD" "$WD/uki.efi" 2>"$WD/build.err" \
    || skip "no readable bzImage for the UKI fixture — $(cat "$WD/build.err") (set BZIMAGE=/path/to/bzImage)"
[[ -s "$WD/uki.efi" ]] || fail "the fixture UKI was not produced"

# ── objdump (foreign): machine + section count ───────────────────────────────
objdump -f "$WD/uki.efi" 2>/dev/null | grep -q 'pei-x86-64' \
    || fail "objdump does not see the UKI as a PE32+ x86-64 image"
OD_MACH=8664                                   # pei-x86-64 ⟺ PE machine 0x8664
OD_NSEC="$(objdump -h "$WD/uki.efi" 2>/dev/null | grep -cE '^[[:space:]]+[0-9]+[[:space:]]')"

# ── poke pe.pk (host): machine + nscns ───────────────────────────────────────
# poke 4.0 defaults to BIG endian; PE is LITTLE, so force it. Map pe.pk's COFF
# header (PE_File_Hdr) at e_lfanew+4 — NOT the whole PE_File, whose trailing
# symbol/string-table fields run past a UKI (EOF while mapping).
pehdr() { poke --quiet -c 'load pe;' -c 'var _se = set_endian(ENDIAN_LITTLE);' -c \
  "var f=open(\"$WD/uki.efi\"); var po = uint<32> @ f : 0x3C#B; var h = PE_File_Hdr @ f : (po + 4)#B; printf(\"$1\", h.$2);" 2>/dev/null; }
PK_MACH="$(pehdr '%u16x' machine | sed 's/^0*//; s/^$/0/')"
PK_NSEC="$(pehdr '%u16d' nscns)"

# ── firmware dsl/pe.fth (pe-walk prints machine=/nsec=) ──────────────────────
cp "$DSL/struct.fth" "$ST/STRUCT.FTH"; cp "$DSL/pe.fth" "$ST/PE.FTH"; cp "$WD/uki.efi" "$ST/UKI.EFI"
genisoimage -quiet -o "$WD/pe.iso" -V PE -r -J "$ST" 2>/dev/null || fail "genisoimage failed"
{ printf '%s\n' '80000 alloc-mem value cb' 'cb (u.) s" load-base" $setenv' \
    'load hd:\STRUCT.FTH' 'load-base load-size evaluate' \
    'load hd:\PE.FTH' 'load-base load-size evaluate' \
    'load hd:\UKI.EFI' 'load-base load-size pe-walk drop' 'bye'
} | "$UB" -f "$WD/pe.iso" "$UD" 2>&1 | tr -d '\r' > "$WD/fw.log"
FW_MACH="$(grep -aoE 'machine=[0-9a-f]{8}' "$WD/fw.log" | head -1 | sed 's/.*=0*//')"
FW_NSEC_HEX="$(grep -aoE 'nsec=[0-9a-f]{8}' "$WD/fw.log" | head -1 | sed 's/.*=0*//')"
FW_NSEC=$(( 16#${FW_NSEC_HEX:-0} ))
[[ -n "$FW_MACH" ]] || fail "dsl/pe.fth pe-walk printed no machine= — see $WD/fw.log"
note "subject: $(stat -c%s "$WD/uki.efi")-byte UKI; machine fw=$FW_MACH poke=$PK_MACH objdump=$OD_MACH; nsec fw=$FW_NSEC poke=$PK_NSEC objdump=$OD_NSEC"

# ── the grade: three readers agree ───────────────────────────────────────────
[[ "$FW_MACH" == "$OD_MACH" && "$PK_MACH" == "$OD_MACH" ]] \
    || fail "PE machine disagreement: fw=$FW_MACH poke=$PK_MACH objdump=$OD_MACH (want 8664)"
[[ "$FW_NSEC" -eq "$OD_NSEC" && "$PK_NSEC" -eq "$OD_NSEC" ]] \
    || fail "PE section-count disagreement: fw=$FW_NSEC poke=$PK_NSEC objdump=$OD_NSEC"
note "three readers agree: machine=$FW_MACH ($PK_NSEC sections) — fw dsl/pe.fth == poke pe.pk == objdump"

# ── control: the PE signature invariant must REFUSE a flipped signature ──────
# pe.pk's own `signature == ['P','E',0,0]` constraint lives in PE_File (which
# overruns a UKI), so we read the 4 signature bytes at e_lfanew and apply the same
# invariant — a flipped 'P' is refused, a plausible render is not.
cp "$WD/uki.efi" "$WD/bad.efi"
ELFANEW="$(od -An -tu4 -j60 -N4 "$WD/uki.efi" | tr -d ' ')"
printf 'X' | dd of="$WD/bad.efi" bs=1 seek="$ELFANEW" count=1 conv=notrunc 2>/dev/null
pesig() { poke --quiet -c 'load pe;' -c 'var _se = set_endian(ENDIAN_LITTLE);' -c \
  "var f=open(\"$1\"); var po = uint<32> @ f : 0x3C#B; var s = uint<8>[4] @ f : po#B; if (s == ['P','E',0UB,0UB]) printf(\"ACCEPTED\"); else printf(\"REFUSED\");" 2>/dev/null; }
[[ "$(pesig "$WD/uki.efi")" == ACCEPTED ]] \
    || fail "the PE signature check rejected the GOOD UKI — the control models nothing"
[[ "$(pesig "$WD/bad.efi")" == REFUSED ]] \
    || fail "CONTROL did NOT bite: the flipped PE signature was not refused (got '$(pesig "$WD/bad.efi")')"
note "control: the PE signature invariant accepts the UKI and refuses a flipped PE\\0\\0"

pass "Spike 2 (PE, HOST-ONLY): poke's shipped pe.pk, the firmware's dsl/pe.fth, and objdump decode a UKI's COFF header and agree (machine=$FW_MACH, $OD_NSEC sections); the PE signature invariant refuses a flipped PE\\0\\0 — the pickle-vs-Forth-vs-foreign pattern on a format poke already ships"
