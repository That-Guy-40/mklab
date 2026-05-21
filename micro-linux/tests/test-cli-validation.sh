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

# clean must actually remove out/<arch> — but ONLY inside a throwaway OUT_DIR.
# (Running it against the real out/ would delete a user's build; MLBUILD_OUT_DIR
# isolates it.  Pre-create the dir so we exercise the real safe_rm path, not the
# "nothing to clean" branch — the bug a live build first exposed.)
tmp_out="$(mktemp -d)"
trap 'rm -rf -- "$tmp_out"' EXIT
mkdir -p "$tmp_out/x86_64/build"
out="$(MLBUILD_OUT_DIR="$tmp_out" "$MLBUILD" clean --arch x86_64 2>&1)" \
    || fail "clean rc=$? ; out: $out"
grep -qi 'rm -rf' <<<"$out" || fail "clean — expected an rm report; got: $out"
[[ ! -e "$tmp_out/x86_64" ]] || fail "clean — out/x86_64 still present after clean"
note "clean removes out/<arch> within an isolated OUT_DIR OK"

pass "CLI validation OK"
