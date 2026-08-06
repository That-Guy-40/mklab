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
on_exit 'rm -f "$OUT"'
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

# ── 2b. the mis-bound BMC — the failure that passed every gate (DEFERRED item 3) ──
# The second live run hit it by accident: two BMCs on one port, and the winner served
# IPMI for both — four commands succeeded, every answer true about the wrong machine.
# The scenario must stay in the matrix, in the oob layer, and stay non-critical.
python3 - "$OUT" <<'PY' || fail "REGRESSION: the bmc-misbound scenario is missing from the oob layer, or graded critical. It is the only failure class this lab has seen that passed every gate on the way to failing (the vbmc port collision) — chaos-run.sh must keep injecting it, and the console-bound health check is what keeps it at an honest HALT"
import json, sys
rows = json.load(open(sys.argv[1]))["rows"]
mb = [r for r in rows if "bmc-misbound" in r["scenario"]]
assert mb, "no bmc-misbound row in the matrix"
assert all(r["layer"] == "oob" for r in mb), "bmc-misbound is not in the oob layer"
assert all(r["verdict"] not in ("STRANDED", "LIED", "STALE") for r in mb), \
    "bmc-misbound graded critical: " + repr(mb)
PY
note "the mis-bound-BMC scenario is present in the oob layer and non-critical  ✓"

# The seam itself, both directions. A mis-bound `power on` must actuate ONLY the
# victim, the victim's console (not the subject's) must show the boot, and `status`
# must answer truthfully about the victim — that truthfulness is what made the live
# incident invisible.
PDIR="$(mktemp -d)"; CONS="$(mktemp -d)"; _SANDBOXES+=("$PDIR" "$CONS")
( MOCK_BMC_POWER_DIR="$PDIR" MOCK_BMC_CONSOLE_DIR="$CONS" MOCK_BMC_ACTUATES=victim \
  "$TEST_DIR/mock-bmc.sh" subj power on ) >/dev/null \
    || fail "mock-bmc refused a mis-bound 'power on' — the fault must succeed to be the fault"
[[ "$(cat "$PDIR/victim.power" 2>/dev/null)" == on ]] \
    || fail "REGRESSION: MOCK_BMC_ACTUATES=victim did not power on the victim machine"
[[ -f "$PDIR/subj.power" ]] \
    && fail "REGRESSION: a mis-bound 'power on' also touched the subject's own machine — the mis-binding must be a redirection, not a broadcast"
grep -q 'victim: powered on' "$CONS/victim.log" 2>/dev/null \
    || fail "REGRESSION: the victim powered on but its console shows no boot line — console-bound health gates would have no ground truth to stand on"
[[ -f "$CONS/subj.log" ]] \
    && fail "REGRESSION: the subject's console shows boot output although its machine never powered on — that is the exact lie the console exists to not tell"
out="$( ( MOCK_BMC_POWER_DIR="$PDIR" MOCK_BMC_ACTUATES=victim "$TEST_DIR/mock-bmc.sh" subj power status ) )"
grep -q 'Chassis Power is on' <<<"$out" \
    || fail "REGRESSION: a mis-bound 'power status' did not answer truthfully about the victim (got: $out) — a status that fails or answers about the subject would make the fault announce itself, which is bmc-drop, not this"
( MOCK_BMC_POWER_DIR="$PDIR" "$TEST_DIR/mock-bmc.sh" subj2 power on ) >/dev/null
[[ "$(cat "$PDIR/subj2.power" 2>/dev/null)" == on ]] \
    || fail "mock-bmc without MOCK_BMC_ACTUATES no longer powers the machine it was addressed for"
note "MOCK_BMC_ACTUATES redirects power, status and console to the victim — and only then  ✓"

# The console check is LOAD-BEARING — run the lie, don't reason about it. With the
# check OFF, a deploy through a mis-bound BMC records `active` on a machine that
# never powered on (the LIED shape, for real); with it ON, the same deploy halts.
maas_env
export MAAS_DRIVER_DIR="$LAB_DIR/drivers" MAAS_IMAGES_DIR="$SANDBOX/images"
export MAAS_HEALTH_TIMEOUT=2 MAAS_POLL_INTERVAL=0
export CHAOS_STATE="$SANDBOX/chaos" CHAOS_LOG="$SANDBOX/chaos.log"
export MOCK_BMC_POWER_DIR="$SANDBOX/mb-power"
mkdir -p "$MAAS_IMAGES_DIR/trust" "$CHAOS_STATE"
"$LAB_DIR/drivers/verify-lib.sh" gen-keys --dir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1 \
    || skip "verify-lib gen-keys failed (openssl missing?)"
mkdir -p "$MAAS_IMAGES_DIR/good-mb"
printf 'PAYLOAD-good-mb\n' > "$MAAS_IMAGES_DIR/good-mb/payload.img"
"$LAB_DIR/drivers/verify-lib.sh" sign "$MAAS_IMAGES_DIR/good-mb/payload.img" \
    --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1 || fail "signing good-mb failed"

( "$MAAS" enroll mb1 --bmc-port 6391 ) >/dev/null 2>&1 || fail "enroll mb1"
( "$MAAS" manage mb1 ) >/dev/null 2>&1 && ( "$MAAS" provide mb1 ) >/dev/null 2>&1 \
    || fail "could not drive mb1 to available"
( export CHAOS_FAULT=none CHAOS_USE_BMC=1 MOCK_BMC_ACTUATES=mb-victim \
         MOCK_BMC_CONSOLE_DIR="$SANDBOX/mb-consoles"
  "$MAAS" deploy mb1 --driver chaos --image good-mb ) >/dev/null 2>&1
[[ "$( ( "$MAAS" state mb1 ) 2>/dev/null )" == active ]] \
    || fail "control: with the console check OFF the mis-bound deploy was expected to (wrongly) reach active — something else refused it, so this test is no longer isolating the console check"
[[ -f "$MOCK_BMC_POWER_DIR/mb1.power" ]] \
    && fail "control: mb1's own machine was powered — the mis-binding did not redirect"
note "defence off: registry says active, the machine never powered on — the lie is real  ✓"

( "$MAAS" enroll mb2 --bmc-port 6392 ) >/dev/null 2>&1 || fail "enroll mb2"
( "$MAAS" manage mb2 ) >/dev/null 2>&1 && ( "$MAAS" provide mb2 ) >/dev/null 2>&1 \
    || fail "could not drive mb2 to available"
( export CHAOS_FAULT=none CHAOS_USE_BMC=1 MOCK_BMC_ACTUATES=mb-victim2 \
         MOCK_BMC_CONSOLE_DIR="$SANDBOX/mb-consoles" CHAOS_CONSOLE_DIR="$SANDBOX/mb-consoles"
  "$MAAS" deploy mb2 --driver chaos --image good-mb ) >/dev/null 2>&1 \
    && fail "REGRESSION: a deploy through a mis-bound BMC SUCCEEDED with the console check ON — the machine never booted and health passed anyway"
[[ "$( ( "$MAAS" state mb2 ) 2>/dev/null )" == error ]] \
    || fail "REGRESSION: the console check refused the mis-bound deploy but the node ended in '$( ( "$MAAS" state mb2 ) 2>/dev/null )' instead of 'error'"
note "defence on: the same deploy halts in error — the console check is load-bearing  ✓"

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

# ── 6. THE PANEL INVARIANT (§5b): delete Phase 6 and nothing is lost ────────
# The actions panel must be a SURFACE over the CLI, never a second implementation of
# it. The test of that is mechanical: every verb the panel may drive is declared by
# MAAS itself, and every one is literally `maas-lab.sh …` — so the same argv works in
# a shell with the TUI deleted.
maas_env
( "$MAAS" enroll p1 --bmc-port 6395 ) >/dev/null 2>&1 || fail "enroll p1"
( export LAB_STATE_DIR="$SANDBOX"; "$MAAS" watch p1 --register-only ) >/dev/null 2>&1 \
    || fail "registering p1 with the control pane failed"
NT="$SANDBOX/control-pane/p1/node.toml"
[[ -f "$NT" ]] || fail "watch --register-only wrote no node.toml"
grep -q "^\[\[action\]\]" "$NT" \
    || fail "REGRESSION: MAAS registered a node but declared NO actions — the panel would have nothing to drive, or would grow commands of its own"

CP="$LAB_DIR/../../tools/control-pane"
if [[ -x "$CP" ]]; then
    acts="$( "$CP" actions p1 --fleet "$SANDBOX/control-pane" --json 2>/dev/null )"
    [[ -n "$acts" ]] || fail "control-pane could not read the actions MAAS declared"
    python3 - "$acts" "$LAB_DIR/maas-lab.sh" <<'PYCHK' || fail "REGRESSION: a declared panel action does not run maas-lab.sh. The panel must be a surface over the CLI — an action that runs anything else is a second implementation, and deleting Phase 6 would lose behaviour that exists nowhere else"
import json, sys
acts, maas = json.loads(sys.argv[1]), sys.argv[2]
assert acts, "no actions declared"
for a in acts:
    assert a["argv"][0] == maas, f"{a['label']}: argv[0]={a['argv'][0]!r}, expected {maas!r}"
assert acts[0]["reconciling"], f"first declared action is not the reconciling one: {acts[0]['label']}"
PYCHK
    note "every panel action is literally 'maas-lab.sh …', and the first one reconciles  ✓"
else
    note "tools/control-pane not executable here — skipped the argv cross-check"
fi

pass "every injected fault was absorbed, fell back, or halted honestly — zero criticals across all declared layers, every layer and driver carries its own fault coverage, and the panel drives only maas-lab.sh"
