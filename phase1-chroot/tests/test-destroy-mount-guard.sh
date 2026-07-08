#!/usr/bin/env bash
# Regression (Review H1): destroy must ground-truth /proc/mounts and unmount a
# live bind BEFORE rm -rf, rather than trusting the .lab-chroot-mounts file.
#
# The bug: unbind_essentials() returns success when the tracking file is
# missing/stale and unmounts nothing; manager_none_destroy then rm -rf's a tree
# that still has a bind mount live, recursing THROUGH the bind and deleting the
# bind SOURCE's contents (on a real chroot that source is the host's /dev).
#
# This test binds a HARMLESS scratch dir (never /dev) into the chroot, deletes
# the tracking file to simulate the stale state, then drives the real destroy
# code (sourced) and asserts the bind source survived intact.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_root                      # bind mount needs CAP_SYS_ADMIN
require_cmd mountpoint realpath

work="$(mktemp -d)"
# EXIT trap: unmount any stragglers, remove the workdir, and — the readability
# safety net — always print a clear FAIL if the test exits early (an uncaught
# `die`/`set -e`) instead of leaving the terminal silent.
_finish() {
    local rc=$?
    awk -v t="$work" 'index($2, t)==1 {print $2}' /proc/mounts 2>/dev/null \
        | sort -r | while IFS= read -r m; do umount -l "$m" 2>/dev/null || true; done
    rm -rf -- "$work"
    (( rc == 0 || rc == 77 )) || printf 'FAIL: test exited early (rc=%s) — see messages above\n' "$rc" >&2
}
trap _finish EXIT

target="$work/chroot"
src="$work/host-dev-standin"
mkdir -p "$target/mnt" "$src"
# Sentinel in the bind SOURCE: if rm -rf recurses through the live bind, this
# file is destroyed — exactly the host-/dev-deletion failure, in miniature.
echo "DO-NOT-DELETE" > "$src/sentinel"

mount --bind "$src" "$target/mnt" || skip "bind mount unavailable in this sandbox"
mountpoint -q "$target/mnt"        || fail "setup: bind mount didn't take"

# Simulate the dangerous state: a live bind with NO tracking-file record.
rm -f "$target/.lab-chroot-mounts"

# Drive the real destroy code (source the script via its guard; no main run).
export LAB_STATE_DIR="$work/state" LAB_CACHE_DIR="$work/cache"
source "$LAB_CHROOT"

manager_none_destroy "$target"

# Assertions: the tree is gone, the mount is gone, and — the crux — the bind
# source and its sentinel are untouched (rm did NOT recurse through the bind).
[[ ! -e "$target" ]]        || fail "target tree still present after destroy"
mountpoint -q "$target/mnt" 2>/dev/null && fail "bind mount still live after destroy"
[[ -f "$src/sentinel" ]]   || fail "REGRESSION: rm -rf recursed through the live bind and deleted the source"
[[ "$(cat "$src/sentinel")" == "DO-NOT-DELETE" ]] || fail "bind source content was clobbered"
note "live bind unmounted before rm -rf; bind source intact"

# And the fail-closed assertion: _safe_rm_rf must REFUSE if a mount is still live.
target2="$work/chroot2"; mkdir -p "$target2/mnt"
mount --bind "$src" "$target2/mnt" || skip "second bind unavailable"
# Run in a subshell: _safe_rm_rf REFUSES via `die` (=exit), which would
# otherwise blow past this `if` and kill the test.  A refusal (subshell exits
# non-zero) is the PASS case here.
if ( _safe_rm_rf "$target2" ) 2>/dev/null; then
    umount -l "$target2/mnt" 2>/dev/null || true
    fail "REGRESSION: _safe_rm_rf deleted a tree with an active mount under it"
fi
umount -l "$target2/mnt" 2>/dev/null || true
[[ -f "$src/sentinel" ]] || fail "fail-closed path still clobbered the source"
note "_safe_rm_rf fails closed on a still-mounted tree"

pass "destroy unmounts (ground-truthed) before rm -rf; never recurses a live bind"
