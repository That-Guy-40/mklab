#!/usr/bin/env bash
# Verdict: the full Ironic-faithful state machine drives correctly and refuses
# every illegal transition with a specific precondition error — headless, via the
# mock BMC (no libvirt / vbmcd / root). Covers the happy path (enroll -> manage ->
# inspect -> provide -> deploy -> rescue/unrescue -> release -> maintenance) AND
# the unhappy path (verify fails -> error -> retry).
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need python3
trap 'cleanup_sandboxes' EXIT
maas_env

N=node1

# ── enrol ───────────────────────────────────────────────────────────────────
( "$MAAS" enroll "$N" --bmc-port 6230 --domain maas-node1 ) >/dev/null 2>&1 \
    || fail "enroll $N failed"
assert_state "$N" enrolled
note "enroll -> enrolled ✓"

# double-enroll must be refused
if ( "$MAAS" enroll "$N" --bmc-port 6230 ) >/dev/null 2>&1; then
    fail "REGRESSION: double-enroll of '$N' was allowed"
fi
note "double-enroll refused ✓"

# ── illegal transition: deploy before the node is available ──────────────────
if ( "$MAAS" deploy "$N" --driver ramdisk ) >/dev/null 2>&1; then
    fail "REGRESSION: deploy from 'enrolled' allowed (must require 'available')"
fi
note "deploy refused from enrolled ✓"

# ── manage: BMC verify OK -> manageable ──────────────────────────────────────
( "$MAAS" manage "$N" ) >/dev/null 2>&1 || fail "manage $N failed (mock BMC should answer)"
assert_state "$N" manageable
grep -q "^$N power status" "$MOCK_BMC_LOG" \
    || fail "manage did not call the BMC 'power status' (verify step missing)"
note "manage -> manageable, called BMC power status ✓"

# history must record the transient 'verifying' state (the saga is observable)
grep -q 'verifying' "$MAAS_STATE/$N/history.log" \
    || fail "history.log missing the transient 'verifying' state"
note "history records the verifying saga ✓"

# ── inspect (facts injected; real probe = step 2) ────────────────────────────
facts="$SANDBOX/facts.json"
printf '{"cpu":4,"ram_mb":8192,"mac":"52:54:00:aa:bb:01"}\n' > "$facts"
( "$MAAS" inspect "$N" --facts "$facts" ) >/dev/null 2>&1 || fail "inspect $N --facts failed"
assert_state "$N" manageable
grep -q 'ram_mb' "$MAAS_STATE/$N/facts.json" || fail "inspect did not record schedulable facts"
note "inspect -> facts recorded, still manageable ✓"

# ── provide: through cleaning -> available ───────────────────────────────────
( "$MAAS" provide "$N" ) >/dev/null 2>&1 || fail "provide $N failed"
assert_state "$N" available
grep -q 'cleaning' "$MAAS_STATE/$N/history.log" \
    || fail "provide did not pass through 'cleaning'"
note "provide -> available (through cleaning) ✓"

# ── deploy: driver-gated (verify + health), available -> active ──────────────
maas_env_drivers                       # --driver mock -> tests/mock.sh; signed image store
make_image busybox-netboot
if ( "$MAAS" deploy "$N" --driver bogus --image busybox-netboot ) >/dev/null 2>&1; then
    fail "REGRESSION: deploy accepted an unknown driver 'bogus'"
fi
note "deploy refused unknown driver ✓"
if ( "$MAAS" deploy "$N" --driver mock ) >/dev/null 2>&1; then
    fail "REGRESSION: deploy accepted a missing --image"
fi
note "deploy requires --image ✓"
( "$MAAS" deploy "$N" --driver mock --image busybox-netboot ) >/dev/null 2>&1 \
    || fail "deploy $N via mock driver failed (signed image + health=pass should reach active)"
assert_state "$N" active
grep -q 'deploying' "$MAAS_STATE/$N/history.log" || fail "deploy did not pass through 'deploying'"
note "deploy -> active via mock driver (F2 verify + health gate) ✓"

# ── rescue / unrescue ────────────────────────────────────────────────────────
( "$MAAS" rescue "$N" ) >/dev/null 2>&1 || fail "rescue $N failed"
assert_state "$N" rescue
# unrescue is only valid from rescue — prove the inverse guard first
( "$MAAS" unrescue "$N" ) >/dev/null 2>&1 || fail "unrescue $N failed"
assert_state "$N" active
note "rescue <-> unrescue ✓"

# ── release: active -> available (through cleaning), slots forgotten ──────────
( "$MAAS" release "$N" ) >/dev/null 2>&1 || fail "release $N failed"
assert_state "$N" available
[[ -f "$MAAS_STATE/$N/driver" ]] && fail "release did not forget the stale driver slot"
note "release -> available, slots cleared ✓"

# ── maintenance / unmaintenance restores the prior state ─────────────────────
( "$MAAS" maintenance "$N" ) >/dev/null 2>&1 || fail "maintenance $N failed"
assert_state "$N" maintenance
( "$MAAS" unmaintenance "$N" ) >/dev/null 2>&1 || fail "unmaintenance $N failed"
assert_state "$N" available
note "maintenance -> back to available (prior state restored) ✓"

# ── unhappy path: a BMC that never answers sends the node to error ───────────
M=node2
( "$MAAS" enroll "$M" --bmc-port 6231 ) >/dev/null 2>&1 || fail "enroll $M failed"
if MOCK_BMC_FAIL=power "$MAAS" manage "$M" >/dev/null 2>&1; then
    fail "REGRESSION: manage 'succeeded' despite the BMC failing 'power status'"
fi
assert_state "$M" error
note "verify failure -> error ✓"

# retry while the BMC is still down stays in error...
if MOCK_BMC_FAIL=power "$MAAS" retry "$M" >/dev/null 2>&1; then
    fail "REGRESSION: retry 'succeeded' while the BMC was still down"
fi
assert_state "$M" error
# ...and recovers once the BMC answers
( "$MAAS" retry "$M" ) >/dev/null 2>&1 || fail "retry $M failed after BMC recovered"
assert_state "$M" manageable
note "retry: error -> manageable once the BMC answers ✓"

pass "full Ironic state machine: happy path + illegal-transition refusals + error/retry (headless)"
