#!/usr/bin/env bash
# Run every openbios-the-rival-that-shipped test; autotools exit codes
# (0 pass / 77 skip / else fail).
#
# ALL FIVE ARE HEADLESS BY CONSTRUCTION — they read and compare files and run `--help`.
# None builds a firmware, boots QEMU, or needs podman. That is deliberate: every track in
# ../smoke-openbios.sh guards on a built artifact and SKIPs without one, so a suite that
# included them would report a clean green tick on a runner that cannot build (TODO §14
# measured exactly that: 15 SKIPs and a pass). The boot-level checks are Tier B and are
# not run from here.
#
# This runner is also why the lab now has a lib.sh: creating one enrolls the directory in
# tools/check-harness-net.sh, and creating this file enrolls it in the ratio checker under
# tools/tests/, which drives it with synthetic pass/fail/skip fixtures and asserts what it
# PRINTS.
#
# THAT CHECKER HARVESTS FIXTURE NAMES BY GREPPING THIS FILE for `test-*.sh` — comments
# included. Naming another suite's test file here, even in prose, makes it build a fixture
# by that name, which the disk-vs-list check below then rejects as unlisted; the checker
# reports that it could not drive this runner rather than quietly weakening its assertion.
# So the ratio checker is referred to by its directory above, not by its filename.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 2

tests=(test-harness-net.sh test-usage-is-data.sh test-patch-scope.sh
       test-track-list.sh test-patch-hygiene.sh)


# A test that sat on disk in no list, for weeks, is what this check exists for — it
# happened in metal-as-a-service. A comment is not a check: it explains a fault to whoever
# is already reading, which is nobody at the moment the next test is added. So the list is compared against the disk, here, and an
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
