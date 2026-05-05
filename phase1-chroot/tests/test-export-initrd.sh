#!/usr/bin/env bash
# Test the `export-initrd` verb against a hand-built fake chroot.
# No root, no network, no debootstrap — just a directory tree shaped
# the way export-initrd expects.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd cpio gzip find

WORK="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT

# ─── helper: build a fresh fakeroot ─────────────────────────────────────────
mk_fakeroot() {
    local root="$WORK/fakeroot"
    rm -rf "$root"
    mkdir -p "$root/boot" "$root/bin" "$root/etc" \
             "$root/proc" "$root/sys" "$root/dev" \
             "$root/run"  "$root/tmp" "$root/lib/modules/6.1.0-test"
    # Fake kernel binary (content doesn't matter — only the filename pattern does)
    printf 'FAKE_KERNEL' > "$root/boot/vmlinuz-6.1.0-test"
    # A normal file that must appear in the initrd
    printf 'hello\n' > "$root/etc/hostname"
    # A file inside lib/modules to test --strip-modules
    printf 'fake module\n' > "$root/lib/modules/6.1.0-test/fake.ko"
    printf '%s' "$root"
}

# ─── test 1: auto-detect busybox ────────────────────────────────────────────
note "test 1: auto-detect busybox (no existing /init, busybox present)"
ROOT="$(mk_fakeroot)"
# Put a fake executable busybox so the auto-detect picks it up
printf '#!/bin/sh\necho busybox\n' > "$ROOT/bin/busybox"
chmod 0755 "$ROOT/bin/busybox"

KOUT="$WORK/t1-vmlinuz"
IOUT="$WORK/t1-initrd.gz"
T1_OUT="$("$LAB_CHROOT" export-initrd "$ROOT" --kernel "$KOUT" --output "$IOUT" 2>&1)"
printf '%s\n' "$T1_OUT" | grep -q 'busybox' || fail "test1: expected 'busybox' in log output"
[[ -f "$IOUT" ]] || fail "test1: initrd.gz not created"
[[ -f "$KOUT" ]] || fail "test1: vmlinuz not created"
# /init must contain busybox shebang
[[ -f "$ROOT/init" ]] || fail "test1: /init not written into fakeroot"
grep -q 'busybox' "$ROOT/init" || fail "test1: /init doesn't look like busybox preset"

# ─── test 2: auto-detect systemd (no busybox, no existing /init) ────────────
note "test 2: auto-detect systemd (no busybox)"
ROOT="$(mk_fakeroot)"   # no busybox this time

KOUT="$WORK/t2-vmlinuz"
IOUT="$WORK/t2-initrd.gz"
T2_OUT="$("$LAB_CHROOT" export-initrd "$ROOT" --kernel "$KOUT" --output "$IOUT" 2>&1)"
printf '%s\n' "$T2_OUT" | grep -q 'systemd' || fail "test2: expected 'systemd' in log output"
[[ -f "$ROOT/init" ]] || fail "test2: /init not written into fakeroot"
grep -q 'sbin/init' "$ROOT/init" || fail "test2: /init doesn't look like systemd preset"

# ─── test 3: --init-flavor busybox explicit ──────────────────────────────────
note "test 3: --init-flavor busybox explicit"
ROOT="$(mk_fakeroot)"

KOUT="$WORK/t3-vmlinuz"
IOUT="$WORK/t3-initrd.gz"
"$LAB_CHROOT" export-initrd "$ROOT" --kernel "$KOUT" --output "$IOUT" --init-flavor busybox 2>/dev/null
[[ -f "$ROOT/init" ]] || fail "test3: /init not written"
grep -q 'busybox' "$ROOT/init" || fail "test3: /init not busybox preset"

# ─── test 4: --init-flavor systemd explicit ──────────────────────────────────
note "test 4: --init-flavor systemd explicit"
ROOT="$(mk_fakeroot)"
# Put busybox so auto-detect would choose busybox; --init-flavor should override
printf '#!/bin/sh\necho busybox\n' > "$ROOT/bin/busybox"
chmod 0755 "$ROOT/bin/busybox"

KOUT="$WORK/t4-vmlinuz"
IOUT="$WORK/t4-initrd.gz"
"$LAB_CHROOT" export-initrd "$ROOT" --kernel "$KOUT" --output "$IOUT" --init-flavor systemd 2>/dev/null
[[ -f "$ROOT/init" ]] || fail "test4: /init not written"
grep -q 'sbin/init' "$ROOT/init" || fail "test4: /init not systemd preset"

# ─── test 5: --strip-modules excludes lib/modules ───────────────────────────
note "test 5: --strip-modules excludes lib/modules"
ROOT="$(mk_fakeroot)"

KOUT="$WORK/t5-vmlinuz"
IOUT="$WORK/t5-initrd.gz"
"$LAB_CHROOT" export-initrd "$ROOT" --kernel "$KOUT" --output "$IOUT" \
    --init-flavor busybox --strip-modules 2>/dev/null

# The fake.ko should NOT be in the archive
if zcat "$IOUT" | cpio -t 2>/dev/null | grep -q 'fake\.ko'; then
    fail "test5: lib/modules content found in initrd despite --strip-modules"
fi

# Without strip-modules the file IS present (control)
ROOT2="$(mk_fakeroot)"
IOUT2="$WORK/t5b-initrd.gz"
"$LAB_CHROOT" export-initrd "$ROOT2" --kernel "$WORK/t5b-vmlinuz" --output "$IOUT2" \
    --init-flavor busybox 2>/dev/null
if ! zcat "$IOUT2" | cpio -t 2>/dev/null | grep -q 'fake\.ko'; then
    fail "test5 control: lib/modules/fake.ko not found in initrd without --strip-modules"
fi

# ─── test 6: error when no vmlinuz ───────────────────────────────────────────
note "test 6: error on missing vmlinuz"
ROOT="$(mk_fakeroot)"
rm -f "$ROOT/boot/vmlinuz-6.1.0-test"

KOUT="$WORK/t6-vmlinuz"
IOUT="$WORK/t6-initrd.gz"
if "$LAB_CHROOT" export-initrd "$ROOT" --kernel "$KOUT" --output "$IOUT" 2>/dev/null; then
    fail "test6: should have failed with no vmlinuz"
fi

# ─── test 7: gzip header validation ─────────────────────────────────────────
note "test 7: gzip header"
ROOT="$(mk_fakeroot)"
KOUT="$WORK/t7-vmlinuz"
IOUT="$WORK/t7-initrd.gz"
"$LAB_CHROOT" export-initrd "$ROOT" --kernel "$KOUT" --output "$IOUT" \
    --init-flavor busybox 2>/dev/null

file "$IOUT" | grep -iq 'gzip' || fail "test7: $IOUT is not a gzip file"

# ─── test 8: cpio contains /init ─────────────────────────────────────────────
note "test 8: cpio contains ./init"
ROOT="$(mk_fakeroot)"
KOUT="$WORK/t8-vmlinuz"
IOUT="$WORK/t8-initrd.gz"
"$LAB_CHROOT" export-initrd "$ROOT" --kernel "$KOUT" --output "$IOUT" \
    --init-flavor busybox 2>/dev/null

zcat "$IOUT" | cpio -t 2>/dev/null | grep -q '\./init\|^init$' \
    || fail "test8: ./init not found in cpio archive"

pass "export-initrd OK"
