#!/usr/bin/env bash
# check-harness-net.sh <tests-dir> — prove one test directory's EXIT-trap safety net.
#
# Verdict: the net that directory's `lib.sh` provides actually fires when a test dies
# without a verdict, stays quiet when one was printed, still runs registered cleanup —
# and cannot be disarmed by a test installing an EXIT trap of its own.
#
# WHY THIS IS ONE SHARED IMPLEMENTATION. Every tests/ directory in this repo carries the
# same net, so a copy per directory is seven places for the same check to drift. Each
# directory ships a five-line `tests/test-harness-net.sh` that execs this with its own
# path, which keeps the check inside that suite's `run-all.sh` (and therefore inside CI)
# without duplicating it.
#
# WHY IT EXISTS AT ALL. The net has been in these libs since the phases were written,
# and on 2026-08-06 it was measured inert across the repo: in metal-as-a-service 23 of
# 36 tests had replaced it with `trap 'cleanup_sandboxes' EXIT` (bash keeps ONE EXIT
# trap per shell), and phases 1-5 and micro-linux had 76 tests with no net at all. None
# of that was visible from any run, because a safety net is only observable when
# something goes wrong — so nothing had ever exercised it. An assertion never seen
# failing is not known to work.
#
# THIS SCRIPT PROVIDES ITS OWN VERDICT HELPERS ON PURPOSE. It must not source the lib it
# is testing: a subject that supplies its own harness can report anything it likes.
set -uo pipefail

_VERDICT=0
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }
_on_exit() {            # the shape this script enforces, applied to itself
    local rc=$?
    rm -rf "${WORK:-}"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: check-harness-net.sh exited early (rc=%d) — no verdict was printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

DIR="${1:-}"
[[ -n "$DIR" && -d "$DIR" ]] || fail "usage: check-harness-net.sh <tests-dir> (got '${DIR:-}')"
DIR="$(cd -- "$DIR" && pwd)"
LIB="$DIR/lib.sh"
[[ -f "$LIB" ]] || fail "no lib.sh in $DIR — there is no shared net to check"
NAME="$(basename "$(dirname "$DIR")")"

WORK="$(mktemp -d)"

# ── 1. no test may install its own EXIT trap ───────────────────────────────
#
# ⚠️ THIS CHECK HAS NOW BEEN A LIAR TWICE, THE SAME WAY BOTH TIMES: a regex over a
# PHYSICAL LINE standing in for a question about a COMMAND.
#
#   2026-08-08 — anchored at `^[[:space:]]*trap`, so it never saw the repo's single most
#   common test opener, `tmp="$(mktemp -d)"; trap 'echo x' EXIT` — the trap after a
#   semicolon, on a line that begins with an assignment. It printed "no test overrides
#   lib.sh's EXIT trap" across six suites while **twenty** tests did.
#
#   2026-08-15 (REVIEW-phase1.md, P1-3) — the replacement matched `trap` and `EXIT` on ONE
#   line, and the fix's own comment advertised "mid-line included". But a trap whose body
#   spans lines puts them on different lines:
#
#       trap '
#           cleanup_target "$t_cli" "$n_cli"
#       ' EXIT
#
#   so it passed over phase1's test-cli-vs-config-parity.sh and phase4's and phase5's
#   test-inspect-json.sh — three tests with the net taken down — and printed a green ✓.
#
# Each rewrite widened the regex by one shape and was read as having answered the real
# question. The real question is not textual at all: **is `trap` run as a command here,
# with `EXIT` among its arguments?** So this is now a scanner over the shell's own
# lexical structure — quotes (which is what spans the lines), comments, heredocs and
# backslash-continuations — rather than a pattern over what a line looks like. A `trap`
# inside quotes is a string, a `trap` in a heredoc is data being written to a fixture,
# and neither is an installation.
#
# It is a bounded lexer, not a shell parser: it tracks quoting and command position, which
# is all that "is this token a command" needs. §1a below holds it to that by running it
# over both shapes it must catch and shapes it must not — see there for why.
_exit_trap_offenders() {   # FILE… → the name of each file that installs a `trap … EXIT`
    awk '
      # ── word boundary: decide what the completed word means ──────────────
      function endword(   w) {
          if (!inword) return
          w = word; word = ""; inword = 0
          if (intrap) {                       # we are inside a trap command argument list
              if (w == "EXIT" && !hit) { hit = 1; print FILENAME }
              if (w == "EXIT") intrap = 0
              return
          }
          if (cmdpos && w == "trap") { intrap = 1; cmdpos = 0; return }
          # Reserved words that introduce another command, so the NEXT word is again in
          # command position (`if x; then trap … EXIT; fi`).
          cmdpos = (w=="then"||w=="do"||w=="else"||w=="elif"||w=="{"||w=="}"||w=="!")
      }
      # ── end of line: ends the command, and opens any heredoc queued on it ─
      function nl() {
          endword(); intrap = 0; cmdpos = 1
          if (hd == "" && hqh < hqt) { hd = hq[hqh]; hdstrip = hqs[hqh]; hqh++ }
      }
      FNR == 1 { q=0; cmdpos=1; inword=0; word=""; intrap=0; hd=""; hqh=0; hqt=0; hit=0 }
      hit { next }                            # one report per file is enough
      {
          # Inside a heredoc body every line is data, not code, until the delimiter.
          if (hd != "") {
              t = $0; if (hdstrip) sub(/^\t+/, "", t)
              if (t == hd) { hd = ""; if (hqh < hqt) { hd=hq[hqh]; hdstrip=hqs[hqh]; hqh++ } }
              next
          }
          L = $0 "\n"; n = length(L); i = 1
          while (i <= n) {
              c = substr(L, i, 1)
              # Single quotes: everything is literal, INCLUDING the newline. This is the
              # state that carries a trap body across lines, and missing it is P1-3.
              if (q == 1) { if (c == "\047") q = 0; else word = word c; i++; continue }
              if (q == 2) {                   # double quotes: same, but backslash escapes
                  if (c == "\\") { i++; if (substr(L,i,1) != "\n") word = word substr(L,i,1); i++; continue }
                  if (c == "\"") q = 0; else word = word c
                  i++; continue
              }
              if (c == "\\") {                # a backslash-newline continues the command
                  i++
                  if (substr(L,i,1) != "\n") { word = word substr(L,i,1); inword = 1 }
                  i++; continue
              }
              if (c == "\047") { q = 1; inword = 1; i++; continue }
              if (c == "\"")   { q = 2; inword = 1; i++; continue }
              # `#` opens a comment only at the START of a word — `${x#y}` is not a comment.
              if (c == "#" && !inword) { nl(); break }
              if (c == " " || c == "\t") { endword(); i++; continue }
              if (c == "\n") { nl(); i++; continue }
              if (c == ";" || c == "&" || c == "|") { endword(); intrap = 0; cmdpos = 1; i++; continue }
              if (c == "(" || c == ")") { endword(); cmdpos = 1; i++; continue }
              # Heredoc: remember the delimiter now, skip its body from the next newline.
              if (c == "<" && substr(L,i+1,1) == "<" && substr(L,i+2,1) != "<") {
                  endword(); i += 2; hdstrip = 0
                  if (substr(L,i,1) == "-") { hdstrip = 1; i++ }
                  while (substr(L,i,1) == " " || substr(L,i,1) == "\t") i++
                  d = ""
                  while (i <= n) {
                      cc = substr(L, i, 1)
                      if (cc=="\n"||cc==" "||cc=="\t"||cc==";"||cc=="&"||cc=="|"||cc==")") break
                      if (cc=="\047"||cc=="\""||cc=="\\") { i++; continue }
                      d = d cc; i++
                  }
                  hq[hqt] = d; hqs[hqt] = hdstrip; hqt++; cmdpos = 0
                  continue
              }
              word = word c; inword = 1; i++
          }
      }
    ' "$@" 2>/dev/null
}

# ── 1a. THE SCANNER'S OWN CONTROLS — the part §1 never had ─────────────────
#
# Sections 2-6 below each prove themselves against a fixture. Section 1 did not, and
# section 1 is the one that has been wrong twice: a scan that matches nothing and a scan
# that is broken are the same green ✓. So the shapes it MUST catch and the shapes it MUST
# NOT are written out here and run on every invocation, in every suite, before it is
# pointed at real tests. Both directions matter — the 2026-08-08 anchor existed to dodge a
# false positive and bought a false negative twenty times its size, so widening this
# scanner must never again be a silent trade.
#
# Fixture bodies are inert (`echo …`) on purpose: this is test DATA that a scanner reads,
# and test data that names a destructive verb is one careless `source` away from being a
# live command.
mkdir -p "$WORK/scan"
_mk() { printf '%s\n' "$2" > "$WORK/scan/$1"; }

# MUST be caught — each is a real `trap … EXIT`, and each has been seen in this repo.
_mk caught-plain.sh      "trap 'echo bye' EXIT"
_mk caught-midline.sh    "tmp=\"\$(mktemp -d)\"; trap 'echo bye' EXIT"     # the 2026-08-08 miss
_mk caught-multiline.sh  "trap '
    echo one
    echo two
' EXIT"                                                                    # the 2026-08-15 miss
_mk caught-multi-dq.sh   "trap \"
    echo one
\" EXIT"
_mk caught-continued.sh  "trap cleanup \\
     EXIT"
_mk caught-disarm.sh     "trap - EXIT"                                     # clearing it also disarms
_mk caught-nested.sh     "if true; then trap 'echo bye' EXIT; fi"
_mk caught-signals.sh    "trap 'echo bye' INT TERM EXIT"
# MUST NOT be caught — every one of these is present in the repo today and is legitimate.
_mk clean-comment.sh     "# trap 'echo bye' EXIT   <- prose about the rule, not the rule"
_mk clean-grepped.sh     "grep -q '^trap reap EXIT' \"\$F\" || fail 'no trap'"
_mk clean-printfed.sh    "printf 'trap reap EXIT\\nexit 3\\n' >> \"\$F\""
_mk clean-heredoc.sh     "cat > \"\$F\" <<'SH'
trap 'echo bye' EXIT
SH"
_mk clean-return.sh      "trap 'echo bye' RETURN 2>/dev/null || true"      # RETURN is not EXIT
_mk clean-on-exit.sh     "on_exit 'echo bye'"
_mk clean-exit-in-body.sh "trap 'echo EXIT-was-here' INT"                  # EXIT inside the body
_mk clean-varname.sh     "EXIT_TRAP_INSTALLED=no; echo \"trap ... EXIT\""

mapfile -t _got < <(_exit_trap_offenders "$WORK"/scan/*.sh | xargs -r -n1 basename | sort)
mapfile -t _want < <(cd "$WORK/scan" && ls caught-*.sh | sort)
_missed=() _falsepos=()
for f in "${_want[@]}";  do [[ " ${_got[*]} "  == *" $f "*  ]] || _missed+=("$f");   done
for f in "${_got[@]}";   do [[ " ${_want[*]} " == *" $f "*  ]] || _falsepos+=("$f"); done
(( ${#_missed[@]} == 0 )) \
    || fail "$NAME: the EXIT-trap scanner is BLIND to ${#_missed[@]} shape(s) it must catch: ${_missed[*]}. A suite it is pointed at can take lib.sh's net down and still get a green ✓ from this check — which is what happened on 2026-08-08 and again on 2026-08-15"
(( ${#_falsepos[@]} == 0 )) \
    || fail "$NAME: the EXIT-trap scanner reports ${#_falsepos[@]} FALSE POSITIVE(s): ${_falsepos[*]}. These shapes are legitimate (a trap in a comment, in a quoted string, in a heredoc, or on a non-EXIT signal) and flagging them makes the rule unfollowable"
(( ${#_want[@]} >= 8 )) \
    || fail "$NAME: only ${#_want[@]} positive control(s) exist for the EXIT-trap scanner — an all-clear from a scan with nothing to find proves nothing"
mapfile -t _clean < <(cd "$WORK/scan" && ls clean-*.sh)
note "$NAME: the EXIT-trap scanner catches all ${#_want[@]} shapes that install one (mid-line, multi-line, continued, nested, \`trap - EXIT\`) and none of the ${#_clean[@]} that only mention one (comment, quoted, heredoc, RETURN)  ✓"

# ── 1b. …now point it at the real tests ────────────────────────────────────
mapfile -t OFFENDERS < <(_exit_trap_offenders "$DIR"/test-*.sh | xargs -r -n1 basename)
(( ${#OFFENDERS[@]} == 0 )) \
    || fail "$NAME: these tests install their own EXIT trap, which REPLACES lib.sh's safety net and leaves them able to die with no verdict line: ${OFFENDERS[*]}. Register cleanup with on_exit '<cmd>' instead"
_all=("$DIR"/test-*.sh)
note "$NAME: no test installs its own \`trap … EXIT\` — checked as a command, not as a line, so a trap whose body spans lines is seen too (${#_all[@]} files checked)  ✓"

# fixture <name> <body> — a throwaway test that sources the REAL lib.sh, so what is
# exercised is the shipped net and not a copy of it. Prints `rc:<n>` then the output.
fixture() {
    local name="$1" body="$2" rc out
    { printf 'source "%s"\n' "$LIB"; printf '%s\n' "$body"; } > "$WORK/$name.sh"
    out="$(bash "$WORK/$name.sh" 2>&1)"; rc=$?
    printf 'rc:%s\n%s\n' "$rc" "$out"
}

# ── 2. THE POSITIVE CASE: a test that dies without a verdict is reported ──
DIED="$(fixture died 'exit 3')"
grep -q '^rc:3$' <<<"$DIED" \
    || fail "$NAME: the fixture that exits 3 did not exit 3 — a broken harness, not a finding about the net. Note that an EXIT trap which runs a failing command under \`set -e\` can change the status. Got: $(tr '\n' ' ' <<<"$DIED")"
grep -q 'FAIL: test exited early (rc=3)' <<<"$DIED" \
    || fail "REGRESSION: $NAME's net is inert — a test that exited 3 with no verdict printed NO FAIL line, so any test that dies early leaves a blank terminal and a bare rc. Got: $(tr '\n' ' ' <<<"$DIED")"
note "$NAME: a test that dies with no verdict gets one: FAIL: test exited early (rc=3)  ✓"

# ── 3. and it says it exactly once ────────────────────────────────────────
FAILED="$(fixture failed 'fail "the specific defect"')"
grep -q '^rc:1$' <<<"$FAILED" || fail "$NAME: fail() did not exit 1: $(tr '\n' ' ' <<<"$FAILED")"
n="$(grep -c '^FAIL:' <<<"$FAILED")"
[[ "$n" == 1 ]] \
    || fail "REGRESSION: $NAME printed $n FAIL lines for one failure, not 1. The net is firing on top of a verdict that was already given, which is how a reader learns to skip past the line that names the actual defect. Got: $(tr '\n' ' ' <<<"$FAILED")"
grep -q 'FAIL: the specific defect' <<<"$FAILED" \
    || fail "$NAME: the single FAIL line was the net's generic one, not the specific message fail() was given"
note "$NAME: one failure prints exactly one FAIL line, and it is the specific one  ✓"

# ── 4. a pass and a skip stay silent ──────────────────────────────────────
PASSED="$(fixture passed 'pass "it worked"')"
grep -q '^rc:0$' <<<"$PASSED" || fail "$NAME: pass() did not exit 0: $(tr '\n' ' ' <<<"$PASSED")"
grep -q 'FAIL:' <<<"$PASSED" \
    && fail "REGRESSION: $NAME printed a FAIL line on a PASSING test — the net fires on success, which makes every green run look broken"
SKIPPED="$(fixture skipped 'skip "no hardware"')"
grep -q '^rc:77$' <<<"$SKIPPED" || fail "$NAME: skip() did not exit 77: $(tr '\n' ' ' <<<"$SKIPPED")"
grep -q 'FAIL:' <<<"$SKIPPED" \
    && fail "REGRESSION: $NAME printed a FAIL line on a SKIPPED test — a skip would be read as a failure by anything parsing the output"
note "$NAME: a pass exits 0 and a skip exits 77, neither printing a FAIL line  ✓"

# ── 5. registered cleanup runs, in reverse, on every path ─────────────────
# The net is worthless if adopting it lost the teardown. Reverse order matters: a later
# registration may depend on an earlier one still existing.
CLEAN="$(fixture cleaned "
on_exit 'echo CLEANUP-ONE'
on_exit 'echo CLEANUP-TWO'
exit 4")"
if ! grep -q 'CLEANUP-TWO' <<<"$CLEAN" || ! grep -q 'CLEANUP-ONE' <<<"$CLEAN"; then
    fail "$NAME: registered cleanup did not run when the test died (rc=4) — adopting the shared trap lost the teardown: $(tr '\n' ' ' <<<"$CLEAN")"
fi
[[ "$(grep -n 'CLEANUP-TWO' <<<"$CLEAN" | cut -d: -f1)" -lt "$(grep -n 'CLEANUP-ONE' <<<"$CLEAN" | cut -d: -f1)" ]] \
    || fail "$NAME: cleanup ran in registration order, not reverse — a teardown that depends on an earlier one having outlived it will break"
grep -q 'FAIL: test exited early (rc=4)' <<<"$CLEAN" \
    || fail "$NAME: the net did not fire on a test that died AFTER registering cleanup — cleanup must not be able to swallow the verdict"
CLEAN_OK="$(fixture cleaned_ok "on_exit 'echo CLEANUP-ON-PASS'
pass 'fine'")"
grep -q 'CLEANUP-ON-PASS' <<<"$CLEAN_OK" \
    || fail "$NAME: registered cleanup did not run on a PASSING test — scratch dirs would leak from every green run"
note "$NAME: cleanup runs in reverse on both the dying and the passing path, without swallowing the verdict  ✓"

# ── 6. cleanup can see the exit status ────────────────────────────────────
# A teardown that must know whether the run failed — keep the evidence, skip the
# tidy-up — would otherwise have to write its own `trap … EXIT` and take the net down
# with it. micro-cloud's DHCP-exhaustion test is exactly that case: it preserves its log
# directory on failure and removes it on success.
RCSEEN="$(fixture rcseen "on_exit 'echo SAW-RC=\$_EXIT_RC'
exit 5")"
grep -q 'SAW-RC=5' <<<"$RCSEEN" \
    || fail "$NAME: registered cleanup could not read the exit status as \$_EXIT_RC (expected SAW-RC=5). A teardown that needs it is pushed back into installing its own EXIT trap, which is the defect this whole shape removes. Got: $(tr '\n' ' ' <<<"$RCSEEN")"
RCOK="$(fixture rcok "on_exit 'echo SAW-RC=\$_EXIT_RC'
pass 'fine'")"
grep -q 'SAW-RC=0' <<<"$RCOK" \
    || fail "$NAME: \$_EXIT_RC was not 0 on a passing test, so a teardown keyed on it would take the failure path on every green run. Got: $(tr '\n' ' ' <<<"$RCOK")"
note "$NAME: registered cleanup reads the exit status as \$_EXIT_RC (5 on a die, 0 on a pass)  ✓"

pass "$NAME: lib.sh's EXIT net fires with a named rc when a test dies silently, stays quiet on pass/skip, prints exactly one FAIL line when the test already gave a verdict, still runs registered cleanup in reverse on every path — and no test in ${DIR#"$(cd "$DIR/../.." && pwd)/"} can disarm it by installing an EXIT trap of its own"
