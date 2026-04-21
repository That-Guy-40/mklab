#!/usr/bin/env bash
# Shared helpers for phase2-qemu-vm tests.

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_VM="${TEST_DIR}/../lab-vm.sh"

skip()  { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass()  { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note()  { printf '  - %s\n' "$*" >&2; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || skip "missing required command: $c"
    done
}

cleanup_vm() {
    local name="$1"
    "$LAB_VM" destroy "$name" --force >/dev/null 2>&1 || true
}

wait_for_ssh() {
    # wait_for_ssh PORT TIMEOUT_SEC
    local port="$1" timeout="$2" elapsed=0
    while (( elapsed < timeout )); do
        if ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=2 -o BatchMode=yes -o PasswordAuthentication=no \
              lab@127.0.0.1 true 2>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}
