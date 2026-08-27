#!/usr/bin/env bash
# test-every-track-has-a-wrapper.sh — the driver's tracks and this suite's wrappers
# must be the SAME SET, in both directions.
#
# WHY. TODO §14 item 3 settled that ../smoke-openbios.sh stays the single
# implementation and tests/ wraps it one file per track. That shape has an obvious
# failure mode and it is silent: someone adds a track to the driver, does not add a
# wrapper, and run-all.sh keeps printing a healthy ratio over a set that no longer
# covers the driver. "A test with no runner is a test nobody runs" — one sat on disk
# here for weeks — and this is the same fault a level up: a TRACK with no test.
#
# The opposite direction matters too, and differently: a wrapper naming a track the
# driver no longer has fails at run time with the driver's own usage error, which is
# legible but late. Catching it here names it as drift.
#
# THE TRACK LIST IS NOT RE-IMPLEMENTED. arms_of() is sed'd out of
# tools/check-track-list.sh — the same extractor guard A2 uses — because a second
# parser for the same dispatch would drift and then prove something about the copy.
# That is the pattern test-ci-tolerates-a-skipped-suite.sh uses on ci.yml.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DRIVER="$LAB_DIR/smoke-openbios.sh"
CHECKER="$REPO/tools/check-track-list.sh"
[[ -f "$DRIVER" ]]  || fail "smoke-openbios.sh is missing — there are no tracks to wrap"
[[ -f "$CHECKER" ]] || fail "tools/check-track-list.sh is missing — its arms_of() is the shipped track extractor this test borrows"

EXTRACT="$(sed -n '/^arms_of()/,/^}/p' "$CHECKER")"
[[ -n "$EXTRACT" ]] || fail "could not sed arms_of() out of check-track-list.sh — it was renamed or reshaped, and this test would otherwise compare two empty sets and pass"
eval "$EXTRACT"

mapfile -t TRACKS < <(arms_of "$DRIVER")
(( ${#TRACKS[@]} > 0 )) || fail "arms_of() found no tracks in smoke-openbios.sh — an empty set matches an empty set, so this check would pass while asserting nothing"

mapfile -t WRAPPERS < <(cd "$TEST_DIR" && ls test-smoke-*.sh 2>/dev/null | sed 's/^test-smoke-//; s/\.sh$//' | sort)
(( ${#WRAPPERS[@]} > 0 )) || fail "no test-smoke-*.sh wrappers exist, so run-all.sh covers none of the ${#TRACKS[@]} tracks"

missing=(); extra=()
for t in "${TRACKS[@]}"; do
    [[ " ${WRAPPERS[*]} " == *" $t "* ]] || missing+=("$t")
done
for w in "${WRAPPERS[@]}"; do
    [[ " ${TRACKS[*]} " == *" $w "* ]] || extra+=("$w")
done
(( ${#missing[@]} == 0 )) \
    || fail "${#missing[@]} track(s) the driver dispatches on have no tests/test-smoke-<track>.sh, so run-all.sh does not cover them: ${missing[*]}"
(( ${#extra[@]} == 0 )) \
    || fail "${#extra[@]} wrapper(s) name a track the driver no longer has, so run-all.sh would fail on the driver's usage error rather than saying the list drifted: ${extra[*]}"

# Each wrapper must actually DELEGATE. A wrapper that reimplements a track defeats the
# point of item 3 — one place to type a track by hand, one place for it to be wrong —
# and would drift from the driver silently.
notdelegating=()
for t in "${TRACKS[@]}"; do
    f="$TEST_DIR/test-smoke-$t.sh"
    grep -qE "exec .*smoke-openbios\.sh\" $t\$" "$f" || notdelegating+=("$t")
done
(( ${#notdelegating[@]} == 0 )) \
    || fail "${#notdelegating[@]} wrapper(s) do not exec the driver with their own track name, so the driver is no longer the single implementation: ${notdelegating[*]}"

# And run-all.sh must LIST them. Existing on disk is not running: the runner's own
# disk-vs-list check catches an unlisted file, but only when the file is there —
# this catches the reverse reading, that the list is what the ratio is measured
# against, so a wrapper missing from it silently shrinks the denominator.
unlisted=()
for t in "${TRACKS[@]}"; do
    grep -qF "test-smoke-$t.sh" "$TEST_DIR/run-all.sh" || unlisted+=("$t")
done
(( ${#unlisted[@]} == 0 )) \
    || fail "${#unlisted[@]} wrapper(s) exist but are not listed in run-all.sh, so the ratio is measured against a shorter list than the driver has tracks: ${unlisted[*]}"

note "${#TRACKS[@]} tracks, ${#WRAPPERS[@]} wrappers, all listed in run-all.sh and all delegating to the driver"
pass "every track ../smoke-openbios.sh dispatches on has exactly one tests/test-smoke-<track>.sh, each execs the driver rather than reimplementing it, and every one is listed in run-all.sh — the driver stays the single implementation and the suite's ratio is measured against the full set of ${#TRACKS[@]} tracks"
