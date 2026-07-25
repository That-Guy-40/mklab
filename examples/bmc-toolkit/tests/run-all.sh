#!/usr/bin/env bash
# Run every bmc-toolkit smoke; print one PASS/FAIL/SKIP per test + a summary.
# (autotools codes: 0 pass, 77 skip, else fail.)
set -uo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pass=0 skip=0 fail=0
for t in test-dispatch.sh test-ipmi_sim-sol.sh test-redfish-vmedia.sh test-vbmcd.sh; do
  printf '\n=== %s ===\n' "$t"
  bash "$TEST_DIR/$t"; rc=$?
  case $rc in 0) ((pass++));; 77) ((skip++));; *) ((fail++));; esac
done
printf '\n==== summary: %d passed, %d skipped, %d failed ====\n' "$pass" "$skip" "$fail"
[[ $fail -eq 0 ]]
