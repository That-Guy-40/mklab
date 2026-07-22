#!/usr/bin/env bash
# build-firmware-x86.sh — build an OpenBIOS-x86 that can actually run a client.
#
# The ppc track needs no firmware build at all (the stock qemu-system-ppc blob
# already wires the client interface — POC-2). x86 does: its client path is a
# museum, and this script builds the revived firmware.
#
# Two patch layers, applied in order:
#   1. ../openbios-the-rival-that-shipped/patches/01-x86-revival.patch
#      the sibling lab's EIGHT x86 fixes (multiboot header, dictionary module
#      loading, load-base defined at all, grubfs seek/tell, ...). Applied by
#      that lab's own build-openbios.sh.
#   2. patches/01-x86-client-revival.patch
#      THIS lab's client-path fixes — see POC-4 for the story of each.
#
# We deliberately build on the sibling lab's clone + container image rather
# than cloning OpenBIOS twice and rebuilding an identical toolchain: the two
# labs revive the same firmware, one layer apart.
#
# Artifacts: $OPENBIOS_WORKDIR/openbios/obj-x86/{openbios.multiboot,openbios.dict}
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RIVAL="$HERE/../openbios-the-rival-that-shipped"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
SRC="$WORKDIR/openbios"
PATCH="$HERE/patches/01-x86-client-revival.patch"
IMG=localhost/openbios-build

if [[ ! -d "$SRC/.git" ]]; then
    echo "==> no OpenBIOS tree at $SRC — building it via the sibling lab first"
    [[ -x "$RIVAL/build-openbios.sh" ]] || {
        echo "ERROR: cannot find $RIVAL/build-openbios.sh" >&2; exit 1; }
    "$RIVAL/build-openbios.sh" x86
fi

# The sibling lab's patch must be in place first: ours is written against a
# tree that already has it (they touch the same files).
echo "==> ensuring the rival lab's x86 revival patch is applied"
"$RIVAL/build-openbios.sh" x86 >/dev/null

echo "==> applying this lab's client-path patch (idempotent)"
if git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
    git -C "$SRC" apply "$PATCH"
    echo "    applied"
elif git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "    already applied"
else
    echo "ERROR: patch neither applies nor reverses — tree diverged?" >&2
    echo "       inspect $SRC against $PATCH" >&2
    exit 1
fi

echo "==> rebuilding OpenBIOS for x86"
podman run --rm -v "$SRC:/src" --userns=keep-id -w /src "$IMG" \
    sh -c "config/scripts/switch-arch x86 >/dev/null && make" 2>&1 | tail -3

echo "==> artifacts:"
ls -1 "$SRC"/obj-x86/openbios.multiboot "$SRC"/obj-x86/openbios.dict
