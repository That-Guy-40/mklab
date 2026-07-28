#!/usr/bin/env bash
# Verdict: `control-pane actions` / `run` drive ONLY what a node's owner declared.
#
# The control pane is a surface, not a second implementation of anybody's CLI. A lab
# writes `[[action]]` entries into its node's node.toml naming the exact argv; the
# panel lists them and runs them. It never composes a command of its own, which is what
# keeps the invariant true for every consumer: delete the TUI and those same argv still
# work in a shell, because they ARE the shell commands.
#
# The two flags that change how a key press is treated:
#   reconciling  safe to press repeatedly — it converges rather than repeats
#   destructive  needs --yes even though it is one keystroke away in the panel
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CP="$HERE/../control-pane"

VERDICT=0; SD=""
pass(){ VERDICT=1; printf 'PASS: %s\n' "$*"; exit 0; }
fail(){ VERDICT=1; printf 'FAIL: %s\n' "$*"; exit 1; }
skip(){ VERDICT=1; printf 'SKIP: %s\n' "$*"; exit 77; }
note(){ printf '  - %s\n' "$*"; }
cleanup(){ _rc=$?; [[ -n "$SD" ]] && rm -rf "$SD"
           [[ $VERDICT -eq 0 ]] && printf 'FAIL: test exited early (rc=%s)\n' "$_rc"; }
trap cleanup EXIT

command -v python3 >/dev/null || skip "python3 not found"

SD="$(mktemp -d)"
FLEET="$SD/control-pane"
mkdir -p "$FLEET/n1" "$FLEET/plain"
MARK="$SD/ran.log"; : > "$MARK"

# A node whose owner declared three actions. The argv are inert: they append to a log.
cat > "$FLEET/n1/node.toml" <<TOML
profile = "install"
console = "$SD/none.console"

[[action]]
key = "a"
label = "Reconcile"
reconciling = true
argv = ["sh", "-c", "echo reconcile >> '$MARK'"]

[[action]]
key = "i"
label = "Show"
argv = ["sh", "-c", "echo show >> '$MARK'"]

[[action]]
key = "R"
label = "Release"
destructive = true
argv = ["sh", "-c", "echo RELEASED >> '$MARK'"]
TOML
# …and one that declares none, which must be a clean answer, not an error.
printf 'profile = "install"\nconsole = "%s/none.console"\n' "$SD" > "$FLEET/plain/node.toml"

# ── 1. actions are listed, with their flags ─────────────────────────────────
out="$("$CP" actions n1 --fleet "$FLEET" 2>&1)" || fail "actions failed: $out"
grep -q 'Reconcile' <<<"$out" || fail "actions did not list the declared 'Reconcile' action"
grep -q 'Release'   <<<"$out" || fail "actions did not list the declared 'Release' action"
js="$("$CP" actions n1 --fleet "$FLEET" --json 2>&1)" || fail "actions --json failed: $js"
python3 - "$js" <<'PY' || fail "actions --json did not carry the declared argv + flags"
import json, sys
a = json.loads(sys.argv[1])
assert len(a) == 3, a
byk = {x["key"]: x for x in a}
assert byk["a"]["reconciling"] is True and byk["a"]["destructive"] is False, a
assert byk["R"]["destructive"] is True, a
assert byk["i"]["argv"][0] == "sh", a
PY
note "declared actions are listed with their argv and their reconciling/destructive flags  ✓"

# ── 2. a node that declares none says so, and does not error ────────────────
out="$("$CP" actions plain --fleet "$FLEET" 2>&1)" \
    || fail "a node with no declared actions should not be an error"
grep -q 'no actions' <<<"$out" || fail "a node with no declared actions did not say so (got: $out)"
note "a node whose owner declared nothing gets an honest answer, not an error  ✓"

# ── 3. run executes the DECLARED argv, and only that ────────────────────────
"$CP" run n1 i --fleet "$FLEET" >/dev/null 2>&1 || fail "run of a declared action failed"
grep -qx 'show' "$MARK" || fail "run did not execute the declared argv (log: $(cat "$MARK"))"
note "run executes exactly the declared argv  ✓"

# ── 4. an UNDECLARED action is refused — the panel invents nothing ──────────
: > "$MARK"
out="$("$CP" run n1 definitely-not-declared --fleet "$FLEET" 2>&1)" \
    && fail "REGRESSION: run accepted an action the node never declared. A panel that can run commands its owner did not declare is a second, unreviewed CLI"
grep -q 'declares no action' <<<"$out" || fail "an undeclared action was refused without saying so (got: $out)"
[[ ! -s "$MARK" ]] || fail "REGRESSION: something ran while refusing an undeclared action"
note "an action the owner never declared is refused, and nothing runs  ✓"

# ── 5. destructive needs --yes ──────────────────────────────────────────────
: > "$MARK"
out="$("$CP" run n1 R --fleet "$FLEET" 2>&1)" \
    && fail "REGRESSION: a DESTRUCTIVE action ran from a single key with no confirmation"
grep -q 'declared destructive' <<<"$out" || fail "the destructive refusal did not explain itself (got: $out)"
[[ ! -s "$MARK" ]] || fail "REGRESSION: the destructive action ran despite being refused"
"$CP" run n1 R --fleet "$FLEET" --yes >/dev/null 2>&1 || fail "--yes did not run the destructive action"
grep -qx 'RELEASED' "$MARK" || fail "--yes did not execute the declared destructive argv"
note "a destructive action needs --yes; with it, it runs  ✓"

# ── 6. a reconciling action is safe to press twice ──────────────────────────
# Not a claim about this fixture — a claim about the FLAG being carried through, so a
# panel can tell "converges" from "repeats" before binding a key to it.
python3 - "$js" <<'PY' || fail "the reconciling flag is not reaching consumers"
import json, sys
a = json.loads(sys.argv[1])
assert any(x["reconciling"] for x in a), "no action carries reconciling=true"
PY
note "the reconciling flag reaches consumers, so a panel can tell converge from repeat  ✓"

pass "control-pane runs only the actions a node's owner declared: undeclared refused, destructive gated behind --yes, flags carried through to consumers"
