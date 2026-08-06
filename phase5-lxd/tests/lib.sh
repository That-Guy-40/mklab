#!/usr/bin/env bash
# Shared helpers for phase5-lxd tests.  Verbatim copy of Phase 3/4's lib.sh
# contract (skip/fail/pass/note/require_cmd/expect_error), retargeted at
# the LXD binary.

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_LXD="${TEST_DIR}/../lab-lxd.sh"

# _VERDICT guards the EXIT net below: a test that already printed FAIL must not also
# be told "no verdict was printed", or the net becomes noise a reader skips past.
_VERDICT=0
skip()  { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail()  { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass()  { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note()  { printf '  - %s\n' "$*" >&2; }

# ── the ONE EXIT trap, and the only place cleanup belongs ────────────────────────────
#
# Belt-and-suspenders (CLAUDE.md): if a test dies early — `set -e` tripping, or a `die`
# inside lab-lxd.sh slipping past the assertions — this prints a FAIL verdict, so the
# terminal is never left blank with a bare non-zero rc.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap … EXIT`. Bash keeps ONE EXIT trap
# per shell, so a test writing its own silently REPLACES this net — measured across the
# repo on 2026-08-06, when 10 of 10 of these tests had no net at all. Register instead:
#
#     on_exit 'rm -rf "$tmp"'     # evaluated at exit, so it may name a later variable
#
# `tests/test-harness-net.sh` proves the net fires and refuses a test that installs an
# EXIT trap of its own.
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }
_on_exit() {
    local rc=$? i
    # Registered cleanup can READ the exit status as $_EXIT_RC. Without it a teardown
    # that needs to know whether the run failed — keep the evidence, skip the tidy-up —
    # has to write its own `trap … EXIT`, which is the defect this block exists to stop.
    _EXIT_RC=$rc
    for (( i=${#_CLEANUPS[@]}-1; i>=0; i-- )); do eval "${_CLEANUPS[i]}" || true; done
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT


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
