#!/usr/bin/env bash
# link_check.py must report a BROKEN #anchor — and must not invent one.
#
# WHY THIS EXISTS. Until 2026-08-05 `link_check.py` split the `#fragment` off every link
# and threw it away. It therefore answered "does the FILE exist?" while the CI step was
# named, and read as, "0 broken links". That is this repo's bug class #2 — a check that
# asserts a cheaper property than the one it stands for — and it is worse than a gap,
# because a missing anchor fails SILENTLY in a browser: you land at the top of the page
# and nothing anywhere says the link was wrong. Three real breaks were hiding behind the
# green when the fragment check was finally switched on, all of them the same shape:
#
#   §5 Spike 0            → the heading later gained "(SPARC)"
#   RUNBOOK.md#part-6     → the heading was never bare "Part 6"
#   "errata: seven …"     → the heading became "eight" and the anchor kept saying seven
#
# WHAT THIS TEST DOES, AND WHY IT IS NOT JUST A HAPPY PATH. An assertion never observed
# failing is not known to work. So the fixture below is built to make the checker BITE
# four times, on four different mechanisms, and to stay silent on eight things that are
# legitimately fine. Both halves are load-bearing: a checker that reports everything is as
# useless as one that reports nothing, and only the second half would catch that.
#
# The control for the control: the SAME fixture is re-run with `--no-anchors`, which must
# report ZERO. That is the pre-2026-08-05 behaviour reproduced on demand — proof that the
# four failures come from the anchor logic and not from some unrelated path check.
#
# The fixture is built in a temp dir OUTSIDE the repo on purpose. A tracked fixture full of
# deliberately-broken anchors would be swept up by the repo-wide run and fail CI forever.
#
# VERIFIED BY BREAKING link_check.py, three ways, and watching this file bite each time:
#
#   ignore the fragment again      → "exited 0 on a fixture with 4 broken anchors"
#   headings inside fences count   → "expected exactly 4 broken anchors, got 3"
#   collapse `--` to `-` in a slug → "1 link(s) in good.md were flagged"
#
# AND ONE INJECTION THAT PROVED NOTHING, recorded because it is the more useful half: the
# slug defect was first applied one line too early — collapsing repeated hyphens BEFORE
# spaces are turned into hyphens changes nothing, because at that point the em dash has left
# two SPACES, not two hyphens. The test passed, and a pass under a defect that never took
# effect is not evidence of anything. An injection has to be observed changing the behaviour
# before the assertion's silence means something.
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$TEST_DIR/../.." && pwd)"
LC="$REPO/tools/link_check.py"

_VERDICT=0
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
note() { printf '  - %s\n' "$*" >&2; }

WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" && -d "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

command -v python3 >/dev/null 2>&1 || skip "python3 not available"
[[ -f "$LC" ]] || skip "link_check.py not found at $LC"

WORK="$(mktemp -d)" || fail "could not create a temp dir for the fixture"
mkdir -p "$WORK/sub" || fail "could not create the fixture subdir"
: > "$WORK/script.sh"

# ── the fixture: eight anchors that must PASS ───────────────────────────────
# Each heading is here for a specific rule of GitHub's slug algorithm.
cat > "$WORK/good.md" <<'FIXTURE'
# Top

### I.9 The one-shot became a test, and the test's root path ran — **PASS**

## Dup

## Dup

## Café

<a id="pinned-by-hand"></a>

```text
# not-a-heading-inside-a-fence
```

- em dash deletes to TWO hyphens, apostrophe deletes to nothing, bold is rendered away:
  [a](#i9-the-one-shot-became-a-test-and-the-tests-root-path-ran--pass)
- a duplicate heading: first keeps the bare slug, second gets `-1`
  [b](#dup) [c](#dup-1)
- an explicit HTML id is a real anchor: [d](#pinned-by-hand)
- percent-encoded non-ASCII must decode: [e](#caf%C3%A9)
- a cross-file anchor: [f](other.md#other-heading)
- GitHub's line anchor on a non-Markdown blob is not a heading: [g](script.sh#L42)
- a directory has no headings: [h](sub/)
FIXTURE

cat > "$WORK/other.md" <<'FIXTURE'
# Other doc

## Other heading
FIXTURE

# ── the fixture: four anchors that must FAIL, four different mechanisms ─────
cat > "$WORK/bad.md" <<'FIXTURE'
# Bad

- the em-dash trap: one hyphen written where the slugger produces two
  [1](good.md#i9-the-one-shot-became-a-test-and-the-tests-root-path-ran-pass)
- a `#` comment inside a fenced block is not a heading and mints no anchor
  [2](good.md#not-a-heading-inside-a-fence)
- duplicate numbering stops at the number of duplicates
  [3](good.md#dup-2)
- and a plain same-document typo
  [4](#nope-nothing-here)
FIXTURE

run() { python3 "$LC" --root "$WORK" --links-only --json "$@" 2>/dev/null; }

# ── with anchor checking: exactly the four, and nothing else ────────────────
OUT="$(run)"; rc=$?
(( rc == 1 )) || fail "REGRESSION: link_check exited $rc on a fixture with 4 broken anchors — a broken anchor must fail the gate (expected 1)"

read -r n_broken n_from_good checked <<<"$(printf '%s' "$OUT" | python3 -c '
import json,sys
d = json.load(sys.stdin)
b = d["broken_links"]
print(len(b), sum(1 for x in b if x["doc"] == "good.md"), d["stats"]["anchors_checked"])
')" || fail "could not parse link_check --json output"

(( n_broken == 4 )) || fail "expected exactly 4 broken anchors, got $n_broken — the fixture pins 4 mechanisms, so any other count means one stopped being detected or a good link was falsely flagged"
(( n_from_good == 0 )) || fail "REGRESSION: $n_from_good link(s) in good.md were flagged — every anchor there is legitimate (em dash, duplicate heading, HTML id, percent-encoding, #L42, a directory); a checker that reports everything is as useless as one that reports nothing"
(( checked > 0 )) || fail "0 anchors were checked — the run is green because it looked at nothing, which is exactly the failure this test exists to prevent"
note "with anchors: rc=1, 4 broken (all in bad.md), $checked anchors actually verified"

for want in \
    'i9-the-one-shot-became-a-test-and-the-tests-root-path-ran-pass' \
    'not-a-heading-inside-a-fence' \
    'dup-2' \
    'nope-nothing-here'
do
    printf '%s' "$OUT" | grep -q -- "$want" \
        || fail "the broken anchor '#$want' was NOT reported — that detection mechanism has regressed"
done
note "all four mechanisms bit: em-dash, fenced-\`#\`, duplicate overshoot, plain typo"

# ── the control for the control: --no-anchors must report zero ──────────────
OUT2="$(run --no-anchors)"; rc2=$?
(( rc2 == 0 )) || fail "--no-anchors exited $rc2 on a fixture whose only defects are anchors — the 4 failures above must come from the anchor logic, not from a path check"
n2="$(printf '%s' "$OUT2" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["broken_links"]))')" \
    || fail "could not parse --no-anchors output"
(( n2 == 0 )) || fail "--no-anchors reported $n2 broken link(s); expected 0 — every path in the fixture exists"
note "--no-anchors: rc=0, 0 broken — the pre-2026-08-05 blindness, reproduced on demand"

# ── and the slug rule itself, asserted directly ─────────────────────────────
got="$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from link_check import github_slug
print(github_slug("I.9 The one-shot became a test, and the test'"'"'s root path ran — **PASS**"))
' "$REPO/tools")" || fail "could not import github_slug from link_check.py"
[[ "$got" == "i9-the-one-shot-became-a-test-and-the-tests-root-path-ran--pass" ]] \
    || fail "github_slug is wrong: got '$got' — the em dash must delete to TWO hyphens and 'test's' must become 'tests'"
note "github_slug: 'I.9 … test's … — **PASS**' → '$got'"

pass "link_check validates #anchors: 4 deliberate breaks caught, 8 legitimate anchors left alone, and --no-anchors proves the anchor logic is what bit"
