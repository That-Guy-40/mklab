#!/usr/bin/env bash
# smoke-pacme-cbfs.sh — Spike 2 (CBFS subject): our cbfs.pk pickle, the Forth
# toolkit's dsl/cbfs.fth reader, and coreboot's own cbfstool ALL decode the SAME
# coreboot ROM's CBFS and agree on its first entry — name + data length.
#
# This subject is a STATIC ROM file, so it is HOST-ONLY — no NAME-live (the live
# CBFS form is guest-physical flash, a gdbstub-IOD seam = Spike 5; the live subject
# today is FDT, see smoke-pacme-fdt.sh). CBFS metadata is BIG-endian ('LARCHIVE'),
# the complement to the little-endian PE — the same poke/Forth cursor reads both.
#
# CONTROL THAT BITES: cbfs.pk's LARCHIVE magic constraint refuses a mapping that is
# not at an entry boundary (off by one) — it does not render plausible garbage.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR, COREBOOT_DIR.
set -u
usage() {
    cat <<'USAGE'
smoke-pacme-cbfs.sh   Spike 2 (CBFS): cbfs.pk == dsl/cbfs.fth == cbfstool (HOST-ONLY)

Reads a coreboot ROM's CBFS three ways — poke's cbfs.pk, the firmware's dsl/cbfs.fth
(cbfs-list), and coreboot's cbfstool — and asserts the first entry's name + length
agree. Control: cbfs.pk refuses an off-by-one (non-LARCHIVE) mapping. SKIPs by name
without poke / a built coreboot ROM+cbfstool / the unix firmware.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
RIVAL="$(cd "$HERE/../openbios-the-rival-that-shipped" && pwd)"
DSL="$RIVAL/dsl"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
UB="$WORKDIR/openbios/obj-amd64/openbios-unix"; UD="$UB.dict"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
ROM="$CB/build-openbios/coreboot.rom"; CBT="$CB/build-openbios/cbfstool"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
WD=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-pacme-cbfs.sh exited early (rc=$rc)"' EXIT

command -v poke >/dev/null || skip "GNU poke not installed — run ./deps.sh"
command -v genisoimage >/dev/null || skip "genisoimage not installed"
[[ -f "$UB" && -f "$UD" ]] || skip "no openbios-unix at $UB — run build-openbios.sh unix first"
[[ -f "$ROM" ]] || skip "no coreboot ROM at $ROM — build it in the linuxboot lab (set COREBOOT_DIR)"
[[ -x "$CBT" ]] || skip "no cbfstool at $CBT — the foreign CBFS oracle (built beside the ROM)"
[[ -f "$HERE/cbfs.pk" ]] || fail "missing $HERE/cbfs.pk — the CBFS pickle"
[[ -f "$DSL/cbfs.fth" && -f "$DSL/struct.fth" ]] || fail "missing dsl/{struct,cbfs}.fth"

WD="$(mktemp -d)"; ST="$WD/stage"; mkdir -p "$ST"

# region offset of the COREBOOT CBFS (never assumed — read from the ROM's FMAP)
CRGN="$("$CBT" "$ROM" layout 2>/dev/null | sed -n "s/.*'COREBOOT'.*offset \([0-9]*\).*/\1/p" | head -1)"
[[ -n "$CRGN" ]] || fail "could not read the COREBOOT region offset from $ROM (cbfstool layout)"
CRGNHEX="$(printf '%x' "$CRGN")"

# ── cbfstool (foreign): the first CBFS entry's name + size ───────────────────
read -r OT_NAME _ _ OT_SIZE _ < <("$CBT" "$ROM" print 2>/dev/null | sed -n '3p')
# cbfstool's `print` columns: Name Offset Type Size Comp — but Type can be two words
# ("cbfs header"); re-extract Size as the last numeric-ish column robustly:
OT_SIZE="$("$CBT" "$ROM" print 2>/dev/null | sed -n '3p' | grep -oE '[0-9]+' | tail -1)"
OT_NAME="$("$CBT" "$ROM" print 2>/dev/null | sed -n '3p' | awk '{print $1}')"
[[ -n "$OT_NAME" && -n "$OT_SIZE" ]] || fail "cbfstool print gave no first entry — the oracle is empty"

# ── poke cbfs.pk (host): the first entry at the region base ──────────────────
PK_NAME="$(POKE_LOAD_PATH="$HERE" poke --quiet -c 'load cbfs;' -c "var f=open(\"$ROM\"); var c = CBFS_File @ f : ${CRGN}#B; printf(\"%s\", c.name);" 2>/dev/null)"
PK_LEN="$(POKE_LOAD_PATH="$HERE" poke --quiet -c 'load cbfs;' -c "var f=open(\"$ROM\"); var c = CBFS_File @ f : ${CRGN}#B; printf(\"%u32d\", c.len);" 2>/dev/null)"

# ── firmware dsl/cbfs.fth (cbfs-list on the first 256 KiB of the ROM) ─────────
head -c 262144 "$ROM" > "$ST/ROM256.BIN"            # the 4 MiB arena cannot hold 4 MiB
cp "$DSL/struct.fth" "$ST/STRUCT.FTH"; cp "$DSL/cbfs.fth" "$ST/CBFS.FTH"
genisoimage -quiet -o "$WD/cbfs.iso" -V CBFS -r -J "$ST" 2>/dev/null || fail "genisoimage failed"
{ printf '%s\n' '80000 alloc-mem value cb' 'cb (u.) s" load-base" $setenv' \
    'load hd:\STRUCT.FTH' 'load-base load-size evaluate' \
    'load hd:\CBFS.FTH' 'load-base load-size evaluate' \
    'load hd:\ROM256.BIN' "load-base $CRGNHEX + 20 cbfs-list" 'bye'
} | "$UB" -f "$WD/cbfs.iso" "$UD" 2>&1 | tr -d '\r' > "$WD/fw.log"
# first entry line: "cbfs| off=... type=... len=XXXXXXXX name=cbfs_master_header"
FW_LINE="$(grep -aE 'cbfs\| off=' "$WD/fw.log" | head -1)"
[[ -n "$FW_LINE" ]] || fail "dsl/cbfs.fth cbfs-list printed no entry — see $WD/fw.log"
FW_NAME="$(sed 's/.*name=//' <<<"$FW_LINE" | tr -dc 'A-Za-z0-9_/-')"
FW_LEN_HEX="$(grep -oE 'len=[0-9a-f]{8}' <<<"$FW_LINE" | head -1 | sed 's/.*=0*//')"
FW_LEN=$(( 16#${FW_LEN_HEX:-0} ))
note "subject: coreboot CBFS at region 0x$CRGNHEX; first entry name cbfstool=$OT_NAME poke=$PK_NAME fw=$FW_NAME; len cbfstool=$OT_SIZE poke=$PK_LEN fw=$FW_LEN"

# ── the grade: three readers agree on the first entry ────────────────────────
[[ "$OT_NAME" == "$PK_NAME" && "$PK_NAME" == "$FW_NAME" ]] \
    || fail "CBFS first-entry NAME disagreement: cbfstool=$OT_NAME poke=$PK_NAME fw=$FW_NAME"
[[ "$OT_SIZE" -eq "$PK_LEN" && "$PK_LEN" -eq "$FW_LEN" ]] \
    || fail "CBFS first-entry LENGTH disagreement: cbfstool=$OT_SIZE poke=$PK_LEN fw=$FW_LEN"
note "three readers agree: first entry '$PK_NAME' len=$PK_LEN (cbfstool == poke cbfs.pk == fw dsl/cbfs.fth)"

# ── control: cbfs.pk must REFUSE a non-LARCHIVE mapping (off by one) ──────────
PK_BAD="$(POKE_LOAD_PATH="$HERE" poke --quiet -c 'load cbfs;' -c "var f=open(\"$ROM\"); try { var c = CBFS_File @ f : $((CRGN+1))#B; printf(\"ACCEPTED\"); } catch if E_constraint { printf(\"REFUSED\"); }" 2>/dev/null)"
[[ "$PK_BAD" == REFUSED ]] \
    || fail "CONTROL did NOT bite: cbfs.pk did not refuse an off-by-one (non-LARCHIVE) mapping (got '$PK_BAD')"
note "control: cbfs.pk refuses a non-LARCHIVE mapping by its magic constraint"

pass "Spike 2 (CBFS, HOST-ONLY): our cbfs.pk, the firmware's dsl/cbfs.fth, and coreboot's cbfstool decode the ROM's CBFS and agree on the first entry ('$PK_NAME', len=$PK_LEN); cbfs.pk refuses a non-LARCHIVE mapping — big-endian metadata (the complement to PE), pickle-vs-Forth-vs-foreign"
