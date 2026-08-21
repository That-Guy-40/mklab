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
       test-probe-boot-script.sh test-bmc-binding-check.sh test-e2e-reaps-sink.sh
       test-e2e-fails-fast.sh test-e2e-manage-idempotent.sh
       test-imgverify-halves.sh test-rollback-driver-pair.sh
       test-apply-reports-and-converges.sh test-apply-selfheal.sh
       test-signing-cert-profile.sh test-rom-xml.sh test-verifying-rom.sh
       test-measured-image.sh
       # test-probe-nic.sh existed on disk for weeks and was in no list, so nothing ran
       # it — a test with no runner is a test nobody runs, and it guards the exact fault
       # this lab keeps rediscovering (a NIC model and a kernel configured in different
       # files by different tools, both individually valid, with no driver between them).
       test-probe-nic.sh
       test-uefi-netboot-dhcp.sh test-dhcp-reservation-identity.sh
       test-fleet-tpm-selection.sh test-tpm-xml.sh
       test-e2e-make-deployable.sh
       test-fleet-firmware-record.sh test-fleet-preflight.sh
       test-chaos-matrix.sh test-harness-net.sh test-describe-ownership.sh
       test-inspect-facts-from-a-stream.sh)

# The comment above records that a test sat on disk for weeks in no list. A comment is
# not a check: it explains a fault to whoever is already reading, which is nobody at the
# moment the next test is added. So the list is compared against the disk, here, and an
# unlisted test is a failure of THIS runner rather than a silence.
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
# Report the count as a RATIO against the list, and refuse a run where they disagree.
#
# The bare "N passed" this used to print was copied into five documents by hand, drifted
# in one of them, and told a reader nothing about coverage anyway: a runner that quietly
# stopped after three tests also prints a clean "3 passed, 0 failed". The number worth
# stating is `ran/listed`, and with the disk-vs-list check above that chains back to the
# files on disk — so the docs can say "every test passes" and be checkable, instead of
# carrying an integer that has to be maintained by hand.
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
exit $rc
