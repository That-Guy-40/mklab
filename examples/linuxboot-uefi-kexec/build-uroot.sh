#!/usr/bin/env bash
# build-uroot.sh — build the u-root userland: the Go "init that is the bootloader".
#
# Produces two initramfs images in $WORKDIR:
#   initramfs.cpio         — plain u-root; boots to a u-root shell (Stage A / a sanity boot)
#   initramfs-stage1.cpio  — u-root + an embedded kernel + an embedded 2nd initramfs
#                            + dokexec.sh wired to /bin/uinit, so init kexecs stage 2
#
# THE GOTCHA (cost the most time in the spike): `go install u-root@latest` makes
# Go's GOTOOLCHAIN=auto silently download go1.25, under which u-root fails with
# "package core is not in std". Fix: GOTOOLCHAIN=local (use the apt Go 1.22) AND
# build from the u-root *source tree* — the `core`/`boot` keywords are u-root's own
# command globs and only resolve in-tree. See POC-MATRYOSHKA.md §2.
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
KERNEL="${KERNEL:-$WORKDIR/vmlinuz}"
UROOT_REF="${UROOT_REF:-v0.14.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$WORKDIR"

[[ -f "$KERNEL" ]] || { echo "no kernel at $KERNEL — run ./fetch-kernel.sh first" >&2; exit 1; }

# --- 1. clone + build the u-root tool under the pinned Go (not the auto one) ---
if [[ ! -x "$WORKDIR/u-root/u-root" ]]; then
  [[ -d "$WORKDIR/u-root" ]] || \
    git clone --depth 1 -b "$UROOT_REF" https://github.com/u-root/u-root "$WORKDIR/u-root"
  ( cd "$WORKDIR/u-root" && GOTOOLCHAIN=local go build -o u-root . )
fi
cd "$WORKDIR/u-root"
UROOT=./u-root

# --- 2. plain image: a LinuxBoot userland (/init + kexec), boots to a shell ---
GOTOOLCHAIN=local "$UROOT" -build=bb -o "$WORKDIR/initramfs.cpio" core boot

# --- 3. stage-1 image: the same userland, PLUS the payload it will kexec ---
#   /boot/bzImage        the kernel to hand off to
#   /boot/initramfs2.cpio the 2nd-stage rootfs (here: a copy of the plain image)
#   /bin/dokexec.sh      the boot policy, run via -uinitcmd
GOTOOLCHAIN=local "$UROOT" -build=bb \
  -uinitcmd="gosh /bin/dokexec.sh" \
  -files "$KERNEL:boot/bzImage" \
  -files "$WORKDIR/initramfs.cpio:boot/initramfs2.cpio" \
  -files "$HERE/uroot/dokexec.sh:bin/dokexec.sh" \
  -o "$WORKDIR/initramfs-stage1.cpio" core boot
cd "$HERE"

echo "==> checkpoints"
ls -lh "$WORKDIR/initramfs.cpio" "$WORKDIR/initramfs-stage1.cpio"
echo "    /init + kexec present in the userland:"
cpio -itv < "$WORKDIR/initramfs.cpio" 2>/dev/null | grep -E '(^|/)(init$|bbin/kexec)' || true
echo "    payload embedded in stage-1:"
cpio -itv < "$WORKDIR/initramfs-stage1.cpio" 2>/dev/null | grep -E 'boot/(bzImage|initramfs2)|bin/dokexec' || true
echo "==> u-root built.  Next: ./run-linuxboot.sh (Tier C)  then  ./build-uki.sh + ./run-uefi-linuxboot.sh (Tier B)"
