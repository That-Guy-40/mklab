#!/usr/bin/env bash
# Verdict: `control-pane watch` drives the install profile from a canned console log to its
# terminal milestone, headless (file input + stdin), and refuses an unknown profile.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CP="$HERE/../control-pane"
LOG="$HERE/fixtures/install-boot.console"

VERDICT=0
pass(){ VERDICT=1; printf 'PASS: %s\n' "$*"; exit 0; }
fail(){ VERDICT=1; printf 'FAIL: %s\n' "$*"; exit 1; }
skip(){ VERDICT=1; printf 'SKIP: %s\n' "$*"; exit 77; }
# shellcheck disable=SC2154  # _rc is assigned inside the trap body
trap '_rc=$?; [[ $VERDICT -eq 0 ]] && printf "FAIL: test exited early (rc=%s)\n" "$_rc"' EXIT

command -v python3 >/dev/null || skip "python3 not found"
[[ -f "$LOG" ]] || fail "missing fixture $LOG"

# 1. file input reaches the terminal milestone, exit 0
out="$("$CP" watch --profile install "$LOG" 2>/dev/null)"; rc=$?
[[ $rc -eq 0 ]] || fail "watch on the install log exited $rc (expected 0): $out"
grep -q "reached 'first boot' (100%)" <<<"$out" || fail "no terminal verdict in: $out"

# 2. stdin input works the same
out2="$("$CP" watch --profile install - < "$LOG" 2>/dev/null)"
grep -q "100%" <<<"$out2" || fail "stdin mode did not reach 100%: $out2"

# 3. an unknown profile is refused, non-zero (never a silent pass)
if "$CP" watch --profile nope "$LOG" >/dev/null 2>&1; then
  fail "REGRESSION: unknown profile 'nope' did not error"
fi

pass "control-pane watch drove install -> 'first boot' (100%) from file + stdin; unknown profile refused"
