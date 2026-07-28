#!/usr/bin/env bash
# Verdict: `apply` reconciles the fleet to its declared end-state, is idempotent, and
# does not trust the registry to tell it what is true.
#
# The imperative verbs drive one node by hand. `apply` is the control loop every real
# fleet manager (MAAS, Terraform, Kubernetes) is built on: declare the end state, diff
# it against what is, issue exactly the missing transitions, and be safe to run
# forever. The invariant that makes it a control loop rather than a script is
# IDEMPOTENCE — a second run must do nothing.
#
# The assertion that matters most, though, is the one about trust. `apply` computes
# its actions from the REGISTRY, and the registry-layer chaos scenario proved the
# registry can diverge from the machine. A node recorded `active` whose payload is
# dead would otherwise SATISFY its declared state, and apply would report convergence
# over a fleet that is not serving. So it re-checks health BEFORE diffing — and this
# test proves that pre-flight is load-bearing by running with it disabled.
#
# SAFETY: mock BMC, mock driver, throwaway registry and spec. Nothing boots.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl python3
trap 'cleanup_sandboxes' EXIT
maas_env
maas_env_drivers                       # MAAS_DRIVER_DIR=tests/ -> tests/mock.sh
export MOCK_BMC_POWER_DIR="$SANDBOX/power"
make_image v1
make_image v2

SPEC="$SANDBOX/fleet.toml"
write_spec() {  # write_spec <image-for-n1> <image-for-n2>
    cat > "$SPEC" <<TOML
[defaults]
bmc_user = "admin"
[[node]]
name = "n1"
bmc_port = 6270
driver = "mock"
image = "$1"
[[node]]
name = "n2"
bmc_port = 6271
driver = "mock"
image = "$2"
TOML
}
write_spec v1 v1

applied_count() { sed -nE 's/.*applied: ([0-9]+) transition.*/\1/p' <<<"$1" | tail -1; }

# ── 1. --dry-run plans and changes NOTHING ──────────────────────────────────
out="$( ( "$MAAS" apply "$SPEC" --dry-run ) 2>&1 )" || fail "apply --dry-run failed"
grep -q 'DRY RUN' <<<"$out" || fail "apply --dry-run did not say it was a dry run"
grep -q 'enroll' <<<"$out" || fail "apply --dry-run did not plan to enroll the declared nodes"
[[ ! -d "$MAAS_STATE/n1" ]] \
    || fail "REGRESSION: apply --dry-run ENROLLED a node — a plan that mutates is not a plan, and nobody will trust the next one"
note "--dry-run prints the plan and changes nothing  ✓"

# ── 2. it converges: exactly the missing transitions, in order ──────────────
out="$( ( "$MAAS" apply "$SPEC" ) 2>&1 )" || fail "apply failed to converge the fleet: ${out//$'\n'/ }"
assert_state n1 active
assert_state n2 active
[[ "$(_show n1 image)" == v1 ]] || fail "n1 converged to the wrong image"
n=$(applied_count "$out"); [[ "${n:-0}" -ge 6 ]] \
    || fail "apply reported only ${n:-0} transitions for two nodes going from nothing to active (expected enroll+manage+provide+deploy each)"
note "converges an empty fleet to its declared end state ($n transitions)  ✓"

# ── 3. THE INVARIANT: running it again does nothing ─────────────────────────
out="$( ( "$MAAS" apply "$SPEC" ) 2>&1 )" || fail "the second apply failed"
n=$(applied_count "$out")
[[ "${n:-1}" -eq 0 ]] \
    || fail "REGRESSION: a second apply issued $n transition(s) on an already-converged fleet. Reconciliation means the same command is safe to run forever; one that re-deploys every run would reinstall a healthy fleet on a timer"
grep -q 'converged' <<<"$out" || fail "the second apply did not report the nodes as converged"
note "a second run is a NO-OP — the reconciliation invariant  ✓"

# ── 4. drift is corrected: change the declaration, apply follows ────────────
write_spec v2 v1
out="$( ( "$MAAS" apply "$SPEC" ) 2>&1 )" || fail "apply failed to correct drift"
[[ "$(_show n1 image)" == v2 ]] \
    || fail "REGRESSION: the spec declared v2 for n1 but apply left it on $(_show n1 image) — drift is not being corrected"
[[ "$(_show n2 image)" == v1 ]] \
    || fail "REGRESSION: apply changed n2, whose declaration did not change — it is issuing more than the missing transitions"
note "changing the declaration redeploys ONLY the node that drifted  ✓"

# ── 5. held states are reported, not steamrollered ──────────────────────────
# A node the operator has pulled out (maintenance) or that failed (error) must not be
# quietly re-driven by a loop running on a timer — that is how an operator loses a
# machine they were in the middle of debugging.
( "$MAAS" maintenance n2 ) >/dev/null 2>&1 || fail "maintenance n2"
out="$( ( "$MAAS" apply "$SPEC" ) 2>&1 )" || fail "apply failed with a node in maintenance"
grep -q 'HELD' <<<"$out" || fail "apply did not report the maintenance node as held (got: ${out//$'\n'/ })"
[[ "$("$MAAS" state n2 2>/dev/null)" == maintenance ]] \
    || fail "REGRESSION: apply pulled a node OUT of maintenance. An operator debugging a machine must not have it re-driven by a loop running on a timer"
note "a node in maintenance is reported as held and left alone  ✓"
( "$MAAS" unmaintenance n2 ) >/dev/null 2>&1

# ── 6. it does not trust the registry ───────────────────────────────────────
# n1 says active on v2. Make v2's health fail: the registry is now a lie. apply must
# notice BEFORE it diffs, or it will see the desired state satisfied and converge on
# a dead node.
assert_state n1 active
out="$( ( export MOCK_HEALTH_V2=fail; "$MAAS" apply "$SPEC" ) 2>&1 )" || true
[[ "$("$MAAS" state n1 2>/dev/null)" != active ]] \
    || fail "REGRESSION: apply reported on a node recorded 'active' whose payload fails its health check, and left it active. A reconcile loop that trusts the registry converges on a dead fleet and calls it success"
grep -qi 'health re-check' <<<"$out" \
    || fail "apply demoted the dead node but did not say the pre-flight health re-check was why (got: ${out//$'\n'/ })"
note "a node recorded active but actually dead is demoted BEFORE the diff  ✓"

# ── 7. …and the pre-flight is what does it (the negative control) ───────────
# Without this, §6 would also pass on an apply that demoted the node for some
# unrelated reason.
maas_env; maas_env_drivers; export MOCK_BMC_POWER_DIR="$SANDBOX/power2"
make_image v1
write_spec v1 v1
( "$MAAS" apply "$SPEC" ) >/dev/null 2>&1 || fail "seeding the second fleet failed"
assert_state n1 active
out="$( ( export MOCK_HEALTH_V1=fail; "$MAAS" apply "$SPEC" --no-recheck ) 2>&1 )" || true
[[ "$("$MAAS" state n1 2>/dev/null)" == active ]] \
    || fail "the --no-recheck control did NOT leave the dead node active, so §6 does not prove the pre-flight is what catches it"
grep -qi 'REGISTRY ALONE' <<<"$out" \
    || fail "--no-recheck did not warn that the diff is computed from the registry alone"
note "with --no-recheck it converges on the dead node — so the pre-flight is load-bearing  ✓"

pass "apply reconciles to the declared end state, is idempotent, corrects only what drifted, leaves held nodes alone, and re-checks reality before trusting the registry"
