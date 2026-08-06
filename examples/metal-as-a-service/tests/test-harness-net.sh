#!/usr/bin/env bash
# Verdict: the EXIT-trap safety net every other test relies on actually fires when a
# test dies without a verdict, stays quiet when one was printed, and cannot be
# disarmed by a test installing its own EXIT trap.
#
# WHY THIS EXISTS. lib.sh has installed that net since the lab was written, and on
# 2026-08-06 it was inert in 23 of 36 tests: bash keeps ONE EXIT trap per shell, and
# each of those tests wrote `trap 'cleanup_sandboxes' EXIT`, silently replacing it. A
# `die` inside maas-lab.sh therefore ended those tests with a bare rc and no verdict
# line at all — the exact incident CLAUDE.md's "belt-and-suspenders" rule exists to
# prevent. Eleven more re-inlined the net and printed FAIL twice on a real failure.
#
# Neither shape was visible from any run, because the net is only observable when
# something goes wrong — so nothing ever exercised it. An assertion never seen failing
# is not known to work. This file makes the net a thing that is tested rather than a
# thing that is present, and §1 makes the structural rule enforceable instead of
# advisory.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

WORK="$(mktemp -d)"
on_exit 'rm -rf "$WORK"'          # dogfood: this test registers cleanup the same way

# ── 1. no test may install its own EXIT trap ───────────────────────────────
# Anchored to the start of a line so the fixtures test-e2e-reaps-sink.sh writes and
# greps (`printf 'trap reap EXIT\n' >> …`) are not mistaken for the real thing.
OFFENDERS="$(grep -ln '^[[:space:]]*trap .*EXIT' "$TEST_DIR"/test-*.sh 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
[[ -z "$OFFENDERS" ]] \
    || fail "these tests install their own EXIT trap, which REPLACES lib.sh's safety net and leaves them able to die with no verdict line: $OFFENDERS. Register cleanup with on_exit '<cmd>' instead"
_all=("$TEST_DIR"/test-*.sh)
note "no test overrides lib.sh's EXIT trap (${#_all[@]} files checked)  ✓"

# run_fixture <name> <body> — a throwaway test that sources the real lib.sh, so what is
# exercised is the shipped net and not a copy of it. Prints `rc:<n>` then the output.
run_fixture() {
    local name="$1" body="$2" rc
    { printf 'source "%s/lib.sh"\n' "$TEST_DIR"; printf '%s\n' "$body"; } > "$WORK/$name.sh"
    local out
    out="$(bash "$WORK/$name.sh" 2>&1)"; rc=$?
    printf 'rc:%s\n%s\n' "$rc" "$out"
}

# ── 2. THE POSITIVE CASE: a test that dies without a verdict is reported ──
# `die` is how maas-lab.sh refuses; an unguarded call exits the whole test.
DIED="$(run_fixture died 'exit 3')"
grep -q '^rc:3$' <<<"$DIED" \
    || fail "the fixture that exits 3 did not exit 3 — the harness is broken, not the net: $(tr '\n' ' ' <<<"$DIED")"
grep -q 'FAIL: test exited early (rc=3)' <<<"$DIED" \
    || fail "REGRESSION: a test that exited 3 with no verdict printed NO FAIL line. The safety net is inert, and any test that dies early will again produce a blank terminal and a bare rc. Got: $(tr '\n' ' ' <<<"$DIED")"
note "a test that dies with no verdict gets one: FAIL: test exited early (rc=3)  ✓"

# ── 3. and it says it exactly once ────────────────────────────────────────
# The blemish this file was written for: `fail` already printed a verdict, so the net
# must stay quiet. Two FAIL lines for one failure trains the reader to skip both.
FAILED="$(run_fixture failed 'fail "the specific defect"')"
grep -q '^rc:1$' <<<"$FAILED" || fail "fail() did not exit 1: $(tr '\n' ' ' <<<"$FAILED")"
n="$(grep -c '^FAIL:' <<<"$FAILED")"
[[ "$n" == 1 ]] \
    || fail "REGRESSION: one failure printed $n FAIL lines, not 1. The net is firing on top of a verdict that was already given, which is how a reader learns to skip past the line that names the actual defect. Got: $(tr '\n' ' ' <<<"$FAILED")"
grep -q 'FAIL: the specific defect' <<<"$FAILED" \
    || fail "the single FAIL line was the net's generic one, not the specific message fail() was given"
note "one failure prints exactly one FAIL line, and it is the specific one  ✓"

# ── 4. a pass and a skip stay silent ──────────────────────────────────────
PASSED="$(run_fixture passed 'pass "it worked"')"
grep -q '^rc:0$' <<<"$PASSED" || fail "pass() did not exit 0: $(tr '\n' ' ' <<<"$PASSED")"
grep -q 'FAIL:' <<<"$PASSED" \
    && fail "REGRESSION: a PASSING test also printed a FAIL line — the net fires on success, which makes every green run look broken"
SKIPPED="$(run_fixture skipped 'skip "no hardware"')"
grep -q '^rc:77$' <<<"$SKIPPED" || fail "skip() did not exit 77: $(tr '\n' ' ' <<<"$SKIPPED")"
grep -q 'FAIL:' <<<"$SKIPPED" \
    && fail "REGRESSION: a SKIPPED test also printed a FAIL line — a skip would be counted as a failure by anything reading the output"
note "a pass exits 0 and a skip exits 77, neither printing a FAIL line  ✓"

# ── 5. registered cleanup runs, in reverse, on every path ─────────────────
# The net is worthless if adopting it lost the teardown. Reverse order matters: a
# later registration may depend on an earlier one still existing.
CLEAN="$(run_fixture cleaned "
on_exit 'echo CLEANUP-ONE'
on_exit 'echo CLEANUP-TWO'
exit 4")"
if ! grep -q 'CLEANUP-TWO' <<<"$CLEAN" || ! grep -q 'CLEANUP-ONE' <<<"$CLEAN"; then
    fail "registered cleanup did not run when the test died (rc=4) — adopting the shared trap lost the teardown: $(tr '\n' ' ' <<<"$CLEAN")"
fi
[[ "$(grep -n 'CLEANUP-TWO' <<<"$CLEAN" | cut -d: -f1)" -lt "$(grep -n 'CLEANUP-ONE' <<<"$CLEAN" | cut -d: -f1)" ]] \
    || fail "cleanup ran in registration order, not reverse — a teardown that depends on an earlier one having outlived it will break"
grep -q 'FAIL: test exited early (rc=4)' <<<"$CLEAN" \
    || fail "the net did not fire on a test that died AFTER registering cleanup — cleanup must not be able to swallow the verdict"
CLEAN_OK="$(run_fixture cleaned_ok "on_exit 'echo CLEANUP-ON-PASS'
pass 'fine'")"
grep -q 'CLEANUP-ON-PASS' <<<"$CLEAN_OK" \
    || fail "registered cleanup did not run on a PASSING test — sandboxes would leak from every green run"
note "cleanup runs in reverse on both the dying and the passing path, without swallowing the verdict  ✓"

pass "lib.sh's EXIT net fires with a named rc when a test dies silently, stays quiet on pass/skip, prints exactly one FAIL line when the test already gave a verdict, still runs registered cleanup in reverse on every path — and no test in this directory can disarm it by installing an EXIT trap of its own"
