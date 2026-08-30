#!/usr/bin/env bash
# test-harness-net-loop.sh — the CI loop that points check-harness-net.sh at every
# tests/ directory must actually enumerate all of them, and must refuse a stale
# exemption.
#
# WHY. TODO 15.1: the loop used to walk `git ls-files '*/tests/lib.sh'`, while
# check-harness-net.sh's FIRST check is whether a lib.sh exists at all. So a suite with
# no shared net was not a failing row — it was not a row, and four directories were
# invisible to CI for as long as the step had existed. The population was keyed on the
# very defect the checker exists to find, which is "a scan that matches nothing and a
# scan that is broken print the same green tick" one level up.
#
# The fix is an enumeration of DIRECTORIES plus a named-exemption file, and both halves
# can go quietly wrong: the enumeration can collapse, and the exemption file can rot into
# a blanket excuse. So this drives the SHIPPED step — sed'd out of ci.yml, never a copy —
# against a fixture repo, and asks five questions by running it:
#
#   1. does it enumerate every tests/ directory, including ones with NO lib.sh?
#   2. does a directory with no lib.sh and no exemption FAIL it? (the 15.1 defect itself)
#   3. does exempting that directory make it pass, and SAY it was not checked?
#   4. does an exemption naming a directory that does not exist fail, by name?
#   5. does an exemption naming a directory that HAS a lib.sh fail, by name?
#      (the second way an exemption rots: it outlives its reason, not its subject)
#
# Own verdict helpers on purpose: it must not source a suite's lib.sh — the same reason
# check-harness-net.sh provides its own.
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
        printf 'FAIL: test-harness-net-loop.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || fail "cannot cd to repo root"
CI=".github/workflows/ci.yml"
EXEMPT=".harness-net-exempt"
[[ -r "$CI"     ]] || fail "no $CI — this check has no subject"
[[ -r "$EXEMPT" ]] || fail "no $EXEMPT — the loop's exemption file is missing, so the loop this drives is not the shipped one"
command -v git >/dev/null 2>&1 || skip "git not available to enumerate the corpus"
WORK="$(mktemp -d)"

# ── the shipped step, extracted ─────────────────────────────────────────────────────────
# The range ends ON the next step's `- name:` line, so that line is dropped explicitly:
# left in, it is YAML in the middle of a bash script and the extraction "fails to parse"
# for a reason that has nothing to do with the step.
STEP="$(sed -n '/^      - name: the EXIT-trap safety net, in every tests\/ directory$/,/^      - name: /p' "$CI" \
        | grep -v '^      - name: ' \
        | sed -n '/^        run: |$/,$p' | sed '1d' | sed 's/^          //')"
[[ -n "$STEP" ]] || fail "could not extract the harness-net step from $CI — it was renamed or reindented, and this check would otherwise pass while testing NOTHING"
grep -q "check-harness-net.sh" <<<"$STEP" \
    || fail "the extracted step never calls check-harness-net.sh — the extraction picked up the wrong lines"
grep -q "harness-net-exempt" <<<"$STEP" \
    || fail "the extracted step does not read $EXEMPT — it is not the exemption-aware loop this drives"
bash -n <<<"$STEP" || fail "the extracted step does not parse as bash"

# ── a fixture repo: enough tests/ directories to clear the step's own floor ─────────────
# The floor exists so a collapsed enumeration cannot read as a clean pass; a fixture that
# does not clear it would fail for that reason instead of the one under test.
mk_repo() { # mk_repo <dir> <n-good-dirs> <n-netless-dirs>
    local d="$1" good="$2" netless="$3" i
    mkdir -p "$d/tools"
    cp "$ROOT/tools/check-harness-net.sh" "$d/tools/"
    for (( i=0; i<good; i++ )); do
        mkdir -p "$d/lab$i/tests"
        cp "$ROOT/phase7-firecracker/tests/lib.sh" "$d/lab$i/tests/lib.sh"
        printf '#!/usr/bin/env bash\n. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"\npass "ok"\n' \
            > "$d/lab$i/tests/test-ok.sh"
    done
    for (( i=0; i<netless; i++ )); do
        mkdir -p "$d/netless$i/tests"
        # No lib.sh at all: exactly the shape the old loop could not see.
        printf '#!/usr/bin/env bash\nprintf "PASS: standalone\\n" >&2\n' \
            > "$d/netless$i/tests/test-standalone.sh"
    done
    ( cd "$d" && git init -q . && git add -A >/dev/null 2>&1 \
        && git -c user.email=t@t -c user.name=t commit -qm x >/dev/null 2>&1 )
}

run_step() { # run_step <repo-dir> <exempt-file-content>
    local d="$1" content="$2" out rc
    printf '%s\n' "$content" > "$d/.harness-net-exempt"
    out="$( cd "$d" && bash -c "$STEP" 2>&1 )"; rc=$?
    printf 'rc:%s\n%s\n' "$rc" "$out"
}

REPO="$WORK/repo"; mk_repo "$REPO" 11 1
problems=()

# ── 1. it sees the netless directory at all ────────────────────────────────────────────
res="$(run_step "$REPO" "# nothing exempt")"
rc="${res%%$'\n'*}"; rc="${rc#rc:}"; body="${res#*$'\n'}"
checked="$(grep -oE 'checked [0-9]+ of [0-9]+' <<<"$body" | head -1)"
[[ -n "$checked" ]] \
    || problems+=("the step printed no 'checked N of M' ratio — a loop over nothing and a loop over everything both exit 0, which is why that line exists")
grep -q 'netless0/tests' <<<"$body" \
    || problems+=("CONTROL DID NOT FIRE: a tests/ directory with NO lib.sh does not appear in the step's output at all. That is TODO 15.1 exactly — it is not a failing row, it is not a row")
note "enumeration: ${checked:-<none>}, and the netless directory is in it  ✓"

# ── 2. …and FAILS on it ────────────────────────────────────────────────────────────────
[[ "$rc" != 0 ]] \
    || problems+=("CONTROL DID NOT FIRE: a tests/ directory with no shared EXIT net passed the loop unexempted. The population is still keyed on the defect")
note "an unexempted directory with no lib.sh fails the step (rc=$rc)  ✓"

# ── 3. exempting it passes, and the step SAYS what it did not check ────────────────────
res="$(run_step "$REPO" "netless0/tests  # a named UNKNOWN")"
rc="${res%%$'\n'*}"; rc="${rc#rc:}"; body="${res#*$'\n'}"
[[ "$rc" == 0 ]] \
    || problems+=("exempting the netless directory did not silence it (rc=$rc) — the exemption file is not being applied, so the one real entry in the shipped file is not working either: $(tail -2 <<<"$body" | tr '\n' ' ')")
grep -q 'NOT checked' <<<"$body" \
    || problems+=("an exempted directory was skipped SILENTLY — an exemption that is not printed is indistinguishable from a directory nobody enumerated, which is the failure this whole step was rewritten for")
grep -q 'netless0/tests' <<<"$body" \
    || problems+=("the 'NOT checked' line does not NAME the exempted directory")
note "exempting it passes, and the step names it as NOT checked  ✓"

# ── 4. an exemption naming a directory that does not exist must fail, by name ──────────
res="$(run_step "$REPO" "netless0/tests
lab-that-was-renamed-away/tests")"
rc="${res%%$'\n'*}"; rc="${rc#rc:}"; body="${res#*$'\n'}"
[[ "$rc" != 0 ]] \
    || problems+=("CONTROL DID NOT FIRE: an exemption naming a directory that does not exist was accepted. A stale entry then excuses something that moved while its replacement is checked by nobody")
grep -q 'lab-that-was-renamed-away' <<<"$body" \
    || problems+=("the stale-exemption failure does not NAME the offending entry")
note "an exemption naming a vanished directory fails, by name  ✓"

# ── 5. an exemption that has outlived its REASON must fail too ─────────────────────────
# The subtler rot: the directory still exists, but it has since gained a lib.sh — so it
# can be checked, and the entry is now hiding a directory nothing looks at. An exemption
# file that only checks existence would go green here forever.
res="$(run_step "$REPO" "netless0/tests
lab0/tests  # this one HAS a lib.sh")"
rc="${res%%$'\n'*}"; rc="${rc#rc:}"; body="${res#*$'\n'}"
[[ "$rc" != 0 ]] \
    || problems+=("CONTROL DID NOT FIRE: a directory that HAS a lib.sh was allowed to stay exempt. The exemption has outlived its reason, and nothing would ever say so")
grep -q 'lab0/tests' <<<"$body" \
    || problems+=("the outlived-reason failure does not NAME the offending entry")
note "an exemption for a directory that now HAS a lib.sh fails, by name  ✓"

# ── 6. the SHIPPED exemption file must be honest about the real repo ───────────────────
# Everything above runs against fixtures. This is the one assertion about what is actually
# committed: every entry names a real directory, and none of them has a lib.sh.
while read -r e; do
    [[ -z "$e" ]] && continue
    [[ -d "$ROOT/$e" ]]      || problems+=("the SHIPPED $EXEMPT names '$e', which is not a directory in this repo")
    [[ ! -f "$ROOT/$e/lib.sh" ]] || problems+=("the SHIPPED $EXEMPT excuses '$e', which now has a lib.sh and could be enrolled")
done < <(sed 's/#.*//' "$ROOT/$EXEMPT" | awk 'NF {print $1}')
n_exempt="$(sed 's/#.*//' "$ROOT/$EXEMPT" | awk 'NF' | wc -l)"
note "the shipped exemption file names $n_exempt directory/ies, all real, none enrollable  ✓"

if (( ${#problems[@]} )); then
    fail "$(printf '%d problem(s) with the harness-net CI loop:' "${#problems[@]}"; printf '\n  - %s' "${problems[@]}")"
fi

pass "the harness-net CI loop enumerates tests/ DIRECTORIES rather than lib.sh files — so a suite with no shared net is a failing row instead of no row at all (TODO 15.1) — prints the ratio it checked, names what it did not, and refuses an exemption that has outlived either its directory or its reason; each proved by running the step sed'd out of ci.yml, and the $n_exempt shipped exemption(s) re-derived against the real tree"
