#!/usr/bin/env bash
# Shared helpers for micro-linux tests (mirrors phase2-qemu-vm/tests/lib.sh).
# autotools-style: exit 77 = skip, 0 = pass, anything else = fail.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
readonly MLBUILD="${TEST_DIR}/../mlbuild.sh"

skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { local c; for c in "$@"; do have "$c" || skip "missing required command: $c"; done; }
