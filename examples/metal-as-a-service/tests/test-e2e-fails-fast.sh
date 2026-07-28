#!/usr/bin/env bash
# Verdict: a failed setup phase stops the live driver, instead of being logged and passed.
#
# THE INCIDENT. run-e2e.sh's `run()` invoked each phase and never looked at its exit
# status. Phase 3 failed outright —
#
#     qemu-img: /var/lib/libvirt/images/node1.qcow2: Failed to get "write" lock
#     create-fleet: create-node node1 failed
#
# — so no domain was recreated, no console instrumented, no BMC verified, nothing
# enrolled. Phases 4 through 10 ran anyway. Phase 4 then failed too ("cannot 'manage'
# from state 'manageable'"), was also ignored, and the run ended blaming a health gate
# eight phases downstream of the actual defect. Two of the three failed live runs were
# read wrong the first time because of this.
#
# The distinction the script now draws, and what this test pins:
#
#   run()       SETUP. Must succeed; everything after depends on it. Failure aborts,
#               naming the step, and does NOT paraphrase the tool's own error.
#   run_soft()  the things UNDER TEST (deploy, apply, watch). Their failure IS the
#               result — we want the state, the apply report and the verdict, not an
#               abort. Deliberately non-fatal, and that has to stay deliberate.
#
# SAFETY: pure text plus one throwaway bash subprocess whose "failing tool" is
# `false`. Nothing here names a destructive command, and nothing touches the fleet.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trap 'cleanup_sandboxes' EXIT
maas_env
E2E="$LAB_DIR/run-e2e.sh"
[[ -f "$E2E" ]] || fail "run-e2e.sh is missing"

# ── 1. run() checks the exit status at all ─────────────────────────────────
sed -n '/^run()  {/,/^}/p' "$E2E" > "$SANDBOX/run.sh"
[[ -s "$SANDBOX/run.sh" ]] || fail "could not extract run() from run-e2e.sh — renamed?"
# Syntactic smoke only — §2/§3 below prove the BEHAVIOUR. Kept because a run() that
# never mentions $? at all is worth naming directly.
grep -qE 'rc=\$\?|if ! "\$@"|"\$@".*\|\| *die|return 1' "$SANDBOX/run.sh" \
    || fail "REGRESSION: run() does not act on the phase's exit status. A setup phase that fails would be logged and stepped over, and the run would report a different failure many phases later — which is exactly how three live runs were misread"
note "run() acts on the exit status of the phase it runs  ✓"

# ── 2. exercise the SHIPPED run(): a failing phase aborts ──────────────────
# Built from the real file, not a paraphrase of it.
harness() {  # harness <fn> <cmd...> ; echoes rc, writes output to $SANDBOX/out
    local fn="$1"; shift
    { printf 'DRY=0\nLOG="%s/harness.log"\n: > "$LOG"\n' "$SANDBOX"
      printf 'die() { printf "FAIL: %%s\\n" "$*" >&2; exit 1; }\n'
      printf 'info() { printf "   %%s\\n" "$*" >&2; }\n'
      sed -n "/^$fn() {*/,/^}/p" "$E2E"
      printf '%s "$@"\n' "$fn"
      printf 'printf "REACHED-THE-NEXT-PHASE\\n" >&2\n'
    } > "$SANDBOX/h.sh"
    ( bash "$SANDBOX/h.sh" "$@" ) >"$SANDBOX/out" 2>&1
    printf '%s' $?
}

rc="$(harness run false)"
[[ "$rc" != 0 ]] \
    || fail "REGRESSION: run() returned success for a phase that failed — every later phase would run on top of a broken one"
grep -q 'REACHED-THE-NEXT-PHASE' "$SANDBOX/out" \
    && fail "REGRESSION: execution continued past a failed setup phase. That is the defect: phase 3 once failed completely and phases 4-10 ran anyway, each reporting its own confusing error"
grep -q 'FAIL:' "$SANDBOX/out" \
    || fail "run() aborted but printed no FAIL verdict — a silent abort is indistinguishable from a broken harness"
note "a failing setup phase aborts the run, with a verdict, before the next phase  ✓"

# ── 3. the positive control: a succeeding phase does NOT abort ─────────────
# Without this, §2 would also pass on a run() that aborts unconditionally.
rc="$(harness run true)"
[[ "$rc" == 0 ]] || fail "run() failed a phase that SUCCEEDED (rc=$rc) — the whole script would be unusable"
grep -q 'REACHED-THE-NEXT-PHASE' "$SANDBOX/out" \
    || fail "run() did not continue past a phase that succeeded"
note "a succeeding phase continues normally  ✓"

# ── 4. run_soft is deliberately NOT fatal, and says so ─────────────────────
# The deploy failing is a result to report, not an obstacle. If someone "fixes" this by
# making everything fatal, a failed deploy would abort before `apply` gets to say HELD
# and before the verdict is computed — losing the most informative output there is.
rc="$(harness run_soft false)"
[[ "$rc" == 0 ]] \
    || fail "REGRESSION: run_soft aborted on failure. The deploy and apply phases ARE the experiment; aborting on them throws away the state, the apply report and the verdict"
grep -q 'REACHED-THE-NEXT-PHASE' "$SANDBOX/out" \
    || fail "REGRESSION: run_soft did not continue past a failed step"
grep -qi 'failed' "$SANDBOX/out" \
    || fail "run_soft swallowed the failure silently — non-fatal must still be VISIBLE, or a failed deploy reads as a successful one"
note "run_soft continues past a failure, but says out loud that it happened  ✓"

# ── 5. the setup phases actually use run(), not run_soft ───────────────────
# The distinction is only worth anything if the load-bearing phases are on the fatal
# side of it. create-fleet.sh's `up` is the one that failed and was stepped over.
grep -qE '^run "\$HERE/create-fleet\.sh" up' "$E2E" \
    || fail "REGRESSION: 'create-fleet.sh up' is no longer a fatal phase — it is THE step whose silent failure caused this test to exist"
grep -qE '^run "\$HERE/netboot-chain\.sh" install' "$E2E" \
    || fail "REGRESSION: 'netboot-chain.sh install' is no longer a fatal phase — without it every node boots the wrong payload"
note "the load-bearing setup phases are on the fatal side of the line  ✓"

# ── 6. --dry-run must not write to the real log ────────────────────────────
# It used to `tee -a` while skipping the truncation, so a dry run appended a ghost run
# to the last real one. A log with two interleaved runs is worse than no log.
before="$(wc -c < "$LAB_DIR/e2e-run.log" 2>/dev/null || echo 0)"
( cd "$LAB_DIR" && ./run-e2e.sh --dry-run ) >/dev/null 2>&1
after="$(wc -c < "$LAB_DIR/e2e-run.log" 2>/dev/null || echo 0)"
[[ "$before" == "$after" ]] \
    || fail "REGRESSION: --dry-run wrote to the real run log ($before -> $after bytes). It appends a ghost run to the last real one, and the next person reading a failure reads two runs interleaved"
note "--dry-run leaves the real run log byte-for-byte alone  ✓"

pass "a failed SETUP phase aborts the live driver with a verdict; the phases under test stay deliberately non-fatal but visible; and --dry-run never touches the run log"
