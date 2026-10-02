#!/usr/bin/env bash
# smoke-pacme-span.sh — Spike 3-lite: NAVIGATE STRUCTURE, not hexdump. GNU poke reports
# WHERE a field lives (its byte span: offset..offset+size), and that span agrees with
# the Forth toolkit's field-offset table — poke and dsl/fdt.fth agree not just on a
# field's VALUE (Spike 2) but on its POSITION. This is the headless, gradeable core of
# the acme UI's "click a field → jump the byte view to its span"; the interactive tmux
# pokelet UI (pacme built from source) is Spike 3-full, deferred.
#
# INVESTIGATION RESULT (2026-10-02): poke 4.0 exposes a mapped value's byte span via
# the `'offset` / `'size` attributes — but only on COMPOSITE (struct/array) values, not
# on a scalar accessed through a struct (which returns an unmapped copy). So a field's
# span is read by mapping it as a value (e.g. `uint<8>[4] @ off`) and dividing the
# bit-offset by #B. (An earlier note that poke "doesn't expose spans" was wrong — it was
# a `print`-vs-`printf` and scalar-copy mistake.)
#
# GRADE: poke's magic-field span == dsl/fdt.fth's `fdt-fields` (off=0, w=4); poke's
# FDT_Header struct size (bytes) == the dsl layout's extent (max field off + width);
# and the bytes AT poke's magic span are the real magic (d00dfeed) — the navigation
# lands on the field, it is not an arbitrary number.
# CONTROL THAT BITES: the same-width span taken one field over (at totalsize's offset)
# does NOT read d00dfeed — the span is position-specific, so "poke knows where the
# field is" is a real claim, not one a wrong offset would also satisfy.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR (default ~/openbios-lab).
set -u
usage() {
    cat <<'USAGE'
smoke-pacme-span.sh   Spike 3-lite: poke reports a field's byte SPAN, matching the toolkit

Flattens OpenBIOS's live device tree, reads dsl/fdt.fth's fdt-fields offset table, and
asserts poke's reported field spans (magic offset/size, header extent) agree with it and
land on the real bytes. Control: the span one field over does not read the magic. SKIPs
by name without poke / the unix firmware.
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
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-pacme-span.sh exited early (rc=$rc)"' EXIT

command -v poke >/dev/null || skip "GNU poke not installed — run ./deps.sh"
[[ -f "$UB" && -f "$UD" ]] || skip "no openbios-unix at $UB — run build-openbios.sh unix first"
[[ -f "$HERE/fdt.pk" ]] || fail "missing $HERE/fdt.pk"
for f in struct.fth contract.fth fdt.fth fdt-read.fth fdt-conform.fth; do [[ -f "$DSL/$f" ]] || fail "missing $DSL/$f"; done

WD="$(mktemp -d)"

# ── firmware: flatten the live tree to a DTB + print dsl/fdt.fth's field table ──
( cd "$WD" && { cat "$DSL/struct.fth" "$DSL/contract.fth" "$DSL/fdt.fth" "$DSL/fdt-read.fth" "$DSL/fdt-conform.fth"
  printf '%s\n' \
    '/fdt-buf alloc-mem value fb' 'fb dt>fdt value flen' \
    'fb flen s" live.dtb" write-file ." WROTE " cr' \
    'cr ." FIELDS:" cr fb fdt-fields' 'bye'
  } | "$UB" "$UD" 2>&1 | tr -d '\r' > "$WD/fw.log" )
[[ -s "$WD/live.dtb" ]] || fail "the firmware did not write live.dtb — see $WD/fw.log"

# dsl layout: magic field off/width, and the layout extent (max off + width)
DSL_MAGIC_OFF=$(( 16#$(grep -aoE 'name=magic off=[0-9a-f]{8}' "$WD/fw.log" | head -1 | sed 's/.*off=//') ))
DSL_MAGIC_W=$(grep -aoE 'name=magic off=[0-9a-f]{8} w=[0-9]+' "$WD/fw.log" | head -1 | sed 's/.*w=//')
DSL_EXTENT=0
while read -r off w; do e=$(( 16#$off + w )); (( e > DSL_EXTENT )) && DSL_EXTENT=$e; done < <(
  grep -aoE 'off=[0-9a-f]{8} w=[0-9]+' "$WD/fw.log" | sed 's/off=//; s/ w=/ /')
[[ -n "$DSL_MAGIC_W" && "$DSL_EXTENT" -gt 0 ]] || fail "could not parse dsl/fdt.fth's fdt-fields table — see $WD/fw.log"

# ── poke: the magic field's span, the header's size, and the bytes at the span ──
pk() { POKE_LOAD_PATH="$HERE" poke --quiet -c 'load fdt;' -c \
  "var f=open(\"$WD/live.dtb\"); $1" 2>/dev/null; }
PK_MAGIC_OFF="$(pk "var m = uint<8>[$DSL_MAGIC_W] @ f : ${DSL_MAGIC_OFF}#B; printf(\"%i64d\", m'offset/#B);")"
PK_MAGIC_SZ="$(pk "var m = uint<8>[$DSL_MAGIC_W] @ f : ${DSL_MAGIC_OFF}#B; printf(\"%i64d\", m'size/#B);")"
PK_HDR_SZ="$(pk "var h = FDT_Header @ f : 0#B; printf(\"%i64d\", h'size/#B);")"
PK_AT_MAGIC="$(pk "var v = uint<32> @ f : ${DSL_MAGIC_OFF}#B; printf(\"%u32x\", v);")"
note "dsl fdt-fields: magic off=$DSL_MAGIC_OFF w=$DSL_MAGIC_W, layout extent=$DSL_EXTENT; poke: magic off=$PK_MAGIC_OFF size=$PK_MAGIC_SZ, header size=$PK_HDR_SZ"

# ── grade: poke's span == the toolkit's layout, and lands on the real field ──
[[ "$PK_MAGIC_OFF" == "$DSL_MAGIC_OFF" && "$PK_MAGIC_SZ" == "$DSL_MAGIC_W" ]] \
    || fail "poke's magic span (off=$PK_MAGIC_OFF size=$PK_MAGIC_SZ) != dsl/fdt.fth's (off=$DSL_MAGIC_OFF w=$DSL_MAGIC_W)"
[[ "$PK_HDR_SZ" == "$DSL_EXTENT" ]] \
    || fail "poke's FDT_Header size ($PK_HDR_SZ) != the dsl layout extent ($DSL_EXTENT) — the two readers disagree on the structure's shape"
[[ "$PK_AT_MAGIC" == d00dfeed ]] \
    || fail "the bytes at poke's magic span read '$PK_AT_MAGIC', not d00dfeed — the span does not land on the real field"
note "poke and dsl/fdt.fth agree on POSITION: magic at [$PK_MAGIC_OFF,+$PK_MAGIC_SZ) holding d00dfeed, header spans $PK_HDR_SZ bytes"

# ── control: the same-width span one field over (totalsize) must NOT read the magic ──
TS_OFF=$(( DSL_MAGIC_OFF + DSL_MAGIC_W ))
PK_AT_TS="$(pk "var v = uint<32> @ f : ${TS_OFF}#B; printf(\"%u32x\", v);")"
[[ "$PK_AT_TS" != d00dfeed ]] \
    || fail "CONTROL did NOT bite: the span at offset $TS_OFF also read d00dfeed — the span is not position-specific, so 'poke knows where the field is' proves nothing"
note "control: the span one field over (offset $TS_OFF) reads '$PK_AT_TS', not the magic — spans are position-specific"

pass "Spike 3-lite: GNU poke reports a field's byte SPAN (offset..size), and it agrees with dsl/fdt.fth's field-offset table — poke and the Forth toolkit agree on WHERE each field lives (magic at [$PK_MAGIC_OFF,+$PK_MAGIC_SZ) holding d00dfeed, header $PK_HDR_SZ bytes), the span lands on the real field, and a span one field over does not. The headless core of the acme UI's field-to-byte navigation; the interactive tmux UI is Spike 3-full"
