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

# Deploy-driver test rig (increment 3): point --driver at tests/mock.sh, set up a
# signed-image store with a real snakeoil trust root, and use a short health timeout.
maas_env_drivers() {
    export MAAS_DRIVER_DIR="$TEST_DIR"           # so `--driver mock` -> tests/mock.sh
    export MAAS_IMAGES_DIR="$SANDBOX/images"
    export MAAS_HEALTH_TIMEOUT=3
    mkdir -p "$MAAS_IMAGES_DIR/trust"
    "$LAB_DIR/drivers/verify-lib.sh" gen-keys --dir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1 \
        || skip "verify-lib gen-keys failed (openssl missing?)"
}
# make_image <name> [tamper] — a signed payload for <name>; `tamper` flips a byte
# AFTER signing so verification must fail.
make_image() {
    local img="$1" dir; dir="$MAAS_IMAGES_DIR/$img"; mkdir -p "$dir"
    printf 'PAYLOAD-%s-%s\n' "$img" "${2:-clean}" > "$dir/payload.img"
    "$LAB_DIR/drivers/verify-lib.sh" sign "$dir/payload.img" --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1 \
        || fail "signing image '$img' failed"
    [[ "${2:-}" == tamper ]] && printf 'X' | dd of="$dir/payload.img" bs=1 seek=1 conv=notrunc >/dev/null 2>&1
    return 0
}

# Read a node's registry field (image, driver, previous_image, …) from the sandbox.
_show() { cat "$MAAS_STATE/$1/$2" 2>/dev/null; }

# Assert a node is in an expected state.
assert_state() {  # assert_state <node> <expected>
    local got; got="$("$MAAS" state "$1" 2>/dev/null)"
    [[ "$got" == "$2" ]] || fail "REGRESSION: node '$1' state expected '$2' but got '${got:-<none>}'"
}
