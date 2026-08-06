#!/usr/bin/env bash
# Shared helpers for phase7-firecracker tests. Same skip/fail/pass/note contract as
# Phase 3/4/5's lib.sh, retargeted at lab-fc.sh.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
readonly LAB_FC="${TEST_DIR}/../lab-fc.sh"

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

# Belt-and-suspenders: a `die` inside lab-fc.sh is an exit, and an unguarded one would
# otherwise end a test with a bare rc and NO verdict line. Real incident in phases 1-5.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap ... EXIT`. Bash keeps ONE EXIT trap
# per shell, so a test writing `trap 'rm -rf "$tmp"' EXIT` silently REPLACES this net and
# the verdict line disappears. Found 2026-08-02: all four tests here did exactly that, and
# an injected fault produced a python traceback, rc=1, and no FAIL: line — the safety net
# was present and inert. Register scratch dirs instead:
#     tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
# TMPDIRS covers scratch directories; on_exit covers any other teardown, which is what
# a test would otherwise reach for a second `trap … EXIT` to do.
TMPDIRS=()
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }
_on_exit() {
    local rc=$? i
    # Registered cleanup can READ the exit status as $_EXIT_RC. Without it a teardown
    # that needs to know whether the run failed — keep the evidence, skip the tidy-up —
    # has to write its own `trap … EXIT`, which is the defect this block exists to stop.
    _EXIT_RC=$rc
    for (( i=${#_CLEANUPS[@]}-1; i>=0; i-- )); do eval "${_CLEANUPS[i]}" || true; done
    local d; for d in ${TMPDIRS+"${TMPDIRS[@]}"}; do [[ -n "$d" ]] && rm -rf "$d"; done
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

# A microVM spec that is valid in shape. Callers append or override keys.
# Uses paths that do not need to exist: gates about FILES are expected to fail here, and
# the tests below assert on SPECIFIC gate lines rather than on the overall exit status.
mkspec() {  # mkspec <file> [extra lines...]
    local f="$1"; shift
    {
        printf '[lab]\nname = "t"\n\n[[microvm]]\n'
        printf 'name = "t1"\nkernel = "/nonexistent/vmlinux"\nrootfs = "/nonexistent/rootfs.ext4"\n'
        local l; for l in "$@"; do printf '%s\n' "$l"; done
    } > "$f"
}

# Run lab-fc.sh and capture combined output WITHOUT letting a pipe decide the exit status.
run_fc() {  # run_fc <outfile> <args...>
    local out="$1"; shift
    set +e
    bash "$LAB_FC" "$@" > "$out" 2>&1
    local rc=$?
    set -e
    return "$rc"
}
