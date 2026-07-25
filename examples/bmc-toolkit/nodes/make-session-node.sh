#!/usr/bin/env bash
# Emit a qemu:///session libvirt domain XML for a demo BMC node (rootless, BIOS).
# The node's serial can go to a FILE (capture) or a TCP socket (so ipmi_sim's SOL
# bridge can connect to it). An optional cdrom boots an ISO directly (used by the SOL
# demo to give the node something that prints to serial).
#
#   make-session-node.sh --name N --serial file:/path.log        [--cdrom x.iso] [--out f.xml]
#   make-session-node.sh --name N --serial tcp:127.0.0.1:9101     [--cdrom x.iso] [--out f.xml]
set -euo pipefail
NAME=""; SERIAL=""; CDROM=""; OUT="/dev/stdout"; MEM_MB=1024
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)   NAME="$2"; shift 2;;
    --serial) SERIAL="$2"; shift 2;;
    --cdrom)  CDROM="$2"; shift 2;;
    --mem)    MEM_MB="$2"; shift 2;;
    --out)    OUT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$NAME" && -n "$SERIAL" ]] || { echo "need --name and --serial" >&2; exit 2; }

# --- serial device XML ---
case "$SERIAL" in
  file:*) path="${SERIAL#file:}"
    read -r -d '' SERIAL_XML <<EOF || true
    <serial type='file'>
      <source path='${path}'/>
      <target type='isa-serial' port='0'/>
    </serial>
    <console type='file'>
      <source path='${path}'/>
      <target type='serial' port='0'/>
    </console>
EOF
    ;;
  tcp:*) hostport="${SERIAL#tcp:}"; host="${hostport%:*}"; port="${hostport##*:}"
    # QEMU binds/listens; ipmi_sim connects as client (tcp:host:port). nowait: don't block boot.
    read -r -d '' SERIAL_XML <<EOF || true
    <serial type='tcp'>
      <source mode='bind' host='${host}' service='${port}'/>
      <protocol type='raw'/>
      <target type='isa-serial' port='0'/>
    </serial>
    <console type='tcp'>
      <source mode='bind' host='${host}' service='${port}'/>
      <protocol type='raw'/>
      <target type='serial' port='0'/>
    </console>
EOF
    ;;
  *) echo "unknown --serial form: $SERIAL (use file:PATH or tcp:HOST:PORT)" >&2; exit 2;;
esac

# --- optional cdrom + boot order ---
CDROM_XML=""; BOOT_DEV="hd"
if [[ -n "$CDROM" ]]; then
  BOOT_DEV="cdrom"
  read -r -d '' CDROM_XML <<EOF || true
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${CDROM}'/>
      <target dev='hdc' bus='ide'/>
      <readonly/>
    </disk>
EOF
fi

cat > "$OUT" <<EOF
<domain type='kvm'>
  <name>${NAME}</name>
  <memory unit='MiB'>${MEM_MB}</memory>
  <vcpu>1</vcpu>
  <os>
    <type arch='x86_64' machine='pc'>hvm</type>
    <boot dev='${BOOT_DEV}'/>
  </os>
  <features><acpi/><apic/></features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>destroy</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <controller type='ide' index='0'/>
${CDROM_XML}
${SERIAL_XML}
    <memballoon model='none'/>
  </devices>
</domain>
EOF
