#!/usr/bin/env bash
# Verdict: `apply` self-heals a node its own pre-flight demoted — bounded, recorded,
# and ONLY that kind of error (DEFERRED item 4).
#
# The two roads into `error` are not the same thing. A node that FAILED A DEPLOY has
# an unproven image and waits for a human — apply must not touch it. A node DEMOTED
# BY THE HEALTH RE-CHECK was healthy at activation and died afterwards, which is
# exactly what a reconcile loop exists to repair — so apply retries it, spending a
# bounded budget (MAAS_APPLY_SELFHEAL_MAX, default 2) that only a human `retry`
# resets. The bound is the mask-guard: a node that dies after every heal must END UP
# held, not be absorbed by the loop forever.
#
# SAFETY: mock BMC, mock driver, throwaway registry and spec. Nothing boots.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl python3
maas_env
maas_env_drivers                       # MAAS_DRIVER_DIR=tests/ -> tests/mock.sh
export MOCK_BMC_POWER_DIR="$SANDBOX/power"
make_image v1
make_image v2

SPEC="$SANDBOX/fleet.toml"
cat > "$SPEC" <<TOML
[[node]]
name = "n1"
bmc_port = 6280
driver = "mock"
image = "v1"
TOML

marker()   { [[ -f "$MAAS_STATE/n1/demoted_by_recheck" ]]; }
attempts() { cat "$MAAS_STATE/n1/selfheal_attempts" 2>/dev/null || echo 0; }
demote()   { ( export MOCK_HEALTH_V1=fail; "$MAAS" recheck n1 ) >/dev/null 2>&1 && return 1 || return 0; }

( "$MAAS" apply "$SPEC" ) >/dev/null 2>&1 || fail "seeding: apply could not converge n1"
assert_state n1 active

# ── 1. dry run: plans the heal, writes nothing ──────────────────────────────
out="$( ( export MOCK_HEALTH_V1=fail; "$MAAS" apply "$SPEC" --dry-run ) 2>&1 )"
grep -q 'self-heal 1/2' <<<"$out" \
    || fail "the dry run observed a dead active node but did not plan the self-heal retry (got: ${out//$'\n'/ })"
assert_state n1 active
marker && fail "REGRESSION: apply --dry-run wrote the demoted_by_recheck marker — a plan that mutates is not a plan"
[[ "$(attempts)" == 0 ]] || fail "REGRESSION: apply --dry-run spent a self-heal attempt"
note "dry run plans 'self-heal 1/2' and writes nothing  ✓"

# ── 2. a recheck demotion is healed, visibly, and the attempt is recorded ───
demote || fail "recheck did not demote the unhealthy node"
assert_state n1 error
marker || fail "REGRESSION: recheck demoted n1 but wrote no demoted_by_recheck marker — apply cannot tell this error from a failed deploy, so item 4's distinction is gone"
out="$( ( "$MAAS" apply "$SPEC" ) 2>&1 )" || fail "apply failed while healing a demoted node: ${out//$'\n'/ }"
assert_state n1 active
grep -q 'self-heal 1/2' <<<"$out" \
    || fail "apply healed the node but the table never said 'self-heal 1/2' — the bound must be visible where the operator looks"
[[ "$(attempts)" == 1 ]] \
    || fail "REGRESSION: one self-heal ran but the spent budget reads '$(attempts)' — an uncounted heal is an unbounded heal"
grep -q 'apply self-heal 1/2' "$MAAS_STATE/n1/history.log" \
    || fail "REGRESSION: the self-heal left no line in the node's history — each autonomous attempt must be on the record"
note "a demoted node is healed back to active; attempt 1/2 spent and in the history  ✓"

# ── 3. the second flap heals too; the third is HELD (the mask-guard) ────────
demote || fail "second demote failed"
( "$MAAS" apply "$SPEC" ) >/dev/null 2>&1 || fail "the second self-heal failed"
assert_state n1 active
[[ "$(attempts)" == 2 ]] || fail "second heal did not spend the budget (attempts=$(attempts))"
demote || fail "third demote failed"
out="$( ( "$MAAS" apply "$SPEC" ) 2>&1 )" || fail "apply errored on a budget-spent node (it should hold it, not fail)"
assert_state n1 error
grep -q 'self-heal budget spent' <<<"$out" \
    || fail "REGRESSION: the budget is spent but the table does not say so — a held node with no stated reason reads as a bug, not a decision (got: ${out//$'\n'/ })"
[[ "$(attempts)" == 2 ]] || fail "a HELD node still spent budget (attempts=$(attempts))"
note "flap #3 is HELD with 'self-heal budget spent' — the loop cannot mask a dying node forever  ✓"

# ── 4. a human retry resets the budget ──────────────────────────────────────
( "$MAAS" retry n1 ) >/dev/null 2>&1 || fail "operator retry failed"
marker && fail "operator retry left the demoted_by_recheck marker in place"
[[ "$(attempts)" == 0 ]] \
    || fail "REGRESSION: an operator retry did not reset the self-heal budget — after three flaps the loop would never touch this node again, even once a human has intervened"
( "$MAAS" apply "$SPEC" ) >/dev/null 2>&1 || fail "apply could not re-converge after the operator retry"
assert_state n1 active
note "a human retry resets the budget; apply re-converges  ✓"

# ── 5. the negative control: a FAILED DEPLOY is never self-healed ───────────
cat >> "$SPEC" <<TOML
[[node]]
name = "n2"
bmc_port = 6281
driver = "mock"
image = "v2"
TOML
( export MOCK_HEALTH_V2=fail; "$MAAS" apply "$SPEC" ) >/dev/null 2>&1   # fresh deploy of v2 fails
assert_state n2 error
[[ -f "$MAAS_STATE/n2/demoted_by_recheck" ]] \
    && fail "REGRESSION: a FAILED DEPLOY carries the demoted_by_recheck marker — apply would self-heal an unproven image, which is the exact thing item 4 says a human must look at"
out="$( ( export MOCK_HEALTH_V2=fail; "$MAAS" apply "$SPEC" ) 2>&1 )"
assert_state n2 error
grep -q 'does not touch a failed deploy' <<<"$out" \
    || fail "apply held the failed-deploy node but did not say why (got: ${out//$'\n'/ })"
grep -q 'self-heal.*n2' <<<"$out" \
    && fail "REGRESSION: apply issued a self-heal for n2, whose error came from a FAILED DEPLOY, not a recheck demotion"
note "a failed-deploy error is held for the operator, never self-healed  ✓"

pass "apply self-heals only recheck-demoted nodes — bounded at 2, each attempt in the history and the table, held with a stated reason when the budget is spent, reset only by a human retry; a failed deploy is never touched"
