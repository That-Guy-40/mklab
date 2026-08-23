#!/usr/bin/env bash
# Verdict: no test gates a verdict on `producer | grep -q …` — the shape that has now
# produced five recorded defects in this repo, two of them red CI runs on main.
#
# WHY THIS IS A CHECK AND NOT A COMMENT. The shape has been explained in `fabric.sh`
# ("NOT `ip … | grep -q inet`"), in the plan (§6's `mke2fs -h`), and in two `tests/lib.sh`
# headers. It came back anyway — twice on 2026-08-07, in tests written the same day as the
# fix. A comment is read by whoever is already looking; a check is read by whoever is about
# to add the sixth.
#
# ── WHAT IS ACTUALLY WRONG WITH IT ──────────────────────────────────────────────────────
#
# `grep -q` exits on its FIRST match and closes the pipe. The producer, still writing, dies
# on SIGPIPE (141). With `pipefail` set — every tests/lib.sh here sets it — the PIPELINE
# reports 141, so:
#
#   producer | grep -q X || fail "…"     a match that WAS found reports absent  (noisy)
#   producer | grep -q X && fail "…"     a match that WAS found reports NOTHING (silent)
#
# The second is the dangerous one, and it was live in three teardown assertions:
# "container still present after destroy" could not fire. Measured, not reasoned:
# `producer | grep -qx name` over 200k lines returns **141**, and the `&& fail` never runs.
#
# THE FIX IS ALWAYS THE SAME: capture, then test. `has_line`/`has_match` for immediate
# state, `await_line`/`await_match` for eventual presence, `await_absent` for eventual
# absence — all in the phase libs.
#
# ── WHAT IS ALLOWED ─────────────────────────────────────────────────────────────────────
#
# A pipe into `grep -q` is fine when it is NOT gating a verdict — a precondition `skip`, or
# a plain `if`. COMMENTS are skipped too: this file and several lib headers quote the shape
# as prose in order to explain it, and a checker that cannot tell an example from an
# instance flags its own documentation (it did, on the first run).
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"
cd "$REPO" || exit 2

# Its own verdict helpers ON PURPOSE: it must not source a lib it is auditing, or the
# subject would be supplying its own harness.
_V=0
pass() { _V=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
fail() { _V=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
note() { printf '  - %s\n' "$*" >&2; }
# shellcheck disable=SC2154  # rc IS assigned, by the `rc=$?` at the start of this same
# single-quoted trap body; shellcheck analyses the string without carrying the assignment
# into the uses that follow it.
trap 'rc=$?; (( rc != 0 && rc != 77 )) && (( _V == 0 )) && printf "FAIL: exited early (rc=%d) with no verdict\n" "$rc" >&2' EXIT

DIRS=(phase1-chroot/tests phase2-qemu-vm/tests phase3-docker/tests phase4-podman/tests
      phase5-lxd/tests phase7-firecracker/tests netboot/tests
      examples/micro-cloud/tests examples/metal-as-a-service/tests
      examples/nested-calico-sandbox/tests)

# ── WHAT THIS GATES ON, AND WHY IT IS NARROWER THAN THE SHAPE ──────────────
#
# The first version of this check flagged EVERY pipe into `grep -q` that touched a verdict:
# 30 hits repo-wide, and most were harmless — `grep -q PATTERN "$FILE"` (no pipe at all), or
# `printf '%s' "$var" | grep -q` where the producer finishes long before grep exits. Failing
# on all of them would have created steady pressure to add exemptions until the check meant
# nothing, which is the blanket-replace this work exists to avoid.
#
# So it gates on the direction that fails **SILENTLY**:
#
#     producer | grep -q X && fail "…"
#
# When the producer is SIGPIPE'd, `pipefail` makes the pipeline non-zero and `&& fail` never
# runs — a missed failure, reported as a pass.
#
# ── 2026-08-16: THE NOISY FORM IS NOW GATED TOO, AND THE REASON IT WASN'T WAS WRONG ─────
#
# This file used to inventory `producer | grep -q X || fail` without failing on it, on the
# stated grounds that it "only bites with a producer large enough to fill a pipe buffer".
# That premise is false, and it was reasoning rather than measurement.
#
# The 64 KiB threshold applies to a producer that writes its output in ONE write(2) — real
# `docker ps` does, which is why the driver-side gates were latent. A producer that STREAMS
# is still writing after grep exits no matter how little it ends up producing. Measured on
# `tar tzvf` over a **13 KB** listing (a fifth of the pipe buffer):
#
#     tar tzvf f.tgz | grep -q 'x ->'      → 140 spurious failures in 200 runs
#     out="$(tar tzvf f.tgz)"; grep -q …   →   0 failures in 200 runs
#
# It was found the way these always are: `phase5-lxd/tests/test-from-chroot-symlink.sh`
# failed once in five runs and passed on every re-run — the flake nobody can reproduce.
# "Self-announcing" was also doing more work than it deserved: a test that goes red one run
# in three announces itself as UNRELIABLE, which is how a real failure gets waved through.
#
# All 8 sites were converted to capture-then-test, so this gate starts at zero. It is one
# check now, not a check plus a TODO.
# ── LOGICAL lines, not physical ones ───────────────────────────────────────────────────
# These scans used to be a `grep -rnE` over a PHYSICAL line, so a gate written as
#
#     ls "$t/lib"* 2>/dev/null | grep -q . \\
#         || fail "no libs copied"
#
# was invisible: the pipe and the `|| fail` are on different lines. Found 2026-08-22 in
# phase1-chroot/tests/test-host-copy.sh, live, while this check reported a clean repo.
#
# That is the THIRD time here that a regex over a line has stood in for a question about a
# COMMAND -- tools/check-harness-net.sh §1 was wrong the same way twice, and its own fix
# note says the real question is not textual. The fixture below had even PLANTED this
# continuation shape; the assertion just said `>= 1`, which the same-line plant satisfied
# on its own, so the plant sat there for months proving nothing. Both are fixed here: the
# scanners join backslash-continuations first, and each planted shape is now required to
# be caught INDIVIDUALLY.
#
# The `[^|]` prefix on both patterns matters once lines are joined: `grep -q X "$f" || grep
# -q Y "$f" || fail` contains no pipe at all, and without it the second bar of `||` reads as
# one. Six such false positives appeared the moment continuations were joined.
#
# It joins continuations and nothing else -- a bounded normalisation, not a shell parser.
# A `grep -q` inside a quoted string or a heredoc would still be read as code; that is a
# narrower blind spot than the one it replaces, and it is named here rather than implied.
logical_lines() {
    local f
    for f in $(git ls-files -- "${DIRS[@]/%//*.sh}" 2>/dev/null); do
        awk -v F="$f" '
            { start = NR; line = $0
              while (line ~ /\\$/) {
                  sub(/\\$/, "", line)
                  if ((getline nxt) > 0) line = line " " nxt; else break
              }
              print F ":" start ": " line }' "$f"
    done
}
gate_hits() {
    logical_lines | grep -E '[^|]\| *grep -q[a-zA-Z]* .*&& *(fail|die)' \
        | grep -v '/lib\.sh:' | grep -vE '^[^:]+:[0-9]+: *#'
}
noisy_hits() {
    logical_lines | grep -E '[^|]\| *grep -q[a-zA-Z]* .*\|\| *(fail|die)' \
        | grep -v '/lib\.sh:' | grep -vE '^[^:]+:[0-9]+: *#'
}

hits="$(gate_hits)"
if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    fail "the above use the SILENT variant: \`producer | grep -q … && fail\`.
grep -q exits on first match and closes the pipe; the producer can die on SIGPIPE (141), and
with \`pipefail\` set the PIPELINE is non-zero — so \`&& fail\` never runs and a condition that
WAS present is reported as absent. Capture first, then test."
fi
note "no test gates a verdict on the SILENT shape (\`| grep -q … && fail\`)  ✓"

noisy="$(noisy_hits)"
if [[ -n "$noisy" ]]; then
    printf '%s\n' "$noisy" | sed 's/^/  /' >&2
    fail "the above use the NOISY variant: \`producer | grep -q … || fail\`.
Same inversion: grep -q closes the pipe, a STREAMING producer takes SIGPIPE, pipefail makes
the pipeline non-zero, and a match that WAS found is reported as absent. This is not gated
on size — measured at 140 spurious failures in 200 runs over a 13 KB \`tar tzvf\` listing,
one fifth of the pipe buffer. Capture first, then test."
fi
note "no test gates a verdict on the NOISY shape (\`| grep -q … || fail\`) either  ✓"

# ── THE NEGATIVE CONTROL ───────────────────────────────────────────────────
# An all-clear is indistinguishable from a scanner that matches nothing. Plant each of the
# three shapes in a fixture and require all three to be caught.
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/tests"
cat > "$TMP/tests/planted.sh" <<'EOS'
docker ps --format '{{.Names}}' | grep -qx "$c" || fail "not running"
podman ps -a --format '{{.Names}}' | grep -qx "$c" && fail "still present"
ip -o link show | grep -q inet \
    || die "no address"
EOS
# Each shape is required INDIVIDUALLY. `>= 1` on the noisy pair is what let the planted
# backslash-continuation sit here unexamined: the same-line plant satisfied it alone.
plant_logical() {
    awk -v F="planted.sh" '
        { start = NR; line = $0
          while (line ~ /\\$/) {
              sub(/\\$/, "", line)
              if ((getline nxt) > 0) line = line " " nxt; else break
          }
          print F ":" start ": " line }' "$TMP/tests/planted.sh"
}
caught="$(plant_logical | grep -cE '[^|]\| *grep -q[a-zA-Z]* .*&& *(fail|die)')"
(( caught == 1 )) \
    || fail "the scanner found $caught of the 1 planted SILENT violation. A scanner that misses its own shape reports a clean repo it never examined"
noisy_same_line="$(plant_logical | grep -E '[^|]\| *grep -q[a-zA-Z]* .*\|\| *(fail|die)' | grep -c 'docker ps')"
(( noisy_same_line == 1 )) \
    || fail "the scanner missed the planted SAME-LINE noisy form (\`docker ps … | grep -qx … || fail\`), so gating on it means nothing"
noisy_continued="$(plant_logical | grep -E '[^|]\| *grep -q[a-zA-Z]* .*\|\| *(fail|die)' | grep -c 'ip -o link')"
(( noisy_continued == 1 )) \
    || fail "the scanner missed the planted BACKSLASH-CONTINUATION noisy form (\`… | grep -q inet \\\` then \`|| die\`). That shape was live in phase1-chroot/tests/test-host-copy.sh while this check reported a clean repo, and this fixture had been carrying it uncaught behind a \`>= 1\` assertion"
note "negative control: all THREE planted shapes were caught individually — silent, noisy same-line, and noisy split across a backslash continuation  ✓"

# ── AND THE PREMISE ITSELF, because the premise is what was wrong before ────────────────
# This file spent months asserting the noisy form "only bites with a producer big enough to
# fill a pipe buffer". That was never measured. So measure it here, every run: a STREAMING
# producer with a tiny total output must invert at least once, or the gate above is
# defending against something that does not happen and will eventually be deleted as noise.
#
# `yes | head` is not usable (head exits deliberately); this uses a shell loop writing line
# by line — the same profile as `tar tzvf`, and nothing like `docker ps`'s single write.
stream_fixture() { local i; for i in $(seq 1 400); do printf 'line-%s\n' "$i"; done; }
inversions=0
for _ in $(seq 1 60); do
    ( set -o pipefail; stream_fixture | grep -q 'line-1$' ) || inversions=$((inversions+1))
done
bytes="$(stream_fixture | wc -c)"
(( inversions > 0 )) || fail "the SIGPIPE inversion did not reproduce in 60 runs over a ${bytes}-byte
streaming producer. Either this kernel behaves differently or the fixture stopped streaming —
investigate before trusting the gate above, because its whole justification is that this happens."
note "premise re-derived: ${inversions}/60 runs inverted over a ${bytes}-byte STREAMING producer (pipe buffer 65536) — the size threshold applies only to single-write producers  ✓"

# ...and the capture-then-test form must NOT invert, or the recommended fix is no fix.
cap_inversions=0
for _ in $(seq 1 60); do
    out="$(stream_fixture)"
    grep -q 'line-1$' <<<"$out" || cap_inversions=$((cap_inversions+1))
done
(( cap_inversions == 0 )) \
    || fail "capture-then-test inverted $cap_inversions/60 times — the fix this check recommends does not hold"
note "control: the recommended capture-then-test form inverted 0/60 times  ✓"

pass "no test in ${#DIRS[@]} directories pipes a producer into \`grep -q\` to reach a verdict — neither the SILENT \`&& fail\` variant (a SIGPIPE'd producer makes the assertion skip entirely) nor the NOISY \`|| fail\` one (it inverts a found match into a miss). Both scanners were watched catching a planted instance, and the inversion itself was re-derived on a streaming producer far smaller than a pipe buffer — the premise that had kept the noisy form ungated"
