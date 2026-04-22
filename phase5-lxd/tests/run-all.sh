#!/usr/bin/env bash
# Run every test-*.sh in this directory, tally pass/skip/fail.
# Exit 77 counts as skip (LSB convention).

set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

pass=0 skip=0 fail=0
failed_names=()

for t in test-*.sh; do
    printf '\n=== %s ===\n' "$t"
    if bash "./$t"; then
        pass=$((pass+1))
    else
        rc=$?
        if (( rc == 77 )); then
            skip=$((skip+1))
        else
            fail=$((fail+1))
            failed_names+=("$t")
        fi
    fi
done

printf '\n──────────────────────────\n'
printf 'passed:  %d\n' "$pass"
printf 'skipped: %d\n' "$skip"
printf 'failed:  %d\n' "$fail"
if (( fail > 0 )); then
    printf '\nfailed tests:\n'
    printf '  %s\n' "${failed_names[@]}"
    exit 1
fi
