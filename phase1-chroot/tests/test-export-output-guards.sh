#!/usr/bin/env bash
# Regression (REVIEW-phase1.md §3): the export verbs must refuse to clobber their output.
#
# THE BUG. Default output names are keyed on the chroot's BASENAME (`/tmp/<label>.tar.gz`),
# so two chroots sharing one silently overwrote each other's artifacts. `export-rootfs`
# already refused an existing file; `export-tarball` and `export-initrd` did not — an
# inconsistent fleet where the quiet member is the dangerous one.
#
# AND THE GUARD THAT EXISTED WAS INCOMPLETE. It tested `[[ -e "$out" ]]`, and `-e` FOLLOWS
# the symlink: a DANGLING symlink at the output path reads as "does not exist", so the guard
# stayed quiet and the write landed on the link's target instead. `/tmp/<basename>.ext4` is a
# predictable name in a world-writable directory and `export-rootfs` runs as ROOT, which
# makes that an arbitrary-file-write primitive rather than a mere clobber. `-L` sees it
# whether or not the link resolves.
#
# Runs unprivileged: `export-tarball` needs no root, and a refusal is observable before any
# privileged step. `export-rootfs` (the root-only verb) shares the same
# `refuse_existing_output`, and §4 asserts that sharing directly rather than needing root.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd tar

work="$(mktemp -d)"
on_exit 'rm -rf -- "$work"'
export LAB_STATE_DIR="$work/state" LAB_CACHE_DIR="$work/cache"

tree="$work/tree"
mkdir -p "$tree/etc"
echo "content" > "$tree/etc/marker"

# ── 1. an existing output is refused, and NOT touched ────────────────────────────────────
out="$work/existing.tar.gz"
# Compared with `cmp` against a saved copy, not `$(cat)`: the file becomes a gzip in §2 and
# command substitution drops null bytes (and would warn), so a text compare is both noisy
# and unable to see a binary difference.
echo "PRECIOUS-DO-NOT-CLOBBER" > "$out"
before="$work/before.copy"; cp "$out" "$before"
o="$(bash "$LAB_CHROOT" export-tarball "$tree" --output "$out" 2>&1)" && rc=0 || rc=$?
(( rc != 0 )) \
    || fail "REGRESSION: 'export-tarball' overwrote an existing output file without --force (REVIEW-phase1.md §3). Two chroots sharing a basename silently destroy each other's artifacts"
cmp -s "$out" "$before" \
    || fail "REGRESSION: 'export-tarball' refused but the output file was modified anyway"
grep -q 'already exists' <<<"$o" \
    || fail "'export-tarball' failed for some reason other than the clobber guard, so this is not measuring it. Got: $(tr '\n' ' ' <<<"$o")"
note "an existing output is refused without --force, and left byte-identical  ✓"

# ── 2. CONTROL: --force still overwrites, and a fresh path still works ───────────────────
# Without this, §1 would also pass if export-tarball had simply stopped working.
bash "$LAB_CHROOT" export-tarball "$tree" --output "$out" --force >/dev/null 2>&1 \
    || fail "CONTROL FAILED: --force did not overwrite the existing output, so the guard is refusing unconditionally and §1 proves nothing"
if cmp -s "$out" "$before"; then
    fail "CONTROL FAILED: --force returned success but the file still holds the old content"
fi
tar -tzf "$out" >/dev/null 2>&1 \
    || fail "CONTROL FAILED: --force produced something that is not a readable tarball"
fresh="$work/fresh.tar.gz"
bash "$LAB_CHROOT" export-tarball "$tree" --output "$fresh" >/dev/null 2>&1 \
    || fail "CONTROL FAILED: exporting to a path that does not exist was refused"
[[ -s "$fresh" ]] || fail "CONTROL FAILED: the fresh export produced an empty file"
note "control: --force overwrites, and a fresh output path still exports normally  ✓"

# ── 3. a DANGLING symlink is refused, and its target is not created ──────────────────────
# The `-e`-only guard could not see this: `-e` follows the link, finds nothing, and lets the
# write through onto whatever the link points at.
victim="$work/victim-should-never-be-created"
link="$work/dangling.tar.gz"
ln -s "$victim" "$link"
[[ ! -e "$link" ]] || fail "setup: the dangling symlink resolves, so it cannot demonstrate the -e blind spot"
o3="$(bash "$LAB_CHROOT" export-tarball "$tree" --output "$link" 2>&1)" && rc3=0 || rc3=$?
(( rc3 != 0 )) \
    || fail "REGRESSION: 'export-tarball' wrote through a DANGLING symlink — \`-e\` follows the link and reports 'absent', so a predictable name in a world-writable directory redirects the write to an attacker-chosen path"
[[ ! -e "$victim" ]] \
    || fail "REGRESSION: the write went through the symlink and created $victim"
grep -q 'symlink' <<<"$o3" \
    || fail "'export-tarball' refused the symlink for some other reason, so this is not measuring the -L guard. Got: $(tr '\n' ' ' <<<"$o3")"
# …and --force must NOT be an escape hatch for it: a symlink is a redirect, not a collision.
o3f="$(bash "$LAB_CHROOT" export-tarball "$tree" --output "$link" --force 2>&1)" && rc3f=0 || rc3f=$?
(( rc3f != 0 )) \
    || fail "REGRESSION: --force overrode the SYMLINK refusal. --force means 'I accept losing the file at this path', not 'follow a link somewhere else'"
[[ ! -e "$victim" ]] || fail "REGRESSION: --force wrote through the symlink and created $victim"
note "a dangling symlink output is refused, --force does not override it, and its target was never created  ✓"

# ── 4. the guard is SHARED, so the root-only verb has it too ─────────────────────────────
# export-rootfs needs root and would skip here; assert the single implementation is what all
# the output paths call, so this test's evidence carries to the verb it cannot run.
sites="$(grep -c 'refuse_existing_output "' "$LAB_CHROOT")"
(( sites >= 4 )) \
    || fail "expected all 4 export output paths (tarball, initrd, kernel, rootfs) to call the shared refuse_existing_output guard; found $sites"
grep -q 'refuse_existing_output "\$out" "an image something may be booting"' "$LAB_CHROOT" \
    || fail "export-rootfs no longer uses the shared guard, so it has drifted back to its own -e-only check that a dangling symlink defeats"
note "all 4 export output paths call the one shared guard, including root-only export-rootfs  ✓"

pass "export outputs are refused rather than silently clobbered: an existing file needs --force, a dangling symlink is refused outright and --force does not override it, and all four output paths share one guard"
