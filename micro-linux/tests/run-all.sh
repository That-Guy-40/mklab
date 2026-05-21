#!/usr/bin/env bash
# Run every test-*.sh in this dir; 77 = skip, 0 = pass, else fail.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

pass=0; fail=0; skip=0
declare -a failed_tests=()

for t in test-*.sh; do
    [[ -x "$t" ]] || chmod +x "$t"
    printf '\n=== %s ===\n' "$t"
    if "./$t"; then
        pass=$((pass+1))
    else
        rc=$?
        if [[ $rc -eq 77 ]]; then
            skip=$((skip+1))
        else
            fail=$((fail+1))
            failed_tests+=("$t")
        fi
    fi
done

printf '\n──────────────────────────\n'
printf 'passed:  %d\n' "$pass"
printf 'skipped: %d\n' "$skip"
printf 'failed:  %d\n' "$fail"
if (( fail > 0 )); then
    printf '\nfailed tests:\n'
    printf '  %s\n' "${failed_tests[@]}"
    exit 1
fi
