#!/usr/bin/env bash
# build-ofw.sh [emu|coreboot|all] — build Open Firmware from source in a container.
#
#   emu       → emuofw.rom   (QEMU-direct flavor, cpu/x86/pc/emu; serial console,
#                             physical mode — the two config flips POC-2 proved out)
#   coreboot  → ofwlb.elf    (coreboot-payload flavor, cpu/x86/pc/biosload;
#                             + resident-packages so deblocker/FAT/ISO9660 exist)
#   all       → both  [default]
#
# The tree (github.com/openbios/openfirmware, frozen Dec 2015) self-hosts its
# build in Forth; the only host toolchain need is 32-bit C for the wrapper —
# provided by the Containerfile next to this script. The one deviation from a
# stock build is CFLAGS with -std=gnu89: gcc-14 makes C89 implicit declarations
# a hard error, and on this all -m32 build implicit-int is the 1989 assumption
# the code was written under (int == long == pointer == 32 bits). See
# POC-1-BUILD-BOX.md.
set -euo pipefail
WHAT="${1:-all}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
SRC="$WORKDIR/openfirmware"
IMG="localhost/ofw-build"
CFLAGS='CFLAGS=-O -g -m32 -DTARGET_X86 -std=gnu89'

mkdir -p "$WORKDIR"
if [[ ! -d "$SRC/.git" ]]; then
  echo "==> cloning openbios/openfirmware (the wiki's svn:// endpoint is dead)"
  git clone --depth 1 https://github.com/openbios/openfirmware.git "$SRC"
fi

echo "==> building the build-box image ($IMG)"
podman build -q -t ofw-build -f "$HERE/Containerfile" "$HERE" >/dev/null

cmake() {  # run make inside the build box, in the given tree subdir
  podman run --rm -v "$SRC":/src --userns=keep-id -w "/src/$1" "$IMG" make "$CFLAGS"
}

if [[ "$WHAT" == emu || "$WHAT" == all ]]; then
  echo "==> configuring emu flavor: serial console ON, virtual-mode OFF"
  # Serial console: our harness is headless (the wiki's default is framebuffer).
  sed -i 's/^\\ create serial-console$/create serial-console/' "$SRC/cpu/x86/pc/emu/config.fth"
  # Physical mode: virtual-mode (MMU on) triple-faults the 64-bit Linux handoff
  # (boot protocol wants paging OFF at the 32-bit entry). See POC-2 Act 2.
  sed -i 's/^create virtual-mode$/\\ create virtual-mode/' "$SRC/cpu/x86/pc/emu/config.fth"
  cmake cpu/x86/pc/emu/build | tail -2
  echo "==> $SRC/cpu/x86/pc/emu/build/emuofw.rom"
  sha256sum "$SRC/cpu/x86/pc/emu/build/emuofw.rom"
fi

if [[ "$WHAT" == coreboot || "$WHAT" == all ]]; then
  echo "==> configuring biosload flavor for coreboot payload"
  cp "$SRC/cpu/x86/pc/biosload/config-coreboot.fth" "$SRC/cpu/x86/pc/biosload/config.fth"
  # The stock coreboot config ships support packages as dropins the payload
  # lacks -> "Can't open deblocker package" on every disk open. Compile them
  # into the dictionary instead. See POC-3 step 4.
  if ! grep -q '^create resident-packages' "$SRC/cpu/x86/pc/biosload/config.fth"; then
    printf '\ncreate resident-packages   \\ deblocker/FAT/ISO9660 in-dictionary (dropins absent in payload)\n' \
      >> "$SRC/cpu/x86/pc/biosload/config.fth"
  fi
  cmake cpu/x86/pc/biosload/build | tail -2
  echo "==> $SRC/cpu/x86/pc/biosload/build/ofwlb.elf"
  sha256sum "$SRC/cpu/x86/pc/biosload/build/ofwlb.elf"
fi
