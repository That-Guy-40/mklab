#!/usr/bin/env bash
# Verdict: deploy is health-gated with A/B rollback (§4b). A node only reaches
# `active` when the image passes its health gate; a failing NEW image rolls the
# node back to its PREVIOUS good image (degraded-but-up) instead of bricking; both
# slots bad -> error; no previous -> error. Headless via the mock driver (real
# openssl verify on signed images; health injected by MOCK_HEALTH_<image>).
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl
maas_env
maas_env_drivers
export MOCK_DEPLOY_LOG="$SANDBOX/deploys.log"; : > "$MOCK_DEPLOY_LOG"
make_image v1
make_image v2

prep() {  # enrol + manage + provide a node to `available`
    ( "$MAAS" enroll "$1" --bmc-port "$2" ) >/dev/null 2>&1 || fail "enroll $1"
    ( "$MAAS" manage "$1" )  >/dev/null 2>&1 || fail "manage $1"
    ( "$MAAS" provide "$1" ) >/dev/null 2>&1 || fail "provide $1"
}

# ── happy path: a healthy signed image reaches active ────────────────────────
prep node1 6230
( "$MAAS" deploy node1 --driver mock --image v1 ) >/dev/null 2>&1 || fail "deploy v1 (health=pass) should reach active"
assert_state node1 active
[[ "$(_show node1 image)" == v1 ]] || fail "current image should be v1"
note "healthy image -> active (current=v1) ✓"

# ── A/B rollback: a NEW image that fails health falls back to the previous ────
# v2 health fails; v1 (previous) is healthy -> node stays up on v1, degraded.
if MOCK_HEALTH_V2=fail "$MAAS" deploy node1 --driver mock --image v2 >/dev/null 2>&1; then
    : # deploy returns 0 because the rollback SUCCEEDED (node is up on v1)
fi
assert_state node1 active
got="$(_show node1 image)"
[[ "$got" == v1 ]] || fail "REGRESSION: after v2 failed health, node should be back on v1, got '$got'"
# the driver actually re-deployed v1 during rollback (the 'previous' slot)
grep -q 'node1 v2 current'  "$MOCK_DEPLOY_LOG" || fail "v2 was never attempted"
grep -q 'node1 v1 previous' "$MOCK_DEPLOY_LOG" || fail "rollback did not re-deploy v1 into the previous slot"
note "v2 fails health -> rolled back to v1 (active, degraded) ✓"

# ── both slots bad -> error ──────────────────────────────────────────────────
prep node2 6231
( "$MAAS" deploy node2 --driver mock --image v1 ) >/dev/null 2>&1 || fail "seed node2 on v1"
if MOCK_HEALTH_V2=fail MOCK_HEALTH_V1=fail "$MAAS" deploy node2 --driver mock --image v2 >/dev/null 2>&1; then
    fail "REGRESSION: deploy 'succeeded' when BOTH the new and previous images failed health"
fi
assert_state node2 error
note "both images fail health -> node error ✓"

# ── health fail with NO previous image -> error (nothing to fall back to) ─────
prep node3 6232
if MOCK_HEALTH_V2=fail "$MAAS" deploy node3 --driver mock --image v2 >/dev/null 2>&1; then
    fail "REGRESSION: a first deploy that fails health did not error (no previous existed)"
fi
assert_state node3 error
note "health fail + no previous -> error ✓"

# ── an UNKNOWN driver is refused with an honest, NAMED message ───────────────
# This assertion used to require the words "fast-follow", because `image+measured`
# was a roadmap entry and its refusal said so. That driver has since been built —
# and this test went on demanding the not-yet message, which is how a test stops
# describing the system and starts pinning a stale claim in place. (The obsolete
# expectation outlived the truth by weeks and was only noticed when the real
# `image+measured` deploy was refused ON THE METAL, 2026-07-29.)
#
# What is durable is the BEHAVIOUR: a driver that does not exist must be refused
# clearly, by name, listing what does exist — never generically, and never by
# quietly deploying something else.
prep node1b 6233
msg="$( ( "$MAAS" deploy node1b --driver no-such-driver --image v1 ) 2>&1 || true )"
grep -q "no-such-driver" <<<"$msg" \
    || fail "an unknown driver was refused without naming it, got: $msg"
grep -qi 'available' <<<"$msg" \
    || fail "the refusal does not list the drivers that DO exist, which is the one thing the operator needs: $msg"
assert_state node1b available
grep -qi 'fast-follow\|not yet implemented' <<<"$msg" \
    && fail "REGRESSION: an unknown driver is being reported as a not-yet-implemented roadmap item. That message was written for image+measured, which now exists; repeating it for any unknown name tells the operator to wait for something that is already here (or was never planned)"
assert_state node1b available   # refused before deploying — stays schedulable
note "an unknown driver is refused by name, listing the ones that exist ✓"

# ── a failed deploy must record WHY, not inherit an older incident's reason ──
# Live 2026-07-29: node3 sat in `error` from a refused measured deploy while `show`
# reported "interrupted live run (recovered by run-e2e-measured.sh)" — the text of an
# abort half an hour earlier. error_reason was written by maintenance, abort and
# recheck, and never by deploy, so the field described whichever incident last
# happened to write it. A stale reason is worse than none: it sends the operator to
# the wrong incident with full confidence.
prep node1c 6234
printf 'STALE-REASON-FROM-AN-EARLIER-INCIDENT' > "$MAAS_STATE/node1c/error_reason"
( "$MAAS" deploy node1c --driver mock --image bad ) >/dev/null 2>&1
assert_state node1c error
reason="$(cat "$MAAS_STATE/node1c/error_reason" 2>/dev/null)"
grep -q 'STALE-REASON-FROM-AN-EARLIER-INCIDENT' <<<"$reason" \
    && fail "REGRESSION: a failed deploy left an EARLIER incident's error_reason in place: '$reason'. The operator is told the node failed for a reason that belongs to a different event"
grep -q 'bad' <<<"$reason" \
    || fail "the recorded reason does not name the image that failed: '$reason'"
note "a failed deploy records its own reason, overwriting an earlier incident's ✓"

pass "deploy is health-gated with A/B rollback: healthy->active, fail->previous(degraded), both-bad->error, no-prev->error"
