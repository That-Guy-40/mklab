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
require_cmd mountpoint realpath unshare

# ── THIS USED TO BE `require_root`, AND THAT MADE IT A TEST NOBODY RAN ───────────────────
# A bind mount needs CAP_SYS_ADMIN — but only in the namespace doing the mounting, so the
# test re-execs itself inside `unshare -rm` instead of being root-gated. Before this
# (2026-08-15) it SKIPped on every unprivileged run, which means the H1 guard it exists to
# protect went unwatched: exactly the shape of "an assertion never observed failing is not
# known to work". Its sibling test-mount-guard-escaped-paths.sh was written this way from
# the start; this brings the older one up to it.
#
# The mount namespace also means the binds below vanish with the process, so a crashed run
# cannot leave a live bind pointing into this test's scratch tree.
if [[ -z "${P1_MOUNT_GUARD_NS:-}" ]]; then
    if unshare -rm true 2>/dev/null; then
        export P1_MOUNT_GUARD_NS=1
        exec unshare -rm bash "$(realpath "${BASH_SOURCE[0]}")"
    elif [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        export P1_MOUNT_GUARD_NS=1      # already root: mount directly
    else
        skip "needs unprivileged user namespaces (unshare -rm) or root to create a bind mount"
    fi
fi

work="$(mktemp -d)"
# Unmount any stragglers before removing the workdir. lib.sh's net prints the FAIL
# verdict if this test exits early (an uncaught `die`/`set -e`); it must not be
# re-implemented here, because a second `trap … EXIT` would REPLACE it.
_unmount_stragglers() {
    awk -v t="$work" 'index($2, t)==1 {print $2}' /proc/mounts 2>/dev/null \
        | sort -r | while IFS= read -r m; do umount -l "$m" 2>/dev/null || true; done
    rm -rf -- "$work"
}
on_exit '_unmount_stragglers'

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

# IN A SUBSHELL, AND THE FAILURE IS NAMED. `manager_none_destroy` reaches `_safe_rm_rf`,
# which refuses via `die` (= exit) — called bare, that exit blows straight past every
# assertion below and the run ends on a bare rc with no verdict. Measured 2026-08-15 by
# re-injecting the H1 defect: the test died at exactly this line and printed only the
# harness net's generic "test exited early (rc=1)". A net firing is not a diagnosis.
#
# The two ways this can go wrong say different things, so they get different messages:
#   refused   → _force_unmount_tree left the bind live and _safe_rm_rf's assertion (the
#               SECOND guard) caught it. Defense in depth held, but the first guard is broken.
#   succeeded → the tree was removed; whether that recursed through the bind is what the
#               sentinel assertion below decides.
d_out="$( ( manager_none_destroy "$target" ) 2>&1 )" && d_rc=0 || d_rc=$?
if (( d_rc != 0 )); then
    if grep -q 'refusing rm -rf' <<<"$d_out"; then
        fail "REGRESSION: _force_unmount_tree did not unmount the live bind — destroy was stopped only by _safe_rm_rf's fail-closed assertion (the second guard). The tracking file was deliberately removed, so this is the H1 case: /proc/mounts ground truth is not being consulted. Got: $(tr '\n' ' ' <<<"$d_out")"
    fi
    fail "destroy failed for an unexpected reason (rc=$d_rc): $(tr '\n' ' ' <<<"$d_out")"
fi

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
