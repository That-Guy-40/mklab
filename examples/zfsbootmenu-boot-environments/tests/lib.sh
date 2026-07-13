#!/usr/bin/env bash
# Shared helpers for the zfsbootmenu-boot-environments tests.
# Mirrors phase2-qemu-vm/tests/lib.sh: every test ends on exactly one verdict
# line — PASS (exit 0) / FAIL (exit 1) / SKIP (exit 77) — and never exits silent.
set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"

skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || skip "missing required command: $c"
    done
}

# Belt-and-suspenders: if a test dies unexpectedly (rc ∉ {0,77}) the trap prints
# a verdict so the terminal is never left blank with a bare non-zero rc.
arm_exit_trap() {
    trap 'rc=$?; [[ $rc == 0 || $rc == 77 ]] || printf "FAIL: test exited early (rc=%s)\n" "$rc" >&2' EXIT
}
