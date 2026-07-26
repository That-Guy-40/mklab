#!/usr/bin/env bash
# build-fcode-rom.sh — dsl/fcode-card.fth -> FCode bytecode -> a PCI expansion ROM.
#
# Needs `toke` from openbios/fcode-utils, which the sibling rival lab already
# builds at ~/openbios-lab/fcode-utils (plain `make`, no fetch). `romheaders`
# from the same package validates the result BEFORE we boot it — a cheap
# host-side gate that catches a malformed ROM without spending a QEMU boot.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
FCU="${FCODE_UTILS:-$HOME/openbios-lab/fcode-utils}"
OUT="${1:-$WORKDIR/fcode-card.rom}"

[ -x "$FCU/toke/toke" ] || { echo "SKIP: no toke at $FCU/toke/toke — run 'make' in $FCU"; exit 77; }
mkdir -p "$WORKDIR"
cp "$HERE/dsl/fcode-card.fth" "$WORKDIR/fcode-card.fth"
( cd "$WORKDIR" && "$FCU/toke/toke" fcode-card.fth ) || { echo "FAIL: toke failed"; exit 1; }
python3 "$HERE/build-fcode-rom.py" "$WORKDIR/fcode-card.fc" "$OUT" || exit 1
[ -x "$FCU/romheaders/romheaders" ] && "$FCU/romheaders/romheaders" "$OUT" | grep -E 'Signature|Code Type|FCode program'
echo "built $OUT"
