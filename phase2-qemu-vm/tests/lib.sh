#!/usr/bin/env bash
# Shared helpers for phase2-qemu-vm tests.

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_VM="${TEST_DIR}/../lab-vm.sh"

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
# inside lab-vm.sh slipping past the assertions — this prints a FAIL verdict, so the
# terminal is never left blank with a bare non-zero rc.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap … EXIT`. Bash keeps ONE EXIT trap
# per shell, so a test writing its own silently REPLACES this net — measured across the
# repo on 2026-08-06, when 13 of 17 of these tests had no net at all. Register instead:
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
