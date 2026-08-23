#!/usr/bin/env bash
# test-shellcheck-gate.sh — the repo-wide shellcheck gate must actually select the repo,
# actually fail on a bad script, and actually notice a stale exclusion.
#
# WHY.  TODO §11.3b inverted a 60-file inclusion list into a `git ls-files` sweep with a
# one-entry exclusion file.  That is strictly better ONLY if it is really looking: an
# all-PASS sweep and a glob that matched nothing print the same green tick, and a typo in
# `git ls-files '*.sh'` would present as the second while reading as the first.  This repo
# has been burned by exactly that shape three times (check-harness-net.sh §1 twice,
# test-no-pipe-gates.sh once), so the gate ships with the control attached.
#
# HOW — AGAINST THE SHIPPED STEP.  The selection is sed'd out of `.github/workflows/ci.yml`
# rather than re-implemented; a copy drifts and then proves something about the copy.
# Four questions, each answered by RUNNING it:
#
#   1. does it select essentially the whole tracked corpus (not a handful, not zero)?
#   2. does a planted bad script make it FAIL, and raise the count by one?
#   3. does excluding that planted file make it pass again — i.e. does the exclusion work?
#   4. does an exclusion naming a path that no longer exists FAIL, by name?
#
# Own verdict helpers on purpose: it must not source a suite's lib.sh.
set -uo pipefail

_V=0
skip() { _V=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _V=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _V=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _V == 0 )); then
        printf 'FAIL: test-shellcheck-gate.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || fail "cannot cd to repo root"
CI=".github/workflows/ci.yml"
EXCL=".shellcheck-exclude"
[[ -r "$CI"   ]] || fail "no $CI — this check has no subject"
[[ -r "$EXCL" ]] || fail "no $EXCL — the gate's exclusion file is missing, so the gate is not the one this checks"
command -v shellcheck >/dev/null 2>&1 || skip "shellcheck is not installed"
command -v git >/dev/null 2>&1        || skip "git not available to enumerate the corpus"
WORK="$(mktemp -d)"

# ── 1. the shipped selection, extracted ────────────────────────────────────────────────
# The range ends ON the next step's `- name:` line, so that line is dropped explicitly --
# left in, it is YAML in the middle of a bash script and the extraction "fails to parse"
# for a reason that has nothing to do with the step.
STEP="$(sed -n '/^      - name: shellcheck EVERY tracked shell script$/,/^      - name: /p' "$CI" \
        | grep -v '^      - name: ' \
        | sed -n '/^        run: |$/,$p' | sed '1d' | sed 's/^          //')"
[[ -n "$STEP" ]] || fail "could not extract the shellcheck step from $CI — it was renamed or reindented, and this check would otherwise pass while testing NOTHING"
grep -q "git ls-files" <<<"$STEP" || fail "the extracted step does not enumerate with git ls-files — extraction picked up the wrong lines"
bash -n <<<"$STEP" || fail "the extracted step does not parse as bash"

# run_gate <exclude-file> [extra-file...] — run the shipped step with a given exclusion file,
# in a scratch clone of the tracked corpus so a planted script can be added without touching
# the repo.  Prints "rc:<n>" then the step's output.
run_gate() {
    local excl="$1"; shift
    local d="$WORK/run$RANDOM"; mkdir -p "$d"
    ( cd "$ROOT" && git ls-files '*.sh' | tar -cf - -T - ) | ( cd "$d" && tar -xf - )
    cp "$excl" "$d/.shellcheck-exclude"
    ( cd "$d" && git init -q . && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm x >/dev/null 2>&1 )
    local f
    for f in "$@"; do
        cp "$f" "$d/$(basename "$f")"
        ( cd "$d" && git add "$(basename "$f")" >/dev/null 2>&1 )
    done
    local out rc
    out="$( cd "$d" && bash -e -c "$STEP" 2>&1 )"; rc=$?
    printf 'rc:%s\n%s\n' "$rc" "$out"
}

TRACKED="$(git ls-files '*.sh' | wc -l)"
(( TRACKED > 100 )) || fail "only $TRACKED tracked scripts found — this check cannot be trusted on a corpus that small; it would pass vacuously"

problems=()

# ── 2. it selects the corpus, and the repo is clean ────────────────────────────────────
res="$(run_gate "$EXCL")"
rc="${res%%$'\n'*}"; rc="${rc#rc:}"; body="${res#*$'\n'}"
linted="$(grep -oE 'linting [0-9]+ of [0-9]+' <<<"$body" | grep -oE '^linting [0-9]+' | grep -oE '[0-9]+' || true)"
[[ "$rc" == 0 ]] || problems+=("the gate FAILS on the repo as it stands (rc=$rc). 11.3b's whole premise is that 11.3a took the corpus to zero first: $(tail -3 <<<"$body" | tr '\n' ' ')")
[[ -n "$linted" ]] || problems+=("the step printed no 'linting N of M' ratio — a step that lints nothing and one that lints everything both exit 0, which is the reason that line exists")
if [[ -n "$linted" ]]; then
    (( linted >= TRACKED - 5 )) \
        || problems+=("the gate linted only $linted of $TRACKED tracked scripts — a selection that collapsed reads exactly like a clean pass")
    note "selection: linted $linted of $TRACKED tracked scripts  ✓"
fi

# ── 3. a planted bad script must FAIL it, and raise the count ──────────────────────────
# `cd /tmp` with no guard is SC2164 — a warning at exactly the severity CI gates on.
BAD="$WORK/zz-planted-bad.sh"
printf '#!/usr/bin/env bash\ncd /tmp\necho "$undefined_thing"\n' > "$BAD"
res="$(run_gate "$EXCL" "$BAD")"
rc="${res%%$'\n'*}"; rc="${rc#rc:}"; body="${res#*$'\n'}"
planted_linted="$(grep -oE '^linting [0-9]+' <<<"$body" | grep -oE '[0-9]+' || true)"
[[ "$rc" != 0 ]] \
    || problems+=("CONTROL DID NOT FIRE: a planted script with an unguarded \`cd\` passed the gate. The sweep is not looking at the files it claims to lint")
if [[ -n "$linted" && -n "$planted_linted" ]]; then
    (( planted_linted == linted + 1 )) \
        || problems+=("the planted file did not raise the linted count ($linted -> $planted_linted): the gate is not picking up newly added scripts, which is the ENTIRE property the inversion buys")
fi
grep -q 'zz-planted-bad.sh' <<<"$body" \
    || problems+=("the gate failed but never named the planted file, so its output does not say what is wrong")
note "planted an unguarded \`cd\`: gate exits $rc and names the file  ✓"

# ── 4. excluding it must make it pass again ────────────────────────────────────────────
cp "$EXCL" "$WORK/excl-with-planted"
echo "zz-planted-bad.sh" >> "$WORK/excl-with-planted"
res="$(run_gate "$WORK/excl-with-planted" "$BAD")"
rc="${res%%$'\n'*}"; rc="${rc#rc:}"
[[ "$rc" == 0 ]] \
    || problems+=("excluding the planted file did not silence it (rc=$rc) — the exclusion file is not being applied, so its one real entry is not working either")
note "excluding it silences it  ✓"

# ── 5. a stale exclusion must FAIL, by name ────────────────────────────────────────────
# Without this the file rots: an entry keeps excusing a path that was renamed, and the NEW
# name is gated by nobody — silently, which is the failure mode this whole section is about.
cp "$EXCL" "$WORK/excl-stale"
echo "examples/this-path-was-renamed-away/gone.sh" >> "$WORK/excl-stale"
res="$(run_gate "$WORK/excl-stale")"
rc="${res%%$'\n'*}"; rc="${rc#rc:}"; body="${res#*$'\n'}"
[[ "$rc" != 0 ]] \
    || problems+=("CONTROL DID NOT FIRE: an exclusion naming a path that does not exist was accepted. A stale entry then silently un-gates whatever the file was renamed to")
grep -q 'this-path-was-renamed-away' <<<"$body" \
    || problems+=("the stale-exclusion failure does not NAME the offending entry")
note "a stale exclusion fails the step, by name  ✓"

if (( ${#problems[@]} )); then
    fail "$(printf '%d problem(s) with the repo-wide shellcheck gate:' "${#problems[@]}"; printf '\n  - %s' "${problems[@]}")"
fi

pass "the repo-wide shellcheck gate selects $linted of $TRACKED tracked scripts and prints that ratio, fails on a newly added script with an unguarded cd (naming it), honours .shellcheck-exclude, and refuses an exclusion whose path no longer exists — each proved by running the step sed'd out of ci.yml, not a copy of it"
