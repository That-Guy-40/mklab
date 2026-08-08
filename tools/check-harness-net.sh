#!/usr/bin/env bash
# check-harness-net.sh <tests-dir> — prove one test directory's EXIT-trap safety net.
#
# Verdict: the net that directory's `lib.sh` provides actually fires when a test dies
# without a verdict, stays quiet when one was printed, still runs registered cleanup —
# and cannot be disarmed by a test installing an EXIT trap of its own.
#
# WHY THIS IS ONE SHARED IMPLEMENTATION. Every tests/ directory in this repo carries the
# same net, so a copy per directory is seven places for the same check to drift. Each
# directory ships a five-line `tests/test-harness-net.sh` that execs this with its own
# path, which keeps the check inside that suite's `run-all.sh` (and therefore inside CI)
# without duplicating it.
#
# WHY IT EXISTS AT ALL. The net has been in these libs since the phases were written,
# and on 2026-08-06 it was measured inert across the repo: in metal-as-a-service 23 of
# 36 tests had replaced it with `trap 'cleanup_sandboxes' EXIT` (bash keeps ONE EXIT
# trap per shell), and phases 1-5 and micro-linux had 76 tests with no net at all. None
# of that was visible from any run, because a safety net is only observable when
# something goes wrong — so nothing had ever exercised it. An assertion never seen
# failing is not known to work.
#
# THIS SCRIPT PROVIDES ITS OWN VERDICT HELPERS ON PURPOSE. It must not source the lib it
# is testing: a subject that supplies its own harness can report anything it likes.
set -uo pipefail

_VERDICT=0
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }
_on_exit() {            # the shape this script enforces, applied to itself
    local rc=$?
    rm -rf "${WORK:-}"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: check-harness-net.sh exited early (rc=%d) — no verdict was printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

DIR="${1:-}"
[[ -n "$DIR" && -d "$DIR" ]] || fail "usage: check-harness-net.sh <tests-dir> (got '${DIR:-}')"
DIR="$(cd -- "$DIR" && pwd)"
LIB="$DIR/lib.sh"
[[ -f "$LIB" ]] || fail "no lib.sh in $DIR — there is no shared net to check"
NAME="$(basename "$(dirname "$DIR")")"

WORK="$(mktemp -d)"

# ── 1. no test may install its own EXIT trap ───────────────────────────────
#
# ⚠️ THIS CHECK WAS ANCHORED TO THE START OF A LINE, AND THAT MADE IT A LIAR. Measured
# 2026-08-08: it printed "no test overrides lib.sh's EXIT trap" across six suites while
# **twenty** tests did, because every one of them writes
#
#     tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
#
# — the trap after a semicolon, on a line beginning with an assignment. `^[[:space:]]*trap`
# cannot see that, and the idiom is not exotic: it is the single most common way to open a
# test in this repo. The anchor was chosen to avoid a FALSE POSITIVE (a test that writes a
# trap into a fixture and greps for it, as metal-as-a-service's test-e2e-reaps-sink.sh does)
# and bought it with a false negative twenty times its size. The cheap check answered an
# easier question — "does a line START with trap" — and was read as the real one.
#
# The real property is "is `trap … EXIT` executed as a COMMAND here", so that is what is
# matched: a `trap` at a command position — start of line, or after `; && || | ( ) { }`.
# A `trap` inside quotes is preceded by a quote or a `^`, neither of which is a command
# separator, so the two fixture-writing lines stay unmatched without needing an anchor. Whole
# comment lines are skipped, because prose about the rule is not an installation of one.
mapfile -t OFFENDERS < <(
    awk '
      /^[[:space:]]*#/ { next }
      /(^|[;&|(){}])[[:space:]]*trap[[:space:]]+.*[[:space:]]EXIT([[:space:]]|;|$)/ {
          if (!(FILENAME in seen)) { seen[FILENAME]=1; print FILENAME }
      }
    ' "$DIR"/test-*.sh 2>/dev/null | xargs -r -n1 basename)
(( ${#OFFENDERS[@]} == 0 )) \
    || fail "$NAME: these tests install their own EXIT trap, which REPLACES lib.sh's safety net and leaves them able to die with no verdict line: ${OFFENDERS[*]}. Register cleanup with on_exit '<cmd>' instead"
_all=("$DIR"/test-*.sh)
note "$NAME: no test overrides lib.sh's EXIT trap at any command position, mid-line included (${#_all[@]} files checked)  ✓"

# fixture <name> <body> — a throwaway test that sources the REAL lib.sh, so what is
# exercised is the shipped net and not a copy of it. Prints `rc:<n>` then the output.
fixture() {
    local name="$1" body="$2" rc out
    { printf 'source "%s"\n' "$LIB"; printf '%s\n' "$body"; } > "$WORK/$name.sh"
    out="$(bash "$WORK/$name.sh" 2>&1)"; rc=$?
    printf 'rc:%s\n%s\n' "$rc" "$out"
}

# ── 2. THE POSITIVE CASE: a test that dies without a verdict is reported ──
DIED="$(fixture died 'exit 3')"
grep -q '^rc:3$' <<<"$DIED" \
    || fail "$NAME: the fixture that exits 3 did not exit 3 — a broken harness, not a finding about the net. Note that an EXIT trap which runs a failing command under \`set -e\` can change the status. Got: $(tr '\n' ' ' <<<"$DIED")"
grep -q 'FAIL: test exited early (rc=3)' <<<"$DIED" \
    || fail "REGRESSION: $NAME's net is inert — a test that exited 3 with no verdict printed NO FAIL line, so any test that dies early leaves a blank terminal and a bare rc. Got: $(tr '\n' ' ' <<<"$DIED")"
note "$NAME: a test that dies with no verdict gets one: FAIL: test exited early (rc=3)  ✓"

# ── 3. and it says it exactly once ────────────────────────────────────────
FAILED="$(fixture failed 'fail "the specific defect"')"
grep -q '^rc:1$' <<<"$FAILED" || fail "$NAME: fail() did not exit 1: $(tr '\n' ' ' <<<"$FAILED")"
n="$(grep -c '^FAIL:' <<<"$FAILED")"
[[ "$n" == 1 ]] \
    || fail "REGRESSION: $NAME printed $n FAIL lines for one failure, not 1. The net is firing on top of a verdict that was already given, which is how a reader learns to skip past the line that names the actual defect. Got: $(tr '\n' ' ' <<<"$FAILED")"
grep -q 'FAIL: the specific defect' <<<"$FAILED" \
    || fail "$NAME: the single FAIL line was the net's generic one, not the specific message fail() was given"
note "$NAME: one failure prints exactly one FAIL line, and it is the specific one  ✓"

# ── 4. a pass and a skip stay silent ──────────────────────────────────────
PASSED="$(fixture passed 'pass "it worked"')"
grep -q '^rc:0$' <<<"$PASSED" || fail "$NAME: pass() did not exit 0: $(tr '\n' ' ' <<<"$PASSED")"
grep -q 'FAIL:' <<<"$PASSED" \
    && fail "REGRESSION: $NAME printed a FAIL line on a PASSING test — the net fires on success, which makes every green run look broken"
SKIPPED="$(fixture skipped 'skip "no hardware"')"
grep -q '^rc:77$' <<<"$SKIPPED" || fail "$NAME: skip() did not exit 77: $(tr '\n' ' ' <<<"$SKIPPED")"
grep -q 'FAIL:' <<<"$SKIPPED" \
    && fail "REGRESSION: $NAME printed a FAIL line on a SKIPPED test — a skip would be read as a failure by anything parsing the output"
note "$NAME: a pass exits 0 and a skip exits 77, neither printing a FAIL line  ✓"

# ── 5. registered cleanup runs, in reverse, on every path ─────────────────
# The net is worthless if adopting it lost the teardown. Reverse order matters: a later
# registration may depend on an earlier one still existing.
CLEAN="$(fixture cleaned "
on_exit 'echo CLEANUP-ONE'
on_exit 'echo CLEANUP-TWO'
exit 4")"
if ! grep -q 'CLEANUP-TWO' <<<"$CLEAN" || ! grep -q 'CLEANUP-ONE' <<<"$CLEAN"; then
    fail "$NAME: registered cleanup did not run when the test died (rc=4) — adopting the shared trap lost the teardown: $(tr '\n' ' ' <<<"$CLEAN")"
fi
[[ "$(grep -n 'CLEANUP-TWO' <<<"$CLEAN" | cut -d: -f1)" -lt "$(grep -n 'CLEANUP-ONE' <<<"$CLEAN" | cut -d: -f1)" ]] \
    || fail "$NAME: cleanup ran in registration order, not reverse — a teardown that depends on an earlier one having outlived it will break"
grep -q 'FAIL: test exited early (rc=4)' <<<"$CLEAN" \
    || fail "$NAME: the net did not fire on a test that died AFTER registering cleanup — cleanup must not be able to swallow the verdict"
CLEAN_OK="$(fixture cleaned_ok "on_exit 'echo CLEANUP-ON-PASS'
pass 'fine'")"
grep -q 'CLEANUP-ON-PASS' <<<"$CLEAN_OK" \
    || fail "$NAME: registered cleanup did not run on a PASSING test — scratch dirs would leak from every green run"
note "$NAME: cleanup runs in reverse on both the dying and the passing path, without swallowing the verdict  ✓"

# ── 6. cleanup can see the exit status ────────────────────────────────────
# A teardown that must know whether the run failed — keep the evidence, skip the
# tidy-up — would otherwise have to write its own `trap … EXIT` and take the net down
# with it. micro-cloud's DHCP-exhaustion test is exactly that case: it preserves its log
# directory on failure and removes it on success.
RCSEEN="$(fixture rcseen "on_exit 'echo SAW-RC=\$_EXIT_RC'
exit 5")"
grep -q 'SAW-RC=5' <<<"$RCSEEN" \
    || fail "$NAME: registered cleanup could not read the exit status as \$_EXIT_RC (expected SAW-RC=5). A teardown that needs it is pushed back into installing its own EXIT trap, which is the defect this whole shape removes. Got: $(tr '\n' ' ' <<<"$RCSEEN")"
RCOK="$(fixture rcok "on_exit 'echo SAW-RC=\$_EXIT_RC'
pass 'fine'")"
grep -q 'SAW-RC=0' <<<"$RCOK" \
    || fail "$NAME: \$_EXIT_RC was not 0 on a passing test, so a teardown keyed on it would take the failure path on every green run. Got: $(tr '\n' ' ' <<<"$RCOK")"
note "$NAME: registered cleanup reads the exit status as \$_EXIT_RC (5 on a die, 0 on a pass)  ✓"

pass "$NAME: lib.sh's EXIT net fires with a named rc when a test dies silently, stays quiet on pass/skip, prints exactly one FAIL line when the test already gave a verdict, still runs registered cleanup in reverse on every path — and no test in ${DIR#"$(cd "$DIR/../.." && pwd)/"} can disarm it by installing an EXIT trap of its own"
