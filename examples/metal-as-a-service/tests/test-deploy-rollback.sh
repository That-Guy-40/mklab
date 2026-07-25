#!/usr/bin/env bash
# Verdict: deploy is health-gated with A/B rollback (§4b). A node only reaches
# `active` when the image passes its health gate; a failing NEW image rolls the
# node back to its PREVIOUS good image (degraded-but-up) instead of bricking; both
# slots bad -> error; no previous -> error. Headless via the mock driver (real
# openssl verify on signed images; health injected by MOCK_HEALTH_<image>).
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl
trap 'cleanup_sandboxes' EXIT
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

# ── an unimplemented driver is refused with an honest 'build step N' message ─
prep node1b 6233
msg="$( ( "$MAAS" deploy node1b --driver ramdisk --image v1 ) 2>&1 || true )"
grep -q 'build step 4' <<<"$msg" || fail "ramdisk driver should be refused as 'build step 4', got: $msg"
assert_state node1b available   # refused before deploying — stays schedulable
note "unimplemented 'ramdisk' driver refused honestly (build step 4) ✓"

pass "deploy is health-gated with A/B rollback: healthy->active, fail->previous(degraded), both-bad->error, no-prev->error"
