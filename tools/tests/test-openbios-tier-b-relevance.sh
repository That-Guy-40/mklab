#!/usr/bin/env bash
# test-openbios-tier-b-relevance.sh — the Tier B path filter must be right in both
# directions, and must not silently stop covering what the lab depends on.
#
# WHY. tools/openbios-tier-b-relevant.sh decides whether a pull request pays three
# minutes to build and boot firmware. Wrong in one direction it burns minutes on
# every PR in the repo; wrong in the other it lets a change reach main without the
# only job that has ever exercised a cold checkout. The second direction is the
# expensive one and it is SILENT — a PR that skips Tier B looks exactly like a PR
# that did not need it.
#
# §0 drives the shipped script on must-match and must-not-match paths. §1 then
# re-derives the `tools/` half of the pattern list FROM THE LAB'S OWN SCRIPTS, so a
# lab that starts using a new repo tool fails here instead of quietly falling
# outside the filter. That is the CLAUDE.md rule applied to a trigger: the list is
# a cached fact, so something has to re-derive it.
#
# Own verdict helpers on purpose: sourcing a suite's lib.sh would let a subject
# supply its own harness.
set -uo pipefail

_V=0
skip() { _V=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _V=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _V=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }
_on_exit() {
    local rc=$?
    if (( rc != 0 && rc != 77 )) && (( _V == 0 )); then
        printf 'FAIL: test-openbios-tier-b-relevance.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="$ROOT/tools/openbios-tier-b-relevant.sh"
LAB="$ROOT/examples/openbios-the-rival-that-shipped"
[[ -x "$SUT" ]] || fail "tools/openbios-tier-b-relevant.sh is missing or not executable — the workflow calls it to decide whether to run Tier B"
[[ -d "$LAB" ]] || fail "$LAB is missing — §1 would re-derive nothing and pass vacuously"

problems=(); n_ok=0
# ask <expected> <label> <path>... — drive the SHIPPED script, assert what it prints.
ask() {
    local want="$1" label="$2"; shift 2
    local got
    got="$(printf '%s\n' "$@" | "$SUT")"
    if [[ "$got" == "$want" ]]; then
        n_ok=$((n_ok + 1))
    else
        problems+=("$label: expected '$want', got '$got' (paths: $*)")
    fi
}

# ── §0: must match ──────────────────────────────────────────────────────────────
ask true  "the lab's build driver"        examples/openbios-the-rival-that-shipped/build-openbios.sh
ask true  "the applied patch"             examples/openbios-the-rival-that-shipped/patches/TESTED-TREE.patch
ask true  "a smoke track"                 examples/openbios-the-rival-that-shipped/smoke-openbios.sh
ask true  "the pty console driver"        tools/drive-pty-repl.py
ask true  "the serial console driver"     tools/drive-serial-repl.py
ask true  "the pin checker"               tools/openbios-pin-check.sh
ask true  "the TESTED-TREE regenerator"   tools/openbios-regen-tested-tree.sh
ask true  "the workflow itself"           .github/workflows/openbios-tier-b.yml
ask true  "one relevant path among many"  README.md docs/x.md examples/openbios-the-rival-that-shipped/README.md CHANGELOG.md

# ── §0: must NOT match ──────────────────────────────────────────────────────────
# Each of these is a real neighbour, not an invented string: a sibling OpenBIOS lab
# that Tier B does not build, the repo root, another phase, another workflow.
ask false "the repo README"               README.md
ask false "a sibling openbios lab"        examples/openbios-clib-hello-to-emacs/build-firmware-x86.sh
ask false "the other IEEE 1275 lab"       examples/open-firmware-native-habitats/smoke-habitat.sh
ask false "an unrelated phase"            phase7-firecracker/lab-firecracker.sh
ask false "an unrelated tool"             tools/link_check.py
ask false "the main CI workflow"          .github/workflows/ci.yml
ask false "nothing changed at all"        ""

if (( ${#problems[@]} )); then
    printf '  - %s\n' "${problems[@]}" >&2
    fail "$(printf '%d' "${#problems[@]}") relevance decision(s) were wrong — the Tier B filter would run on the wrong PRs, or skip the right ones"
fi
note "§0: $n_ok relevance decisions correct (9 must-match, 7 must-not-match)"

# ── §1: the tools/ half of the list, re-derived from WHAT TIER B RUNS ───────────
# Scope matters here, and the first version of this section got it wrong in an
# instructive way: it derived from the whole lab and reported four checkers
# (check-patch-hygiene, -scope, -track-list, -usage-is-data) as uncovered. Those
# are run by the lab's tests/, which Tier B does not invoke and ci.yml already
# gates. Deriving from the lab answered a true thing that was not the question.
#
# The question is what the TIER B JOB runs. So the entry points are read out of the
# workflow itself, and the dependency derivation is scoped to those.
WF="$ROOT/.github/workflows/openbios-tier-b.yml"
[[ -f "$WF" ]] || fail "$WF is missing — §1 cannot learn what Tier B runs and would pass vacuously"
ENTRIES=()
for e in build-openbios.sh smoke-openbios.sh; do
    grep -qF -- "./$e" "$WF" || problems+=("§1: the workflow does not invoke ./$e, so this test's idea of Tier B's entry points has drifted from the job")
    ENTRIES+=("$LAB/$e")
done
if (( ${#problems[@]} )); then
    printf '  - %s\n' "${problems[@]}" >&2
    fail "the Tier B entry points named here are not the ones the workflow runs — every derivation below would be about the wrong scripts"
fi

# Those entry points reach repo tools as "$REPO/tools/NAME", and each is something
# Tier B RUNS, so a change to it can change what Tier B boots. An over-match here
# is safe (it only widens the filter); an under-match is the silent failure this
# section exists for.
mapfile -t DEPS < <(grep -rhoE '\$REPO/tools/[A-Za-z0-9._-]+' "${ENTRIES[@]}" 2>/dev/null \
                    | sed 's|^\$REPO/||' | sort -u)
if (( ${#DEPS[@]} == 0 )); then
    fail "§1 derived NO \$REPO/tools/... dependency from Tier B's entry points — either they stopped using repo tools or this derivation broke, and a check that derives nothing passes vacuously"
fi
uncovered=()
for d in "${DEPS[@]}"; do
    [[ "$(printf '%s\n' "$d" | "$SUT")" == true ]] || uncovered+=("$d")
done
if (( ${#uncovered[@]} )); then
    fail "Tier B runs $(printf '%d' "${#uncovered[@]}") repo tool(s) the filter does NOT cover: ${uncovered[*]} — a change to one of them would reach main without Tier B ever running"
fi
note "§1: all ${#DEPS[@]} repo tool(s) Tier B runs are covered by the filter — ${DEPS[*]}"
note "§1 scope: the lab's tests/ reach other checkers; those are ci.yml's to gate, not Tier B's — NOT covered here, by design"

# ── §1a: the derivation's own control ───────────────────────────────────────────
# §1 passing proves nothing unless an uncovered dependency would actually fail it.
# A tool the lab does not use, run through the same covered? test, must come back
# uncovered — otherwise §1's loop is answering `true` to everything.
if [[ "$(printf 'tools/link_check.py\n' | "$SUT")" == true ]]; then
    fail "CONTROL FAILED: an uncovered tool (tools/link_check.py) tested as covered, so §1 would pass no matter what the lab depends on"
fi
note "§1a control: an uncovered tool is reported uncovered by the same test §1 uses  ✓"

# ── §2: the GATE, which is the check that gets marked required ──────────────────
# It always reports, so it is the shape that can pass while proving nothing. The
# rows that must FAIL are the point of this section: a gate observed only on its
# happy path is indistinguishable from `exit 0`.
GATE="$ROOT/tools/openbios-tier-b-gate.sh"
[[ -x "$GATE" ]] || fail "tools/openbios-tier-b-gate.sh is missing or not executable — it is the required status check"

g_ok=0; g_bad=()
gate() { # gate <want-rc> <label> <changes> <relevant> <tier-b>
    local want="$1" label="$2"; shift 2
    "$GATE" "$@" >/dev/null 2>&1; local got=$?
    if [[ "$got" == "$want" ]]; then g_ok=$((g_ok + 1)); else g_bad+=("$label: expected rc=$want, got rc=$got ($*)"); fi
}
# the two that must pass, and only these two
gate 0 "Tier B ran and passed"                  success true  success
gate 0 "nothing relevant changed, so skipped"   success false skipped
# the silent one: a relevant change that never ran the job
gate 1 "relevant change but Tier B skipped"     success true  skipped
# the build actually broke
gate 1 "Tier B failed"                          success true  failure
gate 1 "Tier B cancelled"                       success true  cancelled
# the machinery itself broke — a gate must not open when its own inputs are junk
gate 1 "relevance job failed"                   failure ""    skipped
gate 1 "relevance job cancelled"                cancelled ""  skipped
gate 1 "relevance said false but Tier B ran"    success false success
gate 1 "empty relevance verdict"                success ""    skipped
gate 2 "wrong number of arguments"              success true

if (( ${#g_bad[@]} )); then
    printf '  - %s\n' "${g_bad[@]}" >&2
    fail "$(printf '%d' "${#g_bad[@]}") gate decision(s) were wrong — the required status check would open on a case it should refuse"
fi
note "§2: the gate is correct on $g_ok combinations — 2 pass, 7 refuse, 1 usage error (default-deny verified, not assumed)"

pass "the Tier B path filter decides correctly on $n_ok real paths in both directions, covers all ${#DEPS[@]} repo tool(s) Tier B actually runs (re-derived from the workflow's own entry points, with a control proving the derivation can fail), and the required gate refuses 8 of the 10 combinations it was driven with, passing only the 2 that were reasoned about"
