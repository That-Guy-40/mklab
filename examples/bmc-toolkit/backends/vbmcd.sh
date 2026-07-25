#!/usr/bin/env bash
# Backend: OpenStack VirtualBMC (vbmcd) — the proven IPMI baseline: power + boot-device.
# Reuses examples/virtualbmc-ipmi-lab/. Live use is ROOTFUL (the qemu:///system socket is
# root:libvirt) => bmc-up/down and the libvirt console are author-run (sudo). The power/
# bootdev verbs themselves are plain ipmitool once vbmcd is up.

declare -A CAP=(
  [power]=yes [bootdev]=yes
  [sol]=substitute
  [insert-media]=no [eject-media]=no
  [sensors]=no [fru]=no [sel]=no [identify]=no
)
declare -A CAP_HINT=(
  [sol]="VirtualBMC has no IPMI SOL (no activate_payload); 'sol' = libvirt's own console (honest stand-in). For REAL SOL use an ipmi_sim-backed node."
  [insert-media]="virtual media is Redfish-only — use a redfish-backed node"
  [sensors]="vbmcd implements power+bootdev only (no SDR/FRU/SEL) — use ipmi_sim for those"
)

_VBMC_LAB="${BMC_TOOLKIT_DIR}/../virtualbmc-ipmi-lab"

bk_up() {
  bk_note "vbmcd is rootful (qemu:///system socket is root:libvirt) — AUTHOR-RUN:"
  bk_note "  cd ${_VBMC_LAB} && ./vbmc-lab.sh up && ./vbmc-lab.sh add   (see its RUNBOOK)"
  bk_note "then set the node's domain/port to match this registry entry."
  return 0
}
bk_down() { bk_note "author-run: cd ${_VBMC_LAB} && ./vbmc-lab.sh down"; return 0; }

_ipmi() { ipmitool -I lanplus -H "${NODE_IPMI_HOST:-127.0.0.1}" -p "${NODE_IPMI_PORT:?}" \
                   -U "${NODE_IPMI_USER:-admin}" -P "${NODE_IPMI_PASS:-password}" "$@"; }

bk_power() {
  bk_need ipmitool
  case "${1:-status}" in
    status) _ipmi chassis power status ;;
    on)     _ipmi chassis power on ;;
    off)    _ipmi chassis power off ;;
    cycle)  _ipmi chassis power cycle ;;
    *) bk_die "power: on|off|cycle|status" ;;
  esac
}

bk_bootdev() {
  bk_need ipmitool
  case "${1:?bootdev: pxe|disk|cdrom}" in
    pxe)  _ipmi chassis bootdev pxe ;;
    disk) _ipmi chassis bootdev disk ;;
    cdrom|cd) _ipmi chassis bootdev cdrom ;;
    *) bk_die "bootdev: pxe|disk|cdrom" ;;
  esac
}

bk_sol() { # substitute: libvirt console (rootful for qemu:///system) — author-run
  bk_note "libvirt console (author-run for qemu:///system):"
  echo "  virsh -c ${NODE_URI:-qemu:///system} console ${NODE_DOMAIN:?}"
}
