#!/usr/bin/env bash
# REGRESSION (REVIEW-phase7.md P7-3): the instance name is a PATH COMPONENT, and four verbs
# took it as a bare positional and pasted it into one.
#
#     fc_dir() { printf '%s/%s' "$LAB_FC_STATE_DIR" "$1"; }
#     cmd_destroy() { d="$(fc_dir "$name")"; [[ -d "$d" ]] || die …; rm -rf "$d"; }
#
# Measured: `destroy ../../<dir>` removed a directory outside the state dir and printed
#     PASS: destroyed ../../trav/precious (its tap, if any, belongs to the fabric …)
#
# The regex that would have stopped it was in the file the whole time — inside
# `preflight_checks`, which only `preflight` and `create` run. This is the same shape as
# Phase 1's P1-1 (a name synthesised from a path, then used as a manifest key) and the fix
# is the same one: guard the ACCESSOR, not each verb, so a verb added later is safe by
# default rather than by someone remembering.
#
# THIS TEST BUILDS NO MICROVM AND NEEDS NO VMM. The defect is entirely in name resolution.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
export LAB_STATE_DIR="$tmp/state"
mkdir -p "$LAB_STATE_DIR/fc"

# The bystander. It sits exactly where `$LAB_FC_STATE_DIR/../../victim` resolves, and it
# holds a file, so "the directory is gone" and "the directory is empty" are different
# outcomes and the message can say which.
victim="$tmp/victim"
mkdir -p "$victim"; printf 'IRREPLACEABLE\n' > "$victim/data.txt"

# ── 1. destroy — the damaging one ─────────────────────────────────────────────────────
run_fc "$tmp/d.out" destroy "../../victim" && rc=0 || rc=$?
(( rc != 0 )) \
    || fail "REGRESSION: 'destroy ../../victim' was ACCEPTED — the instance name is a path again (P7-3)"
[[ -d "$victim" && -r "$victim/data.txt" ]] \
    || fail "REGRESSION: 'destroy ../../victim' rm -rf'd a directory outside the state dir — the exact P7-3 incident"
grep -qi 'invalid instance name' "$tmp/d.out" \
    || fail "destroy refused the traversing name but did not say why; got: $(cat "$tmp/d.out")"
note "destroy refuses a traversing name, and the bystander directory is intact"

# ── 2. the other three verbs, because the guard is meant to be at the accessor ─────────
# If the fix had been pasted into cmd_destroy alone, this section is what notices.
for verb in stop start inspect; do
    run_fc "$tmp/$verb.out" "$verb" "../../victim" && rc=0 || rc=$?
    (( rc != 0 )) \
        || fail "REGRESSION: '$verb ../../victim' was accepted — the guard is in cmd_destroy only, not at the accessor (P7-3)"
    grep -qi 'invalid instance name' "$tmp/$verb.out" \
        || fail "'$verb' refused the traversing name but not with the name guard's message — some other error stopped it by luck; got: $(cat "$tmp/$verb.out")"
done
[[ -d "$victim" && -r "$victim/data.txt" ]] || fail "REGRESSION: one of stop/start/inspect damaged the bystander"
note "stop, start and inspect refuse it at the same accessor, with the same message"

# ── 3. the shapes that are not traversal but are still not names ──────────────────────
# An absolute path, a leading dash (a flag to anything that takes one), an empty component,
# and a name longer than the regex allows.
# NOTE the missing entry this list used to have: it was written `"a/b" "..", ""`, and the
# stray comma made `..` into the single token `..,` — so the plain `..` case was never
# tested at all, while the loop looked like it covered it. shellcheck SC2258 caught it.
for bad in "/etc" "a/b" ".." "." "A1" "$(printf 'x%.0s' {1..40})"; do
    run_fc "$tmp/b.out" inspect "$bad" && rc=0 || rc=$?
    (( rc != 0 )) || fail "REGRESSION: 'inspect $bad' was accepted as an instance name"
    grep -qi 'invalid instance name' "$tmp/b.out" \
        || fail "'inspect $bad' was refused, but by something other than the name guard; got: $(cat "$tmp/b.out")"
done
note "absolute paths, embedded slashes, '.', '..', uppercase and over-long names all refused by the guard"

# A '-'-leading name never reaches the name guard — the flag parser eats it first, which is
# the earlier and better refusal. Asserted separately rather than lumped in above, because
# "it was refused" and "the guard refused it" are different facts and only one of them is
# what this file is about.
run_fc "$tmp/flag.out" inspect "-rf" && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: a '-'-leading instance name was accepted"
grep -qi 'unknown flag' "$tmp/flag.out" \
    || fail "a '-'-leading name should be refused by the flag parser before the name guard sees it; got: $(cat "$tmp/flag.out")"
note "a '-'-leading name is refused earlier still, by the flag parser"

# ...and an empty positional is a different message, not the same one.
run_fc "$tmp/none.out" inspect && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: 'inspect' with no instance name exited 0"
grep -qi 'instance name required' "$tmp/none.out" \
    || fail "a missing name should say so by name; got: $(cat "$tmp/none.out")"
note "a missing name is refused with its own message, not the invalid-name one"

# ── 4. CONTROL: a legal name still resolves, and destroy still destroys ───────────────
# A guard that refused EVERY name would pass every assertion above. This is the half that
# notices — and it is the half Phase 1's P1-1 fix needed too.
n="p7name$$"
mkdir -p "$LAB_STATE_DIR/fc/$n"
printf 'name = "%s"\n' "$n" > "$LAB_STATE_DIR/fc/$n/manifest.toml"
run_fc "$tmp/i.out" inspect "$n" || { cat "$tmp/i.out" >&2; fail "control: 'inspect' refused a LEGAL instance name"; }
grep -q "name = \"$n\"" "$tmp/i.out" || fail "control: inspect did not print the manifest for a legal name"
run_fc "$tmp/l.out" list || fail "control: 'list' failed"
grep -q "^$n " "$tmp/l.out" || fail "control: 'list' does not show a legally-named instance; got: $(cat "$tmp/l.out")"
run_fc "$tmp/dd.out" destroy "$n" || { cat "$tmp/dd.out" >&2; fail "control: 'destroy' refused a legal name"; }
[[ -d "$LAB_STATE_DIR/fc/$n" ]] && fail "control: 'destroy' reported success but the instance directory survives"
note "control: a legal name is still resolved, listed and destroyed"

# ── 5. NEGATIVE CONTROL: re-inject the unguarded accessor and watch it bite ───────────
# Run the pre-fix `fc_dir` against the same argument and confirm it produces a path that
# escapes the state dir. Without this, section 1 could be passing because `destroy` refuses
# everything, or because `-d` happened to be false.
old_dir="$LAB_STATE_DIR/fc/../../victim"
[[ -d "$old_dir" ]] \
    || fail "control: the pre-fix accessor's path ($old_dir) does not resolve to the bystander, so section 1 has not been shown capable of failing"
[[ "$(cd "$old_dir" && pwd -P)" == "$(cd "$victim" && pwd -P)" ]] \
    || fail "control: the pre-fix path resolves somewhere other than the bystander — this fixture is not testing what it claims"
note "negative control: the pre-fix accessor resolves '../../victim' to the bystander, so the refusal above is doing real work"

pass "the instance name is validated at the accessor every path helper goes through: 4 verbs refuse traversal, legal names still work end-to-end (P7-3)"
