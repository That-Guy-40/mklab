#!/usr/bin/env bash
# Verdict: `control-pane list --json` + `inspect` enumerate a fleet
# ($LAB_STATE_DIR/control-pane/<node>/node.toml) with live progress from each node's console.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CP="$HERE/../control-pane"
FIX="$HERE/fixtures/install-boot.console"

VERDICT=0; SD=""
pass(){ VERDICT=1; printf 'PASS: %s\n' "$*"; exit 0; }
fail(){ VERDICT=1; printf 'FAIL: %s\n' "$*"; exit 1; }
skip(){ VERDICT=1; printf 'SKIP: %s\n' "$*"; exit 77; }
cleanup(){ _rc=$?; [[ -n "$SD" ]] && rm -rf "$SD"
           [[ $VERDICT -eq 0 ]] && printf 'FAIL: test exited early (rc=%s)\n' "$_rc"; }
trap cleanup EXIT

command -v python3 >/dev/null || skip "python3 not found"
[[ -f "$FIX" ]] || fail "missing fixture $FIX"

SD="$(mktemp -d)"
mkdir -p "$SD/control-pane/edge1"
printf 'profile = "install"\nconsole = "%s"\n' "$FIX" > "$SD/control-pane/edge1/node.toml"

# list --json: edge1 reached its terminal milestone (100%)
js="$(LAB_STATE_DIR="$SD" "$CP" list --json)"
echo "$js" | python3 -c 'import sys,json
n=json.load(sys.stdin)[0]
assert n["name"]=="edge1" and n["percent"]==100 and n["terminal"], n' \
  || fail "list --json wrong: $js"

# inspect shows the milestone timeline
LAB_STATE_DIR="$SD" "$CP" inspect edge1 | grep -q "partitioning" \
  || fail "inspect did not show the milestone timeline"

# an unknown node is refused, non-zero
if LAB_STATE_DIR="$SD" "$CP" inspect nope >/dev/null 2>&1; then
  fail "REGRESSION: inspect of an unknown node did not error"
fi

pass "control-pane list --json + inspect enumerate a fleet with live progress"
