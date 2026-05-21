#!/usr/bin/env bash
# Argument-handling guardrails — no container, no network, no qemu.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# expect LABEL WANT_RC PATTERN -- ARGS...
expect() {
    local lbl="$1" want_rc="$2" pat="$3"; shift 3
    [[ "${1:-}" == "--" ]] && shift
    local out rc
    out="$("$MLBUILD" "$@" 2>&1)" && rc=0 || rc=$?
    [[ "$rc" == "$want_rc" ]] || fail "$lbl — rc=$rc want=$want_rc; out: $out"
    [[ -z "$pat" ]] || grep -qi -- "$pat" <<<"$out" || fail "$lbl — output !~ /$pat/i; got: $out"
    note "$lbl OK (rc=$rc)"
}

expect "unknown arch"        1 "unknown arch"        -- build --arch m68k
expect "unknown subcommand"  1 "unknown subcommand"  -- frobnicate
expect "help exits 0"        0 "Usage:"              -- --help
expect "no args shows usage" 0 "Usage:"              --
expect "clean is safe"       0 "clean"               -- clean --arch x86_64

pass "CLI validation OK"
