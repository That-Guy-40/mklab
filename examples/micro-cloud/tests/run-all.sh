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
       test-harness-net.sh)

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
for t in "${tests[@]}"; do
    printf '\n=== %s ===\n' "$t" >&2
    bash "$t"; r=$?
    case $r in
        0)  pass=$((pass+1)) ;;
        77) skip=$((skip+1)) ;;
        *)  failn=$((failn+1)); rc=1 ;;
    esac
done
printf '\n=== summary: %d passed, %d skipped, %d failed ===\n' "$pass" "$skip" "$failn" >&2
(( pass == 0 && failn == 0 )) && printf '%s\n' \
    'NOTE: everything skipped — this suite proves nothing without root. Re-run with sudo.' >&2
exit $rc
