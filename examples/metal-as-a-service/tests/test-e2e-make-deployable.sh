#!/usr/bin/env bash
# Verdict: the live runners' shared `make_deployable` brings a node to a state
# `deploy` accepts — including the case that cost a full live run: a node stranded
# mid-transition by an interrupted earlier attempt.
#
# THE INCIDENT. On 2026-07-29 a measured run was interrupted while node3 sat at a UEFI
# firmware prompt, leaving the registry saying `deploying`. The next run then rebuilt
# the fleet, rebuilt a 20 MB UKI, staged it, signed it and started the attestation
# sink — and only THEN did the state machine say, correctly:
#
#     maas: cannot 'deploy' node 'node3' from state 'deploying'
#           — needs one of: available active
#
# The control plane was right; the harness asked several minutes too late. Worse, the
# two runners had drifted: run-e2e-image.sh handled `active`/`error`/`manageable`,
# run-e2e-measured.sh handled nothing, and neither handled a transient. Hence one
# shared implementation, and this test.
#
# IT USES THE REAL VERBS. `abort` -> `retry` -> `provide` is the recovery the control
# plane actually offers for a stranded node; a harness that wrote `available` into the
# registry directly would be testing a state the system never produces, and would keep
# passing if that recovery path broke.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need python3
# A die() slipping past the assertions used to exit this file silently with no verdict,
# because its own `trap 'cleanup_sandboxes' EXIT` had replaced lib.sh's net. Cleanup now
# goes through `on_exit`, and lib.sh owns the one EXIT trap.
maas_env

# shellcheck source=../lib/e2e-common.sh
source "$LAB_DIR/lib/e2e-common.sh"
# make_deployable needs these from its caller; the runners provide them.
info() { printf '  · %s\n' "$*" >&2; }
die()  { printf 'DIE: %s\n' "$*" >&2; exit 9; }

N=node1
( "$MAAS" enroll "$N" --bmc-port 6230 --domain maas-node1 ) >/dev/null 2>&1 \
    || fail "enroll $N failed"

state_of() { ( "$MAAS" state "$N" ) 2>/dev/null; }

# ── 1. from `enrolled`, all the way to deployable ───────────────────────────
( make_deployable "$N" ) >/dev/null 2>&1 \
    || fail "make_deployable refused a freshly enrolled node — the runners could never start from a clean fleet"
make_deployable "$N" >/dev/null 2>&1
[[ "$(state_of)" == available ]] \
    || fail "from 'enrolled' the node ended in '$(state_of)', not 'available'"
note "enrolled -> available (manage, provide)  ✓"

# ── 2. THE REGRESSION: a node stranded mid-transition ───────────────────────
# Writing the state file directly is exactly the wreckage an interrupted run leaves
# on disk — it is the INPUT being reproduced, not a shortcut around the state machine.
# Everything that repairs it below goes through the real verbs.
for stuck in deploying cleaning; do
    printf '%s' "$stuck" > "$MAAS_STATE/$N/state"
    [[ "$(state_of)" == "$stuck" ]] || fail "could not stage the '$stuck' state for the test"

    # Confirm the premise: deploy really is refused from here, or §2 proves nothing.
    if ( "$MAAS" deploy "$N" --driver ramdisk --image micro-linux-x86_64 ) >/dev/null 2>&1; then
        fail "deploy was ACCEPTED from '$stuck' — the premise of this test is wrong and the incident it guards could not happen"
    fi

    # Capture rather than discard: the helper's refusal is the evidence when this
    # assertion fires, and swallowing it leaves the reader with a bare state name.
    rec="$( ( make_deployable "$N" ) 2>&1 )"
    [[ "$(state_of)" == available ]] \
        || fail "REGRESSION: a node stranded in '$stuck' (what an interrupted run leaves behind) came out as '$(state_of)', not 'available'. The next live run would rebuild the fleet, rebuild the image, stage, sign and start the sink before the state machine refused the deploy — which is exactly the 2026-07-29 incident. Helper said: ${rec:-<nothing>}"
    grep -q 'abort' "$MAAS_STATE/$N/history.log" \
        || fail "the recovery did not go through the real 'abort' verb — the harness must use the control plane's own recovery path, not write the registry"
done
note "stranded in a transient state -> recovered via abort/retry/provide -> available  ✓"

# ── 3. from `error` and from `active` ───────────────────────────────────────
printf 'error' > "$MAAS_STATE/$N/state"
make_deployable "$N" >/dev/null 2>&1
[[ "$(state_of)" == available ]] || fail "a node in 'error' came out as '$(state_of)', not 'available'"
printf 'active' > "$MAAS_STATE/$N/state"
make_deployable "$N" >/dev/null 2>&1
[[ "$(state_of)" =~ ^(available|active)$ ]] \
    || fail "a node in 'active' came out as '$(state_of)'; deploy accepts available or active"
note "error -> available, and active is left deployable  ✓"

# ── 4. it REFUSES what it cannot fix, rather than proceeding ────────────────
# The negative control for §2/§3: if the helper simply returned 0 regardless, every
# assertion above would still pass. Here the state is one no verb recovers, so the
# runner must stop with the node named — not start a destructive lay-down.
printf 'wedged-by-hand' > "$MAAS_STATE/$N/state"
out="$( ( make_deployable "$N" ) 2>&1 )"; rc=$?
[[ $rc -ne 0 ]] \
    || fail "REGRESSION: make_deployable ACCEPTED the unrecoverable state 'wedged-by-hand' (rc=0). It would hand a wedged node to a destructive deploy, and §2/§3 would pass even if the helper did nothing at all"
grep -q "$N" <<<"$out" || fail "the refusal does not name the node: $out"
grep -qi 'abort\|recover' <<<"$out" \
    || fail "the refusal does not name a recovery verb, which is the one thing the operator needs: $out"
note "refuses a state no verb recovers, naming the node and the recovery  ✓"

pass "make_deployable brings a node to a deployable state from enrolled, error and active, recovers one stranded mid-transition by an interrupted run through the control plane's own abort/retry/provide, and refuses — naming the node and the recovery — a state no verb can fix"
