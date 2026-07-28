#!/usr/bin/env bash
# Verdict: no injected fault becomes a critical failure, and the recovery verbs that
# make that true are selective.
#
# `chaos-run.sh` injects a fault at each point a deploy can break and grades where the
# node lands on a ladder: ABSORBED (the fault never reached the service — the goal),
# DEGRADED (fell back to the previous image), HALTED (stopped honestly, with a verb
# that recovers it) — and the two that are CRITICAL: STRANDED (stuck in a transient
# state no verb accepts) and STALE/LIED (the registry claiming something reality does
# not support).
#
# This asserts more than "zero criticals", because zero criticals is also what a
# harness that never actually broke anything would report. It also requires the
# middle rungs to be OCCUPIED: at least one fault must have been absorbed, at least
# one must have forced a fallback, and at least one must have halted the node. A
# matrix where everything lands on one rung is not exercising the fallback path.
#
# SAFETY: chaos-run.sh drives the mock BMC and the chaos driver against a throwaway
# registry. Nothing boots, nothing is powered, no disk is touched.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl python3

# lib.sh arms the verdict trap at source time; re-arm it so it also cleans up.
OUT="$(mktemp)"
# shellcheck disable=SC2154
trap '_rc=$?; rm -f "$OUT"; cleanup_sandboxes; [[ $_rc == 0 || $_rc == 77 ]] || printf "FAIL: test exited early (rc=%s)\n" "$_rc" >&2' EXIT
( "$LAB_DIR/chaos-run.sh" --json ) > "$OUT" 2>/dev/null
rc=$?
[[ -s "$OUT" ]] || fail "chaos-run.sh --json produced no report (rc=$rc)"

read -r total crit absorbed degraded halted critnames < <(python3 - "$OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rows = d["rows"]
c = lambda v: sum(1 for r in rows if r["verdict"] == v)
bad = [r["scenario"] for r in rows if r["verdict"] in ("STRANDED", "LIED", "STALE")]
print(d["total"], d["critical"], c("ABSORBED"), c("DEGRADED"), c("HALTED"),
      ",".join(bad) or "-")
PY
) || fail "could not parse chaos-run.sh --json"

note "$total scenarios: $absorbed absorbed, $degraded degraded, $halted halted, $crit critical"

# ── 1. the thing that must be zero ──────────────────────────────────────────
[[ "$crit" -eq 0 ]] \
    || fail "REGRESSION: $crit injected fault(s) became a CRITICAL failure ($critnames) — a node was left stranded in a transient state no verb accepts, or the registry claims an image that never deployed or has since died. Fallback and an honest halt are acceptable; these are not"
[[ "$rc" -eq 0 ]] || fail "chaos-run.sh reported no critical outcomes but exited $rc"
note "no injected fault became a critical failure  ✓"

# ── 2. …and the run was not vacuous ─────────────────────────────────────────
# Each of these would be satisfied by a broken harness in a different way: a matrix
# that never breaks anything is all-ABSORBED; one that breaks everything unrecoverably
# is all-HALTED; one where the A/B path is dead never reaches DEGRADED.
[[ "$total" -ge 10 ]] || fail "the matrix ran only $total scenarios — too few to cover the deploy path's failure points"
[[ "$absorbed" -ge 1 ]] \
    || fail "REGRESSION: not one fault was ABSORBED — including the no-fault control, which means a CLEAN deploy no longer reaches active. Every row failing is not a resilient control plane, it is a broken one"
[[ "$degraded" -ge 1 ]] \
    || fail "REGRESSION: not one fault produced a fallback to the previous image — the A/B rollback path (§4b) is not being exercised at all, so 'zero criticals' proves nothing about it"
[[ "$halted" -ge 1 ]] \
    || fail "REGRESSION: not one fault halted a node — the matrix is not reaching the unrecoverable-image cases (a fresh node with nothing to fall back to)"
note "the ladder's rungs are all occupied: absorbed, degraded AND halted each happened  ✓"

# ── 3. the recovery verbs are selective, not blanket ────────────────────────
# `abort` and `recheck` exist because this harness found the cases. A verb that
# accepted ANY state would make the matrix pass while hiding the same bugs.
maas_env
( "$MAAS" enroll c1 --bmc-port 6390 ) >/dev/null 2>&1 || fail "enroll c1"
( "$MAAS" manage c1 ) >/dev/null 2>&1 || fail "manage c1"

out="$( ( "$MAAS" abort c1 ) 2>&1 )" && fail "REGRESSION: 'abort' accepted a node in 'manageable' — it must only unstick a node caught mid-transition, or it becomes a way to force any node to error"
grep -Fq "stuck mid-transition" <<<"$out" \
    || fail "abort refused a non-transient node but did not explain why (got: ${out//$'\n'/ })"

out="$( ( "$MAAS" recheck c1 ) 2>&1 )" && fail "REGRESSION: 'recheck' accepted a node that is not active — there is no activation claim to re-test"
grep -Fq "claims to be active" <<<"$out" \
    || fail "recheck refused a non-active node but did not explain why (got: ${out//$'\n'/ })"
note "abort and recheck each refuse the states they are not for, and say why  ✓"

# ── 4. unmaintenance must not restore a node INTO a transient state ─────────
# maintenance accepts ANY state, so it was the one verb that took a stranded node —
# and unmaintenance handed it straight back to the state it was stuck in. The strand
# survived a round trip through the only verb that could touch it.
printf 'deploying\n' > "$MAAS_STATE/c1/state"
( "$MAAS" maintenance c1 ) >/dev/null 2>&1 || fail "maintenance should accept any state"
( "$MAAS" unmaintenance c1 ) >/dev/null 2>&1 || fail "unmaintenance failed"
got="$("$MAAS" state c1 2>/dev/null)"
[[ "$got" != deploying ]] \
    || fail "REGRESSION: unmaintenance restored the node INTO 'deploying' — the transient state it was stuck in. The round trip through maintenance changes nothing except adding a line to the history"
[[ "$got" == error ]] \
    || fail "unmaintenance took a mid-transition node out of maintenance into '$got'; expected 'error', where retry can pick it up"
note "a node that was mid-transition comes out of maintenance as 'error', not stuck again  ✓"

# ── 5. THE HOUSE RULE, enforced ─────────────────────────────────────────────
# "Every discrete layer gets a fault-injection point, and every deploy driver gets a
# test that drives the REAL driver through its failure paths." A rule that is only
# written down decays the first time someone is in a hurry, so it is checked here:
# add a layer or a driver without its coverage and this test names what is missing.
mapfile -t COVERED < <("$LAB_DIR/chaos-run.sh" --layers 2>/dev/null | awk '$2+0>0 {print $1}')
mapfile -t DECLARED < <("$LAB_DIR/chaos-run.sh" --layers 2>/dev/null | awk '{print $1}')
[[ ${#DECLARED[@]} -ge 5 ]] \
    || fail "chaos-run.sh --layers reported only ${#DECLARED[@]} layers — the layer taxonomy has gone missing"
for L in "${DECLARED[@]}"; do
    printf '%s\n' "${COVERED[@]}" | grep -qx -- "$L" \
        || fail "REGRESSION: layer '$L' is declared but has NO chaos scenario. The house rule is that every discrete layer gets a fault-injection point — an uncovered layer is one nobody has watched fall over. Add a scenario for it in chaos-run.sh"
done
note "all ${#DECLARED[@]} declared layers have at least one fault scenario: ${DECLARED[*]}  ✓"

# Every deploy driver must have a test that drives the REAL thing. The chaos driver
# stands in at the driver LAYER; it does not stand in for a specific driver's contract
# (install ends on bootdev disk, ramdisk must not, image must not do it early…).
shopt -s nullglob
missing=()
for d in "$LAB_DIR"/drivers/*.sh; do
    n="$(basename "$d" .sh)"
    case "$n" in chaos|verify-lib) continue ;; esac       # the injector and the crypto lib
    [[ -f "$TEST_DIR/test-$n-driver.sh" ]] || missing+=("$n")
done
[[ ${#missing[@]} -eq 0 ]] \
    || fail "REGRESSION: deploy driver(s) with no real-driver test: ${missing[*]}. The house rule is that a driver ships with a test that drives IT, not the mock — the mock proves the control plane's logic, never the driver's own contract. Add tests/test-<name>-driver.sh"
note "every deploy driver has a test that drives the real driver, not the mock  ✓"

pass "every injected fault was absorbed, fell back, or halted honestly — zero criticals across all declared layers, and every layer and driver carries its own fault coverage"
