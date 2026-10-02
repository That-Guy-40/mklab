#!/usr/bin/env bash
# bridge.sh — Spike 0 (THE DECISION): how does poke reach a RUNNING OpenBIOS
# firmware's bytes, and can the live store be exported WRITABLE?
#
# Per DESIGN-NOTES-pacme-a-live-firmware-inspector.md §5, Spike 0 runs first and is
# a decision, not a feature. It brings up OpenBIOS with its IDE NVRAM store, writes
# a nonce into it, and MEASURES the three bridge surfaces + the one hazard:
#   (A) FILE — the backing file / a pmemsave snapshot: zero deps, but SNAPSHOT.
#   (B) NBD  — QMP block-export-add of the live node, read-only: LIVE (block-only).
#   (C) gdbstub IOD — live RAM: named here, built in Spike 5 (RAM stays SNAPSHOT).
#   HAZARD — can the SAME in-use node be exported WRITABLE? (shapes Spike 4's edit)
# It prints the chosen bridge and the honesty label, then one verdict.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR (default ~/openbios-lab).
set -u
usage() {
    cat <<'USAGE'
bridge.sh   Spike 0: choose poke's bridge to the live firmware, measure the hazard

Brings up OpenBIOS x86 + its IDE NVRAM store (a real block node), writes a nonce,
then measures: FILE (snapshot), NBD read-only (live, block-only), and whether a
WRITABLE export of the in-use node is accepted or refused. Prints the chosen bridge
+ honesty label (LIVE: block-only). SKIPs by name without poke / qemu / the firmware.
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
trap 'rc=$?; bridge_down; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: bridge.sh exited early (rc=$rc)"' EXIT

bridge_require skip
note "accel=$ACCEL; firmware=$FW_MB"

bridge_up fail
note "firmware up (PID $BR_QPID), nonce '$BR_NONCE' written to its IDE NVRAM (backed by ide@3)"

# (A) FILE — the backing file is readable now (a snapshot; stale the instant it is read).
OFF="$(bridge_nonce_offset)"
[[ -n "$OFF" ]] || fail "the nonce is not in the backing file — the firmware did not flush the store"
note "bridge A (FILE): the nonce is at offset $OFF in the backing file — a SNAPSHOT surface, works with zero new deps"

# (B) NBD — export the live node read-only; poke must open it. (NOT in $(...) — the
# function sets BR_NODE/BR_URI in THIS shell; a subshell would empty them.)
bridge_export_ro || fail "NBD export failed (see the ERR line above)"
URI="$BR_URI"
note "bridge B (NBD): live node $BR_NODE exported read-only at $URI"
# prove poke actually reaches it (one byte is enough here; the faithful-seam proof is Spike 1)
PK="$(poke_hex "$URI" "$OFF" 4)"
OD="$(od -An -tx1 -j "$OFF" -N 4 "$BR_NV" | tr -d ' \n')"
[[ -n "$PK" && "$PK" == "$OD" ]] || fail "poke could not read the NBD export (poke='$PK' od='$OD')"
note "bridge B confirmed: poke read the live export (poke=$PK == od=$OD)"

# THE HAZARD — the sharp Spike-0 question, measured not assumed.
HZ="$(bridge_writable_probe)"
case "$HZ" in
    accepted)
        LABEL="LIVE: block-only (writable export ACCEPTED on the in-use node)"
        note "hazard: a WRITABLE export of the in-use node was ACCEPTED — Spike 4 may edit over NBD directly" ;;
    refused:*)
        LABEL="LIVE: block-only (read-only; writable export REFUSED while the guest holds the node)"
        note "hazard MEASURED: a writable export of the in-use node is REFUSED — ${HZ#refused: }"
        note "  → Spike 4 (edit live) must pause the guest, or route the edit through the guest's own store words — NOT a silent writable export behind QEMU's back" ;;
    *) fail "hazard probe returned something unexpected: $HZ" ;;
esac

echo "BRIDGE: B (NBD, QMP block-export-add of the live IDE node)"
echo "LABEL:  $LABEL"
echo "        FILE (A) available as the SNAPSHOT surface; gdbstub IOD (C) for live RAM is Spike 5 (RAM stays SNAPSHOT)"
pass "Spike 0 decided: poke bridges to the live firmware over NBD (read-only, block-only), FILE is the snapshot fallback, and the writable-export hazard is measured (${HZ%%:*}) — so Spike 4's shape is settled by data, not assumption"
