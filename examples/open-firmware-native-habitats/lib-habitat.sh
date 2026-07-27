#!/usr/bin/env bash
# shellcheck disable=SC2034  # this file exists to SET variables for its callers
# lib-habitat.sh — the two tracks, as data. Sourced by stage/run/smoke.
#
# Sun SPARC and Apple PowerPC "differ in topology and idiom, not in mechanism"
# (the lab's thesis), so ONE harness with a --track argument covers both — the
# same shape the sister lab's smoke-dsl.sh uses for its ROM flavors. Everything
# that actually differs between the two is in this file and nowhere else.
#
# Both run the STOCK OpenBIOS blob QEMU ships (/usr/share/qemu/openbios-*). This
# lab builds no firmware on purpose: the sibling
# ../openbios-the-rival-that-shipped/ already owns the "compile it yourself"
# story, and this one is about the habitat, not the build.

# habitat_track <sparc32|ppc> — sets QEMU, QARGS, and the per-track probe targets.
habitat_track() {
    case "$1" in
      sparc32)
        QEMU=qemu-system-sparc
        MACHINE="SS-5 (sun4m), SBus, ESP SCSI, mk48t08 NVRAM"
        QARGS=(-nographic -m 128)
        # Media: sparc32 compiles ext2 + UFS + FFS + ISO9660 (config/examples/
        # sparc32_config.xml), so an ISO9660 cdrom is readable. NOTE the Sun
        # path idiom: "cdrom:\FILE" — NO comma. Apple's is "cd:,\file".
        MEDIA_ARGS=(-cdrom "$WORKDIR/dsl.iso")
        LOADCMD='load cdrom:\OFDIAG.FTH'
        HAS_FS=yes
        # Persisting a setenv needs the nvram package's `update-nvram` method.
        # sun4m never gets one: drivers/obio.c's ob_nvram_init() builds a bare
        # /obio/eeprom node (reg/address/model) and never calls nvram_init(),
        # which is what BIND_NODE_METHODS(nvram) lives in.
        CAN_PERSIST=no
        # The four rungs of the ladder, as live targets on this machine.
        T_NOALIAS='nosuchalias'                  # OFDIAG-1
        T_NONODE='/obio/nosuch@9'                # OFDIAG-2
        T_OPENOK='cdrom'                         # OFDIAG-0 (with the ISO attached)
        T_OPENFAIL='/obio/eeprom'                # OFDIAG-3 (node exists, no open)
        BOOTDEV='disk:a disk'
        # increment 3: the firmware built with patch REALLY implemented
        # (build-firmware.sh), plus the stock blob to prove ours is not it.
        STOCK_BLOB=/usr/share/qemu/openbios-sparc32
        FW_ARTIFACT="$WORKDIR/openbios-sparc32-patched"
        ;;
      ppc)
        QEMU=qemu-system-ppc
        MACHINE="g3beige (Heathrow PowerMac, PowerPC 750), PCI + mac-io, ADB/CUDA/ESCC"
        QARGS=(-nographic -m 128)
        # NO media: ppc_config.xml disables EVERY CONFIG_FSYS_* — the firmware
        # can read HFS/HFS+ and nothing else, so there is no filesystem we can
        # put a .fth file on. `dir cd:\` dies with "out of malloc memory".
        MEDIA_ARGS=()
        LOADCMD=''
        HAS_FS=no
        # Apple machines DO get the nvram package: drivers/macio.c calls
        # nvram_init(), and arch/ppc/qemu/main.c even flushes on is_apple().
        CAN_PERSIST=yes
        T_NOALIAS='nosuchalias'                  # OFDIAG-1
        T_NONODE='/pci@80000000/nosuch@9'        # OFDIAG-2
        T_OPENOK='/memory@0'                     # OFDIAG-0
        T_OPENFAIL='cd'                          # OFDIAG-3 (no medium in the drive)
        BOOTDEV='hd:,\\:tbxi hd:,\ppc\bootinfo.txt hd:,%BOOT'
        STOCK_BLOB=/usr/share/qemu/openbios-ppc
        FW_ARTIFACT="$WORKDIR/openbios-ppc-patched"
        ;;
      *) return 1 ;;
    esac
    TRACK="$1"
}
