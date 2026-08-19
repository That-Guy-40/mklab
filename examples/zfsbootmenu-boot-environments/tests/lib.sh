#!/usr/bin/env bash
# Shared helpers for the zfsbootmenu-boot-environments tests.
# Mirrors phase2-qemu-vm/tests/lib.sh: every test ends on exactly one verdict
# line — PASS (exit 0) / FAIL (exit 1) / SKIP (exit 77) — and never exits silent.
set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"

# _VERDICT guards the EXIT net: a test that already printed FAIL must not also be told
# "no verdict was printed", or the net becomes noise a reader learns to skip past.
_VERDICT=0
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || skip "missing required command: $c"
    done
}

# Belt-and-suspenders: if a test dies unexpectedly (rc ∉ {0,77}) this prints a verdict
# so the terminal is never left blank with a bare non-zero rc.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap … EXIT`: bash keeps ONE EXIT trap
# per shell, so a test installing its own silently replaces the net. Two tests here did,
# re-inlining it — which cost only a doubled FAIL line, but in metal-as-a-service the
# same shape left 23 tests with no net at all (2026-08-06). Register cleanup instead:
#     on_exit 'rm -rf "$WORK"'      # evaluated at exit, so it may name a later variable
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }
# Armed at source time, so the net exists whether or not a test remembers to call
# arm_exit_trap — which every test here does, but "remembers to" is not a guarantee.
arm_exit_trap() {
    trap '_on_exit' EXIT
}
trap _on_exit EXIT

# ── being KILLED is not the same as FAILING, and the net could not tell you which ────────
# See the note in the sibling lib.sh files: bash runs no EXIT trap for an untrapped fatal
# signal, so a run stopped from outside used to end in silence. `arm_exit_trap` above may
# re-install the EXIT trap; these three are separate dispositions and survive that.
_SIGNALLED=""
_on_signal() { _SIGNALLED="$1"; exit $(( 128 + $2 )); }
trap '_on_signal TERM 15' TERM
trap '_on_signal INT 2'   INT
trap '_on_signal HUP 1'   HUP
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
