#!/usr/bin/env bash
# Shared helpers for nested-calico-sandbox tests. Same skip/fail/pass/note contract as every
# other tests/lib.sh in this repo — see CLAUDE.md, "Every test emits exactly one
# human-readable verdict line".
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
REPO_DIR="$(cd -- "$LAB_DIR/../.." && pwd)"
SANDBOX="$LAB_DIR/sandbox.sh"
FINDINGS="$LAB_DIR/findings.env"
readonly TEST_DIR LAB_DIR REPO_DIR SANDBOX FINDINGS

# _VERDICT guards the EXIT net: a test that already said FAIL must not also be told "no
# verdict was printed", or the net becomes noise a reader learns to skip past.
_VERDICT=0
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { local c; for c in "$@"; do have "$c" || skip "missing required command: $c"; done; }

# ── the ONE EXIT trap, and the only place cleanup belongs ────────────────────────────────
# Bash keeps ONE EXIT trap per shell, so a test writing `trap 'cleanup' EXIT` silently
# REPLACES this net — invisible, because a safety net is only observable when something goes
# wrong. Register cleanup instead:  on_exit 'rm -rf -- "$WORK"'
TMPDIRS=()
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }
_on_exit() {
    local rc=$? i
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

# Read findings.env in a SUBSHELL and export the values, so a `set -e` inside it cannot end
# the test and a stray variable cannot leak in. It is code, not data (AUDIT F3).
load_findings() {
    [[ -f "$FINDINGS" ]] || fail "findings.env is missing — this lab's recorded result has no file to live in"
    # shellcheck source=/dev/null
    eval "$( ( . "$FINDINGS" >/dev/null 2>&1
               printf 'F_CALICO=%q\nF_MICROK8S=%q\nF_METHOD=%q\nF_RULE1=%q\nF_RULE2=%q\nF_ORDER=%q\nF_SECS_MIN=%q\nF_SECS_MAX=%q\n' \
                   "${NCS_CALICO_VERSION:-}" "${NCS_MICROK8S_VERSION:-}" \
                   "${NCS_AUTODETECTION_METHOD:-}" "${NCS_RULE1_BR_EXCLUSION:-}" \
                   "${NCS_RULE2_ADDRESSED_BECOMES_CANDIDATE:-}" "${NCS_ORDERING_OBSERVED:-}" \
                   "${NCS_MIGRATION_SECONDS_MIN:-}" "${NCS_MIGRATION_SECONDS_MAX:-}" ) )"
}

# Is the sandbox VM up and answering? Every live test gates on this and SKIPs otherwise —
# a 15-minute VM build is not a precondition CI can meet, and an unmet precondition is an
# UNKNOWN, never a pass.
vm_running() {
    local vm_dir="$HOME/.local/state/lab-create/vms/$1"
    [[ -f "$vm_dir/qemu.pid" ]] || return 1
    local p; p="$(cat "$vm_dir/qemu.pid" 2>/dev/null)" || return 1
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}
sandbox_running() { vm_running calico-sandbox; }

# The two-node pair is a SEPARATE subject from the one-node sandbox and lives in its own VMs;
# a test that needs a peer must not be satisfied by the single node being up. Both, or neither.
two_node_running() { vm_running calico-n1 && vm_running calico-n2; }
