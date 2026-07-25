#!/usr/bin/env bash
# Shared helpers for bmc-toolkit tests (mirrors the repo convention).
# autotools-style exit codes: 0 = pass, 77 = skip, anything else = fail.
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
BMC="$LAB_DIR/bmc.sh"
readonly TEST_DIR LAB_DIR BMC

skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { local c; for c in "$@"; do have "$c" || skip "missing required command: $c"; done; }

# Belt-and-suspenders (CLAUDE.md): if a test dies early (a die/exit slips past the
# assertions), the EXIT trap prints a FAIL verdict so output is never silently blank.
# (pass/skip exit 0/77 -> trap stays quiet; any other rc -> a FAIL line.)
# shellcheck disable=SC2154  # _rc is assigned inside the trap body below
trap '_rc=$?; if [[ $_rc -ne 0 && $_rc -ne 77 ]]; then printf "FAIL: test exited early (rc=%s)\n" "$_rc" >&2; fi' EXIT

# Session-libvirt node lifecycle helpers (rootless).
V() { virsh -c "${URI:-qemu:///session}" "$@"; }
node_destroy() { V destroy "$1" >/dev/null 2>&1 || true; V undefine "$1" --nvram >/dev/null 2>&1 || true; }
