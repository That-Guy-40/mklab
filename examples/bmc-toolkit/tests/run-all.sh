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

for t in "${tests[@]}"; do
  printf '\n=== %s ===\n' "$t"
  bash "$TEST_DIR/$t"; rc=$?
  case $rc in 0) ((pass++));; 77) ((skip++));; *) ((fail++));; esac
done
printf '\n==== summary: %d passed, %d skipped, %d failed ====\n' "$pass" "$skip" "$fail"
[[ $fail -eq 0 ]]
