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
# runs — a missed failure, reported as a pass. The `|| fail` direction is wrong for the same
# reason but fails NOISILY (a spurious FAIL on a match that was found), which announces
# itself and only bites with a producer large enough to fill a pipe buffer. Those are
# counted and reported below, not gated.
gate_hits() {
    grep -rnE '\| *grep -q[a-zA-Z]* .*&& *(fail|die)' --include='*.sh' \
        "${DIRS[@]}" 2>/dev/null | grep -v '/lib\.sh:' | grep -vE '^[^:]+:[0-9]+: *#'
}
noisy_hits() {
    grep -rnE '\| *grep -q[a-zA-Z]* .*\|\| *(fail|die)' --include='*.sh' \
        "${DIRS[@]}" 2>/dev/null | grep -v '/lib\.sh:' | grep -vE '^[^:]+:[0-9]+: *#'
}

hits="$(gate_hits)"
if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    fail "the above use the SILENT variant: \`producer | grep -q … && fail\`.
grep -q exits on first match and closes the pipe; the producer can die on SIGPIPE (141), and
with \`pipefail\` set the PIPELINE is non-zero — so \`&& fail\` never runs and a condition that
WAS present is reported as absent. Capture first, then test."
fi
noisy=$(noisy_hits | wc -l)
note "no test gates a verdict on the SILENT shape (\`| grep -q … && fail\`)  ✓"
note "$noisy sites still use the noisy \`| grep -q … || fail\` form — wrong for the same reason but self-announcing, and only reachable with a producer big enough to fill a pipe buffer. Inventoried, not gated (TODO 0.4)"

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
caught="$(grep -cE '\| *grep -q[a-zA-Z]* .*&& *(fail|die)' "$TMP/tests/planted.sh")"
(( caught == 1 )) \
    || fail "the scanner found $caught of the 1 planted SILENT violation. A scanner that misses its own shape reports a clean repo it never examined"
noisy_caught="$(grep -cE '\| *grep -q[a-zA-Z]* .*\|\| *(fail|die)' "$TMP/tests/planted.sh")"
(( noisy_caught >= 1 )) \
    || fail "the inventory pattern matched none of the planted noisy forms, so its count is meaningless"
note "negative control: the planted \`&& fail\` was caught, and the noisy form counted separately  ✓"

pass "no test in ${#DIRS[@]} directories uses the SILENT \`| grep -q … && fail\` shape — the variant where a SIGPIPE'd producer makes the assertion skip entirely — and the scanner was watched catching a planted one. The $noisy remaining \`|| fail\` sites are inventoried rather than gated: same defect, but it announces itself"
