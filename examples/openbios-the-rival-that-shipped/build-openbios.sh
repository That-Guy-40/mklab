#!/usr/bin/env bash
# build-openbios.sh [x86|ppc|unix|all] — build OpenBIOS (the *other* IEEE 1275)
# in a container, with the lab's revival patch applied.
#
#   x86   → obj-x86/openbios.multiboot + openbios.dict   (QEMU -kernel track)
#           obj-x86/openbios-builtin.elf                 (coreboot payload track)
#   ppc   → obj-ppc/openbios-qemu.elf                    (swap-in for qemu-system-ppc)
#   unix  → obj-amd64/openbios-unix + .dict              (the firmware as a host process)
#   all   → all three                                    [default]
#
# State lives in ${OPENBIOS_WORKDIR:-$HOME/openbios-lab}: clones of
# github.com/openbios/openbios and github.com/openbios/fcode-utils (toke is a
# hard build prereq — built from source in the image, no prebuilt pulls).
#
# patches/01-x86-revival.patch is applied to the openbios clone first: eight
# small fixes that resurrect the never-finished x86 paths (multiboot header,
# dictionary-module loading, load-base, grubfs seek/tell, boot→linux_load,
# ctx->esp, modern zero page, coreboot forwarding tables) plus auto-boot?=false
# on x86 (the unconditional auto-boot detonates when IDE media is attached).
# Each fix's story: POC-2/POC-4. Idempotent: skipped when already applied.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
IMG=localhost/openbios-build
TARGET="${1:-all}"

mkdir -p "$WORKDIR"
[[ -d "$WORKDIR/openbios/.git" ]] || \
    git clone https://github.com/openbios/openbios.git "$WORKDIR/openbios"
[[ -d "$WORKDIR/fcode-utils/.git" ]] || \
    git clone https://github.com/openbios/fcode-utils.git "$WORKDIR/fcode-utils"

echo "==> applying the revival patch (idempotent)"
if git -C "$WORKDIR/openbios" apply --check "$HERE/patches/01-x86-revival.patch" 2>/dev/null; then
    git -C "$WORKDIR/openbios" apply "$HERE/patches/01-x86-revival.patch"
    echo "    applied"
elif git -C "$WORKDIR/openbios" apply --reverse --check "$HERE/patches/01-x86-revival.patch" 2>/dev/null; then
    echo "    already applied"
else
    echo "ERROR: patch neither applies nor reverses — tree diverged (upstream moved?)" >&2
    echo "       inspect $WORKDIR/openbios against patches/01-x86-revival.patch" >&2
    exit 1
fi

echo "==> building the build-box image ($IMG)"
# Context = WORKDIR so the Containerfile can COPY the fcode-utils clone.
podman build -q -t openbios-build -f "$HERE/Containerfile" "$WORKDIR" >/dev/null

obuild() { # obuild <switch-arch target...>
    podman run --rm -v "$WORKDIR/openbios:/src" --userns=keep-id -w /src \
        "$IMG" sh -c "config/scripts/switch-arch $* && make"
}

case "$TARGET" in
  x86)  obuild x86 ;;
  ppc)  obuild qemu-ppc ;;
  unix) obuild unix-amd64 ;;
  all)  obuild x86; obuild qemu-ppc; obuild unix-amd64 ;;
  *) echo "usage: $0 [x86|ppc|unix|all]" >&2; exit 1 ;;
esac

echo "==> artifacts:"
ls -1 "$WORKDIR"/openbios/obj-x86/openbios.multiboot \
      "$WORKDIR"/openbios/obj-x86/openbios.dict \
      "$WORKDIR"/openbios/obj-x86/openbios-builtin.elf \
      "$WORKDIR"/openbios/obj-ppc/openbios-qemu.elf \
      "$WORKDIR"/openbios/obj-amd64/openbios-unix 2>/dev/null || true
