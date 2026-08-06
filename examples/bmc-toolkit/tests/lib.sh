#!/usr/bin/env bash
# Shared helpers for bmc-toolkit tests (mirrors the repo convention).
# autotools-style exit codes: 0 = pass, 77 = skip, anything else = fail.
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
BMC="$LAB_DIR/bmc.sh"
readonly TEST_DIR LAB_DIR BMC

# _VERDICT guards the EXIT net below: a test that already printed FAIL must not also be
# told "no verdict was printed", or the net becomes noise a reader learns to skip past.
_VERDICT=0
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { local c; for c in "$@"; do have "$c" || skip "missing required command: $c"; done; }

# Belt-and-suspenders (CLAUDE.md): if a test dies early (a die/exit slips past the
# assertions), this prints a FAIL verdict so output is never silently blank.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap … EXIT`. Bash keeps ONE EXIT trap
# per shell, so a test writing `trap 'cleanup' EXIT` silently REPLACES this net and the
# verdict line disappears. Both SOL tests here did exactly that until 2026-08-06 (the
# same defect found in metal-as-a-service's 23 tests and phase7-firecracker's 4).
# Register cleanup instead:  on_exit 'cleanup'
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }
_on_exit() {
    local rc=$? i
    for (( i=${#_CLEANUPS[@]}-1; i>=0; i-- )); do eval "${_CLEANUPS[i]}" || true; done
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

# Session-libvirt node lifecycle helpers (rootless).
V() { virsh -c "${URI:-qemu:///session}" "$@"; }
node_destroy() { V destroy "$1" >/dev/null 2>&1 || true; V undefine "$1" --nvram >/dev/null 2>&1 || true; }
