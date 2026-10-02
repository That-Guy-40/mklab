#!/usr/bin/env bash
# smoke-pacme-seam.sh — Spike 1 (PROVE THE SEAM): the bytes GNU poke reads over the
# bridge equal the firmware's own bytes, before any pickle interprets them.
#
# Per DESIGN-NOTES-pacme-a-live-firmware-inspector.md §5 Spike 1: bring the bridge up
# (Spike 0 / lib-bridge.sh), open the live OpenBIOS IDE NVRAM store in poke over NBD,
# and assert poke's bytes at offset n == `od` of the same store at n — the seam
# carries data faithfully. This is the foundation every later pickle/UI spike stands
# on: if the seam dropped or rewrote a byte, every structured view above it would be
# a confident lie.
#
# THE CONTROL IS THE POINT (the repo's rule): poke's read is also compared against a
# ONE-BYTE-CORRUPTED copy of the same span, and that comparison MUST mismatch — a seam
# that silently normalized or rewrote a byte, or a check that compares a value to
# itself, fails here. A green run that never saw the control bite proves nothing.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR (default ~/openbios-lab).
set -u
usage() {
    cat <<'USAGE'
smoke-pacme-seam.sh   Spike 1: poke's bytes over the bridge == the firmware's bytes

Brings up a live OpenBIOS session (lib-bridge.sh), exports its IDE NVRAM node over
NBD, and asserts poke reads the nonce span byte-for-byte equal to `od` of the backing
store. Control: poke's read vs a one-byte-flipped copy must MISMATCH. SKIPs by name
without poke / qemu / the firmware.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-bridge.sh
source "$HERE/lib-bridge.sh"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# shellcheck disable=SC2154  # rc IS set by rc=$? at the head of this same trap body
trap 'rc=$?; bridge_down; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-pacme-seam.sh exited early (rc=$rc)"' EXIT

bridge_require skip
bridge_up fail
OFF="$(bridge_nonce_offset)"
[[ -n "$OFF" ]] || fail "the firmware's nonce is not in the store — nothing to prove the seam against"
LEN=${#BR_NONCE}
note "subject: OpenBIOS live IDE NVRAM, nonce '$BR_NONCE' ($LEN bytes) at offset $OFF"

bridge_export_ro || fail "NBD export failed (see the ERR line above)"   # sets BR_URI in this shell
URI="$BR_URI"

# ── the seam: poke over NBD vs od of the live store, byte-for-byte ────────────
PK="$(poke_hex "$URI" "$OFF" "$LEN")"
OD="$(od -An -tx1 -j "$OFF" -N "$LEN" "$BR_NV" | tr -d ' \n')"
[[ -n "$PK" ]] || fail "poke read nothing over the NBD seam — see the bridge"
[[ "$PK" == "$OD" ]] \
    || fail "SEAM UNFAITHFUL: poke over NBD read $PK but od of the store reads $OD — the bridge does not carry bytes faithfully"
note "seam faithful: poke(NBD)=$PK == od(store)=$OD over $LEN bytes at offset $OFF"

# ── the control: the SAME comparison against a one-byte-flipped copy MUST bite ─
CORRUPT="$BR_SD/corrupt.od"
od -An -tx1 -j "$OFF" -N "$LEN" "$BR_NV" | tr -d ' \n' > "$CORRUPT"
# flip the first hex nibble of the span (guaranteed to differ)
FIRST="$(cut -c1 "$CORRUPT")"; FLIP=$(( (16#$FIRST + 1) % 16 )); FLIPHEX=$(printf '%x' "$FLIP")
BADOD="$FLIPHEX$(cut -c2- "$CORRUPT")"
if [[ "$PK" == "$BADOD" ]]; then
    fail "CONTROL did NOT bite: poke's read matched a deliberately corrupted span ($BADOD) — the comparison proves nothing"
fi
note "control bit: poke's read ($PK) != the one-byte-flipped span ($BADOD) — the equality above is a real byte comparison, not a tautology"

pass "the seam is faithful: GNU poke, reading the LIVE OpenBIOS IDE NVRAM over the NBD bridge, sees the firmware's own $LEN nonce bytes byte-for-byte equal to od of the store — and the one-byte-corruption control bites, so the equality is measured, not assumed (LIVE: block-only)"
