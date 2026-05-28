#!/usr/bin/env bash
# Unit tests for the three new build variants:
#   (1) musl — build_busybox_musl skips aarch64, requires musl-gcc on x86_64
#   (2) tiny — build_kernel_tiny uses tinyconfig + our minimal symbol set;
#              assert the required symbols are set and asserted
#   (3) baked — pack_busybox_baked writes a cpio SPEC and sets
#               CONFIG_INITRAMFS_SOURCE; spec format is valid
#   (4) compare_sizes — runs cleanly with no artifacts (all "—")
#
# All tests are static/offline (no kernel compile, no Docker).
# shellcheck disable=SC2034  # globals declared for sourced functions

. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export MLBUILD_OUT_DIR="$tmp/out"
export MLBUILD_LOCK_FILE="$tmp/versions.lock"
# shellcheck disable=SC1090
source "$MLBUILD"

# ── (1) musl: aarch64 always skips, x86_64 checks for musl-gcc ─────────────
# We can't ACTUALLY build, but we can verify the guard logic.

# aarch64 should skip (warn, return 0) regardless of musl-gcc presence.
note "musl aarch64 skip"
build_busybox_musl aarch64 /nonexistent 2>/dev/null; rc=$?
[[ "$rc" -eq 0 ]] || fail "musl aarch64: expected return 0 (skip), got $rc"
note "musl aarch64 returns 0 (skip)"

# x86_64 must die when musl-gcc is absent (PATH override).
note "musl x86_64 fails cleanly without musl-gcc"
out="$(PATH="" build_busybox_musl x86_64 /nonexistent 2>&1)" && fail "expected die, got 0" || true
echo "$out" | grep -qi "musl" || fail "error message must mention musl; got: $out"
note "musl x86_64 error mentions musl-gcc"

# ── (2) tiny: set_kconfig/assert_kconfig wiring in build_kernel_tiny ────────
note "tiny: code-level wiring"
bkt="$(sed -n '/^build_kernel_tiny()/,/^}/p' "$MLBUILD")"
[[ -n "$bkt" ]] || fail "cannot extract build_kernel_tiny() from mlbuild.sh"
grep -q 'tinyconfig'      <<<"$bkt" || fail "build_kernel_tiny doesn't use tinyconfig"
grep -q 'VIRTIO_MMIO'     <<<"$bkt" || fail "build_kernel_tiny doesn't set VIRTIO_MMIO"
grep -q 'BLK_DEV_INITRD'  <<<"$bkt" || fail "build_kernel_tiny doesn't set BLK_DEV_INITRD"
grep -q 'DEVTMPFS'        <<<"$bkt" || fail "build_kernel_tiny doesn't set DEVTMPFS"
grep -q 'SERIAL_8250_CONSOLE\|SERIAL_AMBA_PL011_CONSOLE' <<<"$bkt" \
    || fail "build_kernel_tiny doesn't set a serial console"
grep -q 'kmake_oot'       <<<"$bkt" || fail "build_kernel_tiny must use kmake_oot (out-of-tree)"
grep -q 'assert_kconfig'  <<<"$bkt" || fail "build_kernel_tiny must assert CONFIG_VIRTIO_MMIO"
note "build_kernel_tiny wiring OK"

# ── (3) baked: emit_cpio_spec + INITRAMFS_SOURCE wiring ─────────────────────
note "baked: emit_cpio_spec produces a parseable spec"
# Need a plausible _install tree and /init for emit_cpio_spec.
install -d "$tmp/out/x86_64/_install/bin" "$tmp/out/x86_64/_install/sbin"
printf '#!/bin/sh\n' > "$tmp/out/x86_64/_install/bin/busybox"
chmod +x "$tmp/out/x86_64/_install/bin/busybox"
ln -s /bin/busybox "$tmp/out/x86_64/_install/bin/sh"
install -d "$tmp/out/x86_64/_install/usr/share/udhcpc"
fake_init="$tmp/fake-init"; printf '#!/bin/sh\necho hi\n' > "$fake_init"
# SCRIPT_DIR is readonly (set by mlbuild.sh); use the real one — udhcpc.script
# lives there and emit_cpio_spec references it.
[[ -r "$SCRIPT_DIR/udhcpc.script" ]] || fail "udhcpc.script not found at $SCRIPT_DIR — sourcing issue?"
etc="$(stage_etc)"
spec_out="$(emit_cpio_spec "$fake_init" "$tmp/out/x86_64/_install" "$etc")"
[[ -n "$spec_out" ]] || fail "emit_cpio_spec produced no output"
grep -q '^file /init ' <<<"$spec_out" || fail "spec missing /init entry"
grep -q '^dir /proc '  <<<"$spec_out" || fail "spec missing /proc dir"
note "emit_cpio_spec output looks valid"

# pack_busybox_baked wiring: INITRAMFS_SOURCE must be set + out-of-tree build
pbk="$(sed -n '/^pack_busybox_baked()/,/^}/p' "$MLBUILD")"
[[ -n "$pbk" ]] || fail "cannot extract pack_busybox_baked() from mlbuild.sh"
grep -q 'INITRAMFS_SOURCE'           <<<"$pbk" || fail "pack_busybox_baked must set INITRAMFS_SOURCE"
grep -q 'INITRAMFS_COMPRESSION_GZIP' <<<"$pbk" || fail "pack_busybox_baked must enable gzip compression"
grep -q 'kmake_oot'                  <<<"$pbk" || fail "pack_busybox_baked must use kmake_oot (out-of-tree)"
grep -q 'kernel-baked'               <<<"$pbk" || fail "pack_busybox_baked must output kernel-baked"
note "pack_busybox_baked wiring OK"

# ── (4) compare_sizes: runs cleanly with no artifacts ───────────────────────
note "compare_sizes with no artifacts"
ARCHES=(x86_64 aarch64)
# Capture before grepping — piping to grep -q causes SIGPIPE on grep exit,
# which with set -o pipefail makes the pipeline exit 141 even when grep found
# the pattern.  (Same trap as Phase 3 cmd_list.)
cmp_out="$(compare_sizes 2>&1)"
grep -q "arch" <<<"$cmp_out" || fail "compare_sizes produced no header; got: $cmp_out"
note "compare_sizes header present"

# ── (5) kmake_oot: O= flag is present ───────────────────────────────────────
note "kmake_oot includes O= flag"
km_oot_src="$(grep -A5 '^kmake_oot()' "$MLBUILD")"
grep -q 'O="$bdir"' <<<"$km_oot_src" || fail "kmake_oot must pass O= to make"
note "kmake_oot OK"

# ── (6) CLI: new flags present in parse/usage ────────────────────────────────
note "CLI flags exist"
grep -q '\-\-musl'         "$MLBUILD" || fail "--musl not in mlbuild.sh"
grep -q '\-\-tiny'         "$MLBUILD" || fail "--tiny not in mlbuild.sh"
grep -q '\-\-baked'        "$MLBUILD" || fail "--baked not in mlbuild.sh"
grep -q '\-\-compare'      "$MLBUILD" || fail "--compare not in mlbuild.sh"
grep -q '\-\-all-variants' "$MLBUILD" || fail "--all-variants not in mlbuild.sh"
note "CLI flags OK"

pass "variant wiring OK (musl skip, tiny tinyconfig, baked INITRAMFS_SOURCE)"
