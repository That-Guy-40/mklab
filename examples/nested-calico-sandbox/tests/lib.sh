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
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

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
