#!/usr/bin/env bash
# Run every metal-as-a-service test; autotools exit codes (0 pass / 77 skip / else fail).
# All tests are HEADLESS (mock BMC, throwaway state dir) — no libvirt/vbmcd/root.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 2

tests=(test-state-machine.sh test-cleaning-guard.sh test-registry.sh
       test-inspect-metadata.sh test-watch.sh test-probe-build.sh
       test-deploy-rollback.sh test-verify-tamper.sh test-install-driver.sh
       test-ramdisk-driver.sh test-image-driver.sh test-image-measured-driver.sh
       test-apply-reconcile.sh test-region-and-scheduler.sh
       test-chaos-matrix.sh)
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
exit $rc
