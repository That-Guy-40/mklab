#!/usr/bin/env bash
# build-client.sh [ppc|x86|all] [program] — cross-compile an OpenBIOS client
# program (clib + <program>.c) in a container. program defaults to "hello".
#
#   ppc → $WORKDIR/<program>-ppc   big-endian PowerPC EXEC, entered by the
#                                  STOCK qemu-system-ppc firmware (no OpenBIOS
#                                  build needed — the client interface is
#                                  already wired on ppc). This is the track
#                                  that runs today (Phase 1).
#   x86 → $WORKDIR/<program>-x86   32-bit x86 EXEC. Builds now, but only RUNS
#                                  once the firmware is revived (Phase 3 —
#                                  patches/00-x86-cif-plant.patch + two more).
#
# Artifacts land in ${OPENBIOS_CLIENTS_WORKDIR:-$HOME/openbios-clients-lab}.
#
# Cross-compile gotchas baked in below (each cost a spike iteration — POC-1):
#   -std=gnu89        the of1275 sources are K&R; GCC 14 makes implicit-int a
#                     hard error otherwise.
#   -lgcc  (ppc)      -Os emits out-of-line _restgpr_* GPR-restore helpers that
#                     live in libgcc; -nostdlib drops it, so add it back.
#   -G0 -mno-sdata    keep everything in one segment (no small-data anchor at a
#     + linker script stray high address); the script pins _start to the load
#                     base so both `boot cd:` and `-kernel` enter it correctly.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_CLIENTS_WORKDIR:-$HOME/openbios-clients-lab}"
IMG=localhost/openbios-clients-build
TARGET="${1:-all}"
PROG="${2:-hello}"

[[ -f "$HERE/clib/$PROG.c" ]] || { echo "no such client program: clib/$PROG.c" >&2; exit 1; }
mkdir -p "$WORKDIR"

echo "==> building the client build-box image ($IMG)"
podman build -q -t openbios-clients-build -f "$HERE/Containerfile" "$HERE" >/dev/null

# The clib sources every client links against (order matters only for readability).
SRC="clib/of1275.c clib/of1275_io.c clib/clib.c clib/$PROG.c"

build_ppc() {
    echo "==> ppc: $PROG-ppc (big-endian, entered by stock qemu-system-ppc)"
    podman run --rm -v "$HERE:/lab:ro" -v "$WORKDIR:/out" --userns=keep-id -w /lab "$IMG" sh -c "
        powerpc-linux-gnu-gcc -std=gnu89 -Os -G0 -mno-sdata \
            -ffunction-sections -fdata-sections -fno-builtin -fno-stack-protector \
            -nostdlib -nostartfiles -static -Wl,-T,clib/client-ppc.ld \
            -o /out/$PROG-ppc $SRC -lgcc 2>&1 | grep -v 'RWX\|build-id' || true
        powerpc-linux-gnu-readelf -h /out/$PROG-ppc | grep -E 'Data|Machine|Entry'"
}

build_x86() {
    echo "==> x86: $PROG-x86 (runs only after the Phase-3 revival)"
    podman run --rm -v "$HERE:/lab:ro" -v "$WORKDIR:/out" --userns=keep-id -w /lab "$IMG" sh -c "
        cd /tmp && gcc -std=gnu89 -m32 -fno-pic -fno-builtin -fno-stack-protector -Os -c \
            /lab/clib/of1275.c /lab/clib/of1275_io.c /lab/clib/clib.c /lab/clib/$PROG.c
        ld -melf_i386 -N -Ttext 0x200000 -e _start -o /out/$PROG-x86 \
            of1275.o of1275_io.o clib.o $PROG.o
        readelf -h /out/$PROG-x86 | grep -E 'Data|Machine|Entry'"
}

case "$TARGET" in
  ppc)  build_ppc ;;
  x86)  build_x86 ;;
  all)  build_ppc; build_x86 ;;
  *) echo "usage: $0 [ppc|x86|all] [program]" >&2; exit 1 ;;
esac

echo "==> artifacts in $WORKDIR:"
ls -1 "$WORKDIR/$PROG-ppc" "$WORKDIR/$PROG-x86" 2>/dev/null || true
