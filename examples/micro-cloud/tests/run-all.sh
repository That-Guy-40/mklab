#!/usr/bin/env bash
# Run every micro-cloud test; autotools exit codes (0 pass / 77 skip / else fail).
#
# UNLIKE the sibling labs' suites, these are NOT all headless. The fabric is the thing
# under test and it is real host networking beside a live microk8s/Calico, so
# test-fabric-round-trip.sh needs root and SKIPs without it. That is why an all-SKIP run
# here is the normal unprivileged result and not a green light: read the skip reasons.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 2

tests=(test-fabric-mac-derivation.sh test-bench-boot.sh test-fabric-round-trip.sh test-dhcp-exhaustion.sh test-two-engines-one-fabric.sh test-edge-on-the-fabric.sh
       test-harness-net.sh test-retap-recovers-a-root-owned-tap.sh
       # Slice 5c. The only boot test here that needs NO root and NO fabric — which is its
       # thesis, not a convenience: vsock is the first channel that is not the fabric.
       test-vsock-both-engines.sh
       # 5c's break pass: a chaos matrix over the layers vsock can lose. Also unprivileged.
       test-vsock-chaos.sh)

# The list is compared against the disk: a test with no runner is a test nobody runs,
# and a comment saying so does not fail a build (metal-as-a-service kept one for weeks).
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
skipped_names=() failed_names=()
for t in "${tests[@]}"; do
    printf '\n=== %s ===\n' "$t" >&2
    bash "$t"; r=$?
    case $r in
        0)  pass=$((pass+1)) ;;
        77) skip=$((skip+1)); skipped_names+=("$t") ;;
        *)  failn=$((failn+1)); failed_names+=("$t"); rc=1 ;;
    esac
done
# A RATIO, not a bare count. "4 passed, 5 skipped" is also what a runner that quietly
# stopped after nine of twenty tests prints; ran/listed chains back to the disk check above,
# so a doc can say "every listed test ran" and stay true as tests are added.
ran=$((pass + skip + failn))
ondisk=(test-*.sh)
printf '\n=== summary: %d/%d listed tests ran (matching the %d test files on disk) — %d passed, %d skipped, %d failed ===\n' \
    "$ran" "${#tests[@]}" "${#ondisk[@]}" "$pass" "$skip" "$failn" >&2
# …and NAME them. A count cannot say WHICH guard did not run: on 2026-08-15 two mount-guard
# tests skipped in phase 1 (a transient `unshare -rm` failure, never reproduced) and that
# suite still printed a healthy-looking summary. The reason for each skip is already on its
# own SKIP line above; naming the files here is what lets a reader notice that a guard they
# expected to run did not.
if (( skip > 0 )); then
    printf '\nskipped — these did NOT run (see each SKIP line above for why):\n' >&2
    printf '  %s\n' "${skipped_names[@]}" >&2
fi
if (( failn > 0 )); then
    printf '\nfailed:\n' >&2
    printf '  %s\n' "${failed_names[@]}" >&2
fi
if (( ran != ${#tests[@]} )); then
    printf 'FAIL: %d of %d listed tests never ran — the loop above exited early, so "%d passed" describes a partial run\n' \
        "$((${#tests[@]} - ran))" "${#tests[@]}" "$pass" >&2
    exit 1
fi
(( pass == 0 && failn == 0 )) && printf '%s\n' \
    'NOTE: everything skipped — this suite proves nothing without root. Re-run with sudo.' >&2
exit $rc
