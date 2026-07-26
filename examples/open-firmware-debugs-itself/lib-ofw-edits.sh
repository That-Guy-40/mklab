#!/usr/bin/env bash
# lib-ofw-edits.sh — the source edits this lab makes to an OFW tree, in ONE place.
#
# Sourced by build-dropin-rom.sh and build-nvram-rom.sh. Both need the same NVRAM
# edits; a value that has to change in two scripts is a value that will eventually
# change in one. Every function VERIFIES its own edit landed, because a sed that
# silently matches nothing yields an unchanged binary and an hour of confusion.
#
# Not executable on its own.

# The two flips the sister lab's build-ofw.sh makes: serial console on (the
# harness is headless) and virtual-mode off (MMU on triple-faults the handoff).
# Applying these keeps our ROMs differing from the stock one ONLY by our features.
ofw_base_flips() {   # $1 = tree
    local cfg="$1/cpu/x86/pc/emu/config.fth"
    sed -i 's/^\\ create serial-console$/create serial-console/' "$cfg"
    sed -i 's/^create virtual-mode$/\\ create virtual-mode/'     "$cfg"
    grep -q '^create serial-console$' "$cfg" || { echo "FAIL: serial-console flip did not land in $cfg"; return 1; }
}

# Switch ON Open Firmware's configuration-variable store. See NVRAM-ON-X86.md.
# The emu build's "no NVRAM" is a disabled config switch, not a missing
# peripheral: cpu/x86/basefw.bth:58 already floads the whole confvar stack and
# only the backing store is unbound (defer nv-c@ / nv-c!, ofwcore.fth:236).
ofw_nvram_edits() {   # $1 = tree
    local cfg="$1/cpu/x86/pc/emu/config.fth" dev="$1/cpu/x86/pc/emu/devices.fth"
    sed -i 's/^\\ create pseudo-nvram$/create pseudo-nvram/'     "$cfg"
    # vestigial in emu: nothing in emu's build chain tests [ifdef] use-null-nvram
    sed -i 's/^create use-null-nvram$/\\ create use-null-nvram/' "$cfg"
    # LOAD-BEARING: emu's block says c:\nvram.dat but emu declares NO `c` devalias
    # -- only `devalias a /isa/fdc/disk@0`. The c: line is copy-pasted from
    # biosload/devices.fth; config.fth's own prose says "a fixed-name file on
    # drive A". Left as shipped, the store opens nothing.
    # '.' matches the literal backslash; writing \n here would become a newline
    # in sed's pattern space and match nothing at all.
    sed -i 's|" c:.nvram.dat"|" a:\\nvram.dat"|'                 "$dev"
    grep -q '^create pseudo-nvram$' "$cfg" || { echo "FAIL: pseudo-nvram not enabled in $cfg"; return 1; }
    grep -q 'a:.nvram.dat' "$dev"          || { echo "FAIL: nv-file not retargeted to a: in $dev"; return 1; }
    printf '==> NVRAM: pseudo-nvram ON, nv-file -> a:\\nvram.dat\n'
}

# Give emu's OWN startup the copy-reboot-info call it lacks. The emu flavor
# defines its own startup (cpu/x86/pc/emu/fw.bth:288) which -- unlike the generic
# ofw/core/startup.fth:16 -- never calls it. copy-reboot-info is the ONLY writer
# of `reboot?`, so auto-boot's warm-reboot branch (bootparm.fth:330) is dead code
# on this flavor INDEPENDENTLY OF NVRAM. Keep this separable from the NVRAM edits:
# that separation is what proves the two causes independent.
ofw_reboot_hook() {   # $1 = tree
    local fwb="$1/cpu/x86/pc/emu/fw.bth"
    awk '
      /^: startup/ { instartup=1 }
      { print }
      instartup && /^   standalone\?  0=  if  exit  then$/ && !done {
          print "   copy-reboot-info"; done=1; instartup=0
      }
    ' "$fwb" > "$fwb.new" && mv "$fwb.new" "$fwb"
    grep -q '^   copy-reboot-info$' "$fwb" || { echo "FAIL: copy-reboot-info not injected into $fwb"; return 1; }
    echo "==> reboot: emu startup now calls copy-reboot-info"
}
