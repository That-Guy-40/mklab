#!/usr/bin/env bash
# Shared helpers for phase1-chroot tests.
# Sourced by every test-*.sh; each test stays self-contained otherwise.

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_CHROOT="${TEST_DIR}/../lab-chroot.sh"
readonly TEST_TMP_ROOT="${TEST_TMP_ROOT:-/tmp/lab-chroot-tests}"

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
# inside lab-chroot.sh slipping past the assertions — this prints a FAIL verdict, so the
# terminal is never left blank with a bare non-zero rc.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap … EXIT`. Bash keeps ONE EXIT trap
# per shell, so a test writing its own silently REPLACES this net — measured across the
# repo on 2026-08-06, when 17 of 21 of these tests had no net at all. Register instead:
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


require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || skip "needs root"
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || skip "missing required command: $c"
    done
}

mktest_target() {
    local name="$1"
    local p="${TEST_TMP_ROOT}/${name}.$$"
    mkdir -p "$(dirname "$p")"
    printf '%s' "$p"
}

cleanup_target() {
    local target="$1" name="${2:-}"
    if [[ -n "$name" ]]; then
        "$LAB_CHROOT" destroy "$name" --force >/dev/null 2>&1 || true
    fi
    if [[ -d "$target" ]]; then
        # Best-effort: unmount anything inside, then rm -rf.
        awk -v t="$target/" '$2 ~ "^"t {print $2}' /proc/mounts 2>/dev/null \
            | tac | while IFS= read -r mp; do umount -l "$mp" 2>/dev/null || true; done
        rm -rf -- "$target"
    fi
}
