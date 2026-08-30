#!/usr/bin/env bash
# Run every test-*.sh here; bucket by exit code (0 pass / 77 skip / else fail).
# Mirrors phase2-qemu-vm/tests/run-all.sh (copied, not rewritten).
#
# WHY THIS DIRECTORY GOT A RUNNER LAST, AND WHY IT NEEDED ONE (TODO 15.8).
# ci.yml named the meta-checkers ONE `run:` STEP AT A TIME — a hand-maintained
# INCLUSION LIST, which is the exact shape §11.3b inverted everywhere else in
# this repo. Measured 2026-08-30: **8 of the 19 files here were named by no CI
# step at all**, including the checker that guards every document's commands
# (test-doc-verbs.sh) and the one that guards every ASCII tree
# (test-tree-diagrams.sh). All eight pass headless in about a minute, so none
# was "deliberately manual" — they were forgotten, which is precisely the point:
# from outside, deliberate and forgotten look identical.
#
# Discovery, not a list, so a checker added tomorrow is run by this without
# anyone remembering to say so. tools/tests/test-run-all-reports-a-ratio.sh
# drives this runner like every other one, against synthetic tests.
#
# NO lib.sh HERE, DELIBERATELY, and that is not the same question as a runner.
# Several of these files test lib.sh-shaped things; one that SOURCED the shared
# harness would be supplying its own subject, which is why each carries its own
# verdict helpers and why .harness-net-exempt exempts this directory from the
# EXIT-net loop. A runner buckets exit codes and needs no harness at all.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

# ── discover ONCE, so "how many ran" has something to be a ratio against ────────────────
shopt -s nullglob
tests=(test-*.sh)
shopt -u nullglob
if (( ${#tests[@]} == 0 )); then
    printf 'FAIL: no test-*.sh found in %s — a runner that discovers nothing still prints a clean "0 passed, 0 failed"\n' "$PWD" >&2
    exit 1
fi

pass=0 skip=0 fail=0
skipped_names=() failed_names=()
for t in "${tests[@]}"; do
    printf '\n=== %s ===\n' "$t"
    bash "$t"; r=$?
    case "$r" in
        0)  pass=$((pass+1)) ;;
        77) skip=$((skip+1)); skipped_names+=("$t") ;;
        *)  fail=$((fail+1)); failed_names+=("$t") ;;
    esac
done

# ── a RATIO, and the NAMES of everything that did not run ───────────────────────────────
#
# A bare "N passed" says nothing about coverage: a runner that quietly stopped after three
# tests also prints a clean "3 passed, 0 failed". And a SKIP is invisible in a count — on
# 2026-08-15 two mount-guard tests skipped here (a transient `unshare -rm` failure that was
# never reproduced) and the suite still looked healthy, so nothing distinguished that run
# from one where both safety guards actually ran. An unmet precondition is an UNKNOWN, not
# a pass, and it has to be legible as one.
#
# So: the ratio chains ran -> discovered -> files on disk, and the skipped tests are named.
# The reason for each skip is already on its own SKIP line above; naming the files here is
# what lets a reader notice that a guard they expected to run did not.
ran=$((pass + skip + fail))
shopt -s nullglob; ondisk=(test-*.sh); shopt -u nullglob
printf '\n──────────────────────────\n'
printf 'summary: %d/%d discovered tests ran (%d test files on disk) — %d passed, %d skipped, %d failed\n' \
    "$ran" "${#tests[@]}" "${#ondisk[@]}" "$pass" "$skip" "$fail"
if (( skip > 0 )); then
    printf '\nskipped — these did NOT run (see each SKIP line above for why):\n'
    printf '  %s\n' "${skipped_names[@]}"
fi
if (( fail > 0 )); then
    printf '\nfailed:\n'
    printf '  %s\n' "${failed_names[@]}"
fi
if (( ${#ondisk[@]} != ${#tests[@]} )); then
    printf 'FAIL: %d test files are on disk but %d were discovered at start — a test created or removed one mid-run\n' \
        "${#ondisk[@]}" "${#tests[@]}" >&2
    exit 1
fi
if (( ran != ${#tests[@]} )); then
    printf 'FAIL: %d of %d discovered tests never ran — the loop exited early, so the summary above describes a partial run\n' \
        "$(( ${#tests[@]} - ran ))" "${#tests[@]}" >&2
    exit 1
fi
(( fail == 0 )) || exit 1
exit 0
