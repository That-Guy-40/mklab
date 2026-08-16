#!/usr/bin/env bash
# Regression (REVIEW-phase1.md, P1-2): the H1 fail-closed mount guard must see a live mount
# under a chroot path that contains a SPACE.
#
# THE BUG. /proc/mounts octal-escapes whitespace, so a bind under `/x/spacey dir/tree` is
# written by the kernel as `/x/spacey\040dir/tree`. `_mounts_under` compared field 2
# LITERALLY, so it matched nothing: the mount was neither force-unmounted nor caught by
# `_safe_rm_rf`'s "still has active mounts — refusing rm -rf" assertion, and `rm -rf` then
# recursed straight THROUGH the live bind — which on a real chroot is the host's /dev. That
# is the H1 incident the assertion exists to prevent, reopened by a parsing detail.
#
# The old code comment waved it away ("lab targets live under the state dir and don't contain
# such characters"). True of the auto-derived state path; false of the arbitrary absolute path
# `enter <path>` / `destroy <path>` take from the user, which `bind_essentials` mounts /dev
# under and which nothing rejects a space in.
#
# WHY THIS RUNS WITHOUT ROOT. A bind mount needs CAP_SYS_ADMIN — but only in the namespace
# doing the mounting, so the whole test re-execs itself inside `unshare -rm`. That matters:
# phase 1's other mount test was root-gated and therefore SKIPPED on every CI run, which is
# how a guard rots unwatched. This one needs only a user namespace.
#
# ⚠️ THAT IS NOT AUTOMATICALLY BROADER. Ubuntu 24.04 ships
# kernel.apparmor_restrict_unprivileged_userns=1, which denies unprivileged userns to
# unconfined binaries — so on a stock GitHub runner this SKIPped too (measured on PR #199),
# swapping one unwatched guard for another. CI now relaxes that sysctl explicitly and logs
# a ::warning:: if it could not, so a future runner-image change is visible rather than
# quietly turning this back into a skip.
#
# THREE ASSERTIONS, AND TWO OF THEM ARE CONTROLS:
#   1. positive — with the shipped guard, `_safe_rm_rf` REFUSES the space-bearing tree and
#      the bind source survives.
#   2. control — a space-free tree with NO mounts is still removed, so #1 cannot be passing
#      because the guard started refusing everything.
#   3. negative control — the pre-fix parser is re-injected and the SAME call deletes the
#      sentinel through the live bind. Without this, #1 proves only that something was
#      printed; with it, #1 is known to be measuring the defect.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd unshare mountpoint realpath awk

# ── re-exec inside a user+mount namespace ───────────────────────────────────────────────
require_userns_or_root P1_ESCAPED_MOUNT_NS

work="$(mktemp -d)"
export LAB_STATE_DIR="$work/state" LAB_CACHE_DIR="$work/cache"
source "$LAB_CHROOT"                        # the real driver, via its sourced-not-run guard

# Teardown must unmount BEFORE removing anything, or it would commit the very error under
# test. It uses the fixed parser deliberately — and refuses to remove the tree if anything
# is still mounted, so a broken run leaves evidence instead of recursing through a bind.
_teardown() {
    local mp left
    while IFS= read -r mp; do
        [[ -n "$mp" ]] && umount -l "$mp" 2>/dev/null
    done < <(_mounts_under "$work")
    left="$(_mounts_under "$work")"
    if [[ -n "$left" ]]; then
        printf '  - NOT removing %s: still mounted:\n%s\n' "$work" "$left" >&2
    else
        rm -rf -- "$work"
    fi
}
on_exit '_teardown'

# ── fixture: a chroot whose path contains a space, with a live bind under it ─────────────
spacey="$work/spacey dir/tree"
src="$work/host-dev-standin"
mkdir -p "$spacey/dev" "$src"
echo "DO-NOT-DELETE" > "$src/sentinel"
mount --bind "$src" "$spacey/dev" || skip "bind mount unavailable even in a user namespace"
mountpoint -q "$spacey/dev"       || fail "setup: the bind mount did not take"

# The kernel really does escape it — if it stopped, this test would be proving nothing.
grep -q 'spacey\\040dir' /proc/mounts \
    || fail "setup: /proc/mounts does not octal-escape the space in this path, so the defect under test cannot be reproduced here (kernel wrote: $(awk '/spacey/{print $2}' /proc/mounts | head -1))"
note "the kernel writes the mountpoint as spacey\\040dir — the escaping this guard must decode"

# ── 1. POSITIVE: the guard sees it, and _safe_rm_rf refuses ──────────────────────────────
[[ -n "$(_mounts_under "$spacey")" ]] \
    || fail "REGRESSION: _mounts_under is blind to a live mount under a path containing a space — /proc/mounts writes it as spacey\\040dir and the comparison is literal again. rm -rf would recurse through the bind into the host's /dev (REVIEW-phase1.md P1-2)"

# `_safe_rm_rf` refuses via `die`, which is `exit` — in a subshell so it cannot blow past
# these assertions and leave the terminal blank (CLAUDE.md's silent-exit trap).
refused_out="$( ( _safe_rm_rf "$spacey" ) 2>&1 )" && refused_rc=0 || refused_rc=$?
(( refused_rc != 0 )) \
    || fail "REGRESSION: _safe_rm_rf DELETED a tree with a live bind mount under it because the path contains a space — the H1 fail-closed assertion did not fire"
grep -q 'refusing rm -rf' <<<"$refused_out" \
    || fail "_safe_rm_rf failed for some other reason than the mount guard, so this test is not measuring the guard. Got: $(tr '\n' ' ' <<<"$refused_out")"
[[ -f "$src/sentinel" && "$(cat "$src/sentinel")" == "DO-NOT-DELETE" ]] \
    || fail "REGRESSION: the bind source was deleted through the live bind — on a real chroot this is the host's /dev"
[[ -d "$spacey" ]] || fail "the tree was removed despite the refusal"
note "space-bearing path: guard sees the mount, _safe_rm_rf refuses, bind source intact  ✓"

# ── 2. CONTROL: an unmounted tree is still removed ───────────────────────────────────────
# Without this, assertion 1 would also pass if the guard had begun refusing unconditionally —
# a guard that never lets anything through is not a working guard, it is a broken one.
plain="$work/plain/tree"
mkdir -p "$plain/dev"
( _safe_rm_rf "$plain" ) 2>/dev/null \
    || fail "_safe_rm_rf refused a tree with NOTHING mounted under it — the guard is refusing unconditionally, which would make assertion 1 pass for the wrong reason"
[[ ! -e "$plain" ]] || fail "_safe_rm_rf returned success but the tree is still there"
note "control: a tree with no mounts is still removed, so the refusal is not unconditional  ✓"

# ── 3. NEGATIVE CONTROL: re-inject the pre-fix parser and watch the bind get deleted ─────
# Contained in a subshell, so the blind definition cannot leak into teardown above. The
# sentinel it destroys lives in this test's own mktemp tree.
spacey2="$work/spacey2 dir/tree"
src2="$work/host-dev-standin-2"
mkdir -p "$spacey2/dev" "$src2"
echo "DO-NOT-DELETE" > "$src2/sentinel"
mount --bind "$src2" "$spacey2/dev" || skip "second bind unavailable"

blind_out="$( (
    # verbatim the pre-2026-08-15 implementation: a literal compare against field 2
    _mounts_under() {
        local real; real="$(realpath -m "$1" 2>/dev/null || printf '%s' "$1")"
        awk -v t="$real" '
            $2==t || index($2, t "/")==1 { print length($2) "\t" $2 }
        ' /proc/mounts 2>/dev/null | sort -rn | cut -f2-
    }
    _safe_rm_rf "$spacey2"
) 2>&1 )" || true

grep -q 'refusing rm -rf' <<<"$blind_out" \
    && fail "the re-injected pre-fix parser REFUSED too, so assertion 1 above proves nothing about the escaping — this test is not exercising what it claims"
[[ ! -f "$src2/sentinel" ]] \
    || fail "the re-injected pre-fix parser did NOT delete the bind source, so the defect this test guards is not reproducible here and assertion 1 is unproven"
note "negative control: the pre-fix parser deletes the bind source through the live mount — assertion 1 is measuring the real defect  ✓"

umount -l "$spacey2/dev" 2>/dev/null || true

pass "the mount guard decodes /proc/mounts' octal escapes: a live bind under a space-bearing chroot path is seen and _safe_rm_rf refuses it (with the pre-fix parser re-injected, the same call deletes the bind source), while an unmounted tree is still removed"
