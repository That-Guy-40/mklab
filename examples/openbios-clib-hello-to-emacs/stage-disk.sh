#!/usr/bin/env bash
# stage-disk.sh [program] — build a hard-disk image with an x86 client on it, so
# the firmware can load a client from a DISK instead of a CD (see POC-7). Default
# program is "hello". Sudo-free: the filesystem is populated with `debugfs`, no
# mount, no loop device, no root.
#
# Artifact: $WORKDIR/<program>-x86.ext2.img  (a whole-disk "superfloppy" ext2 —
# no partition table; disk-label's missing-partition-map fallback finds the fs).
#
# TWO non-obvious choices, both learned the hard way in the POC-7 spike:
#
#   * ext2, NOT FAT. The revived OpenBIOS-x86's grubfs is compiled with
#     CONFIG_FSYS_ISO9660 (the CD) + CONFIG_FSYS_EXT2FS, but CONFIG_FSYS_FAT is
#     FALSE. A FAT image mounts-probe-fails *silently* (state-valid stays 0, no
#     error) — ext2 is the disk filesystem this firmware actually reads.
#
#   * a CLASSIC ext2 layout (-b 1024 -I 128 + the ^feature list). Modern mke2fs
#     defaults (256-byte inodes, resize_inode/dir_index/ext_attr) parse-fail in
#     grubfs's GRUB-0.97-era ext2 driver: the fs MOUNTS but every directory
#     lookup returns "File not found". Stripping to 128-byte inodes, 1 KiB
#     blocks, and only the `filetype` feature gives the ancient driver something
#     it can read.
#
# Load it at the 0 > prompt with (note the BACKSLASH — grubfs converts \ to /;
# a forward slash gets eaten by the device-path parser):
#     " /ide@0/disk@0:\<program>" $load    go
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_CLIENTS_WORKDIR:-$HOME/openbios-clients-lab}"
PROG="${1:-hello}"

command -v mke2fs  >/dev/null || { echo "need mke2fs (e2fsprogs)" >&2; exit 1; }
command -v debugfs >/dev/null || { echo "need debugfs (e2fsprogs)" >&2; exit 1; }
[[ -f "$HERE/clib/$PROG.c" ]] || { echo "no such client program: clib/$PROG.c" >&2; exit 1; }

mkdir -p "$WORKDIR"
CLIENT="$WORKDIR/$PROG-x86"
if [[ ! -f "$CLIENT" ]]; then
    echo "==> no $CLIENT yet — building it"
    ( cd "$HERE" && ./build-client.sh x86 "$PROG" ) >/dev/null
fi
[[ -f "$CLIENT" ]] || { echo "$PROG-x86 missing after build" >&2; exit 1; }

IMG="$WORKDIR/$PROG-x86.ext2.img"
rm -f "$IMG"
truncate -s 16M "$IMG"
# classic ext2 the GRUB-legacy driver can read (see the header for WHY these flags)
mke2fs -F -q -t ext2 -b 1024 -I 128 \
    -O ^resize_inode,^dir_index,^ext_attr,^sparse_super,^large_file \
    -L CLIENT "$IMG" >/dev/null 2>&1
# populate WITHOUT mounting — debugfs writes straight into the image
debugfs -w -R "write $CLIENT $PROG" "$IMG" >/dev/null 2>&1

echo "==> staged $PROG on an ext2 hard disk: $IMG"
echo "    load at the 0 > prompt:   \" /ide@0/disk@0:\\$PROG\" \$load   then   go"
