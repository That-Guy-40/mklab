#!/usr/bin/env bash
# run-client-qemu.sh [ppc|x86] [program] — boot the firmware with a client CD
# and drop you at the prompt to run it by hand. program defaults to "hello".
#
#   ppc: stock qemu-system-ppc (its OpenBIOS already wires the client
#        interface). At the 0 > prompt, type:   boot cd:\HELLO.;1
#        (uppercase name, the ".;1" ISO9660 version suffix is required.)
#        Quit QEMU with Ctrl-A X.
#   x86: needs the revived firmware (Phase 3) — see PLAN.md.
#
# ppc console I/O is on the muxed stdio (-nographic); a human types fine here —
# the flow-control caveat only bites scripted drivers (smoke-client.sh).
set -euo pipefail
WORKDIR="${OPENBIOS_CLIENTS_WORKDIR:-$HOME/openbios-clients-lab}"
FLAVOR="${1:-ppc}"
PROG="${2:-hello}"

case "$FLAVOR" in
  ppc)
    CLIENT="$WORKDIR/$PROG-ppc"
    [[ -f "$CLIENT" ]] || { echo "build it first: ./build-client.sh ppc $PROG"; exit 1; }
    ISO="$WORKDIR/$PROG-ppc.iso"; STAGE="$WORKDIR/.isoroot-ppc"
    NAME="$(echo "$PROG" | tr '[:lower:]' '[:upper:]')"
    rm -rf "$STAGE" "$ISO"; mkdir -p "$STAGE"; cp "$CLIENT" "$STAGE/$NAME"
    genisoimage -quiet -o "$ISO" -V CLIENT "$STAGE"
    echo "==> at the 0 > prompt, type:   boot cd:\\$NAME.;1     (Ctrl-A X quits)"
    exec qemu-system-ppc -M mac99 -m 256 -cdrom "$ISO" -nographic -vga none ;;
  x86)
    echo "x86 client track needs the firmware revival (Phase 3). See PLAN.md" >&2
    exit 77 ;;
  *) echo "usage: $0 [ppc|x86] [program]" >&2; exit 1 ;;
esac
