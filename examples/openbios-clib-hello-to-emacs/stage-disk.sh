#!/usr/bin/env bash
# stage-disk.sh [program] [ext2|fat] [x86|ppc] — build a hard-disk image with a
# client on it, so the firmware can load a client from a DISK instead of a CD
# (see POC-7). program defaults to "hello", filesystem to "ext2", arch to "x86".
# Sudo-free: the filesystem is populated without mounting — no loop, no root.
#
# Artifact: $WORKDIR/<program>-<arch>.<fs>.img  (a whole-disk "superfloppy" — no
# partition table; disk-label's missing-partition-map fallback finds the fs).
#
# WHICH FILESYSTEM / ARCH:
#   x86 ext2  works on the revived firmware AS SHIPPED (CONFIG_FSYS_EXT2FS on).
#   x86 fat   needs the FAT-ENABLED firmware rebuild (x86 ships CONFIG_FSYS_FAT
#             off, so a FAT image mounts-probe-fails *silently* until you rebuild
#             — build-firmware-x86.sh flips it). Populated with `mcopy`.
#   ppc ext2  works on the STOCK qemu-system-ppc — NO build at all. ppc's grubfs
#             is empty, but it has a NATIVE ext2 reader (CONFIG_EXT2=true); the
#             disk loads with `boot hd:\<prog>` (backslash, NO comma — the comma
#             partition-form fails). ppc has no FAT reader, so `fat` is x86-only.
#
# WHY the odd ext2 mke2fs flags: modern mke2fs defaults (256-byte inodes,
# resize_inode/dir_index/ext_attr) parse-fail in the GRUB-0.97-era ext2 driver —
# the fs MOUNTS but every directory lookup returns "File not found". -b 1024
# -I 128 + the ^feature list gives a classic ext2 the old driver reads. (The ppc
# native reader is happy with it too, so one recipe serves both.)
#
# Load it at the 0 > prompt:
#   x86:   " /ide@0/disk@0:\<program>" $load    go
#   ppc:   boot hd:\<program>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_CLIENTS_WORKDIR:-$HOME/openbios-clients-lab}"
PROG="${1:-hello}"
FS="${2:-ext2}"
ARCH="${3:-x86}"

[[ -f "$HERE/clib/$PROG.c" ]] || { echo "no such client program: clib/$PROG.c" >&2; exit 1; }
[[ "$ARCH" == x86 || "$ARCH" == ppc ]] || { echo "unknown arch '$ARCH' (want x86|ppc)" >&2; exit 1; }
[[ "$ARCH" == ppc && "$FS" == fat ]] && { echo "ppc has no FAT reader — use ext2" >&2; exit 1; }
case "$FS" in
  ext2) if ! command -v mke2fs >/dev/null || ! command -v debugfs >/dev/null; then
            echo "need mke2fs + debugfs (e2fsprogs)" >&2; exit 1; fi ;;
  fat)  if ! command -v mkfs.vfat >/dev/null || ! command -v mcopy >/dev/null; then
            echo "need mkfs.vfat (dosfstools) + mcopy (mtools)" >&2; exit 1; fi ;;
  *)    echo "unknown filesystem '$FS' (want ext2|fat)" >&2; exit 1 ;;
esac

mkdir -p "$WORKDIR"
CLIENT="$WORKDIR/$PROG-$ARCH"
if [[ ! -f "$CLIENT" ]]; then
    echo "==> no $CLIENT yet — building it"
    ( cd "$HERE" && ./build-client.sh "$ARCH" "$PROG" ) >/dev/null
fi
[[ -f "$CLIENT" ]] || { echo "$PROG-$ARCH missing after build" >&2; exit 1; }

IMG="$WORKDIR/$PROG-$ARCH.$FS.img"
rm -f "$IMG"
if [[ "$FS" == ext2 ]]; then
    truncate -s 16M "$IMG"
    # classic ext2 the GRUB-legacy / native readers can both read (see header)
    mke2fs -F -q -t ext2 -b 1024 -I 128 \
        -O ^resize_inode,^dir_index,^ext_attr,^sparse_super,^large_file \
        -L CLIENT "$IMG" >/dev/null 2>&1
    debugfs -w -R "write $CLIENT $PROG" "$IMG" >/dev/null 2>&1     # populate, no mount
else
    mkfs.vfat -C "$IMG" 16384 >/dev/null                          # 16 MiB superfloppy
    mcopy -i "$IMG" "$CLIENT" "::$PROG"                           # populate, no mount
fi

echo "==> staged $PROG on a $FS hard disk ($ARCH): $IMG"
if [[ "$ARCH" == ppc ]]; then
    echo "    load at the 0 > prompt:   boot hd:\\$PROG          (backslash, NO comma)"
else
    echo "    load at the 0 > prompt:   \" /ide@0/disk@0:\\$PROG\" \$load   then   go"
    [[ "$FS" == fat ]] && echo "    NOTE: FAT needs the FAT-enabled firmware — run ./build-firmware-x86.sh first"
fi
exit 0
