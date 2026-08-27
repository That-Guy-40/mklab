#!/usr/bin/env bash
# test-tier-b-refuses-an-empty-track-list.sh — the "Boot the tracks" step must FAIL,
# loudly, when its track list is empty. It must never finish green having run none.
#
# WHY. `${{ inputs.tracks }}` exists only on `workflow_dispatch`. When Tier B was
# wired to `pull_request` and a weekly `schedule`, TRACKS began arriving EMPTY on
# both — and an empty `for` list runs zero tracks, prints no failure, and exits 0.
# That is this repo's oldest shape (a checker that looks at nothing prints the same
# tick as one that passes), and it appeared inside the very job built to catch it.
#
# The fix was a fallback to DEFAULT_TRACKS *and* a refusal to finish having run
# zero. Both were reasoned about and neither had ever been WATCHED. The fallback
# has since fired in production (Tier B ran seven tracks on a pull_request), but
# the refusal has never executed at all: an assertion never observed failing is
# not known to work — it may be checking a path that never runs.
#
# HOW — AGAINST THE SHIPPED STEP. The `run:` body is sed'd out of the workflow and
# executed, the way test-ci-tolerates-a-skipped-suite.sh does with `run_suite`. A
# re-implementation would drift and then prove something about the copy. Only
# smoke-openbios.sh is stubbed, because the question is about the LOOP, not about
# whether firmware boots.
#
# Own verdict helpers: this must not source a suite's lib.sh, or a subject would be
# supplying its own harness.
set -uo pipefail

_V=0
skip() { _V=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _V=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _V=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _V == 0 )); then
        printf 'FAIL: test-tier-b-refuses-an-empty-track-list.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
WF="$ROOT/.github/workflows/openbios-tier-b.yml"
[[ -f "$WF" ]] || fail "$WF is missing — there is no shipped step to extract, and this check would otherwise pass while testing nothing"

# ── 1. extract the shipped step ────────────────────────────────────────────────
BODY="$(sed -n '/^      - name: Boot the tracks$/,/^      - name: Timings$/p' "$WF" \
        | sed -n '/^        run: |$/,$p' | sed '1d' | sed 's/^          //')"
# An empty or mis-aimed extraction is the failure mode that makes this whole file a
# liar, so it is checked by CONTENT and not merely for being non-empty.
[[ -n "$BODY" ]] || fail "could not extract the 'Boot the tracks' run: body from openbios-tier-b.yml — the step was renamed or reindented, and this check would pass while testing NOTHING"
grep -q 'for t in \$TRACKS' <<<"$BODY" \
    || fail "the extracted body does not contain the track loop — the sed picked up the wrong lines, so every assertion below would be about the wrong code"
grep -q 'DEFAULT_TRACKS' <<<"$BODY" \
    || fail "the extracted body does not reference DEFAULT_TRACKS — the fallback this test exists to verify is not in the text that was extracted"
bash -n <<<"$BODY" || fail "the extracted body does not parse as bash — the extraction is wrong, or the shipped step is broken"
note "extracted the shipped 'Boot the tracks' body ($(wc -l <<<"$BODY") lines) from openbios-tier-b.yml — not a copy of it"

WORK="$(mktemp -d)"

# ── 2. drive it ────────────────────────────────────────────────────────────────
# Only smoke-openbios.sh is faked. It records what it was asked to run, so the
# assertions can be about WHICH tracks executed rather than only about the exit code.
run_step() { # run_step <TRACKS> <DEFAULT_TRACKS|__unset__>; echoes rc, leaves $WORK/ran
    local tracks="$1" deft="$2" d
    d="$WORK/case"; rm -rf "$d"; mkdir -p "$d/examples/openbios-the-rival-that-shipped"
    cat > "$d/examples/openbios-the-rival-that-shipped/smoke-openbios.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$WORK/ran"
case "\$1" in
    fail-me) echo "FAIL: synthetic"; exit 1 ;;
    skip-me) echo "SKIP: synthetic"; exit 77 ;;
    *)       echo "PASS: synthetic \$1"; exit 0 ;;
esac
STUB
    chmod +x "$d/examples/openbios-the-rival-that-shipped/smoke-openbios.sh"
    : > "$WORK/ran"
    local out rc
    if [[ "$deft" == __unset__ ]]; then
        out="$( cd "$d" && TRACKS="$tracks" bash -c "$BODY" 2>&1 )"; rc=$?
    else
        out="$( cd "$d" && TRACKS="$tracks" DEFAULT_TRACKS="$deft" bash -c "$BODY" 2>&1 )"; rc=$?
    fi
    printf '%s\n' "$out" > "$WORK/out"
    printf '%s' "$rc"
}
ran_count() { grep -c . < "$WORK/ran" || true; }

problems=(); n=0
check() { # check <label> <condition-as-string>
    n=$((n + 1))
    if eval "$2"; then :; else problems+=("$1 — rc=$RC, ran=$(ran_count), output: $(tr '\n' ' ' < "$WORK/out" | tail -c 200)"); fi
}

# THE ROW THIS FILE EXISTS FOR. TRACKS empty AND the fallback empty too — which is
# what a typo in the workflow's `env:` produces. Before the guard this printed
# nothing and exited 0.
RC="$(run_step "" "")"
check "an empty track list must FAIL, not finish green" '[[ "$RC" != 0 ]]'
check "...and must SAY so by name"                      'grep -q "no tracks ran" "$WORK/out"'
check "...having run nothing"                           '[[ "$(ran_count)" == 0 ]]'

# The fallback: empty input, real default. This is every pull_request and the weekly run.
RC="$(run_step "" "a b c")"
check "an empty input falls back to DEFAULT_TRACKS" '[[ "$RC" == 0 ]]'
check "...and runs all three of them"               '[[ "$(ran_count)" == 3 ]]'

# Whitespace is emptiness. `${TRACKS// /}` is what makes this true, and a plain
# `[[ -n "$TRACKS" ]]` would have passed the string through to a zero-iteration loop.
RC="$(run_step "   " "a b c")"
check "a whitespace-only input is treated as empty" '[[ "$RC" == 0 ]]'
check "...and also falls back"                      '[[ "$(ran_count)" == 3 ]]'

# An explicit list must win over the fallback.
RC="$(run_step "x y" "a b c")"
check "an explicit list is used verbatim"      '[[ "$RC" == 0 ]]'
check "...and the fallback does not run"       '[[ "$(ran_count)" == 2 ]] && grep -q "^x$" "$WORK/ran"'

# The loop must still report real failures — a guard that made everything pass would
# satisfy every row above.
RC="$(run_step "ok-1 fail-me ok-2" "a b c")"
check "a failing track fails the step"         '[[ "$RC" != 0 ]]'
check "...after running all three"             '[[ "$(ran_count)" == 3 ]]'

# A 77 is a warning here, not a pass and not a failure: the artifacts exist by now.
RC="$(run_step "skip-me" "a b c")"
check "a skipping track does not fail the step" '[[ "$RC" == 0 ]]'
check "...but is announced as a warning"        'grep -q "::warning::" "$WORK/out"'

# A bad name is refused before it reaches smoke-openbios.sh.
RC="$(run_step "Bad_Name" "a b c")"
check "an invalid track name is refused"        '[[ "$RC" != 0 ]]'
check "...naming the offending track"           'grep -q "refusing track name" "$WORK/out"'
check "...without running it"                   '[[ "$(ran_count)" == 0 ]]'

# DEFAULT_TRACKS missing entirely: `set -u` must make that loud too. A silent empty
# expansion here would put the job straight back into the shape being fixed.
RC="$(run_step "" __unset__)"
check "an unset DEFAULT_TRACKS fails loudly under set -u" '[[ "$RC" != 0 ]]'
check "...and runs nothing"                               '[[ "$(ran_count)" == 0 ]]'

if (( ${#problems[@]} )); then
    printf '  - %s\n' "${problems[@]}" >&2
    fail "$(printf '%d' "${#problems[@]}") of $n assertions failed against the SHIPPED 'Boot the tracks' step"
fi

# ── 3. the control: the pre-fix shape must fail these same assertions ──────────
# Without this, an all-clear is indistinguishable from a set of assertions that
# cannot fail. The shape is the one that shipped: no fallback, no count check.
LEGACY="$(printf '%s\n' \
    'set -u' \
    'cd examples/openbios-the-rival-that-shipped' \
    'rc=0' \
    'for t in $TRACKS; do' \
    '  timeout 60 ./smoke-openbios.sh "$t" >/dev/null 2>&1; r=$?' \
    '  case $r in 0) ;; 77) ;; *) rc=1 ;; esac' \
    'done' \
    'exit $rc')"
d="$WORK/legacy"; mkdir -p "$d/examples/openbios-the-rival-that-shipped"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/examples/openbios-the-rival-that-shipped/smoke-openbios.sh"
chmod +x "$d/examples/openbios-the-rival-that-shipped/smoke-openbios.sh"
lout="$( cd "$d" && TRACKS="" DEFAULT_TRACKS="a b c" bash -c "$LEGACY" 2>&1 )"; lrc=$?
if [[ "$lrc" == 0 ]] && ! grep -q "no tracks ran" <<<"$lout"; then
    note "control: the pre-fix shape exits 0 on an empty track list, silently — which is the defect  ✓"
else
    fail "CONTROL FAILED: the pre-fix shape did not reproduce the defect (rc=$lrc), so these assertions are not measuring the difference the fix makes"
fi

pass "the shipped 'Boot the tracks' step refuses an empty track list by name instead of exiting 0 having run nothing, falls back to DEFAULT_TRACKS on the empty input every pull_request and the weekly run produce, treats whitespace as empty, and still reports real track failures — $n assertions against the extracted step, with a control proving the pre-fix shape fails them"
