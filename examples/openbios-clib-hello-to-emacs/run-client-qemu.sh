#!/usr/bin/env bash
# run-client-qemu.sh [ppc|x86] [program] [cd|disk|disk-fat] — boot the firmware
# with a client medium and drop you at the prompt to run it by hand. program
# defaults to "hello"; the 3rd arg picks the medium — "cd" (default), "disk"
# (ext2), or "disk-fat" (x86 only; needs the FAT-enabled firmware rebuild).
#
#   ppc: stock qemu-system-ppc (its OpenBIOS already wires the client
#        interface). At the 0 > prompt, type:   boot cd:\HELLO.;1
#        (uppercase name, the ".;1" ISO9660 version suffix is required.)
#        With `disk`: an ext2 hard disk read by the stock blob's native ext2
#        driver (POC-7) — type instead:   boot hd:\hello   (backslash, NO comma).
#        Quit QEMU with Ctrl-A X.
#   x86: needs the revived firmware (Phase 3 / POC-4 — build it once with
#        ./build-firmware-x86.sh). No `boot cd:` shortcut for a client; at the
#        0 > prompt load then go:   " /ide@1/cdrom@0:\hello" $load   then   go
#        With `disk`: an ext2 hard disk instead (POC-7), path /ide@0/disk@0:\hello
#
# Interactive editors: `edit` saves-and-exits on Ctrl-X; `emacs` on C-x C-c
# (and C-x C-s to "save"). Both paint the screen with ANSI — use a real terminal.
#
# ppc console I/O is on the muxed stdio (-nographic); a human types fine here —
# the flow-control caveat only bites scripted drivers (smoke-client.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_CLIENTS_WORKDIR:-$HOME/openbios-clients-lab}"
ACCEL="$([[ -w /dev/kvm ]] && echo kvm || echo tcg)"
FLAVOR="${1:-ppc}"
PROG="${2:-hello}"
MEDIA="${3:-cd}"

case "$FLAVOR" in
  ppc)
    if [[ "$MEDIA" == disk ]]; then
        # ext2 hard disk on the STOCK qemu-system-ppc (its native ext2 reader —
        # no firmware build). Load with `boot hd:\<prog>` (backslash, NO comma).
        ( cd "$HERE" && ./stage-disk.sh "$PROG" ext2 ppc ) >/dev/null || exit 1
        IMG="$WORKDIR/$PROG-ppc.ext2.img"
        echo "==> at the 0 > prompt, type:   boot hd:\\$PROG     (backslash, NO comma; Ctrl-A X quits)"
        exec qemu-system-ppc -M mac99 -m 256 -drive "file=$IMG,format=raw" -nographic -vga none
    fi
    CLIENT="$WORKDIR/$PROG-ppc"
    [[ -f "$CLIENT" ]] || { echo "build it first: ./build-client.sh ppc $PROG"; exit 1; }
    ISO="$WORKDIR/$PROG-ppc.iso"; STAGE="$WORKDIR/.isoroot-ppc"
    NAME="$(echo "$PROG" | tr '[:lower:]' '[:upper:]')"
    rm -rf "$STAGE" "$ISO"; mkdir -p "$STAGE"; cp "$CLIENT" "$STAGE/$NAME"
    genisoimage -quiet -o "$ISO" -V CLIENT "$STAGE"
    echo "==> at the 0 > prompt, type:   boot cd:\\$NAME.;1     (Ctrl-A X quits)"
    exec qemu-system-ppc -M mac99 -m 256 -cdrom "$ISO" -nographic -vga none ;;
  x86)
    CLIENT="$WORKDIR/$PROG-x86"
    [[ -f "$CLIENT" ]] || { echo "build it first: ./build-client.sh x86 $PROG"; exit 1; }
    FW="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}/openbios/obj-x86"
    [[ -f "$FW/openbios.multiboot" && -f "$FW/openbios.dict" ]] \
        || { echo "no revived OpenBIOS-x86 — run ./build-firmware-x86.sh first"; exit 1; }
    if [[ "$MEDIA" == disk || "$MEDIA" == disk-fat ]]; then
        # hard disk on the primary-master IDE (POC-7). ext2 works as shipped; FAT
        # needs the FAT-enabled firmware rebuild. stage-disk.sh builds the image.
        FS=ext2; [[ "$MEDIA" == disk-fat ]] && FS=fat
        ( cd "$HERE" && ./stage-disk.sh "$PROG" "$FS" ) >/dev/null || exit 1
        IMG="$WORKDIR/$PROG-x86.$FS.img"
        echo "==> at the 0 > prompt, type:   \" /ide@0/disk@0:\\$PROG\" \$load   then   go     (Ctrl-A X quits)"
        exec qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 \
            -kernel "$FW/openbios.multiboot" -initrd "$FW/openbios.dict" \
            -hda "$IMG" -display none -serial mon:stdio -no-reboot
    fi
    ISO="$WORKDIR/$PROG-x86.iso"; STAGE="$WORKDIR/.isoroot-x86run"
    rm -rf "$STAGE" "$ISO"; mkdir -p "$STAGE"; cp "$CLIENT" "$STAGE/$PROG"
    genisoimage -quiet -r -o "$ISO" -V CLIENT "$STAGE"     # -r → lowercase name, no .;1
    echo "==> at the 0 > prompt, type:   \" /ide@1/cdrom@0:\\$PROG\" \$load   then   go     (Ctrl-A X quits)"
    exec qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 \
        -kernel "$FW/openbios.multiboot" -initrd "$FW/openbios.dict" \
        -cdrom "$ISO" -display none -serial mon:stdio -no-reboot ;;
  *) echo "usage: $0 [ppc|x86] [program] [cd|disk|disk-fat]" >&2; exit 1 ;;
esac
