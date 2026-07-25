#!/usr/bin/env bash
# Verdict: `cleaning` is a real security boundary, not a silent no-op. A node with
# a backing disk NEVER reaches 'available' by auto-wiping — the machine hands the
# destructive command to the operator and stays in 'cleaning' until --wiped; and
# it REFUSES a disk outside the lab-owned allow-list. Guards F7 (destructive-op).
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap 'cleanup_sandboxes' EXIT
maas_env

N=disknode
( "$MAAS" enroll "$N" --bmc-port 6230 ) >/dev/null 2>&1 || fail "enroll failed"
( "$MAAS" manage "$N" ) >/dev/null 2>&1 || fail "manage failed"

# Register a REAL backing disk (a temp file standing in for the qcow2) inside the
# lab-owned state dir so it passes the allow-list but still must be wiped.
disk="$MAAS_STATE/$N/disk.img"
head -c 4096 /dev/zero > "$disk"
canary="THIS-DATA-MUST-SURVIVE-A-DRY-CLEANING"
printf '%s' "$canary" > "$disk"
printf '%s\n' "$disk" > "$MAAS_STATE/$N/disk"   # register it in the node's registry

# ── provide must STOP in cleaning (no auto-wipe) and hand over the command ────
out="$( ( "$MAAS" provide "$N" ) 2>&1 )" && fail "REGRESSION: provide reached 'available' without a real wipe"
assert_state "$N" cleaning
note "provide halted in 'cleaning' (did not auto-advance) ✓"

# the destructive command is PRINTED for the operator, not executed
grep -Eq 'blkdiscard|dd if=' <<<"$out" || fail "cleaning did not hand over the wipe command"
note "wipe command handed to operator (blkdiscard/dd) ✓"

# and the data is UNTOUCHED — nothing destructive actually ran
got="$(cat "$disk")"
[[ "$got" == "$canary" ]] || fail "REGRESSION: cleaning DESTROYED disk data on the dry path (canary gone)"
note "disk canary intact — no destructive verb ran ✓"

# ── --wiped is the operator's attestation; only then -> available ────────────
( "$MAAS" provide "$N" --wiped ) >/dev/null 2>&1 || fail "provide --wiped failed to complete cleaning"
assert_state "$N" available
note "provide --wiped -> available ✓"

# ── an out-of-allow-list disk is REFUSED, never wiped ────────────────────────
M=evilnode
( "$MAAS" enroll "$M" --bmc-port 6231 ) >/dev/null 2>&1 || fail "enroll evil failed"
( "$MAAS" manage "$M" ) >/dev/null 2>&1 || fail "manage evil failed"
printf '/etc/passwd\n' > "$MAAS_STATE/$M/disk"   # a path outside the lab
if ( "$MAAS" provide "$M" ) >/dev/null 2>&1; then
    fail "REGRESSION: cleaning did not refuse a disk outside the allow-list (/etc/passwd)"
fi
note "out-of-allow-list disk refused ✓"

pass "cleaning is guarded: no auto-wipe, command handed over, data survives, allow-list enforced"
