#!/usr/bin/env bash
# Run every openbios-the-rival-that-shipped test; autotools exit codes
# (0 pass / 77 skip / else fail).
#
# TWO KINDS OF TEST, AND THE DIFFERENCE IS LOAD-BEARING.
#
# The HEADLESS ones read and compare files and run `--help`: no firmware, no QEMU,
# no podman. The TRACK ones are thin wrappers that `exec` ../smoke-openbios.sh, one
# per track, so the driver stays the single implementation (TODO §14, item 3) while
# this runner — and its ran/listed ratio and its by-name skip reporting — covers
# every track rather than only the file-level checkers.
#
# WHY THE TRACKS WERE ORIGINALLY LEFT OUT, and what changed. Every track guards on a
# built artifact and SKIPs without one, so a suite that merely INCLUDED them reported
# a clean green tick on a runner that cannot build — §14 measured exactly that: a
# sweep of SKIPs and a pass. That objection is correct and it is not answered by
# leaving the tracks out; it is answered by refusing to call an all-SKIP sweep a
# result. So the summary reports the two groups SEPARATELY, and a run where no track
# actually executed says so as an UNKNOWN in as many words. Set
# OPENBIOS_REQUIRE_TRACKS=1 — on a machine where the firmware IS built — to turn that
# unknown into a failure.
#
# This runner is also why the lab has a lib.sh: creating one enrolls the directory in
# tools/check-harness-net.sh, and creating this file enrolls it in the ratio checker
# under tools/tests/, which drives it with synthetic pass/fail/skip fixtures and
# asserts what it PRINTS.
#
# THAT CHECKER HARVESTS FIXTURE NAMES BY GREPPING THIS FILE for test file names —
# comments included. Naming another suite's test file here, even in prose, makes it
# build a fixture by that name, which the disk-vs-list check below then rejects as
# unlisted; the checker reports that it could not drive this runner rather than
# quietly weakening its assertion. So the ratio checker is referred to by its
# directory above, not by its filename.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 2

headless=(test-harness-net.sh test-usage-is-data.sh test-patch-scope.sh
          test-track-list.sh test-patch-hygiene.sh test-vsprintf-ub.sh
          test-every-track-has-a-wrapper.sh)

# One per track in ../smoke-openbios.sh. tools/check-track-list.sh guards the names
# themselves; tests/test-every-track-has-a-wrapper.sh guards that this list and the
# driver's dispatch arms are the same set, in both directions.
tracks=(
    test-smoke-amd64.sh
    test-smoke-amd64-ctx.sh
    test-smoke-amd64-fault.sh
    test-smoke-amd64-linux.sh
    test-smoke-amd64-pmem.sh
    test-smoke-cbfs.sh
    test-smoke-cbfs-write.sh
    test-smoke-cbfs-payload.sh
    test-smoke-cbfs-live.sh
    test-smoke-event-log.sh
    test-smoke-event-replay.sh
    test-smoke-event-real.sh
    test-smoke-event-bench.sh
    test-smoke-client-forth.sh
    test-smoke-coreboot.sh
    test-smoke-coreboot-amd64.sh
    test-smoke-diagnostics.sh
    test-smoke-dict-identity.sh
    test-smoke-elf-methods.sh
    test-smoke-file-writer.sh
    test-smoke-flash-writer.sh
    test-smoke-floppy.sh
    test-smoke-mmio-writer.sh
    test-smoke-memory-available.sh
    test-smoke-multiboot.sh
    test-smoke-nvram.sh
    test-smoke-persist.sh
    test-smoke-persist-flash.sh
    test-smoke-persist-os.sh
    test-smoke-persist-os-flash.sh
    test-smoke-pmem-writer.sh
    test-smoke-ppc.sh
    test-smoke-property-abi.sh
    test-smoke-rmw-fields.sh
    test-smoke-struct-array.sh
    test-smoke-struct-device.sh
    test-smoke-struct-layer.sh
    test-smoke-tlv-primitives.sh
    test-smoke-unix.sh
    test-smoke-vga.sh
)

tests=("${headless[@]}" "${tracks[@]}")

# A test that sat on disk in no list, for weeks, is what this check exists for — it
# happened in metal-as-a-service. A comment is not a check: it explains a fault to
# whoever is already reading, which is nobody at the moment the next test is added.
# So the list is compared against the disk, here, and an unlisted test is a failure
# of THIS runner rather than a silence.
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
t_pass=0 t_skip=0 t_fail=0
skipped_names=() failed_names=()
for t in "${tests[@]}"; do
    printf '\n=== %s ===\n' "$t" >&2
    bash "$t"; r=$?
    is_track=0; [[ "$t" == test-smoke-* ]] && is_track=1
    case $r in
        0)  pass=$((pass+1));  (( is_track )) && t_pass=$((t_pass+1)) ;;
        77) skip=$((skip+1));  (( is_track )) && t_skip=$((t_skip+1)); skipped_names+=("$t") ;;
        *)  failn=$((failn+1)); (( is_track )) && t_fail=$((t_fail+1)); failed_names+=("$t"); rc=1 ;;
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
# The tracks get their own line, because they are the half that can be entirely absent
# without the total looking any different.
printf '=== of which boot tracks: %d/%d — %d passed, %d skipped, %d failed ===\n' \
    "$((t_pass + t_skip + t_fail))" "${#tracks[@]}" "$t_pass" "$t_skip" "$t_fail" >&2
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
# AN ALL-SKIP BOOT SWEEP IS AN UNKNOWN, NOT A PASS. Without this line the summary
# above reads as a healthy run on a machine where no firmware was ever built — which
# is the precise shape §14 measured and the reason the tracks were kept out of this
# runner until the distinction was printed.
if (( ${#tracks[@]} > 0 && t_pass == 0 && t_fail == 0 )); then
    printf '\nUNKNOWN: none of the %d boot tracks executed — every one SKIPped, so this run says\n' "${#tracks[@]}" >&2
    printf '         NOTHING about boot behaviour. Build the firmware (../build-openbios.sh all)\n' >&2
    printf '         and rerun, or set OPENBIOS_REQUIRE_TRACKS=1 to make any skip a failure.\n' >&2
elif (( t_skip > 0 )); then
    printf '\nPARTIAL: %d of %d boot tracks SKIPped, so boot coverage is incomplete — see the names above.\n' \
        "$t_skip" "${#tracks[@]}" >&2
fi
# STRICT MODE FAILS ON ANY SKIP, NOT ONLY ON ALL OF THEM, and the difference is not
# pedantry. Measured 2026-08-27 against an empty OPENBIOS_WORKDIR: 21 tracks skipped
# and ONE passed, because the coreboot track reads its ROM from the linuxboot lab
# (COREBOOT_DIR) and is therefore independent of the tree under test. A guard that
# only fires when EVERY track skips is silenced by exactly that — one unrelated pass
# hiding twenty-one unknowns. On a machine where the firmware is built, a skip is a
# track that wanted something the machine lacks, and that is a result nobody has.
if [[ "${OPENBIOS_REQUIRE_TRACKS:-0}" == 1 ]] && (( t_skip > 0 )); then
    printf 'FAIL: OPENBIOS_REQUIRE_TRACKS=1 and %d of %d boot tracks did not run\n' \
        "$t_skip" "${#tracks[@]}" >&2
    exit 1
fi
if (( ran != ${#tests[@]} )); then
    printf 'FAIL: %d of %d listed tests never ran — the loop above exited early, so "%d passed" describes a partial run\n' \
        "$((${#tests[@]} - ran))" "${#tests[@]}" "$pass" >&2
    exit 1
fi
exit $rc
