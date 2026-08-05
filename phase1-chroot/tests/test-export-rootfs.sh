#!/usr/bin/env bash
# export-rootfs builds a POPULATED raw ext4 image from a directory, with no loop mount and
# no privilege — MICRO_CLOUD_LAB_PLAN.md §6. Host-safe: everything happens in a temp dir,
# nothing is mounted, no chroot is created, and the test needs no root.
#
# The positive case is the cheap half. What earns this file its place are the four negative
# controls: an all-PASS suite is indistinguishable from one that checks nothing, so each
# assertion below is paired with a run that must make it bite.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd mkfs.ext4 debugfs truncate du

# lib.sh has no EXIT net of its own, so this test brings one: a `die` inside lab-chroot.sh
# is an exit, and an unguarded one would otherwise end the run with a bare rc and NO
# verdict line. _VERDICT keeps the net from adding noise after a real verdict.
_VERDICT=0
skip()  { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail()  { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass()  { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }

tmp="$(mktemp -d)"
_on_exit() {
    local rc=$?
    # Restore permissions BEFORE removing: negative control 5 creates a chmod-000 directory,
    # and if the test fails before its own restore line, rm cannot descend into it and the
    # temp dir leaks. Found by running that control's own negative control.
    chmod -R u+rwX -- "$tmp" 2>/dev/null || true
    rm -rf -- "$tmp"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

# Run lab-chroot.sh WITHOUT letting a pipe decide the exit status (house rule: `cmd | tail`
# reports tail's status, and that once merged a red PR).
run_lc() {  # run_lc <outfile> <args...>
    local out="$1"; shift
    set +e
    bash "$LAB_CHROOT" "$@" > "$out" 2>&1
    local rc=$?
    set -e
    return "$rc"
}

# ── a minimal but realistic tree: an init, a readable marker, a modules dir to strip ──
tree="$tmp/tree"
mkdir -p "$tree"/{sbin,etc,lib/modules/6.1.0-test,usr/bin}
printf '#!/bin/sh\nexec /bin/sh\n' > "$tree/sbin/init"; chmod 0755 "$tree/sbin/init"
printf 'mc-export-rootfs-marker\n' > "$tree/etc/hostname"
# 24 MB, and the size is load-bearing, not arbitrary. The default size is
# du*1.5 + 32M floored at 64M, so a tree over ~21 MB is the ONLY kind that takes the
# branch where the floor does NOT apply. The first version of this test used a 3 MB tree
# and passed while `(( bytes < 64M )) && bytes=...` was killing the verb under `set -e`
# for every real tree — an arithmetic command returns 1 when its expression is false.
# The synthetic tree was small enough to always be true, so the bug was invisible here and
# instantly visible on the 202 MB Debian tree.
head -c 24000000 /dev/urandom > "$tree/lib/modules/6.1.0-test/bulk.ko"

# ═══ POSITIVE ═══════════════════════════════════════════════════════════════
img="$tmp/out.ext4"
run_lc "$tmp/o1" export-rootfs "$tree" --output "$img" --label mcroot \
    || { cat "$tmp/o1" >&2; fail "export-rootfs refused a well-formed tree: $(tail -1 "$tmp/o1")"; }
[[ -f "$img" ]] || fail "no image at $img"

# Assert the OUTCOME (the bytes are readable as a filesystem), not the mechanism (that a
# command exited 0). Read the marker back out of the image with no mount.
got="$(debugfs -R "cat /etc/hostname" "$img" 2>/dev/null | tr -d '\0')"
[[ "$got" == *mc-export-rootfs-marker* ]] \
    || fail "the image does not contain the source tree's /etc/hostname (read back: '${got:0:40}')"
note "content round-trips: /etc/hostname read back out of the image with debugfs"

debugfs -R "stat /sbin/init" "$img" 2>/dev/null | grep -q 'Inode:' \
    || fail "/sbin/init is missing from an image built from a tree that has one"
[[ "$(blkid -s LABEL -o value "$img" 2>/dev/null)" == mcroot ]] \
    || note "label not readable via blkid here (not fatal)"
note "no loop device was used: $(losetup -a 2>/dev/null | grep -c "$tmp" || true) loop devices reference this tmpdir"

# ═══ NEGATIVE CONTROL 1 — a tree with no /sbin/init must FAIL, not pass ═════
bad="$tmp/noinit"; mkdir -p "$bad/etc"; printf 'x\n' > "$bad/etc/hostname"
if run_lc "$tmp/o2" export-rootfs "$bad" --output "$tmp/bad.ext4"; then
    fail "REGRESSION: an image with no /sbin/init was accepted — a guest kernel would panic on it"
fi
grep -q 'no /sbin/init' "$tmp/o2" \
    || fail "the no-init run failed, but not for the stated reason: $(tail -1 "$tmp/o2")"
note "negative control 1 bit: a tree with no /sbin/init is refused, by name"

# ═══ NEGATIVE CONTROL 2 — too small must fail loudly AND leave no partial image ═══
if run_lc "$tmp/o3" export-rootfs "$tree" --output "$tmp/small.ext4" --size 2M; then
    fail "REGRESSION: a 2M image accepted for a tree that cannot fit in it"
fi
[[ ! -e "$tmp/small.ext4" ]] \
    || fail "REGRESSION: the undersized run left a partial image behind — a later run would boot garbage"
note "negative control 2 bit: undersized refused, and the partial image was removed"

# ═══ NEGATIVE CONTROL 3 — an unimplemented --fstype is refused BY NAME ═════
if run_lc "$tmp/o4" export-rootfs "$tree" --output "$tmp/x.img" --fstype xfs; then
    fail "REGRESSION: --fstype xfs was accepted, so the image is ext4 while the caller asked for xfs"
fi
grep -q 'CANNOT BE POPULATED WITHOUT A MOUNT' "$tmp/o4" \
    || fail "--fstype xfs was refused without saying why (a refusal nobody can act on): $(tail -1 "$tmp/o4")"
[[ ! -e "$tmp/x.img" ]] || fail "the refused --fstype run still created a file"
note "negative control 3 bit: --fstype xfs refused with its measured reason, no file created"

# ═══ NEGATIVE CONTROL 4 — an existing output is not silently overwritten ═══
if run_lc "$tmp/o5" export-rootfs "$tree" --output "$img"; then
    fail "REGRESSION: an existing image was overwritten without --force — something may be booting it"
fi
run_lc "$tmp/o6" export-rootfs "$tree" --output "$img" --force \
    || fail "--force did not permit the overwrite: $(tail -1 "$tmp/o6")"
note "negative control 4 bit: overwrite refused without --force, permitted with it"

# ═══ --strip-modules actually removes bytes, and does not touch the source ═══
run_lc "$tmp/o7" export-rootfs "$tree" --output "$tmp/stripped.ext4" --strip-modules --size 64M \
    || { cat "$tmp/o7" >&2; fail "--strip-modules run failed: $(tail -1 "$tmp/o7")"; }
if debugfs -R "stat /lib/modules/6.1.0-test/bulk.ko" "$tmp/stripped.ext4" 2>/dev/null | grep -q 'Inode:'; then
    fail "REGRESSION: --strip-modules left /lib/modules in the image"
fi
[[ -f "$tree/lib/modules/6.1.0-test/bulk.ko" ]] \
    || fail "REGRESSION: --strip-modules deleted from the SOURCE tree, not the staging farm"
compgen -G "$(dirname "$tmp/stripped.ext4")/.export-rootfs-farm.*" >/dev/null \
    && fail "--strip-modules left its staging farm behind"
note "strip-modules: image lacks the module, source tree intact, no staging dir left"

# ═══ NEGATIVE CONTROL 5 — an unreadable source file is refused BEFORE the allocation ═══
# mke2fs is honest about this (measured: it exits 1 naming the file), but only after the
# image has been allocated and partly written. The gate must fire first and say what to do.
# Root skips: root can read everything, so the condition cannot be constructed.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    unread="$tmp/unread"; mkdir -p "$unread/sbin" "$unread/etc" "$unread/root"
    printf '#!/bin/sh\n' > "$unread/sbin/init"; chmod 0755 "$unread/sbin/init"
    printf 'secret\n' > "$unread/etc/shadow"; chmod 000 "$unread/etc/shadow"
    # An unreadable DIRECTORY as well as an unreadable file, and the difference matters:
    # only the directory makes `find` itself exit non-zero, which is what arms the
    # `find | head` + pipefail trap in the gate. With only the chmod-000 file, the guard
    # that turned out to be genuinely load-bearing was never exercised — the refusal
    # message was asserted while the silent-exit path it protects went untested.
    printf 'x\n' > "$unread/root/.ssh-key"; chmod 000 "$unread/root"
    if run_lc "$tmp/o8" export-rootfs "$unread" --output "$tmp/unread.ext4"; then
        fail "REGRESSION: a tree with unreadable files was accepted — mkfs would abort partway through"
    fi
    grep -q 'cannot read' "$tmp/o8" \
        || fail "the unreadable-tree run failed without naming the cause: $(tail -1 "$tmp/o8")"
    grep -q 'etc/shadow' "$tmp/o8" \
        || fail "the refusal did not name WHICH file could not be read — an alarm nobody can act on"
    [[ ! -e "$tmp/unread.ext4" ]] \
        || fail "REGRESSION: refused for unreadable files but allocated the image anyway (a gate after the act is a post-mortem)"
    # The refusal must be a REFUSAL, not a silent death. Re-injecting the unguarded
    # `find … | head` makes this exact run exit 1 with zero bytes of output, which a test
    # asserting only "it failed" would happily call a pass.
    [[ -s "$tmp/o8" ]] \
        || fail "REGRESSION: the run exited non-zero with NO output at all — a silent exit is a bug, not a refusal"
    chmod 0755 "$unread/root" 2>/dev/null || true   # so the EXIT trap's rm -rf can clean up
    note "negative control 5 bit: unreadable source refused by name and out loud, before any allocation"
else
    note "negative control 5 SKIPPED as root — the condition cannot be constructed (root reads everything)"
fi

pass "export-rootfs builds a readable ext4 from a directory with no mount — and every negative control bit"
