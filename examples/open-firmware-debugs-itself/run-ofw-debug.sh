#!/usr/bin/env bash
# run-ofw-debug.sh [emu|coreboot] [--card] — interactive ok prompt, DSL media attached.
#
# Ctrl-A X quits QEMU. Pass --card to also plug in the FCode option-ROM card
# (build it first with ./build-fcode-rom.sh).
set -u
FLAVOR="emu"; EXTRA=""
for a in "$@"; do
    case "$a" in
        emu|coreboot) FLAVOR="$a" ;;
        --card)       EXTRA="--card" ;;
        *) echo "usage: $0 [emu|coreboot] [--card]"; exit 1 ;;
    esac
done
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
CARD="$WORKDIR/fcode-card.rom"

case "$FLAVOR" in
  emu)
      ROM="${OFW_ROM:-$WORKDIR/openfirmware/cpu/x86/pc/emu/build/emuofw.rom}"
      MEDIA="$WORKDIR/dsl.iso"; MEDIA_ARGS="-cdrom $MEDIA"
      DEV='/pci/pci-ide@1,1/ide@1/cdrom@0'
      HINT="run the sister lab's ./build-ofw.sh"
      FIX=""
      ;;
  coreboot)
      ROM="${OFW_ROM_COREBOOT:-$CB/build-ofw/coreboot.rom}"
      MEDIA="$WORKDIR/dsl.img"; MEDIA_ARGS="-drive file=$MEDIA,format=raw,if=ide,index=0"
      DEV='/isa/ide@i1f0/disk@0'
      HINT="run the sister lab's ./build-coreboot-ofw.sh"
      FIX="yes"
      ;;
esac
[ -f "$ROM" ]   || { echo "no $FLAVOR ROM at $ROM — $HINT"; exit 77; }
[ -f "$MEDIA" ] || { echo "no $MEDIA — run ./stage-dsl.sh"; exit 77; }
[ "$EXTRA" = "--card" ] && { [ -f "$CARD" ] || { echo "no $CARD — run ./build-fcode-rom.sh"; exit 1; }; EXTRA="-device e1000,romfile=$CARD"; }
ACCEL=$([ -w /dev/kvm ] && echo kvm || echo tcg)

echo "Once you reach the ok prompt ($FLAVOR flavor):"
echo
echo "  fload $DEV:\\nopage.fth           FIRST -- or long listings block on the pager"
if [ -n "$FIX" ]; then
cat <<'EOF'

  This flavor CANNOT READ A FILE until you re-point a dead defer -- `allocate-dma`
  aims at `null-allocate-dma` and nothing on the coreboot path ever fixes it, so
  every fload fails with "Can't open deblocker package". Type this first (it is
  the one thing that cannot be loaded from a file, because loading needs it):

  : my-dma h# 1000 mem-claim ;
  ' my-dma to allocate-dma
EOF
fi
cat <<EOF

  fload $DEV:\\ofdiag.fth
  fload $DEV:\\ofscope.fth
  why-no-boot                      why this machine will not boot, per entry
  trace-boot   ... untrace         #T milestones around the boot path
  dev /pci pci-map device-end      config space, cross-checkable against QMP
  mem-map                          the memory map the firmware believes in
  see open-dev                     the firmware decompiling itself
  ' open-dev .calls                who calls it (13 answers)
  debug diag-open                  full-screen single-stepper (a HUMAN tool)

Ctrl-A X quits.
EOF
# -m 256 is load-bearing: OFW anchors its PCI window at ~0x10000000 regardless
# of RAM, so more than 256M shadows a card's option ROM behind DRAM.
# shellcheck disable=SC2086
exec qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 256 -bios "$ROM" $MEDIA_ARGS \
     $EXTRA -nographic -no-reboot
