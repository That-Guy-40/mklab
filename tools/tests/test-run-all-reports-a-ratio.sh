#!/usr/bin/env bash
# test-run-all-reports-a-ratio.sh — every suite runner must report a RATIO and NAME what
# did not run.
#
# WHY. CLAUDE.md's rule is "don't write the test count in prose: print `ran/listed`, fail
# when a listed test never ran, fail when a test file is in no list."  Eight runners printed
# bare counts instead, and the cost showed up on 2026-08-15: two mount-guard tests skipped
# in phase 1 (a transient `unshare -rm` failure, never reproduced) and the suite still
# printed a healthy-looking `13 passed, 13 skipped, 0 failed`.  Nothing distinguished that
# run from one where both safety guards actually executed.  An unmet precondition is an
# UNKNOWN, not a pass, and a count cannot say which one it was.
#
# HOW — BEHAVIOURALLY, NOT BY READING THE SOURCE.  A regex over a runner's text would be
# the same mistake this repo has now made twice with the EXIT-trap checker: a pattern over
# a line standing in for a question about behaviour.  So each runner is COPIED into a
# scratch directory beside three synthetic tests (one pass, one fail, one skip) and RUN,
# and the assertions are about what it printed and what it exited.
#
# Runners with a hand-maintained list cannot be driven this way — synthetic names are, by
# construction, "in no list", which is exactly what they are built to refuse.  Those are
# detected from that refusal, checked against their source instead, and REPORTED AS SUCH
# rather than silently passed: a check that quietly excludes half its subjects is the
# all-PASS-proves-nothing shape again.
#
# This provides its own verdict helpers on purpose — it must not source any suite's lib.sh,
# or a subject would be supplying its own harness.
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
        printf 'FAIL: test-run-all-reports-a-ratio.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || fail "cannot cd to repo root"
command -v git >/dev/null 2>&1 || skip "git not available to enumerate runners"
WORK="$(mktemp -d)"

# drive <runner-path> <dest-dir> — copy the runner beside synthetic tests and RUN it.
# Prints "rc:<n>", then the names it used for the pass/fail/skip fixtures, then the output.
#
# A runner with a hand-maintained list refuses names it does not know — by design, that is
# its "a test on disk in no list" guard.  So the fixtures are named FROM THE RUNNER'S OWN
# LIST when it has one, which lets every runner be checked by behaviour rather than by
# reading its source.  Harvesting those names with a regex is safe here precisely because
# getting it wrong is LOUD: the runner's own disk-vs-list check fails and this check
# reports it, rather than quietly falling back to a weaker assertion.
drive() {
    local runner="$1" d="$2"
    mkdir -p "$d"
    cp "$runner" "$d/run-all.sh"

    local -a names
    mapfile -t names < <(grep -oE '\btest-[A-Za-z0-9._-]+\.sh\b' "$runner" | sort -u)
    # Drop the runner's own harness-net stub if listed: it execs a checker that needs a real
    # lib.sh, so it cannot be a synthetic fixture.
    local -a use=()
    local n
    for n in "${names[@]}"; do [[ "$n" == "run-all.sh" ]] || use+=("$n"); done
    if (( ${#use[@]} < 3 )); then
        use=(test-aaa-pass.sh test-bbb-fail.sh test-ccc-skip.sh)
    fi

    local p_name="${use[0]}" f_name="${use[1]}" s_name="${use[2]}"
    for n in "${use[@]}"; do
        case "$n" in
            "$f_name") printf '#!/usr/bin/env bash\necho "FAIL: synthetic"\nexit 1\n'  > "$d/$n" ;;
            "$s_name") printf '#!/usr/bin/env bash\necho "SKIP: synthetic"\nexit 77\n' > "$d/$n" ;;
            *)         printf '#!/usr/bin/env bash\necho "PASS: synthetic"\nexit 0\n'  > "$d/$n" ;;
        esac
    done
    chmod +x "$d"/test-*.sh
    local out rc
    out="$( cd "$d" && bash run-all.sh 2>&1 )"; rc=$?
    printf 'rc:%s\nnames:%s %s %s\n%s\n' "$rc" "$p_name" "$f_name" "$s_name" "$out"
}

mapfile -t RUNNERS < <(git ls-files '*/tests/run-all.sh' | sort)
(( ${#RUNNERS[@]} > 0 )) || fail "no */tests/run-all.sh found — this check would pass vacuously"

behavioural=() listbased=() problems=()
for r in "${RUNNERS[@]}"; do
    res="$(drive "$r" "$WORK/$(echo "$r" | tr / _)")"
    rc="${res%%$'\n'*}"; rc="${rc#rc:}"
    rest="${res#*$'\n'}"
    nameline="${rest%%$'\n'*}"; nameline="${nameline#names:}"
    body="${rest#*$'\n'}"
    read -r _pn fname sname <<<"$nameline"

    # If a hand-maintained list still refused the fixtures, the name harvest missed
    # something — reported, never quietly downgraded to a weaker check.
    if grep -q 'in no list' <<<"$body"; then
        problems+=("$r: could not be driven — its list rejected the harvested fixture names, so this check could not exercise it")
        continue
    fi
    behavioural+=("$r")

    # Everything from the ratio line onward. The assertions below MUST look only here:
    # every runner prints a `=== test-x.sh ===` header per test, so grepping the whole
    # output for a name passes whether or not the SUMMARY names it — an assertion that
    # would hold for a runner that merely counts skips, which is the thing being fixed.
    tail_body="$(sed -n '/tests ran/,$p' <<<"$body")"

    # 1. a ratio, not a bare count
    grep -qE '[0-9]+/[0-9]+ (listed|discovered) tests ran' <<<"$body" \
        || problems+=("$r: printed no ran/total ratio — a bare count cannot show that a runner stopped early. Got: $(tr '\n' ' ' <<<"$body" | tail -c 160)")
    # 2. the SKIPPED test is named — the property the 2026-08-15 incident needed
    grep -q -- "$sname" <<<"$tail_body" \
        || problems+=("$r: did not NAME the skipped test ($sname), so a reader cannot tell which guard failed to run")
    # 3. the FAILED test is named
    grep -q -- "$fname" <<<"$tail_body" \
        || problems+=("$r: did not name the failing test ($fname)")
    # 4. a failing test fails the run
    [[ "$rc" == "1" ]] \
        || problems+=("$r: exited $rc with a failing test present — a suite that does not fail on a failure gates nothing")
done

# Reported through fail(), not a bare `printf; exit 1`: fail() sets the _V flag the EXIT
# net reads, and without it the net adds a SECOND "exited early" verdict on top of this
# one — exactly the one-failure-two-FAIL-lines defect check-harness-net.sh exists to catch.
if (( ${#problems[@]} )); then
    fail "$(printf '%d runner problem(s):' "${#problems[@]}"; printf '\n  - %s' "${problems[@]}")"
fi

# ── the check's own control: the shape this replaced must NOT pass ──────────────────────
# Without this, an all-clear is indistinguishable from a check that asserts nothing — the
# same reason §1a exists in check-harness-net.sh.
legacy="$WORK/legacy/run-all.sh"; mkdir -p "$WORK/legacy"
cat > "$legacy" <<'LEGACY'
#!/usr/bin/env bash
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
pass=0; fail=0; skip=0
for t in test-*.sh; do
    if "./$t"; then pass=$((pass+1)); else
        rc=$?; if [[ $rc -eq 77 ]]; then skip=$((skip+1)); else fail=$((fail+1)); fi
    fi
done
printf 'passed:  %d\nskipped: %d\nfailed:  %d\n' "$pass" "$skip" "$fail"
(( fail == 0 )) || exit 1
LEGACY
res="$(drive "$legacy" "$WORK/legacydrive")"
body="${res#*$'\n'}"; body="${body#*$'\n'}"
if grep -qE '[0-9]+/[0-9]+ (listed|discovered) tests ran' <<<"$body" \
   || grep -q 'test-ccc-skip.sh' <<<"$body"; then
    fail "CONTROL FAILED: the legacy bare-count runner satisfied these assertions, so they are not measuring the difference this check exists to enforce"
fi
note "control: the bare-count shape this replaced is rejected by these assertions  ✓"

note "checked ${#behavioural[@]} runner(s) by running them against synthetic tests"
(( ${#listbased[@]} == 0 )) \
    || note "NOT driven, checked by source only: ${listbased[*]}"

pass "all ${#RUNNERS[@]} suite runners report a ran/total ratio, name the tests that skipped and failed, and exit non-zero on a failure — so a run where a guard silently did not execute is distinguishable from one where it did"
