#!/usr/bin/env bash
# Shared helpers for netboot/ tests. Same skip/fail/pass/note contract as every other
# tests/lib.sh in this repo — see CLAUDE.md, "Every test emits exactly one human-readable
# verdict line".
#
# This directory got a lib late (2026-08-07). Its one test predated the convention, carried
# its own inline `trap … EXIT`, and — because CI's loop keys on `*/tests/lib.sh` — the whole
# directory was invisible to CI. Both are fixed here.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
NETBOOT_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
readonly NETBOOT_DIR

# _VERDICT guards the EXIT net below: a test that already said FAIL must not also be told
# "no verdict was printed", or the net becomes noise a reader learns to skip past.
_VERDICT=0
skip()  { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail()  { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass()  { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note()  { printf '  - %s\n' "$*" >&2; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || skip "missing required command: $c"
    done
}

# Belt-and-suspenders: the tools under test report refusal with `die`, which is an exit, not
# a return — an unguarded one would end a test with a bare rc and NO verdict line.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap ... EXIT`. Bash keeps ONE EXIT trap
# per shell, so a test writing `trap 'rm -rf "$tmp"' EXIT` silently REPLACES this net and
# the verdict line disappears. Register scratch dirs instead:
#     tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
TMPDIRS=()
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }
_on_exit() {
    local rc=$? i
    # Registered cleanup can READ the exit status as $_EXIT_RC — without it a teardown that
    # needs to know whether the run failed has to write its own trap, which is the defect
    # this block exists to stop.
    _EXIT_RC=$rc
    for (( i=${#_CLEANUPS[@]}-1; i>=0; i-- )); do eval "${_CLEANUPS[i]}" || true; done
    local d; for d in ${TMPDIRS+"${TMPDIRS[@]}"}; do [[ -n "$d" ]] && rm -rf "$d"; done
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
