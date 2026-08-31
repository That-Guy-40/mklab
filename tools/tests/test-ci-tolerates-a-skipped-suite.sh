#!/usr/bin/env bash
# test-ci-tolerates-a-skipped-suite.sh — the CI step that runs every suite must tolerate a
# suite that exits 77 (wholesale skip), CONTINUE to the suites after it, still fail on a
# real failure, and surface what skipped as one annotation.
#
# WHY.  TODO §11.1.  The example-lab loop in `.github/workflows/ci.yml` used to read:
#
#     bash "$t"; r=$?
#     [ "$r" -eq 0 ] || [ "$r" -eq 77 ] || rc=1
#
# GitHub's default shell is `bash -e {0}`, and under errexit `cmd; r=$?` never reaches the
# assignment — the step dies with the raw status.  So the 77 that line exists to permit
# killed the step instead, and every suite after it in the loop silently never ran.  #267
# repaired it to `|| r=$?`, which is errexit-exempt.
#
# But the repair has never executed in production: no suite has yet exited 77 wholesale on a
# runner, so the tolerant branch has never been taken there.  A fix nobody has watched work
# is not known to work — this repo's own rule, pointed at its own pipeline.  This check runs
# on every push and takes the branch deliberately.
#
# HOW — BEHAVIOURALLY, AND AGAINST THE SHIPPED CODE.  `run_suite` is sed'd out of `ci.yml`
# rather than re-implemented here: a copy would drift from its subject and then prove
# something about the copy.  It is driven under `bash -e` AND `bash -eo pipefail` (the two
# shapes GitHub uses depending on whether a step names `shell:`) against synthetic suites
# that exit 0, 77 and 1, and the assertions are about what the step PRINTED and EXITED —
# not what its source looks like, which is the mistake tools/check-harness-net.sh §1 made
# twice.
#
# Its controls are §5: the pre-#267 shape must FAIL these assertions, and a run_suite with
# the annotation block removed must fail the annotation assertion.  Without them an
# all-clear here is indistinguishable from a check that asserts nothing.
#
# Own verdict helpers on purpose: sourcing a suite's lib.sh would let a subject supply its
# own harness.
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
        printf 'FAIL: test-ci-tolerates-a-skipped-suite.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
[[ -r "$CI" ]] || fail "cannot read $CI — this check has no subject"
WORK="$(mktemp -d)"

# ── 1. extract the shipped code ────────────────────────────────────────────────────────
# The step's `run: |` block is indented 10 spaces; the function's own closing brace is the
# only line that is exactly that indent followed by `}`.  Dedent so it can be sourced.
DEDENT='s/^          //'
RUN_SUITE="$(sed -n '/^          run_suite() {$/,/^          }$/p' "$CI" | sed "$DEDENT")"
ANNOT="$(sed -n '/^          if \[ -n "\$skipped_report" \]; then$/,/^          fi$/p' "$CI" | sed "$DEDENT")"

# A scan that matches nothing and a scan that works print the same green ✓.  Refuse to
# proceed on an empty extraction rather than passing vacuously.
[[ -n "$RUN_SUITE" ]] || fail "could not extract run_suite() from ci.yml — the step was renamed, reindented or removed, and this check would otherwise pass while testing NOTHING"
[[ -n "$ANNOT" ]]     || fail "could not extract the skipped-report annotation block from ci.yml — same problem: an empty extraction proves nothing"
grep -q 'bash "\$cmd"' <<<"$RUN_SUITE" || fail "the extracted run_suite() does not invoke a suite — extraction picked up the wrong lines"
# Deliberately NOT `grep -q 77`. A first draft had one, and a mutant that deleted the
# tolerance line entirely tripped it — reporting "extraction picked up the wrong lines"
# for a defect that was nothing of the sort. A checker whose message names the wrong cause
# is the liar this repo fixes first; whether 77 is tolerated is section 4a's question, and
# 4a answers it by running the thing.
bash -n <<<"$RUN_SUITE" || fail "the extracted run_suite() does not parse as bash"
note "extracted run_suite() ($(wc -l <<<"$RUN_SUITE") lines) and the annotation block from ci.yml — the shipped text, not a copy"

# ── 2. synthetic suites ────────────────────────────────────────────────────────────────
S="$WORK/suites"; mkdir -p "$S"
# Every test skipped: what a suite prints when its whole precondition set is absent.  This
# is the case the repaired branch exists for and the one no runner has yet produced.
cat > "$S/all-skip.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP: needs root"
echo "SKIP: needs a container engine"
printf '\nskipped — these did NOT run (see each SKIP line above for why):\n' >&2
printf '  %s\n' test-needs-root.sh test-needs-engine.sh >&2
echo "summary: 2/2 listed tests ran — 0 passed, 2 skipped, 0 failed"
exit 77
EOF
cat > "$S/ok.sh" <<'EOF'
#!/usr/bin/env bash
echo "summary: 3/3 listed tests ran — 3 passed, 0 skipped, 0 failed"
exit 0
EOF
cat > "$S/partial-skip.sh" <<'EOF'
#!/usr/bin/env bash
printf '\nskipped — these did NOT run (see each SKIP line above for why):\n' >&2
printf '  %s\n' test-needs-kvm.sh >&2
echo "summary: 4/4 listed tests ran — 3 passed, 1 skipped, 0 failed"
exit 0
EOF
cat > "$S/fails.sh" <<'EOF'
#!/usr/bin/env bash
printf '\nfailed:\n  test-broken.sh\n' >&2
echo "summary: 2/2 listed tests ran — 1 passed, 0 skipped, 1 failed"
exit 1
EOF
# The sentinel: it can only appear if the LOOP REACHED THE SUITE AFTER the one under test.
# That, not the step's exit code, is the property #267 restored.
cat > "$S/later.sh" <<'EOF'
#!/usr/bin/env bash
echo "SENTINEL-THE-LOOP-CONTINUED"
exit 0
EOF
chmod +x "$S"/*.sh

# ── 3. build a step out of the shipped function ────────────────────────────────────────
# build_step <dest> <run_suite-text> [<annot-text>] — same skeleton as the real step:
# rc/skipped_report init, the function, a loop over the suites named on argv, the
# annotation, `exit $rc`.
build_step() {
    local dest="$1" fn="$2" annot="${3-}"
    {
        echo 'rc=0'
        echo 'skipped_report=""'
        printf '%s\n' "$fn"
        echo 'for s in "$@"; do run_suite "$(basename "$s" .sh)" "$s"; done'
        [[ -n "$annot" ]] && printf '%s\n' "$annot"
        echo 'exit $rc'
    } > "$dest"
}
build_step "$WORK/step.sh" "$RUN_SUITE" "$ANNOT"

# build_strict_step <dest> <run_suite-text> — the same skeleton, but every suite is driven
# with the third `strict` argument, which is what ci.yml passes for a suite whose
# preconditions the job installs itself.
build_strict_step() {
    local dest="$1" fn="$2"
    {
        echo 'rc=0'
        echo 'skipped_report=""'
        printf '%s\n' "$fn"
        echo 'for s in "$@"; do run_suite "$(basename "$s" .sh)" "$s" strict; done'
        echo 'exit $rc'
    } > "$dest"
}
build_strict_step "$WORK/strict.sh" "$RUN_SUITE"

# drive <step> <mode> <suite...> — run the step the way GitHub does and report rc + output.
OUT=""; RC=0
drive() {
    local step="$1" mode="$2"; shift 2
    # shellcheck disable=SC2086   # $mode is a deliberate flag split ("-e" vs "-eo pipefail")
    OUT="$(bash $mode "$step" "$@" 2>&1)"; RC=$?
}

problems=()
check() { local cond="$1"; shift; eval "$cond" || problems+=("$*"); }

# ── 4. the assertions, under both shells GitHub uses ───────────────────────────────────
for MODE in "-e" "-eo pipefail"; do
    m="bash $MODE"

    # 4a. a suite that skips WHOLESALE is tolerated, and the loop goes on.
    drive "$WORK/step.sh" "$MODE" "$S/all-skip.sh" "$S/later.sh"
    check '[[ "$RC" == 0 ]]' \
        "$m: a suite exiting 77 failed the step (rc=$RC) — the skip tolerance is dead code again"
    check 'grep -q SENTINEL-THE-LOOP-CONTINUED <<<"$OUT"' \
        "$m: the suite AFTER the 77 never ran — a wholesale skip still silently truncates the loop, which is the #267 defect"
    check '[[ "$(grep -c "::endgroup::" <<<"$OUT")" == 2 ]]' \
        "$m: ::group:: was left open across the 77 — later output would be folded into the skipped suite's collapsed group"

    # 4b. a real FAILURE still fails the step — and still does not truncate the loop.
    drive "$WORK/step.sh" "$MODE" "$S/fails.sh" "$S/later.sh"
    check '[[ "$RC" == 1 ]]' \
        "$m: a suite exiting 1 did not fail the step (rc=$RC) — the tolerance is too wide and CI gates nothing"
    check 'grep -q SENTINEL-THE-LOOP-CONTINUED <<<"$OUT"' \
        "$m: the suite after a FAILING one never ran — one red suite would hide the state of every suite behind it"

    # 4c. the annotation names what skipped, on ONE line, for every suite that skipped.
    drive "$WORK/step.sh" "$MODE" "$S/partial-skip.sh" "$S/all-skip.sh" "$S/ok.sh"
    ann="$(grep '^::warning::' <<<"$OUT" || true)"
    check '[[ -n "$ann" ]]' \
        "$m: no ::warning:: annotation although two suites named skipped tests — what did not run stays invisible behind a green tick"
    check '[[ "$(grep -c "^::warning::" <<<"$OUT")" == 1 ]]' \
        "$m: emitted more than one annotation — GitHub shows only the first few per step, so a per-suite list is truncated silently"
    check 'grep -q "test-needs-kvm.sh" <<<"$ann" && grep -q "test-needs-root.sh" <<<"$ann"' \
        "$m: the annotation does not NAME the skipped tests from both suites — a count cannot say which guard went unexercised. Got: $ann"
    check 'grep -q "partial-skip" <<<"$ann" && grep -q "all-skip" <<<"$ann"' \
        "$m: the annotation does not label which suite each skip came from. Got: $ann"

    # 4d. …and stays quiet when nothing skipped.  Without this, 4c would hold for an
    # annotation that fires unconditionally, which would say nothing at all.
    drive "$WORK/step.sh" "$MODE" "$S/ok.sh" "$S/later.sh"
    check '[[ "$RC" == 0 ]]' "$m: a clean run exited $RC"
    check '! grep -q "^::warning::" <<<"$OUT"' \
        "$m: annotated skipped rows on a run where nothing skipped — an annotation that always fires carries no information"

    # 4e. STRICT: a suite whose preconditions CI installs itself must go RED when it skips.
    # partial-skip.sh EXITS 0 and names a skipped test — the sneaky shape, and exactly what
    # examples/air-gapped-install/ did on its first CI run: green, with both tests that make
    # a claim unexecuted.
    drive "$WORK/strict.sh" "$MODE" "$S/partial-skip.sh" "$S/later.sh"
    check '[[ "$RC" == 1 ]]' \
        "$m: strict did NOT fail the step on a suite that skipped a test while exiting 0 (rc=$RC) — the quiet all-skip this argument exists to catch stays green"
    check 'grep -q "^::error::" <<<"$OUT"' \
        "$m: strict failed the step with no ::error:: — a red tick with no reason is a bug report nobody can act on"
    check 'grep -q "test-needs-kvm.sh" <<<"$OUT"' \
        "$m: the strict error does not NAME the test that did not run — a count cannot say which guard went unexercised"
    check 'grep -q SENTINEL-THE-LOOP-CONTINUED <<<"$OUT"' \
        "$m: strict truncated the loop — one strict suite would hide the state of every suite behind it"

    # 4f. …and must stay quiet on a suite that skipped nothing, or it carries no information.
    drive "$WORK/strict.sh" "$MODE" "$S/ok.sh"
    check '[[ "$RC" == 0 ]]' \
        "$m: strict failed a suite that skipped nothing (rc=$RC) — a gate that always fires is not a gate"
    check '! grep -q "^::error::" <<<"$OUT"' \
        "$m: strict emitted an ::error:: for a clean suite"

    # 4g. THE NON-REGRESSION, and the one that matters most: a NON-strict suite must keep
    # tolerating the identical input. Twelve suites here legitimately skip on this runner;
    # if strict leaked into the default they would all go red at once.
    drive "$WORK/step.sh" "$MODE" "$S/partial-skip.sh"
    check '[[ "$RC" == 0 ]]' \
        "$m: a NON-strict suite that skipped a test now fails the step (rc=$RC) — strict leaked into the default, and every suite that legitimately skips on this runner goes red"
done

# ── 5. the controls: these assertions must be able to fail ─────────────────────────────
# 5a. the pre-#267 shape.  `|| r=$?` -> `; r=$?`, nothing else changed.
# Replace only the `|| r=$?` fragment, and NOT the whole redirection line: in ${v/pat/repl}
# an unescaped `&` in the REPLACEMENT expands to the matched text, so a replacement
# containing `2>&1` silently splices the match back into itself. That is what the first
# draft did — and 5a caught it, reporting that the "legacy" shape survived a 77, because
# what it had actually built was a mangled line that never ran. A control earning its
# keep on its first execution by failing.
legacy="${RUN_SUITE/|| r=\$?/; r=\$?}"
if [[ "$legacy" == "$RUN_SUITE" ]]; then
    # Not a hard exit: §4's findings are the reason anyone reads this, and exiting here
    # would print a note about the control while swallowing them.
    problems+=("CONTROL COULD NOT BE BUILT: run_suite() no longer contains the errexit-exempt '|| r=\$?', so the pre-#267 shape cannot be re-injected and section 4a is unproven")
else
    build_step "$WORK/legacy.sh" "$legacy" "$ANNOT"
    drive "$WORK/legacy.sh" "-e" "$S/all-skip.sh" "$S/later.sh"
    if [[ "$RC" == 0 ]] && grep -q SENTINEL-THE-LOOP-CONTINUED <<<"$OUT"; then
        problems+=("CONTROL DID NOT FIRE: the pre-#267 '; r=\$?' shape survived a 77 too (rc=$RC, loop continued), so 4a is not measuring the difference #267 made")
    else
        note "control: the pre-#267 '; r=\$?' shape dies at the 77 (rc=$RC) and the later suite never runs  ✓"
    fi
fi

# 5b. an annotation block that is simply absent must fail 4c.
build_step "$WORK/noannot.sh" "$RUN_SUITE" ""
drive "$WORK/noannot.sh" "-e" "$S/all-skip.sh"
if grep -q '^::warning::' <<<"$OUT"; then
    problems+=("CONTROL DID NOT FIRE: an annotation appeared with the annotation block removed, so 4c is asserting something other than what it claims")
else
    note "control: with the annotation block removed, no ::warning:: appears  ✓"
fi

# 5c. remove the strict branch and 4e must stop firing. Built by DELETING the block rather
# than by ${v/pat/repl}: the replacement form is what 5a's comment above warns about, and an
# `&` or a backslash inside this block would splice the match into itself.
nostrict="$(awk '/if \[ -n "\$strict" \]/ {skip=1} skip && /^[[:space:]]*fi$/ {skip=0; next} !skip' <<<"$RUN_SUITE")"
if [[ "$nostrict" == "$RUN_SUITE" ]]; then
    problems+=("CONTROL COULD NOT BE BUILT: run_suite() no longer contains an 'if [ -n \"\$strict\" ]' block, so the strict gate cannot be re-injected and sections 4e-4f are unproven")
else
    build_strict_step "$WORK/nostrict.sh" "$nostrict"
    drive "$WORK/nostrict.sh" "-e" "$S/partial-skip.sh"
    if [[ "$RC" == 0 ]] && ! grep -q '^::error::' <<<"$OUT"; then
        note "control: with the strict branch removed, a skipping suite goes green again (rc=$RC, no ::error::)  ✓"
    else
        problems+=("CONTROL DID NOT FIRE: with the strict branch deleted the step STILL failed or annotated a skipping suite (rc=$RC), so 4e is measuring something other than the strict gate")
    fi
fi

if (( ${#problems[@]} )); then
    fail "$(printf '%d problem(s) in the CI suite loop:' "${#problems[@]}"; printf '\n  - %s' "${problems[@]}")"
fi

pass "ci.yml's run_suite tolerates a suite that exits 77 wholesale and CONTINUES the loop, still fails the step on a real failure, names every skipped test in exactly one annotation, and — for a suite marked 'strict', whose preconditions the job installs itself — goes RED with a naming ::error:: when it skips while leaving every non-strict suite's tolerance intact; under bash -e and bash -eo pipefail, with the pre-#267 shape AND a strict-branch-deleted shape each shown to fail the assertions they are supposed to"
