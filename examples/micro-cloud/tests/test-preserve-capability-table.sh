#!/usr/bin/env bash
# preserve.sh's capability table is a CACHED FACT ABOUT SIX OTHER SCRIPTS. Gate it.
#
# `preserve.sh capabilities` prints which phase can do which tier. Nothing in preserve.sh
# re-derives that at runtime — it cannot, cheaply — so the table is exactly the kind of
# record §9.5 is about, just describing sibling drivers instead of a tarball. Left
# unchecked it fails in both directions, and the second one is the quiet one:
#
#   TOO NARROW — a driver grows `snapshot` and the table still refuses the tier by name.
#                Nothing errors. The tool is simply, confidently, out of date, and the
#                refusal message it prints is the most convincing thing in the room.
#   TOO WIDE   — the table claims a verb a driver never had, and `save` dies mid-backup.
#
# ── THE PROBE IS DRIVER-AGNOSTIC, AND THAT IS THE POINT ─────────────────────────────────
# There is no shared "does this driver have verb X" API, and grepping each driver's
# dispatch `case` would be a regex over a physical line standing in for a question about a
# command — the mistake `tools/check-harness-net.sh` made twice. So ASK THE DRIVER: a
# driver answers a verb it does not have EXACTLY as it answers a verb nobody has. Run
# both, normalise the verb token out of each answer, and compare.
#
# ── AND THE TRAP THAT MAKES THE NORMALISATION LOAD-BEARING ──────────────────────────────
# The same probe in `lab_tui/topology.py` reported `up` as PRESENT on two drivers that
# never had it, because `sed s/up/VERB/g` also rewrote "gro*up*" and "set*up*" in the
# usage text — different substitutions, different strings, "the verb exists". Word
# boundaries are not a tidiness detail here; without them the probe inverts.
set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PRESERVE="$LAB_DIR/preserve.sh"
[[ -x "$PRESERVE" ]] || fail "preserve.sh is missing or not executable at $PRESERVE"

NONCE='zzz-no-driver-has-this-verb-9d1'

# verb_present <driver-abs> <verb>  → 0 if the driver treats it as a real verb
verb_present() {
    local d="$1" v="$2" a b
    a="$(bash "$d" "$v"     </dev/null 2>&1 || true)"
    b="$(bash "$d" "$NONCE" </dev/null 2>&1 || true)"
    a="$(sed -E "s/\\b${v}\\b/THEVERB/g" <<<"$a")"
    b="$(sed -E "s/\\b${NONCE}\\b/THEVERB/g" <<<"$b")"
    [[ "$a" != "$b" ]]
}

# ── 0. THE PROBE'S OWN CONTROLS, BEFORE IT IS AIMED AT ANYTHING ─────────────────────────
# A probe that always says "present" and a probe that always says "absent" both produce a
# clean-looking table comparison — one green, one uniformly red and easy to blame on the
# drivers. So it is exercised against a verb every driver has and a verb no driver has
# before a single row below is trusted. (`tools/check-harness-net.sh` §1a exists because
# the section that never proved itself was the section that was wrong.)
probe_controls_ok=0
for phase_driver in "phase1-chroot/lab-chroot.sh" "phase4-podman/lab-podman.sh" "phase7-firecracker/lab-fc.sh"; do
    d="$REPO_DIR/$phase_driver"
    [[ -r "$d" ]] || fail "driver missing: $d"
    verb_present "$d" list  || fail "the probe's POSITIVE control failed: $phase_driver has a 'list' verb and the probe says it does not"
    ! verb_present "$d" "$NONCE-2" \
        || fail "the probe's NEGATIVE control failed: $phase_driver reported a verb nobody has as present"
    probe_controls_ok=$((probe_controls_ok + 1))
done
(( probe_controls_ok == 3 )) || fail "the probe's controls did not all run"
note "probe controls: 3 drivers × (a verb they have, a verb nobody has) — both directions bite"

# ── 1. THE TABLE, ROW BY ROW ────────────────────────────────────────────────────────────
caps="$(bash "$PRESERVE" capabilities)" || fail "preserve.sh capabilities failed"
rows=0 mismatches=()
while IFS=$'\t' read -r phase driver portable fast _engine; do
    [[ "$phase" == \#* || -z "$phase" ]] && continue
    d="$REPO_DIR/$driver"
    [[ -r "$d" ]] || { mismatches+=("$phase: the table names a driver that is not there: $driver"); continue; }
    rows=$((rows + 1))

    # tier 2. `copy` is not a driver verb — it is preserve.sh's own path for phase 7, and
    # the claim it rests on is that lab-fc.sh has NO export verb, so that is what is
    # checked. If phase 7 ever grows one, this row fails and the table should change.
    if [[ "$portable" == "copy" ]]; then
        ! verb_present "$d" export-tarball \
            || mismatches+=("$phase: the table says 'copy' because $driver has no export-tarball — but it does now. Use the verb.")
        verb_present "$d" inspect \
            || mismatches+=("$phase: preserve.sh derives this phase's paths from '$driver inspect', and that verb is gone")
    else
        verb_present "$d" "$portable" \
            || mismatches+=("$phase: the table claims '$portable' and $driver does not have it — save would die mid-backup")
    fi

    # tier 1.
    if [[ "$fast" == "-" ]]; then
        ! verb_present "$d" snapshot \
            || mismatches+=("$phase: $driver HAS a snapshot verb now, and the table still refuses the fast tier by name — the refusal is out of date, and it is more convincing than the truth")
    else
        verb_present "$d" "$fast" \
            || mismatches+=("$phase: the table claims fast-tier '$fast' and $driver does not have it")
    fi
done <<<"$caps"

(( rows == 6 )) || fail "expected 6 phases in the capability table, checked $rows — a table that lists fewer is a phase nobody preserves"

if (( ${#mismatches[@]} )); then
    printf 'FAIL: preserve.sh'\''s capability table and the drivers disagree:\n' >&2
    printf '  - %s\n' "${mismatches[@]}" >&2
    fail "${#mismatches[@]} capability row(s) drifted from the drivers they describe"
fi

pass "all 6 capability rows match what the drivers actually answer (probe controls fired in both directions)"
