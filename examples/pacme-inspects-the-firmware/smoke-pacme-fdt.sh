#!/usr/bin/env bash
# smoke-pacme-fdt.sh — Spike 2 (FDT subject): GNU poke's fdt.pk pickle, the Forth
# toolkit's dsl/fdt.fth reader, and the foreign fdtdump ALL decode the SAME flattened
# device tree and agree field-for-field — three readers, one tree. Plus the NAME-live
# (fdt-live) live-vs-snapshot control.
#
# The subject is OpenBIOS's OWN live device tree, flattened in-firmware (dt>fdt) and
# written out with the hosted unix firmware's write-file (the FILE seam — a SNAPSHOT
# on the host side; the firmware's fdt-live is the LIVE handle). poke's fdt.pk reads
# that DTB; dsl/fdt.fth (in the firmware) reads the same buffer; fdtdump reads the
# file. The grade: magic/totalsize/off_dt_struct equal across all three.
#
# CONTROLS THAT BITE (the repo's rule):
#   * fdt.pk on a flipped-magic copy is REFUSED by its magic constraint (not rendered).
#   * fdt-live: a property added to the live tree grows the live re-read while an
#     independent snapshot does not — NAME-live is live, not a static buffer.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR (default ~/openbios-lab).
set -u
usage() {
    cat <<'USAGE'
smoke-pacme-fdt.sh   Spike 2 (FDT): fdt.pk == dsl/fdt.fth == fdtdump; fdt-live is LIVE

Flattens OpenBIOS's live device tree (unix write-file), then grades poke's fdt.pk,
the firmware's dsl/fdt.fth, and fdtdump on the same DTB header (magic/totalsize/
off_dt_struct). Controls: fdt.pk refuses a flipped-magic blob; fdt-live's re-read
reflects a tree change a captured snapshot does not. SKIPs by name without poke /
fdtdump / the unix firmware.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
RIVAL="$(cd "$HERE/../openbios-the-rival-that-shipped" && pwd)"
DSL="$RIVAL/dsl"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
FUBIN="$WORKDIR/openbios/obj-amd64/openbios-unix"; FUDICT="$FUBIN.dict"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
WD=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-pacme-fdt.sh exited early (rc=$rc)"' EXIT

command -v poke  >/dev/null || skip "GNU poke not installed — run ./deps.sh (sudo apt-get install -y poke)"
command -v fdtdump >/dev/null || skip "fdtdump not installed (device-tree-compiler) — the foreign FDT oracle"
[[ -f "$FUBIN" && -f "$FUDICT" ]] || skip "no openbios-unix at $FUBIN — run openbios-the-rival-that-shipped/build-openbios.sh unix first"
[[ -f "$HERE/fdt.pk" ]] || fail "missing $HERE/fdt.pk — the DTB pickle"
for f in struct.fth contract.fth fdt.fth fdt-read.fth fdt-conform.fth; do
    [[ -f "$DSL/$f" ]] || fail "missing $DSL/$f"
done

WD="$(mktemp -d)"

# ── drive the hosted unix firmware: flatten the live tree, write the DTB, print the
# firmware's own header reads (dsl/fdt.fth via fr@), and run the fdt-live control.
# Each line <= 80 cols (the hosted editor truncates). write-file writes to CWD.
( cd "$WD" && { cat "$DSL/struct.fth" "$DSL/contract.fth" "$DSL/fdt.fth" \
                    "$DSL/fdt-read.fth" "$DSL/fdt-conform.fth"
  printf '%s\n' \
    '/fdt-buf alloc-mem value fb' \
    'fb dt>fdt value flen' \
    'fb flen s" live.dtb" write-file ." WROTE " cr' \
    'cr ." FW-MAGIC=" fb fr@ .hx8 cr' \
    'cr ." FW-TOTAL=" fb 4 + fr@ .hx8 cr' \
    'cr ." FW-OFFST=" fb 8 + fr@ .hx8 cr' \
    'fdt-live value H1  cr ." FW-SNAP=" H1 4 + fr@ .hx8 cr' \
    '/fdt-buf alloc-mem value SNAP  H1 SNAP /fdt-buf move' \
    's" /options" find-package if active-package! then' \
    's" PACME-FDT" encode-string s" pacme-live" property' \
    'fdt-live value H2  cr ." FW-LIVE=" H2 4 + fr@ .hx8 cr' \
    'cr ." FW-SNAP2=" SNAP 4 + fr@ .hx8 cr' \
    'bye'
  } | "$FUBIN" "$FUDICT" 2>&1 | tr -d '\r' > "$WD/fw.log" )
[[ -s "$WD/live.dtb" ]] || fail "the firmware did not write live.dtb — $(grep -aoE 'write-file:.*' "$WD/fw.log" | head -1) (see $WD/fw.log)"

# firmware's own reads (dsl/fdt.fth), normalized to bare lowercase hex, no leading 0s
fwhex() { grep -aoE "$1=[0-9a-f]{8}" "$WD/fw.log" | head -1 | sed 's/.*=0*//'; }
FW_MAGIC="$(fwhex FW-MAGIC)"; FW_TOTAL="$(fwhex FW-TOTAL)"; FW_OFFST="$(fwhex FW-OFFST)"
[[ -n "$FW_MAGIC" ]] || fail "the firmware printed no FW-MAGIC — dsl/fdt.fth did not read the flattened header (see $WD/fw.log)"

# poke / fdt.pk reads (host), bare lowercase hex
# poke's %u32x zero-pads to the 32-bit width; strip leading zeros to match fwhex/fdq.
pkq() { POKE_LOAD_PATH="$HERE" poke --quiet -c "load fdt;" -c \
  "var f=open(\"$WD/live.dtb\"); var h=FDT_Header @ f : 0#B; printf(\"%u32x\", h.$1);" 2>/dev/null \
  | sed 's/^0*//; s/^$/0/'; }
PK_MAGIC="$(pkq magic)"; PK_TOTAL="$(pkq totalsize)"; PK_OFFST="$(pkq off_dt_struct)"

# fdtdump (foreign), bare lowercase hex
fdq() { fdtdump "$WD/live.dtb" 2>/dev/null | grep -aoE "$1:[[:space:]]*0x[0-9a-f]+" | head -1 | sed 's/.*0x0*//'; }
FD_MAGIC="$(fdq magic)"; FD_TOTAL="$(fdq totalsize)"; FD_OFFST="$(fdq off_dt_struct)"

note "subject: $(stat -c%s "$WD/live.dtb")-byte live DTB; magic fw=$FW_MAGIC poke=$PK_MAGIC fdtdump=$FD_MAGIC"

# ── the grade: three readers agree, field-for-field ──────────────────────────
[[ "$FW_MAGIC" == d00dfeed && "$PK_MAGIC" == d00dfeed && "$FD_MAGIC" == d00dfeed ]] \
    || fail "magic disagreement: fw=$FW_MAGIC poke=$PK_MAGIC fdtdump=$FD_MAGIC (want d00dfeed from all three)"
[[ "$FW_TOTAL" == "$PK_TOTAL" && "$PK_TOTAL" == "$FD_TOTAL" ]] \
    || fail "totalsize disagreement: fw=$FW_TOTAL poke=$PK_TOTAL fdtdump=$FD_TOTAL"
[[ "$FW_OFFST" == "$PK_OFFST" && "$PK_OFFST" == "$FD_OFFST" ]] \
    || fail "off_dt_struct disagreement: fw=$FW_OFFST poke=$PK_OFFST fdtdump=$FD_OFFST"
note "three readers agree: totalsize=$FW_TOTAL off_dt_struct=$FW_OFFST (fw dsl/fdt.fth == poke fdt.pk == fdtdump)"

# ── control: fdt.pk must REFUSE a flipped-magic copy ─────────────────────────
head -c 4 /dev/zero | tr '\0' 'Z' > "$WD/bad.dtb"; tail -c +5 "$WD/live.dtb" >> "$WD/bad.dtb"
PK_BAD="$(POKE_LOAD_PATH="$HERE" poke --quiet -c "load fdt;" -c \
  "var f=open(\"$WD/bad.dtb\"); try { var h=FDT_Header @ f : 0#B; printf(\"ACCEPTED\"); } catch if E_constraint { printf(\"REFUSED\"); }" 2>/dev/null)"
[[ "$PK_BAD" == REFUSED ]] \
    || fail "CONTROL did NOT bite: fdt.pk did not refuse a flipped-magic DTB (got '$PK_BAD') — the magic constraint is vacuous"
note "control: fdt.pk refuses a flipped-magic DTB by its magic constraint"

# ── control: fdt-live (NAME-live) is LIVE, not a static snapshot ──────────────
L_SNAP="$(fwhex FW-SNAP)"; L_LIVE="$(fwhex FW-LIVE)"; L_SNAP2="$(fwhex FW-SNAP2)"
[[ -n "$L_SNAP" && -n "$L_LIVE" ]] || fail "fdt-live produced no lengths (see $WD/fw.log)"
[[ "$L_SNAP" != "$L_LIVE" ]] \
    || fail "fdt-live: the live re-read did not reflect a tree change (snap $L_SNAP == live $L_LIVE) — not live"
[[ "$L_SNAP" == "$L_SNAP2" ]] \
    || fail "fdt-live: the captured snapshot changed ($L_SNAP -> $L_SNAP2) — not an independent copy"
note "fdt-live (NAME-live): a live property-add grew the live re-read (snap=$L_SNAP -> live=$L_LIVE) while the snapshot held ($L_SNAP2)"

pass "Spike 2 (FDT): poke's fdt.pk, the firmware's dsl/fdt.fth, and fdtdump decode OpenBIOS's live flattened device tree and agree field-for-field (magic/totalsize/off_dt_struct); fdt.pk refuses a flipped-magic blob; and fdt-live (the contract's NAME-live) is LIVE — a tree change re-reads while a captured snapshot does not"
