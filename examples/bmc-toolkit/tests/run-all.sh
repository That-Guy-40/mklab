#!/usr/bin/env bash
# Run every bmc-toolkit smoke; print one PASS/FAIL/SKIP per test + a summary.
# (autotools codes: 0 pass, 77 skip, else fail.)
set -uo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pass=0 skip=0 fail=0
tests=(test-dispatch.sh test-ipmi_sim-sol.sh test-redfish-vmedia.sh test-vbmcd.sh
       test-harness-net.sh)

# The list is compared against the disk: a test with no runner is a test nobody runs,
# and a comment saying so does not fail a build (metal-as-a-service kept one for weeks).
unlisted=()
for f in "$TEST_DIR"/test-*.sh; do
    f="$(basename "$f")"
    [[ " ${tests[*]} " == *" $f "* ]] || unlisted+=("$f")
done
if (( ${#unlisted[@]} )); then
    printf 'FAIL: %d test(s) exist on disk but are in no list, so nothing runs them: %s\n' \
        "${#unlisted[@]}" "${unlisted[*]}" >&2
    exit 1
fi

skipped_names=() failed_names=()
for t in "${tests[@]}"; do
  printf '\n=== %s ===\n' "$t"
  bash "$TEST_DIR/$t"; rc=$?
  case $rc in
    0)  ((pass++)) ;;
    77) ((skip++)); skipped_names+=("$t") ;;
    *)  ((fail++)); failed_names+=("$t") ;;
  esac
done

# A RATIO, and the NAMES of anything that did not run.  The bare "N passed, N skipped"
# this used to print said nothing about coverage — a loop that exited early prints a clean
# one too — and a SKIP is invisible in a count.  On 2026-08-15 two mount-guard tests
# skipped in phase 1 and that suite still looked healthy; nothing distinguished it from a
# run where both guards executed.  The disk-vs-list check above already chains list → disk,
# so stating ran/listed here makes the whole chain checkable.
ran=$((pass + skip + fail))
ondisk=("$TEST_DIR"/test-*.sh)
printf '\n==== summary: %d/%d listed tests ran (matching the %d test files on disk) — %d passed, %d skipped, %d failed ====\n' \
    "$ran" "${#tests[@]}" "${#ondisk[@]}" "$pass" "$skip" "$fail"
if (( skip > 0 )); then
    printf '\nskipped — these did NOT run (see each SKIP line above for why):\n'
    printf '  %s\n' "${skipped_names[@]}"
fi
if (( fail > 0 )); then
    printf '\nfailed:\n'
    printf '  %s\n' "${failed_names[@]}"
fi
if (( ran != ${#tests[@]} )); then
    printf 'FAIL: %d of %d listed tests never ran — the loop exited early, so the summary above describes a partial run\n' \
        "$(( ${#tests[@]} - ran ))" "${#tests[@]}" >&2
    exit 1
fi
[[ $fail -eq 0 ]]
