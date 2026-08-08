#!/usr/bin/env bash
# Run every nested-calico-sandbox test; autotools exit codes (0 pass / 77 skip / else fail).
#
# ONE of these is headless and one needs a live sandbox VM, so an all-but-one-SKIP run is
# the normal unprivileged result — read the skip reason rather than the count. The live test
# will not invent a cluster: bring one up with `sandbox.sh up` (~15 min, unprivileged, no
# root) and re-run.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 2

tests=(test-findings-are-bound.sh test-selection-rules.sh
       # G.9's deferred scenario, on the REAL fabric.sh rather than a dummy interface.
       test-fabric-tap-becomes-candidate.sh
       test-harness-net.sh)

# A test on disk that is in no list is a test nobody runs — one sat unlisted in another
# suite here for weeks, so this is a check rather than a comment.
unlisted=()
for f in test-*.sh; do
    [[ " ${tests[*]} " == *" $f "* ]] || unlisted+=("$f")
done
if (( ${#unlisted[@]} )); then
    printf 'FAIL: %d test(s) exist on disk but are in no list, so nothing runs them: %s\n' \
        "${#unlisted[@]}" "${unlisted[*]}" >&2
    exit 1
fi

pass=0 skip=0 failn=0 rc=0
for t in "${tests[@]}"; do
    printf '\n=== %s ===\n' "$t" >&2
    bash "$t"; r=$?
    case $r in
        0)  pass=$((pass+1)) ;;
        77) skip=$((skip+1)) ;;
        *)  failn=$((failn+1)); rc=1 ;;
    esac
done
# A ratio, not a bare count: "2 passed, 0 failed" is also what a runner that stopped after
# two tests prints. ran/listed chains back to the disk check above.
ran=$((pass + skip + failn))
ondisk=(test-*.sh)
printf '\n=== summary: %d/%d listed tests ran (matching the %d test files on disk) — %d passed, %d skipped, %d failed ===\n' \
    "$ran" "${#tests[@]}" "${#ondisk[@]}" "$pass" "$skip" "$failn" >&2
if (( ran != ${#tests[@]} )); then
    printf 'FAIL: %d of %d listed tests never ran — the loop above exited early\n' \
        "$((${#tests[@]} - ran))" "${#tests[@]}" >&2
    exit 1
fi
exit $rc
