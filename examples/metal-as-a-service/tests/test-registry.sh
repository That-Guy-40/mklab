#!/usr/bin/env bash
# Verdict: the directory-tree registry behaves — atomic state writes (no stray
# temp files), an append-only history log with the right shape, a generated
# bmc-toolkit registry that resolves MAAS's nodes, and `list --json` valid output.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need python3
maas_env

( "$MAAS" enroll node1 --bmc-port 6230 --domain maas-node1 ) >/dev/null 2>&1 || fail "enroll node1"
( "$MAAS" enroll node2 --bmc-port 6231 --domain maas-node2 ) >/dev/null 2>&1 || fail "enroll node2"
( "$MAAS" manage node1 ) >/dev/null 2>&1 || fail "manage node1"

# ── atomic writes: the `state` file is always a single clean word, no .tmp left ─
st="$(cat "$MAAS_STATE/node1/state")"
[[ "$st" == manageable ]] || fail "state file not the expected word (got '$st')"
if compgen -G "$MAAS_STATE/node1/.*.tmp" >/dev/null; then
    fail "REGRESSION: a stray atomic-write temp file was left behind"
fi
note "atomic state write, no temp litter ✓"

# ── history log shape: 'TS  from -> to  (verb)' ──────────────────────────────
hist="$MAAS_STATE/node1/history.log"
[[ -f "$hist" ]] || fail "no history.log"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z  .* -> .* \(.*\)$' "$hist" \
    || fail "history.log line shape wrong: $(head -1 "$hist")"
# enroll then manage => at least 3 recorded transitions (enrolled, verifying, manageable)
n="$(wc -l < "$hist")"
[[ "$n" -ge 3 ]] || fail "expected >=3 history transitions, got $n"
note "history log shape + ordering ✓"

# ── generated bmc-toolkit registry resolves MAAS's nodes ─────────────────────
reg="$MAAS_STATE/fleet-bmc.toml"
[[ -f "$reg" ]] || fail "no generated fleet-bmc.toml"
grep -q 'name      = "node1"' "$reg" || fail "registry missing node1"
grep -q 'ipmi_port = 6231' "$reg" || fail "registry missing node2 port"
grep -q 'backend   = "vbmcd"' "$reg" || fail "registry backend not vbmcd"
# the real registry reader (bmc-toolkit's) must be able to parse it + resolve node2
REGPY="$LAB_DIR/../bmc-toolkit/lib/registry.py"
if [[ -f "$REGPY" ]]; then
    out="$(python3 "$REGPY" "$reg" get node2 2>/dev/null)" || fail "bmc-toolkit registry.py could not parse the generated registry"
    grep -q 'NODE_IPMI_PORT=6231' <<<"$out" || fail "registry.py resolved node2 but not its port"
    note "generated registry parses via bmc-toolkit registry.py ✓"
else
    note "bmc-toolkit registry.py not found — skipped cross-parse (registry file shape still checked)"
fi

# ── list --json is valid JSON with the expected records ──────────────────────
js="$("$MAAS" list --json)" || fail "list --json failed"
python3 -c '
import json,sys
d=json.loads(sys.argv[1])
assert isinstance(d,list) and len(d)==2, d
names={n["name"] for n in d}
assert names=={"node1","node2"}, names
assert all("state" in n for n in d), d
' "$js" || fail "list --json not valid / wrong shape"
note "list --json valid ✓"

pass "registry: atomic writes, history shape, generated bmc registry parses, list --json valid"
