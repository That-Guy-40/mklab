#!/usr/bin/env bash
# Unit test: topo_sort produces dependency-first ordering and detects cycles.
# No docker, no network — sources helper functions directly from lab-docker.sh.

# shellcheck disable=SC1090,SC2034
set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

# Source the topo-sort helpers from the main script without running main().
export LAB_LOG_LEVEL=error   # suppress _log output during sourcing
# shellcheck disable=SC1090
. "$LAB_DOCKER" 2>/dev/null || true   # ignore "docker not found" from require_docker paths

# ── Basic ordering: db and cache must precede web ──────────────────────────
svc='[
  {"name":"web",   "depends_on":["db","cache"]},
  {"name":"db",    "depends_on":[]},
  {"name":"cache", "depends_on":[]}
]'

topo_sort "$svc"
sorted=("${_TOPO_SORTED[@]}")

# All three names present
for expected in web db cache; do
    found=0
    for s in "${sorted[@]}"; do [[ "$s" == "$expected" ]] && found=1; done
    (( found )) || fail "service '$expected' missing from sorted output: ${sorted[*]}"
done

# db and cache must precede web
idx_web=-1; idx_db=-1; idx_cache=-1
for i in "${!sorted[@]}"; do
    case "${sorted[$i]}" in
        web)   idx_web=$i   ;;
        db)    idx_db=$i    ;;
        cache) idx_cache=$i ;;
    esac
done
(( idx_db    < idx_web )) || fail "db must precede web; order: ${sorted[*]}"
(( idx_cache < idx_web )) || fail "cache must precede web; order: ${sorted[*]}"
note "basic depends_on ordering OK (${sorted[*]})"

# ── Chain: a → b → c must produce c, b, a ──────────────────────────────────
chain='[{"name":"a","depends_on":["b"]},{"name":"b","depends_on":["c"]},{"name":"c","depends_on":[]}]'
topo_sort "$chain"
chain_sorted=("${_TOPO_SORTED[@]}")
[[ "${chain_sorted[0]}" == "c" ]] || fail "chain: expected c first; got: ${chain_sorted[*]}"
[[ "${chain_sorted[1]}" == "b" ]] || fail "chain: expected b second; got: ${chain_sorted[*]}"
[[ "${chain_sorted[2]}" == "a" ]] || fail "chain: expected a third; got: ${chain_sorted[*]}"
note "chain ordering OK"

# ── No depends_on field: stable insertion order ────────────────────────────
nodep='[{"name":"x"},{"name":"y"},{"name":"z"}]'
topo_sort "$nodep"
nd=("${_TOPO_SORTED[@]}")
[[ "${nd[0]}" == "x" && "${nd[1]}" == "y" && "${nd[2]}" == "z" ]] \
    || fail "no-depends_on: expected x y z; got: ${nd[*]}"
note "no depends_on: insertion order preserved"

# ── Cycle detection ─────────────────────────────────────────────────────────
cycle='[{"name":"a","depends_on":["b"]},{"name":"b","depends_on":["a"]}]'
cycle_out="$(topo_sort "$cycle" 2>&1)" && fail "cycle: expected die, got success" || true
grep -qi "cycle" <<<"$cycle_out" || fail "cycle: error message must mention 'cycle'; got: $cycle_out"
note "cycle detection fires correctly"

pass "depends_on topo sort OK"
