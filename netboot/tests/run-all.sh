#!/usr/bin/env bash
# Run every netboot test; autotools exit codes (0 pass / 77 skip / else fail).
#
# All HEADLESS: openssl and a PATH-shimmed docker. The builds these tests reason about
# (a real iPXE compile, an imgverify boot, an A/B rollback) are in MANUAL_TESTING.md —
# they need Docker and QEMU, and nothing here pretends to stand in for them.
#
# This directory had no runner until 2026-08-07, which is why CI never ran its one test:
# the CI loop keys on */tests/lib.sh and there wasn't one.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 2

tests=(test-sign-payload.sh test-sign-payload-lab-ca.sh test-ipxe-pin.sh test-harness-net.sh)

# A test on disk that is in no list is a test nobody runs — one sat unlisted in another
# suite here for weeks. The comment explaining that would only be read by someone already
# looking, so it is a check instead.
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
# A ratio, not a bare count: "3 passed, 0 failed" is also what a runner that stopped
# after three tests prints. ran/listed chains back to the disk check above.
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
