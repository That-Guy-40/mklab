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

# ── user-namespace probe, which KEEPS the reason it failed ──────────────────────────────
#
# `require_userns_or_root` decides whether a test that needs a bind mount can run here. A
# bind needs CAP_SYS_ADMIN only in the namespace doing the mounting, so `unshare -rm` is
# enough and these tests need no root — which matters, because a root-gated test SKIPs on
# every CI run and the guard it protects goes unwatched.
#
# ⚠️ IT USED TO BE `if unshare -rm true 2>/dev/null`, AND THAT REDIRECT IS WHY A REAL
# INCIDENT BECAME AN UNKNOWN. On 2026-08-15 both mount-guard tests skipped inside one
# phase-1 run — the suite printed a healthy-looking `13 passed, 13 skipped, 0 failed` — and
# the only thing recoverable afterwards was the generic message "needs unprivileged user
# namespaces". The errno that would have named the cause had been thrown away by the very
# line testing for it. It was never reproduced (0 failures in 440 later attempts, the
# AppArmor sysctl unchanged at 0, no matching denial in the journal), so the cause is STILL
# unknown. What is fixed is that the next occurrence reports itself.
#
# The retry is deliberate, and so is announcing it. A silent retry would erase exactly the
# signal that went missing; a bare first-failure costs a safety guard for what may be a
# blip. So it recovers AND says that it had to.
USERNS_ERR=""
_userns_ok() {
    local err rc
    err="$(unshare -rm true 2>&1)"; rc=$?
    (( rc == 0 )) && return 0
    printf '  - unshare -rm failed (rc=%d): %s — retrying once\n' "$rc" "${err:-no message}" >&2
    err="$(unshare -rm true 2>&1)"; rc=$?
    if (( rc == 0 )); then
        printf '  - retry succeeded, so the first failure was transient — recording it here because an unannounced retry is how this stopped being diagnosable in the first place\n' >&2
        return 0
    fi
    USERNS_ERR="rc=$rc: ${err:-no message}"
    return 1
}

# require_userns_or_root VAR — re-exec into `unshare -rm`, or run directly when already
# root, or skip with a message that says WHY rather than only WHAT.
# VAR is the guard variable that marks "already inside the namespace".
require_userns_or_root() {
    local var="$1" self
    [[ -n "${!var:-}" ]] && return 0
    self="$(realpath "${BASH_SOURCE[1]}")"
    if _userns_ok; then
        export "$var=1"
        exec unshare -rm bash "$self"
    fi
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        export "$var=1"          # already root: mount directly, no namespace needed
        return 0
    fi
    # Everything a reader needs to tell "policy forbids this" from "something transient":
    # the errno, the AppArmor knob Ubuntu 24.04 gates userns with, and who we are.
    local knob=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
    skip "needs unprivileged user namespaces or root to create a bind mount — unshare -rm $USERNS_ERR; $(basename "$knob")=$(cat "$knob" 2>/dev/null || printf 'n/a'), EUID=${EUID:-?}"
}
