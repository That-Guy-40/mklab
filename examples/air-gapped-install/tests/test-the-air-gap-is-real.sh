#!/usr/bin/env bash
# test-the-air-gap-is-real.sh — the negative control on the harness itself: run the SAME
# control rows with the namespace taken away, and require the run to refuse.
#
# WHY THIS FILE EXISTS, and it is the most important test here. Everything else in this
# lab is a claim about an install that had nowhere to go. That claim rests entirely on one
# thing — `unshare -rn` really removing the route — and a green suite cannot tell the
# difference between "isolated" and "never checked". A run with full internet access would
# print the identical PASS.
#
# It has already been wrong once, which is why the check is shaped this way. The first
# draft proved isolation by pointing debootstrap at deb.debian.org and watching it fail.
# Run outside the namespace on 2026-08-30 that row still printed "failed as required",
# because a non-root debootstrap refuses before it opens a socket. The row was reporting
# the wrong refusal in exactly the scenario it existed to catch. `airgap.sh` now asks curl
# directly, whose network-class exit codes are the answer, and stops the run rather than
# grading anything against an unknown.
#
# So: break the subject and watch the assertion bite. `__inside` is the half that runs
# inside the namespace; invoked on its own it is the same code with host networking.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
set +e

DRIVER="$LAB_DIR/airgap.sh"
[[ -x "$DRIVER" ]] || fail "missing the lab driver: $DRIVER"
require_cmd curl python3

# Captured, not piped — see the note in test-airgap-install.sh. Piping status into
# `grep -q` SIGPIPEs it, and under pipefail that reads as "no mirror", which skipped THIS
# test (the one that keeps the whole lab honest) while the mirror was sitting on disk.
status_out="$("$DRIVER" status 2>/dev/null)"
if ! grep -q '^mirror  *built for' <<<"$status_out"; then
    skip "no mirror built yet — run 'airgap.sh mirror' (test-airgap-install.sh builds one). Without it the run below would stop on the missing mirror rather than on the missing air gap, which is a different question"
fi

paths_out="$("$DRIVER" paths)"
port="$(awk '/^url/ {print $2}' <<<"$paths_out" | sed 's/.*://')"
if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${port}[[:space:]]"; then
    skip "host port $port is already in use, so the un-namespaced run below could not bind its mirror server and would fail for that reason instead of the one under test"
fi

out="$("$DRIVER" __inside controls 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /' >&2

(( rc != 0 )) \
    || fail "REGRESSION: the control rows PASSED with no network namespace at all. Every 'air-gapped install' verdict in this lab is then unfounded — the install would have had a route to upstream the whole time"

# Two honest outcomes, and which one fired depends on whether THIS machine has upstream
# access. Both are refusals; neither is a clean pass. Naming them separately is the point
# — "it exited non-zero" would also be satisfied by the driver being missing.
if grep -q 'THE AIR GAP IS OPEN' <<<"$out"; then
    note "the designed catch fired: upstream answered, and the run refused to print a result that would be read as an offline install"
elif grep -q 'control rows behaved wrongly' <<<"$out"; then
    note "this machine has no upstream access either, so C0 could not distinguish the two; the graded rows still refused to report a clean pass"
else
    fail "the un-namespaced run failed (rc=$rc), but for none of the reasons this test can account for — it must either name the open air gap or grade a row wrongly, and it did neither. The output is above"
fi

grep -q '5 rows behaved' <<<"$out" \
    && fail "REGRESSION: the summary line claimed all five rows behaved in a run with no namespace — the summary is what the test suite and every reader trusts, so a false one here is worse than a crash"

pass "with the network namespace removed, the same control rows refuse to produce a verdict — so this lab's air-gapped install results are attached to the isolation and not merely printed alongside it"
