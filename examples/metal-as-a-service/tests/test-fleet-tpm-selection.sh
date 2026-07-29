#!/usr/bin/env bash
# Verdict: FLEET_TPM gives UEFI+TPM to exactly the nodes it names — and refuses a
# name that matches nothing rather than silently equipping no one.
#
# THE INCIDENT THIS COMES FROM. The first live `image+measured` attempt used
# FLEET_TPM=1, which was the only setting there was. It switched node1 and node2 to
# UEFI along with node3 — and those two had disks INSTALLED under BIOS, which UEFI
# firmware cannot boot. Measured boot is a property of one node's job, not of a
# fleet, so the knob now takes node names.
#
# WHY THE TYPO GUARD IS NOT FUSSY. `FLEET_TPM=node33` would match no node, equip
# nobody, and print nothing. The failure surfaces an hour later as an empty console
# and "the node never delivered a quote" — which reads as a bug in the measuring
# payload, and sends you debugging the wrong half of the lab entirely.
#
# No libvirt, no swtpm, no fleet: create-fleet.sh exposes the selection itself
# (`_selects-tpm`, `_check-tpm`) so the decision can be asked without building
# anything, which is also why there is one implementation of it rather than two.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need python3

FLEET="$LAB_DIR/create-fleet.sh"
[[ -x "$FLEET" ]] || skip "create-fleet.sh is not executable"

# selects <FLEET_TPM value> [node...] -> the node names it picks, space-separated.
# The subshell contains create-fleet.sh's `die` (CLAUDE.md's silent-exit trap: a die
# is an exit, and an uncontained one would kill this test before its assertions).
selects() {
    local want="$1" n out=""
    shift
    for n in "${@:-node1 node2 node3}"; do
        ( FLEET_TPM="$want" "$FLEET" _selects-tpm "$n" ) >/dev/null 2>&1 && out="$out $n"
    done
    printf '%s' "${out# }"
}

# ── 1. off by default, and off when explicitly off ──────────────────────────
# The default matters: the other three drivers all boot BIOS payloads, so a fleet
# that quietly became UEFI would break every one of them.
for off in "" 0 no off; do
    got="$(selects "$off" node1 node2 node3)"
    [[ -z "$got" ]] \
        || fail "REGRESSION: FLEET_TPM='$off' selected [$got]. UEFI is not the default: every other driver's payload is BIOS-booted and would stop working"
done
note "unset / 0 / no / off select nothing — BIOS stays the default  ✓"

# ── 2. it selects exactly what it names ─────────────────────────────────────
got="$(selects node3 node1 node2 node3)"
[[ "$got" == "node3" ]] || fail "FLEET_TPM=node3 selected [$got], expected [node3]"
got="$(selects node2,node3 node1 node2 node3)"
[[ "$got" == "node2 node3" ]] || fail "FLEET_TPM=node2,node3 selected [$got], expected [node2 node3]"
note "names one node, or a comma-separated list, and gets exactly those  ✓"

# ── 3. THE PREFIX TRAP: node1 must not match node10 ─────────────────────────
# A substring test would equip node10 when asked for node1, and — worse — equip
# node1 when asked for node10. Both give a TPM to a machine nobody asked about,
# which under this lab's own rules is the LIED shape: the record says one fleet
# shape and the hardware has another.
got="$(selects node1 node1 node10 node100)"
[[ "$got" == "node1" ]] \
    || fail "REGRESSION: FLEET_TPM=node1 selected [$got] — a prefix match equips a node nobody named. The commas on both sides of the comparison are what prevent this"
got="$(selects node10 node1 node10)"
[[ "$got" == "node10" ]] \
    || fail "REGRESSION: FLEET_TPM=node10 selected [$got], expected only node10"
note "node1 does not match node10, and node10 does not match node1  ✓"

# ── 4. the whole-fleet setting still works (it is in scripts and notes) ─────
for all in 1 all yes; do
    got="$(selects "$all" node1 node2 node3)"
    [[ "$got" == "node1 node2 node3" ]] \
        || fail "FLEET_TPM=$all selected [$got], expected the whole fleet — run-e2e-measured.sh and DEFERRED.md both still say FLEET_TPM=1"
done
note "FLEET_TPM=1 / all / yes still equip the whole fleet  ✓"

# ── 5. a name that matches nothing is REFUSED, not ignored ─────────────────
if ( FLEET_TPM=node33 "$FLEET" _check-tpm ) >/dev/null 2>&1; then
    fail "REGRESSION: FLEET_TPM=node33 was accepted. It matches no node, so the run would equip NOBODY and say nothing — and the measured deploy would fail an hour later with an empty console, looking like a payload bug"
fi
err="$( ( FLEET_TPM=node33 "$FLEET" _check-tpm ) 2>&1 )"
grep -q 'node33' <<<"$err" \
    || fail "the refusal does not name the offending value: $err"
grep -qi 'known nodes' <<<"$err" \
    || fail "the refusal does not list the names that WOULD have worked, which is the one thing the operator needs: $err"
note "refuses an unknown node name, quoting it and listing the real ones  ✓"

# The positive control for §5: a valid name must NOT be refused, or the guard is
# simply "always refuse" and proves nothing.
( FLEET_TPM=node2,node3 "$FLEET" _check-tpm ) >/dev/null 2>&1 \
    || fail "a valid FLEET_TPM=node2,node3 was refused by the same guard — it rejects everything, so §5 proved nothing"
note "and accepts a valid selection — the guard discriminates  ✓"

pass "FLEET_TPM equips exactly the nodes it names (never a prefix neighbour), leaves the fleet on BIOS by default, still honours the whole-fleet form, and refuses a name matching no node instead of silently equipping nobody"
