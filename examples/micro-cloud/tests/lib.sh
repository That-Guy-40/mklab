#!/usr/bin/env bash
# Shared helpers for micro-cloud lab tests (repo convention; mirrors
# examples/metal-as-a-service/tests/lib.sh and bmc-toolkit's).
# autotools exit codes: 0 = pass, 77 = skip, anything else = fail.
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
REPO_DIR="$(cd -- "$LAB_DIR/../.." && pwd)"
FABRIC="$LAB_DIR/fabric.sh"
readonly TEST_DIR LAB_DIR REPO_DIR FABRIC

# _VERDICT guards the EXIT net: a test that already printed FAIL must not also be told
# "no verdict was printed", or the net becomes noise a reader learns to skip past.
_VERDICT=0
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { local c; for c in "$@"; do have "$c" || skip "missing required command: $c"; done; }

# ── the ONE EXIT trap, and the only place cleanup belongs ────────────────────────────
# Each test here used to define this block itself. Bash keeps ONE EXIT trap per shell,
# so six copies were six chances to drop the net while looking like it was there — the
# shape that left 23 of metal-as-a-service's tests with none (2026-08-06). Register
# cleanup instead:  on_exit 'rm -rf -- "$WORK"'   (evaluated at exit)
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }
_on_exit() {
    local rc=$? i
    # Registered cleanup can READ the exit status as $_EXIT_RC. Without it a teardown
    # that needs to know whether the run failed — keep the evidence, skip the tidy-up —
    # has to write its own `trap … EXIT`, which is the defect this block exists to stop.
    _EXIT_RC=$rc
    for (( i=${#_CLEANUPS[@]}-1; i>=0; i-- )); do eval "${_CLEANUPS[i]}" || true; done
    if [[ -n "${_SIGNALLED:-}" ]]; then
        printf 'FAIL: test was TERMINATED FROM OUTSIDE by SIG%s — the run was cut short, so nothing above is a result about the code under test\n' "$_SIGNALLED" >&2
    elif (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

# ── being KILLED is not the same as FAILING, and the net could not tell you which ────────
# Bash does not run an EXIT trap for an untrapped fatal signal. So a run stopped from
# outside — a CI job timeout, a harness deadline, Ctrl-C, an OOM reaper, a closed terminal —
# produced a log that simply STOPS: no verdict, no reason, and a reader left hunting inside
# a test that never got the chance to fail. Measured 2026-08-19: a SIGTERM to the process
# group mid-suite printed bash's bare `Terminated` and nothing else, and the truncated log
# was read for a day as an intermittent defect in the test it happened to interrupt.
#
# Trapping the three signals converts that silence into a sentence. The handler records
# WHICH signal and re-exits with the conventional 128+N, so the EXIT trap runs normally.
#
# WHAT THIS DOES *NOT* FIX, because the first draft of this comment claimed it did and the
# control in tools/check-harness-net.sh §7 caught the claim: teardown was never lost. A
# killed run already executed its registered cleanup — measured against the pre-change lib,
# which printed its cleanup and no verdict. The whole of what changes here is that the run
# now SAYS it was killed. That is worth having on its own, and it is all that is claimed.
#
# `_VERDICT` is left alone on purpose: this is a verdict, but a verdict about the RUN rather
# than about the code, and _on_exit prints it as such.
_SIGNALLED=""
_on_signal() { _SIGNALLED="$1"; exit $(( 128 + $2 )); }
trap '_on_signal TERM 15' TERM
trap '_on_signal INT 2'   INT
trap '_on_signal HUP 1'   HUP

# ── the two observations every micro-cloud test must be able to make ────────
# DERIVED, never named. This host's CNI binding has moved twice (plan D.1, Appendix I);
# a test that hard-codes an interface reports a migration the lab did not cause.
calico_binding() {
    ip -d link show vxlan.calico 2>/dev/null \
        | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' || true
}
calico_veths() { ip -o link show 2>/dev/null | grep -cE ': cali[0-9a-f]+@' || true; }

# ── where the lab's artifacts live, when the test may be running under sudo ──
# `$HOME` is ROOT's home under sudo, but every micro-cloud artifact belongs to the invoking
# user — so a default built from `$HOME` sends a root-run test to
# /root/.local/state/lab-create/… and it SKIPs on a host that has the files.
#
# Found 2026-08-05 by exactly that: `sudo bash tests/run-all.sh` skipped both boot tests with
# "slice 3's kernel/rootfs are not in /root/.local/state/…". The skip was honest and the
# default was wrong; had those tests reported a pass-shaped verdict instead, the two engines
# would have been "verified" without booting.
#
# `${SUDO_USER}` alone is not enough — it is literally `root` when sudo runs from a root
# shell, which is the same trap that produced the unopenable root-owned tap (plan G.4). So
# fall back to the checkout's owner, and read the home directory out of passwd rather than
# assuming /home/<user>.
mc_user_home() {
    local u h
    u="${SUDO_USER:-}"
    [[ -z "$u" || "$u" == root ]] && u="$(stat -c %U "$REPO_DIR" 2>/dev/null || true)"
    if [[ -n "$u" && "$u" != root ]]; then
        h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
        [[ -n "$h" && -d "$h" ]] && { printf '%s\n' "$h"; return 0; }
    fi
    printf '%s\n' "$HOME"
}
mc_workdir() { printf '%s/.local/state/lab-create/micro-cloud-s3\n' "$(mc_user_home)"; }
