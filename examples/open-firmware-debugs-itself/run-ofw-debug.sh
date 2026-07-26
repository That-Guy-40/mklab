#!/usr/bin/env bash
# run-ofw-debug.sh [--card] — interactive ok prompt with the DSL media attached.
#
# Ctrl-A X quits QEMU. Pass --card to also plug in the FCode option-ROM card
# (build it first with ./build-fcode-rom.sh).
set -u
WORKDIR="${OFW_WORKDIR:-$HOME/ofw-lab}"
ROM="${OFW_ROM:-$WORKDIR/openfirmware/cpu/x86/pc/emu/build/emuofw.rom}"
ISO="$WORKDIR/dsl.iso"
CARD="$WORKDIR/fcode-card.rom"
CD='/pci/pci-ide@1,1/ide@1/cdrom@0'
EXTRA=""
[ "${1:-}" = "--card" ] && { [ -f "$CARD" ] || { echo "no $CARD — run ./build-fcode-rom.sh"; exit 1; }; EXTRA="-device e1000,romfile=$CARD"; }
[ -f "$ROM" ] || { echo "no ROM at $ROM — run the parent lab's ./build-ofw.sh"; exit 77; }
[ -f "$ISO" ] || { echo "no $ISO — run ./stage-dsl.sh"; exit 77; }
ACCEL=$([ -w /dev/kvm ] && echo kvm || echo tcg)

cat <<EOF
Once you reach the ok prompt:

  no-page                          FIRST -- else long listings block on the pager
  fload $CD:\\ofdiag.fth
  fload $CD:\\ofscope.fth
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
exec qemu-system-x86_64 -machine "pc,accel=$ACCEL" -m 256 -bios "$ROM" -cdrom "$ISO" \
     $EXTRA -nographic -no-reboot
