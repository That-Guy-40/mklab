#!/usr/bin/env bash
# Shared helpers for phase5-lxd tests.  Verbatim copy of Phase 3/4's lib.sh
# contract (skip/fail/pass/note/require_cmd/expect_error), retargeted at
# the LXD binary.

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_LXD="${TEST_DIR}/../lab-lxd.sh"

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

# Determine which CLI is available and which group it wants.  Tests should
# prefer this over bare `lxc`/`incus` so they work on either engine.
LXC_CMD=""
LXC_GROUP=""
# Same reachability-aware probe as lab-lxd.sh: pick the binary that
# actually answers `info`, not just whichever is installed.  Without
# this the test suite gets stuck on "incus daemon not reachable" on
# hosts where incus is packaged but only the snap-based lxd is running.
detect_lxd_engine() {
    if command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1; then
        LXC_CMD=incus; LXC_GROUP=incus-admin
    elif command -v lxc >/dev/null 2>&1 && lxc info >/dev/null 2>&1; then
        LXC_CMD=lxc;   LXC_GROUP=lxd
    fi
}

require_lxd_or_incus() {
    detect_lxd_engine
    [[ -n "$LXC_CMD" ]] || skip "no reachable LXD/Incus daemon (neither incus nor lxc 'info' succeeded)"

    # The default profile must carry a root-disk device, otherwise every
    # `launch` fails with "No root device could be found".  This is the
    # post-install state — engine is running but `init` has never been run.
    # Skip with a precise pointer instead of cascading lifecycle failures.
    if ! "$LXC_CMD" profile show default 2>/dev/null | grep -qE '^[[:space:]]+root:'; then
        case "$LXC_CMD" in
            incus) skip "default Incus profile has no root device — run: sudo incus admin init --auto  (see phase5-lxd/MANUAL_TESTING.md §0a)" ;;
            lxc)   skip "default LXD profile has no root device — run: sudo lxd init --auto  (see phase5-lxd/MANUAL_TESTING.md §0a)" ;;
        esac
    fi
}

# expect_error LABEL PATTERN -- ARGS...
expect_error() {
    local label="$1" pattern="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    local out rc
    out="$("$LAB_LXD" "$@" 2>&1)" && rc=0 || rc=$?
    if (( rc == 0 )); then
        fail "$label — expected non-zero exit, got 0; output: $out"
    fi
    if ! grep -qi -- "$pattern" <<<"$out"; then
        fail "$label — error did not match /$pattern/i; got: $out"
    fi
    note "$label OK"
}

cleanup_lab() {
    local lab="$1"
    "$LAB_LXD" down --lab "$lab" >/dev/null 2>&1 || true
}

cleanup_instance() {
    local iname="$1"
    [[ -n "$LXC_CMD" ]] || detect_lxd_engine
    [[ -n "$LXC_CMD" ]] || return 0
    "$LXC_CMD" stop   "$iname" --force >/dev/null 2>&1 || true
    "$LXC_CMD" delete "$iname" --force >/dev/null 2>&1 || true
}

cleanup_image_alias() {
    local alias="$1"
    [[ -n "$LXC_CMD" ]] || detect_lxd_engine
    [[ -n "$LXC_CMD" ]] || return 0
    "$LXC_CMD" image delete "$alias" >/dev/null 2>&1 || true
}
