#!/usr/bin/env bash
# `--user name:pass` must carry a password containing `:` through to the spec, intact.
#
# THIS TEST EXISTS BECAUSE THE AUDIT WAS WRONG, AND THAT IS WORTH A TEST OF ITS OWN.
#
# AUDIT.md **F8 (Info)** reads: *"`IFS=: read -r uname upass` for `--user name:pass`
# truncates any password containing a `:` … the CLI form should document the limitation or
# split on the first `:` only."*
#
# Measured 2026-08-06: **it does not truncate.** `read` assigns the remaining fields —
# *including the delimiters between them* — to the LAST variable, which is precisely
# "split on the first `:` only". The shipped line already has the behaviour the finding
# asked for:
#
#     $ IFS=: read -r n p <<< 'alice:pa:ss:word'; echo "[$n] [$p]"
#     [alice] [pa:ss:word]
#
# So F8 named a mechanism (`IFS=:` looks lossy) and inferred an outcome (truncation)
# without measuring it — the plan's bug class #2, in a document rather than a test. The row
# is corrected rather than "fixed": there was nothing to fix, and a well-meaning patch here
# (`${u%%:*}` / `${u#*:}` rewritten carelessly, or a switch to `cut -d:`) could easily have
# INTRODUCED the truncation the audit imagined.
#
# That is the real reason for this file. The correct behaviour was never asserted anywhere
# — no test in this suite touches `--user` at all — so it was one refactor away from
# becoming true, and the audit would then have looked prescient rather than mistaken.
#
# NO ROOT, NO BOOTSTRAP. `spec_from_cli` turns parsed options into JSON and touches
# nothing else, so the parse can be exercised directly.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

_verdict=0
_fail() { _verdict=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
_on_exit() {
    local rc=$?
    if (( rc != 0 && rc != 77 )) && (( _verdict == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

# shellcheck disable=SC1090
source "$LAB_CHROOT" >/dev/null 2>&1 || true
declare -F spec_from_cli >/dev/null \
    || _fail "spec_from_cli is not defined after sourcing $LAB_CHROOT — the CLI spec builder was renamed, so this test no longer exercises the shipped parse and must be repaired rather than deleted"

# users_json_for <user-arg>... — run the SHIPPED parse and return the users array.
users_json_for() {
    OPT_USERS=("$@")
    OPT_NAME=t OPT_BACKEND=debootstrap OPT_DISTRO=debian OPT_SUITE=bookworm
    OPT_ARCH=amd64 OPT_TARGET=/tmp/x OPT_MANAGER=none
    spec_from_cli | jq -c '.users'
}

# ── 1. a password full of colons survives whole ────────────────────────────
u="$(users_json_for 'alice:pa:ss:word')" || _fail "spec_from_cli failed on a colon-bearing password"
name="$(jq -r '.[0].name' <<<"$u")"; pass_="$(jq -r '.[0].password' <<<"$u")"
[[ "$name" == "alice" ]] \
    || _fail "the username was parsed as '$name', expected 'alice' — the split must take everything BEFORE the first colon as the name"
[[ "$pass_" == "pa:ss:word" ]] \
    || _fail "REGRESSION: --user 'alice:pa:ss:word' produced password '$pass_', expected 'pa:ss:word'. The password is truncated at a colon — this is AUDIT F8's imagined defect made real, and it fails SILENTLY: the chroot is created with a password the operator never chose, and the mismatch only shows up at a login prompt"
note "'alice:pa:ss:word' -> name=alice password=pa:ss:word (nothing lost)"

# ── 2. the ordinary case still works — the control for assertion 1 ─────────
# A parse that returned the whole string as the password would satisfy nothing above on
# its own; this pins the split point from the other side.
u="$(users_json_for 'bob:simple')"
[[ "$(jq -r '.[0].name' <<<"$u")" == "bob" && "$(jq -r '.[0].password' <<<"$u")" == "simple" ]] \
    || _fail "the ordinary 'bob:simple' form broke: $(jq -c '.[0]' <<<"$u")"
note "'bob:simple' -> name=bob password=simple"

# ── 3. edge shapes that must not crash or silently mangle ──────────────────
u="$(users_json_for 'carol:')"
[[ "$(jq -r '.[0].name' <<<"$u")" == "carol" && "$(jq -r '.[0].password' <<<"$u")" == "" ]] \
    || _fail "'carol:' (empty password) mis-parsed: $(jq -c '.[0]' <<<"$u")"
u="$(users_json_for 'dave')"
[[ "$(jq -r '.[0].name' <<<"$u")" == "dave" && "$(jq -r '.[0].password' <<<"$u")" == "" ]] \
    || _fail "'dave' (no colon at all) mis-parsed: $(jq -c '.[0]' <<<"$u")"
note "edge shapes: 'carol:' and bare 'dave' both give an empty password, not a crash"

# ── 4. several users at once, one of them colon-laden ──────────────────────
u="$(users_json_for 'alice:a:b' 'bob:simple')"
[[ "$(jq -r 'length' <<<"$u")" == "2" ]] || _fail "two --user flags did not produce two users: $u"
[[ "$(jq -r '.[0].password' <<<"$u")" == "a:b" ]] \
    || _fail "the colon-bearing password was mangled when a second --user was present: $u"
note "two users, the colon-bearing one unaffected by the other"

# ── 5. a shell metacharacter must reach the spec as DATA, not be evaluated ──
# Inert on purpose: '$(echo INJECTED)' is a placeholder, never a destructive verb. If the
# parse ever evaluated it, the assertion below shows the evaluated text and the password is
# not what the operator typed.
lit='p$(echo INJECTED)w'
u="$(users_json_for "eve:$lit")"
[[ "$(jq -r '.[0].password' <<<"$u")" == "$lit" ]] \
    || _fail "REGRESSION: a '\$(...)' in a password was not carried through verbatim — got '$(jq -r '.[0].password' <<<"$u")', expected '$lit'. The parse is expanding what it should be quoting"
note "a \$(...) in a password reaches the spec verbatim, unevaluated"

pass "--user carries colon-bearing passwords through to the spec intact (AUDIT F8's claimed truncation does not exist; this pins the correct behaviour so a refactor cannot introduce it)"
