#!/usr/bin/env bash
# stage-dsl.sh — put the vocabularies on media the firmware can fload.
#
# TWO gotchas baked in:
#  1. OFW's ISO9660 reader is 8.3-ONLY (no Rock Ridge). `fload ...\long-name.fth`
#     fails with "cannot be opened" and `dir <cd>:\` shows the mangled 8.3 name.
#     Every staged file therefore uses a short name.
#  2. The two ROM flavors read DIFFERENT media (a parent-lab finding): the emu
#     flavor reads ISO9660 on the ATAPI path, the coreboot flavor reads FAT16 on
#     the legacy ISA-IDE path. So stage both.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
STAGE="$WORKDIR/dsl-stage"
command -v genisoimage >/dev/null || { echo "SKIP: genisoimage not installed"; exit 77; }
rm -rf "$STAGE"; mkdir -p "$STAGE" "$WORKDIR"
for f in "$HERE"/dsl/*.fth; do
    b="$(basename "$f")"
    case "$b" in fcode-card.fth) continue ;; esac      # goes in a ROM, not on media
    n="${b%.fth}"
    [ "${#n}" -le 8 ] || { echo "FAIL: '$b' is not 8.3 — OFW's ISO9660 reader cannot open it"; exit 1; }
    cp "$f" "$STAGE/$b"
done
genisoimage -quiet -o "$WORKDIR/dsl.iso" -V OFDSL -r -J "$STAGE" || exit 1
echo "staged $(ls "$STAGE" | tr '\n' ' ')-> $WORKDIR/dsl.iso"
if command -v mkfs.vfat >/dev/null && command -v mcopy >/dev/null; then
    # 64M, not 8M: mkfs.vfat -F16 refuses a too-small image, and an unchecked
    # failure here silently produces media the firmware cannot read. Every step
    # is checked -- a stage script that reports success on a broken image is
    # worse than one that fails.
    rm -f "$WORKDIR/dsl.img"
    truncate -s 64M "$WORKDIR/dsl.img"            || { echo "FAIL: truncate"; exit 1; }
    mkfs.vfat -F16 "$WORKDIR/dsl.img" >/dev/null  || { echo "FAIL: mkfs.vfat -F16"; exit 1; }
    for f in "$STAGE"/*; do
        mcopy -o -i "$WORKDIR/dsl.img" "$f" "::/$(basename "$f")" \
            || { echo "FAIL: mcopy $(basename "$f")"; exit 1; }
    done
    mdir -i "$WORKDIR/dsl.img" >/dev/null         || { echo "FAIL: FAT16 image unreadable"; exit 1; }
    echo "staged -> $WORKDIR/dsl.img (FAT16, for the coreboot flavor)"
fi
