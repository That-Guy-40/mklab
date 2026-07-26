#!/usr/bin/env bash
# build-nvram-rom.sh [--reboot-hook] — turn ON Open Firmware's config-variable
# store on the x86 emu flavor, which upstream ships disabled.
#
# The emu build's "no NVRAM" is NOT a missing peripheral. cpu/x86/basefw.bth:58
# already floads the whole confvar stack (conftype/nvramrcg/nvalias/nvcache/
# nameval); only the backing store is unbound (defer nv-c@ / nv-c!,
# ofwcore.fth:236). cpu/x86/pc/emu/devices.fth:176 even carries the complete
# [ifdef] pseudo-nvram block already. Three edits switch it on:
#
#   1. config.fth   \ create pseudo-nvram   ->  create pseudo-nvram
#   2. config.fth   create use-null-nvram   ->  commented (vestigial in emu:
#                   nothing in emu's build chain tests [ifdef] use-null-nvram)
#   3. devices.fth  nv-file " c:\nvram.dat" ->  " a:\nvram.dat"
#      NON-OBVIOUS AND LOAD-BEARING: emu declares `devalias a /isa/fdc/disk@0`
#      and NO `c` alias -- the c: line is copy-pasted from biosload/devices.fth.
#      config.fth's own prose says "a fixed-name file on drive A". Left as
#      shipped, the store opens nothing and stand-init reports the EEPROM dead.
#
# --reboot-hook ALSO adds `copy-reboot-info` to emu's startup. The emu flavor
# defines its OWN startup (cpu/x86/pc/emu/fw.bth:288) which -- unlike the generic
# ofw/core/startup.fth:16 -- never calls it. copy-reboot-info is the only writer
# of `reboot?`, so auto-boot's warm-reboot branch (bootparm.fth:330) is dead code
# on this flavor INDEPENDENTLY OF NVRAM. Keep the two separable: that separation
# is what proves the warm-reboot gap was never an NVRAM problem.
#
# ISOLATION IS THE POINT. Builds in its OWN clone; the sister lab's emuofw.rom is
# sha-guarded before and after. See NVRAM-ON-X86.md for the full result.
set -euo pipefail
REBOOT_HOOK=""
[ "${1:-}" = "--reboot-hook" ] && REBOOT_HOOK=yes

HERE="$(cd "$(dirname "$0")" && pwd)"
SISTER="$(cd "$HERE/../open-firmware-forth-to-boot" && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
SRC="$WORKDIR/openfirmware"                 # the sister lab's tree — READ ONLY here
SRC2="$WORKDIR/openfirmware-nvram"          # ours
IMG="localhost/ofw-build"
CFLAGS='CFLAGS=-O -g -m32 -DTARGET_X86 -std=gnu89'
OUT="$WORKDIR/nvram$([ -n "$REBOOT_HOOK" ] && echo -reboot)-emuofw.rom"
STOCK="$SRC/cpu/x86/pc/emu/build/emuofw.rom"

command -v podman >/dev/null || { echo "SKIP: podman not installed"; exit 77; }

GUARD=""
[ -f "$STOCK" ] && GUARD="$(sha256sum "$STOCK" | cut -d' ' -f1)"

if [ ! -d "$SRC2/.git" ]; then
    echo "==> cloning an isolated OFW tree -> $SRC2"
    if [ -d "$SRC/.git" ]; then
        git clone -q "$SRC" "$SRC2"
    else
        git clone -q --depth 1 https://github.com/openbios/openfirmware.git "$SRC2"
    fi
fi
# pristine tree each run, so the sed edits below can never stack
git -C "$SRC2" checkout -q -- . 2>/dev/null || true

CFG="$SRC2/cpu/x86/pc/emu/config.fth"
DEV="$SRC2/cpu/x86/pc/emu/devices.fth"

# the sister lab's two flips, so this ROM differs from the stock one only by NVRAM
sed -i 's/^\\ create serial-console$/create serial-console/' "$CFG"
sed -i 's/^create virtual-mode$/\\ create virtual-mode/'     "$CFG"

sed -i 's/^\\ create pseudo-nvram$/create pseudo-nvram/'     "$CFG"
sed -i 's/^create use-null-nvram$/\\ create use-null-nvram/' "$CFG"
# '.' matches the literal backslash in "c:\nvram.dat"; writing \n here would
# become a newline in sed's pattern space and match nothing.
sed -i 's|" c:.nvram.dat"|" a:\\nvram.dat"|'                 "$DEV"

# VERIFY the edits landed. A sed that silently matches nothing is the classic way
# to spend an hour debugging an unchanged binary — this repo has done it once.
grep -q '^create pseudo-nvram$' "$CFG" || { echo "FAIL: pseudo-nvram not enabled in $CFG"; exit 1; }
grep -q 'a:.nvram.dat' "$DEV"          || { echo "FAIL: nv-file not retargeted to a: in $DEV"; exit 1; }
echo "==> config.fth:"; grep -n '^create pseudo-nvram$\|^\\ create use-null-nvram$' "$CFG" | sed 's/^/    /'
echo "==> devices.fth:"; grep -n 'nv-file' "$DEV" | sed 's/^/    /'

if [ -n "$REBOOT_HOOK" ]; then
    FWB="$SRC2/cpu/x86/pc/emu/fw.bth"
    awk '
      /^: startup/ { instartup=1 }
      { print }
      instartup && /^   standalone\?  0=  if  exit  then$/ && !done {
          print "   copy-reboot-info"; done=1; instartup=0
      }
    ' "$FWB" > "$FWB.new" && mv "$FWB.new" "$FWB"
    grep -q '^   copy-reboot-info$' "$FWB" || { echo "FAIL: copy-reboot-info not injected into $FWB"; exit 1; }
    echo "==> emu startup now calls copy-reboot-info:"
    grep -n -A2 '^: startup' "$FWB" | sed 's/^/    /'
fi

echo "==> building the build box ($IMG) — the sister lab's Containerfile"
podman build -q -t ofw-build -f "$SISTER/Containerfile" "$SISTER" >/dev/null
echo "==> building the emu flavor with pseudo-nvram ON"
podman run --rm -v "$SRC2":/src --userns=keep-id -w /src/cpu/x86/pc/emu/build "$IMG" \
    make "$CFLAGS" | tail -2
cp "$SRC2/cpu/x86/pc/emu/build/emuofw.rom" "$OUT"
echo "==> $OUT"
sha256sum "$OUT"

if [ -n "$GUARD" ]; then
    NOW="$(sha256sum "$STOCK" | cut -d' ' -f1)"
    [ "$GUARD" = "$NOW" ] || { echo "FAIL: the sister lab's emuofw.rom CHANGED"; exit 1; }
    echo "==> guard OK: the sister lab's emuofw.rom is untouched"
fi
echo "==> now run: ./smoke-nvram.sh"
