#!/usr/bin/env bash
# Verdict: a RAM node must JOIN its region to count as active, and `apply` can schedule
# by inspected facts instead of by name.
#
# Two fast-follows, one test, because they are the same idea from two ends: stop
# addressing machines individually.
#
#   REGION WIRING   `deploy --region R` is not satisfied by "the service answered".
#                   A RAM node that is up but never announced is the nastiest shape
#                   there is — it passes every local check while the region routes
#                   nothing to it, and every dashboard says healthy.
#   SCHEDULER       a [[claim]] declares WHAT is wanted ("2 nodes, >=2 cpus, >=2G")
#                   and apply picks nodes whose INSPECTED facts satisfy it. A node
#                   nobody inspected has no facts and is therefore not schedulable —
#                   which is correct: scheduling onto hardware you have never looked
#                   at is how you get surprises.
#
# SAFETY: mock BMC, fixture catalog, throwaway registry. Nothing boots.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl
maas_env
maas_env_drivers
export MAAS_DRIVER_DIR="$LAB_DIR/drivers"
export MAAS_POLL_INTERVAL=0 MAAS_POWERON_TIMEOUT=5 MAAS_HEALTH_TIMEOUT=2 MAAS_REGION_TIMEOUT=2
export MOCK_BMC_POWER_DIR="$SANDBOX/power"
export MAAS_NETBOOT_DIR="$SANDBOX/netboot"

ART="$SANDBOX/art"; mkdir -p "$ART"
printf 'K\n' > "$ART/kernel"; printf 'I\n' > "$ART/initrd"
export MAAS_CATALOG="$SANDBOX/catalog.toml"
cat > "$MAAS_CATALOG" <<TOML
[meta]
version = 1
[[image]]
name    = "edge"
summary = "fixture: a RAM service that must announce to count"
lab     = "tests/"
build   = "true"
kernel  = "$ART/kernel"
initrd  = "$ART/initrd"
cmdline = "console=ttyS0"
health  = "console"
marker  = "SERVICE-UP"
region_check  = "console"
region_marker = "ANNOUNCED"
[[image]]
name    = "loner"
summary = "fixture: a RAM service with NO way to prove membership"
lab     = "tests/"
build   = "true"
kernel  = "$ART/kernel"
initrd  = "$ART/initrd"
cmdline = "console=ttyS0"
health  = "console"
marker  = "SERVICE-UP"
TOML
( "$LAB_DIR/drivers/ramdisk.sh" stage edge  ) >/dev/null 2>&1 || fail "stage edge"
( "$LAB_DIR/drivers/ramdisk.sh" stage loner ) >/dev/null 2>&1 || fail "stage loner"

prep() {
    ( "$MAAS" enroll "$1" --bmc-port "$2" ) >/dev/null 2>&1 || fail "enroll $1"
    ( "$MAAS" manage "$1" )  >/dev/null 2>&1 || fail "manage $1"
    [[ -n "${3:-}" ]] && printf '%s\n' "$3" > "$MAAS_STATE/$1/cpus"
    [[ -n "${4:-}" ]] && printf '%s\n' "$4" > "$MAAS_STATE/$1/mem_mb"
    ( "$MAAS" provide "$1" ) >/dev/null 2>&1 || fail "provide $1"
}

# ── 1. up but NOT announced -> not active ───────────────────────────────────
prep r1 6260
printf 'SERVICE-UP\n' > "$MAAS_STATE/r1/console.log"      # serving; never announced
( "$MAAS" deploy r1 --driver ramdisk --image edge --region east ) >/dev/null 2>&1 \
    && fail "REGRESSION: a node that is UP but never joined its region was marked active. It answers every local check while the region routes nothing to it — the one failure where every dashboard says healthy"
assert_state r1 error
note "serving but never announced -> refused (region membership is not local health)  ✓"

# ── 2. …and announced -> active (the positive control) ──────────────────────
prep r2 6261
printf 'SERVICE-UP\nANNOUNCED via bgp\n' > "$MAAS_STATE/r2/console.log"
( "$MAAS" deploy r2 --driver ramdisk --image edge --region east ) >/dev/null 2>&1 \
    || fail "a node that IS serving and HAS announced did not reach active"
assert_state r2 active
[[ "$(_show r2 region)" == east ]] || fail "the node's region was not recorded"
note "serving AND announced -> active, region recorded  ✓"

# ── 3. no --region: the same image activates on local health alone ──────────
# Without this, §1 would also pass on a driver that simply never activates.
prep r3 6262
printf 'SERVICE-UP\n' > "$MAAS_STATE/r3/console.log"
( "$MAAS" deploy r3 --driver ramdisk --image edge ) >/dev/null 2>&1 \
    || fail "with no --region, a serving node should activate on its health signal alone"
assert_state r3 active
note "no --region: local health is enough — the region gate is selective, not blanket  ✓"

# ── 4. an image that cannot PROVE membership is refused, not assumed ────────
prep r4 6263
printf 'SERVICE-UP\n' > "$MAAS_STATE/r4/console.log"
out="$( ( "$MAAS" deploy r4 --driver ramdisk --image loner --region east ) 2>&1 )" \
    && fail "REGRESSION: a node was deployed into a region using an image that declares no region_check — the control plane would be claiming a membership it has no way to verify"
grep -Fq 'declares no region_check' <<<"$out" \
    || fail "the refusal did not name the missing region_check (got: ${out//$'\n'/ })"
note "an image with no region_check cannot be deployed into a region  ✓"

# ── 5. the scheduler picks by FACTS, not by name ────────────────────────────
maas_env; maas_env_drivers
# maas_env_drivers points MAAS_DRIVER_DIR at tests/ (for the mock driver) and gives a
# fresh image store + trust root. Both have to be undone here or the scheduler looks
# broken when it is not: `ramdisk` would resolve to a stub that does not exist, and
# every deploy would fail F2 against an empty trust root.
export MAAS_DRIVER_DIR="$LAB_DIR/drivers"
export MOCK_BMC_POWER_DIR="$SANDBOX/power2" MAAS_NETBOOT_DIR="$SANDBOX/netboot2"
( "$LAB_DIR/drivers/ramdisk.sh" stage edge ) >/dev/null 2>&1 || fail "re-stage edge"
prep big1 6270 4 8192          # qualifies
prep big2 6271 2 4096          # qualifies
prep small 6272 1 512          # too small
prep blind 6273                # never inspected: no facts at all
for n in big1 big2 small blind; do printf 'SERVICE-UP\n' > "$MAAS_STATE/$n/console.log"; done

SPEC="$SANDBOX/claims.toml"
cat > "$SPEC" <<TOML
[[claim]]
name = "edge"
count = 2
driver = "ramdisk"
image = "edge"
min_cpus = 2
min_mem_mb = 2048
TOML
out="$( ( "$MAAS" apply "$SPEC" --dry-run ) 2>&1 )" || fail "apply --dry-run with a claim failed"
grep -q 'claim edge' <<<"$out" || fail "apply did not report the claim (got: ${out//$'\n'/ })"
grep -q 'big1' <<<"$out" || fail "the scheduler did not pick big1, which satisfies the claim"
grep -q "small" <<<"$out" \
    && fail "REGRESSION: the scheduler picked 'small' (1 cpu / 512 MB) for a claim requiring >=2 cpus and >=2048 MB"
grep -q "blind" <<<"$out" \
    && fail "REGRESSION: the scheduler picked 'blind', a node that was NEVER INSPECTED and has no facts. Scheduling onto hardware nobody has looked at is exactly the surprise the introspection step exists to prevent"
note "picks only nodes whose inspected facts satisfy the claim; skips the small one and the uninspected one  ✓"

# ── 6. …and it actually deploys them, then stops (idempotence) ──────────────
export MAAS_CLAIM_LOG="$SANDBOX/claim.log"   # so a failure names what the DRIVER said
_ao="$( ( "$MAAS" apply "$SPEC" ) 2>&1 )" \
    || fail "apply with a claim failed. The driver said: $(tr '\n' '|' < "$SANDBOX/claim.log")"
n_active=0
for n in big1 big2 small blind; do
    [[ "$("$MAAS" state "$n" 2>/dev/null)" == active ]] && n_active=$((n_active+1))
done
[[ $n_active -eq 2 ]] \
    || fail "REGRESSION: the claim asked for 2 nodes and $n_active are active — a scheduler that over- or under-fills a claim is worse than none"
out="$( ( "$MAAS" apply "$SPEC" ) 2>&1 )" || fail "the second apply failed"
grep -qE 'claim +edge +satisfied \(2/2\)' <<<"$out" \
    || fail "REGRESSION: a satisfied claim was not reported satisfied on the second run — apply would keep deploying nodes forever (got: $(grep claim <<<"$out"))"
note "fills the claim with exactly 2, and the second run reports it satisfied  ✓"

# ── 7. an unsatisfiable claim says so instead of silently under-filling ─────
cat > "$SPEC" <<TOML
[[claim]]
name = "huge"
count = 1
driver = "ramdisk"
image = "edge"
min_cpus = 64
min_mem_mb = 1048576
TOML
out="$( ( "$MAAS" apply "$SPEC" ) 2>&1 )" || true
grep -q 'UNSATISFIABLE' <<<"$out" \
    || fail "REGRESSION: a claim no node can satisfy was not reported. Silently converging on 'nothing to do' tells the operator their fleet is fine when their declaration is impossible"
note "a claim nothing can satisfy is reported, not silently ignored  ✓"

pass "region membership is proven before a RAM node counts as active, and apply schedules claims by inspected facts — never onto a node nobody looked at"
