#!/usr/bin/env bash
# Verdict: the F2 signature gate is REAL and load-bearing. Using genuine OpenSSL
# CMS signatures (the same detached-DER/codeSigning format iPXE imgverify + the
# repo's netboot/sign-payload.sh use), a tampered image FAILS verification and is
# NEVER activated — the node stays on its previous good image (the required
# tamper->rollback drill, mirroring RAM-INFRA §13). No previous -> error.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl
trap 'cleanup_sandboxes' EXIT
maas_env
maas_env_drivers
export MOCK_DEPLOY_LOG="$SANDBOX/deploys.log"; : > "$MOCK_DEPLOY_LOG"

make_image good-v1              # clean, correctly signed
make_image bad-v2 tamper        # signed, then a byte flipped -> signature must fail

VL="$LAB_DIR/drivers/verify-lib.sh"
CA="$MAAS_IMAGES_DIR/trust/ca.crt"

# ── the crypto itself: untampered verifies, tampered does not ────────────────
( "$VL" verify "$MAAS_IMAGES_DIR/good-v1/payload.img" --ca "$CA" ) >/dev/null 2>&1 \
    || fail "REGRESSION: a correctly-signed payload failed verification"
if ( "$VL" verify "$MAAS_IMAGES_DIR/bad-v2/payload.img" --ca "$CA" ) >/dev/null 2>&1; then
    fail "REGRESSION: a TAMPERED payload passed signature verification (F2 broken)"
fi
note "openssl CMS: clean payload verifies, tampered payload fails ✓"

# ── seed a node on the good image ────────────────────────────────────────────
( "$MAAS" enroll node1 --bmc-port 6230 ) >/dev/null 2>&1 || fail "enroll node1"
( "$MAAS" manage node1 )  >/dev/null 2>&1 || fail "manage node1"
( "$MAAS" provide node1 ) >/dev/null 2>&1 || fail "provide node1"
( "$MAAS" deploy node1 --driver mock --image good-v1 ) >/dev/null 2>&1 || fail "deploy good-v1"
assert_state node1 active
[[ "$(_show node1 image)" == good-v1 ]] || fail "node1 should be on good-v1"
note "node1 active on good-v1 ✓"

# ── deploy a TAMPERED image -> verify fails -> rolls back, stays on good-v1 ───
if ( "$MAAS" deploy node1 --driver mock --image bad-v2 ) >/dev/null 2>&1; then
    : # returns 0 because the rollback to good-v1 succeeded
fi
assert_state node1 active
[[ "$(_show node1 image)" == good-v1 ]] \
    || fail "REGRESSION: a tampered image was activated — node should have stayed on good-v1"
# the tampered image must never have been deployed (verify blocks BEFORE deploy)
if grep -q 'node1 bad-v2 current' "$MOCK_DEPLOY_LOG"; then
    fail "REGRESSION: the tampered image was deployed despite failing signature verification"
fi
grep -q 'node1 good-v1 previous' "$MOCK_DEPLOY_LOG" || fail "rollback did not re-deploy the good image"
note "tampered image rejected pre-boot -> node stayed on good-v1 (never deployed) ✓"

# ── a first deploy of a tampered image (no previous) -> error ────────────────
( "$MAAS" enroll node2 --bmc-port 6231 ) >/dev/null 2>&1 || fail "enroll node2"
( "$MAAS" manage node2 )  >/dev/null 2>&1 || fail "manage node2"
( "$MAAS" provide node2 ) >/dev/null 2>&1 || fail "provide node2"
if ( "$MAAS" deploy node2 --driver mock --image bad-v2 ) >/dev/null 2>&1; then
    fail "REGRESSION: a first-deploy tampered image did not error (nothing to roll back to)"
fi
assert_state node2 error
note "tampered first deploy (no previous) -> error ✓"

# ── --no-verify bypasses the gate (documented escape hatch) — proves the gate ─
# was what stopped it: with verify off, the tampered image proceeds to the health
# gate (which passes for bad-v2 by default) and activates.
( "$MAAS" enroll node3 --bmc-port 6232 ) >/dev/null 2>&1 || fail "enroll node3"
( "$MAAS" manage node3 )  >/dev/null 2>&1 || fail "manage node3"
( "$MAAS" provide node3 ) >/dev/null 2>&1 || fail "provide node3"
( "$MAAS" deploy node3 --driver mock --image bad-v2 --no-verify ) >/dev/null 2>&1 \
    || fail "--no-verify should let the tampered image through the (now-skipped) F2 gate"
assert_state node3 active
note "--no-verify bypasses F2 (confirms the gate was the thing that blocked it) ✓"

pass "F2 signature gate is real: tampered image never activated, rolls back to good / errors with no previous"
