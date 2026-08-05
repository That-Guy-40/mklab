#!/usr/bin/env bash
# Run every micro-cloud test; autotools exit codes (0 pass / 77 skip / else fail).
#
# UNLIKE the sibling labs' suites, these are NOT all headless. The fabric is the thing
# under test and it is real host networking beside a live microk8s/Calico, so
# test-fabric-round-trip.sh needs root and SKIPs without it. That is why an all-SKIP run
# here is the normal unprivileged result and not a green light: read the skip reasons.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 2

tests=(test-fabric-round-trip.sh)

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
