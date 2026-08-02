#!/usr/bin/env bash
# §5.9: preflight must be THE SAME function create runs first, never a second
# implementation that predicts what create will do. Two implementations drift, and the one
# that drifts is always the one that says "fine".
#
# Asserted structurally: for one spec, the gate lines `preflight` prints and the gate lines
# `create` prints must be IDENTICAL. A reimplementation would diverge on some row.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
mkspec "$tmp/s.toml" 'memory = "256M"'

run_fc "$tmp/pf.out"  preflight --config "$tmp/s.toml" || true
run_fc "$tmp/cr.out"  create --dry-run --config "$tmp/s.toml" || true

# The gate lines are the ones indented with a verdict word.
grep -E '^  (ok|FAIL|UNKNOWN) ' "$tmp/pf.out" > "$tmp/pf.gates" || true
grep -E '^  (ok|FAIL|UNKNOWN) ' "$tmp/cr.out" > "$tmp/cr.gates" || true

[[ -s "$tmp/pf.gates" ]] || fail "preflight printed no gate lines at all — the harness is not exercising anything"

if ! diff -q "$tmp/pf.gates" "$tmp/cr.gates" >/dev/null; then
    printf 'preflight-only vs create-only gate lines:\n' >&2
    diff "$tmp/pf.gates" "$tmp/cr.gates" >&2 || true
    fail "REGRESSION: create's gates differ from preflight's — they are no longer one function (§5.9)"
fi
note "$(wc -l < "$tmp/pf.gates") gate lines, byte-identical between preflight and create"

# And create must REFUSE when preflight refuses -- the ordering rule: refuse before the
# irreversible step, not after it.
if grep -q '^  FAIL ' "$tmp/pf.gates"; then
    grep -q 'nothing was created' "$tmp/cr.out" \
        || fail "REGRESSION: preflight refused but create did not stop before acting (§5.9 ordering rule)"
    note "create refused before copying anything"
else
    fail "this spec was supposed to fail at least one gate; the test proves nothing as written"
fi

pass "preflight and create run one function, and create refuses before the irreversible step"
