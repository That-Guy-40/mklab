#!/usr/bin/env bash
# stage-disk.sh [program] [ext2|fat] — build a hard-disk image with an x86 client
# on it, so the firmware can load a client from a DISK instead of a CD (see
# POC-7). program defaults to "hello", filesystem to "ext2". Sudo-free: the
# filesystem is populated without mounting, no loop device, no root.
#
# Artifact: $WORKDIR/<program>-x86.<fs>.img  (a whole-disk "superfloppy" — no
# partition table; disk-label's missing-partition-map fallback finds the fs).
#
# WHICH FILESYSTEM:
#   ext2  works on the firmware AS SHIPPED (CONFIG_FSYS_EXT2FS is on). Populated
#         with `debugfs`. This is the no-rebuild default.
#   fat   needs the FAT-ENABLED firmware — x86 ships CONFIG_FSYS_FAT=false, so a
#         FAT image mounts-probe-fails *silently* until you rebuild the firmware
#         (build-firmware-x86.sh now flips CONFIG_FSYS_FAT=true). Populated with
#         `mcopy`.
#
# WHY the odd ext2 mke2fs flags: modern mke2fs defaults (256-byte inodes,
# resize_inode/dir_index/ext_attr) parse-fail in grubfs's GRUB-0.97-era ext2
# driver — the fs MOUNTS but every directory lookup returns "File not found".
# -b 1024 -I 128 + the ^feature list gives a classic ext2 the old driver reads.
#
# Load it at the 0 > prompt with (note the BACKSLASH — grubfs converts \ to /;
# a forward slash gets eaten by the device-path parser):
#     " /ide@0/disk@0:\<program>" $load    go
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_CLIENTS_WORKDIR:-$HOME/openbios-clients-lab}"
PROG="${1:-hello}"
FS="${2:-ext2}"

[[ -f "$HERE/clib/$PROG.c" ]] || { echo "no such client program: clib/$PROG.c" >&2; exit 1; }
case "$FS" in
  ext2) if ! command -v mke2fs >/dev/null || ! command -v debugfs >/dev/null; then
            echo "need mke2fs + debugfs (e2fsprogs)" >&2; exit 1; fi ;;
  fat)  if ! command -v mkfs.vfat >/dev/null || ! command -v mcopy >/dev/null; then
            echo "need mkfs.vfat (dosfstools) + mcopy (mtools)" >&2; exit 1; fi ;;
  *)    echo "unknown filesystem '$FS' (want ext2|fat)" >&2; exit 1 ;;
esac

mkdir -p "$WORKDIR"
CLIENT="$WORKDIR/$PROG-x86"
if [[ ! -f "$CLIENT" ]]; then
    echo "==> no $CLIENT yet — building it"
    ( cd "$HERE" && ./build-client.sh x86 "$PROG" ) >/dev/null
fi
[[ -f "$CLIENT" ]] || { echo "$PROG-x86 missing after build" >&2; exit 1; }

IMG="$WORKDIR/$PROG-x86.$FS.img"
rm -f "$IMG"
if [[ "$FS" == ext2 ]]; then
    truncate -s 16M "$IMG"
    # classic ext2 the GRUB-legacy driver can read (see the header for WHY)
    mke2fs -F -q -t ext2 -b 1024 -I 128 \
        -O ^resize_inode,^dir_index,^ext_attr,^sparse_super,^large_file \
        -L CLIENT "$IMG" >/dev/null 2>&1
    debugfs -w -R "write $CLIENT $PROG" "$IMG" >/dev/null 2>&1     # populate, no mount
else
    mkfs.vfat -C "$IMG" 16384 >/dev/null                          # 16 MiB superfloppy
    mcopy -i "$IMG" "$CLIENT" "::$PROG"                           # populate, no mount
fi

echo "==> staged $PROG on a $FS hard disk: $IMG"
echo "    load at the 0 > prompt:   \" /ide@0/disk@0:\\$PROG\" \$load   then   go"
[[ "$FS" == fat ]] && echo "    NOTE: FAT needs the FAT-enabled firmware — run ./build-firmware-x86.sh first"
exit 0
