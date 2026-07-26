#!/usr/bin/env bash
# build-dropin-rom.sh [--boot-hook] — build an OFW ROM with the DSL inside it.
#
#   (default)     B1: ships dsl/ofdiag.fth + dsl/ofscope.fth as NAMED dropins.
#                 They do not auto-run; `fload /dropin-fs:\ofdiag.fth` loads the
#                 vocabulary with no CD, no floppy, no staged media at all.
#                 Behaviour is otherwise identical to the stock ROM.
#
#   --boot-hook   B2: ALSO ships dsl/autotrace.fth as the `boot-` dropin, which
#                 OFW executes immediately before do-auto-boot
#                 (ofw/core/bootparm.fth:345) -- so the POWER-ON AUTOBOOT itself
#                 is traced, which no amount of fload-ing after the prompt can do.
#
# ISOLATION IS THE POINT. This never touches the sister lab's tree or ROM: it
# builds in its OWN clone at $WORKDIR/openfirmware-dropin and writes its own
# output. The sister lab's emuofw.rom is sha-guarded before and after, because a
# shared, already-verified artifact changing underneath another lab is exactly
# the kind of silent cross-lab regression this repo has been bitten by before.
set -euo pipefail
BOOT_HOOK=""
[ "${1:-}" = "--boot-hook" ] && BOOT_HOOK=yes

HERE="$(cd "$(dirname "$0")" && pwd)"
SISTER="$(cd "$HERE/../open-firmware-forth-to-boot" && pwd)"
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
SRC="$WORKDIR/openfirmware"                 # the sister lab's tree — READ ONLY here
SRC2="$WORKDIR/openfirmware-dropin"         # ours
IMG="localhost/ofw-build"
CFLAGS='CFLAGS=-O -g -m32 -DTARGET_X86 -std=gnu89'
OUT="$WORKDIR/$([ -n "$BOOT_HOOK" ] && echo autotrace || echo ofdiag)-emuofw.rom"
STOCK="$SRC/cpu/x86/pc/emu/build/emuofw.rom"

command -v podman >/dev/null || { echo "SKIP: podman not installed"; exit 77; }

# --- guard: remember the sister lab's ROM ------------------------------------
GUARD=""
[ -f "$STOCK" ] && GUARD="$(sha256sum "$STOCK" | cut -d' ' -f1)"

# --- our own tree ------------------------------------------------------------
if [ ! -d "$SRC2/.git" ]; then
    echo "==> cloning an isolated OFW tree -> $SRC2"
    if [ -d "$SRC/.git" ]; then
        git clone -q "$SRC" "$SRC2"          # local clone: cheap, and shares no working files
    else
        git clone -q --depth 1 https://github.com/openbios/openfirmware.git "$SRC2"
    fi
fi

# --- the same two config flips the sister lab makes --------------------------
# Serial console on (our harness is headless) and virtual-mode OFF (MMU on
# triple-faults the 64-bit handoff). Identical to build-ofw.sh, so the ROM only
# differs from the sister's by the dropins we add.
sed -i 's/^\\ create serial-console$/create serial-console/' "$SRC2/cpu/x86/pc/emu/config.fth"
sed -i 's/^create virtual-mode$/\\ create virtual-mode/'     "$SRC2/cpu/x86/pc/emu/config.fth"

# --- stage the vocabularies inside the tree so ${BP} can reach them -----------
mkdir -p "$SRC2/labdsl"
cp "$HERE"/dsl/ofdiag.fth "$HERE"/dsl/ofscope.fth "$HERE"/dsl/nopage.fth "$SRC2/labdsl/"
[ -n "$BOOT_HOOK" ] && cp "$HERE/dsl/autotrace.fth" "$SRC2/labdsl/"

# --- inject into the dropin manifest -----------------------------------------
# Anchor on the flavor's existing startup-hook line; the manifest lives in
# cpu/x86/pc/emu/emuofw.bth. Idempotent: re-running must not stack duplicates.
BTH="$SRC2/cpu/x86/pc/emu/emuofw.bth"
grep -q '^   " builton.fth"' "$BTH" || { echo "FAIL: dropin manifest anchor not found in $BTH"; exit 1; }
sed -i '/labdsl\//d' "$BTH"                       # drop any previous injection
INJECT='   " ${BP}/labdsl/ofdiag.fth"            " ofdiag.fth"      $add-deflated-dropin\n'
INJECT+='   " ${BP}/labdsl/ofscope.fth"           " ofscope.fth"     $add-deflated-dropin\n'
INJECT+='   " ${BP}/labdsl/nopage.fth"            " nopage.fth"      $add-deflated-dropin'
[ -n "$BOOT_HOOK" ] && INJECT+='\n   " ${BP}/labdsl/autotrace.fth"         " boot-"           $add-deflated-dropin'
awk -v ins="$INJECT" '
  /^   " builton.fth"/ && !done { gsub(/\\n/, "\n", ins); print ins; done=1 }
  { print }
' "$BTH" > "$BTH.new" && mv "$BTH.new" "$BTH"
echo "==> dropin manifest now carries:"
grep -n 'labdsl/' "$BTH" | sed 's/^/    /'

# --- build -------------------------------------------------------------------
echo "==> building the build box ($IMG) — this is the sister lab's Containerfile"
podman build -q -t ofw-build -f "$SISTER/Containerfile" "$SISTER" >/dev/null
echo "==> building the emu flavor with the DSL inside it"
podman run --rm -v "$SRC2":/src --userns=keep-id -w /src/cpu/x86/pc/emu/build "$IMG" \
    make "$CFLAGS" | tail -2
cp "$SRC2/cpu/x86/pc/emu/build/emuofw.rom" "$OUT"
echo "==> $OUT"
sha256sum "$OUT"

# --- guard: the sister lab's ROM must be byte-identical ----------------------
if [ -n "$GUARD" ]; then
    NOW="$(sha256sum "$STOCK" | cut -d' ' -f1)"
    [ "$GUARD" = "$NOW" ] || { echo "FAIL: the sister lab's emuofw.rom CHANGED ($GUARD -> $NOW)"; exit 1; }
    echo "==> guard OK: the sister lab's emuofw.rom is untouched"
fi
