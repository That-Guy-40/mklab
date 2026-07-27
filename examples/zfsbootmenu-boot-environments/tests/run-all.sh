#!/usr/bin/env bash
# Run every test-*.sh here; bucket by exit code (0 pass / 77 skip / else fail).
# Mirrors phase2-qemu-vm/tests/run-all.sh.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

passed=0; skipped=0; failed=0; failed_tests=()
for t in test-*.sh; do
    [[ -e "$t" ]] || continue
    [[ -x "$t" ]] || chmod +x "$t"
    "./$t"; rc=$?
    case "$rc" in
        0)  passed=$((passed+1)) ;;
        77) skipped=$((skipped+1)) ;;
        *)  failed=$((failed+1)); failed_tests+=("$t") ;;
    esac
done

printf '\n== %d passed, %d skipped, %d failed ==\n' "$passed" "$skipped" "$failed"
if (( failed > 0 )); then
    printf 'FAILED: %s\n' "${failed_tests[*]}"
    exit 1
fi
exit 0
