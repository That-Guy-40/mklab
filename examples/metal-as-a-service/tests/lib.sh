#!/usr/bin/env bash
# Shared helpers for metal-as-a-service tests (repo convention; mirrors bmc-toolkit).
# autotools exit codes: 0 = pass, 77 = skip, anything else = fail.
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
MAAS="$LAB_DIR/maas-lab.sh"
MOCK_BMC="$TEST_DIR/mock-bmc.sh"
readonly TEST_DIR LAB_DIR MAAS MOCK_BMC

skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { local c; for c in "$@"; do have "$c" || skip "missing required command: $c"; done; }

# Belt-and-suspenders (CLAUDE.md): if a test dies early (a die/exit slips past the
# assertions), the EXIT trap prints a FAIL verdict so output is never silently blank.
# shellcheck disable=SC2154  # _rc is assigned inside the trap body below
trap '_rc=$?; if [[ $_rc -ne 0 && $_rc -ne 77 ]]; then printf "FAIL: test exited early (rc=%s)\n" "$_rc" >&2; fi' EXIT

# Every test runs against a throwaway state dir and the mock BMC, so the whole
# state machine drives with zero libvirt / vbmcd / root. Call once per test.
maas_env() {
    SANDBOX="$(mktemp -d)"
    export MAAS_STATE="$SANDBOX/maas"
    export MAAS_BMC="$MOCK_BMC"
    export MOCK_BMC_LOG="$SANDBOX/bmc-calls.log"
    : > "$MOCK_BMC_LOG"
    # cleaned by the caller's trap; record it for teardown
    _SANDBOXES+=("$SANDBOX")
}
_SANDBOXES=()
cleanup_sandboxes() { local s; for s in "${_SANDBOXES[@]:-}"; do [[ -n "$s" ]] && rm -rf "$s"; done; }

# Run maas-lab.sh; capture rc without tripping the EXIT trap (subshell contains any die).
m() { ( "$MAAS" "$@" ); }

# Assert a node is in an expected state.
assert_state() {  # assert_state <node> <expected>
    local got; got="$("$MAAS" state "$1" 2>/dev/null)"
    [[ "$got" == "$2" ]] || fail "REGRESSION: node '$1' state expected '$2' but got '${got:-<none>}'"
}
