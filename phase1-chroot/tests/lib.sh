#!/usr/bin/env bash
# Shared helpers for phase1-chroot tests.
# Sourced by every test-*.sh; each test stays self-contained otherwise.

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_CHROOT="${TEST_DIR}/../lab-chroot.sh"
readonly TEST_TMP_ROOT="${TEST_TMP_ROOT:-/tmp/lab-chroot-tests}"

skip()  { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass()  { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note()  { printf '  - %s\n' "$*" >&2; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || skip "needs root"
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || skip "missing required command: $c"
    done
}

mktest_target() {
    local name="$1"
    local p="${TEST_TMP_ROOT}/${name}.$$"
    mkdir -p "$(dirname "$p")"
    printf '%s' "$p"
}

cleanup_target() {
    local target="$1" name="${2:-}"
    if [[ -n "$name" ]]; then
        "$LAB_CHROOT" destroy "$name" --force >/dev/null 2>&1 || true
    fi
    if [[ -d "$target" ]]; then
        # Best-effort: unmount anything inside, then rm -rf.
        awk -v t="$target/" '$2 ~ "^"t {print $2}' /proc/mounts 2>/dev/null \
            | tac | while IFS= read -r mp; do umount -l "$mp" 2>/dev/null || true; done
        rm -rf -- "$target"
    fi
}
