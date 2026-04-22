#!/usr/bin/env bash
# Build a self-contained Alpine microvm image (kernel + initramfs).
#
# Produces two files in ~/.cache/lab-create/netboot/alpine-<suite>-<arch>/:
#   vmlinuz-virt            — Alpine's virt-flavour kernel (direct-boot ready)
#   microvm-initramfs.gz    — full Alpine minirootfs wrapped as a cpio.gz
#                             initramfs, with a tiny /init that mounts
#                             /proc /sys /dev and exec's a shell on the
#                             serial console
#
# Usage:
#   build-alpine-microvm.sh [suite] [arch] [patch]
#     suite: 3.19 (default)
#     arch : x86_64 (default)
#     patch: 5     (default — maps to alpine-minirootfs-3.19.5-...)
#
# Why this shape:
#   Alpine's netboot initramfs-virt is an *installer* — it assumes you're
#   setting up a real disk via apk.  For a true microvm (no disk, boot
#   straight into an interactive OS) we want the initramfs to BE the rootfs.
#   The kernel mounts any cpio passed via -initrd as the initial rootfs and
#   runs /init.  minirootfs is ~8 MB extracted and has busybox + apk, so
#   it's the perfect payload.

set -euo pipefail

SUITE="${1:-3.19}"
ARCH="${2:-x86_64}"
PATCH="${3:-5}"

CACHE_ROOT="${HOME}/.cache/lab-create/netboot/alpine-${SUITE}-${ARCH}"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${SUITE}/releases/${ARCH}"

TAR="alpine-minirootfs-${SUITE}.${PATCH}-${ARCH}.tar.gz"
KERNEL="vmlinuz-virt"
OUT_INITRAMFS="microvm-initramfs.gz"

log() { printf '[build-alpine-microvm] %s\n' "$*" >&2; }

mkdir -p "$CACHE_ROOT"
cd       "$CACHE_ROOT"

# 1. Kernel (cached across builds — ~13 MB).
if [[ ! -s "$KERNEL" ]]; then
    log "downloading $MIRROR/netboot/$KERNEL"
    curl --fail --location -o "$KERNEL" "$MIRROR/netboot/$KERNEL"
fi

# 2. Minirootfs tarball (~3 MB compressed).
if [[ ! -s "$TAR" ]]; then
    log "downloading $MIRROR/$TAR"
    curl --fail --location -o "$TAR" "$MIRROR/$TAR"
fi

# 3. Assemble the initramfs in a temp dir; wrap as cpio.gz.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

log "extracting minirootfs → $work"
tar -xzf "$TAR" -C "$work"

# PID 1 strategy: use busybox's `init` applet.  Why not a shell /init?
#   - if PID 1 is a shell and the user types `exit`, the kernel panics
#   - a shell PID 1 doesn't handle SIGPWR/SIGUSR1, so `poweroff` hangs
#   - a shell PID 1 doesn't give child shells a controlling tty, so
#     Ctrl-C doesn't work inside the interactive shell
# busybox init solves all three: respawns its children, handles poweroff/
# reboot signals, and sets up a proper ctty for each getty/sh it spawns.
#
# Alpine's minirootfs ships /bin/busybox but not always a /sbin/init
# symlink, so we create one.  busybox dispatches by argv[0].
mkdir -p "$work/sbin" "$work/etc"
ln -sf /bin/busybox "$work/sbin/init"

# Minimal /etc/inittab understood by busybox init.  Format is
# `<id>::<action>:<command>`.
#   sysinit   runs once at boot
#   respawn   restarts the command when it exits — keeps the shell alive
#   shutdown  runs at poweroff/reboot for cleanup
#   ctrlaltdel  handler for Ctrl-Alt-Del from the console
cat > "$work/etc/inittab" <<'INITTAB'
# microvm inittab — busybox init handles PID 1 duties
::sysinit:/bin/mount -t proc     none /proc
::sysinit:/bin/mount -t sysfs    none /sys
::sysinit:/bin/mount -t devtmpfs none /dev
::sysinit:/bin/mount -t tmpfs    none /tmp
::sysinit:/bin/mount -t tmpfs    none /run
::sysinit:/bin/hostname alpine-microvm
::sysinit:/bin/sh -c 'printf "\n═══════════════════════════════════════════════\n alpine microvm — initramfs-only, RAM-resident\n═══════════════════════════════════════════════\n kernel : $(uname -r)\n type \`poweroff\` to shut down cleanly.\n\n"'

# Interactive shell on the serial console, respawned if exited.
ttyS0::respawn:/bin/sh

# Handle poweroff/reboot cleanly.
::shutdown:/bin/umount -a -r
::ctrlaltdel:/sbin/reboot
INITTAB

# cpio -H newc is the format the Linux kernel understands for initramfs.
log "packing cpio → $OUT_INITRAMFS"
(cd "$work" && find . -print0 \
    | cpio --null -o -H newc --quiet \
    | gzip -9) > "$CACHE_ROOT/$OUT_INITRAMFS"

log "done:"
ls -lh "$CACHE_ROOT/$KERNEL" "$CACHE_ROOT/$OUT_INITRAMFS" >&2
