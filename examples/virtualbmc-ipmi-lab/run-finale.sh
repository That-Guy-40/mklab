#!/usr/bin/env bash
# run-finale.sh — one-shot AlmaLinux PXE-install finale + serial-login capture.
#
# Run from this directory in a shell with sudo PRIMED (e.g. you ran
# `sudo -v` first).  All the sudo-needing work is front-loaded; the long install
# and the capture afterward use no sudo.  Captured login lands in finale-capture.log.
set -euo pipefail
cd "$(dirname "$0")"
LOG="finale-capture.log"; : > "$LOG"
ipmi() { ipmitool -I lanplus -H 127.0.0.1 -p 6230 -U admin -P password "$@"; }
VIRSH="virsh -c qemu:///system"

echo "== [1/6] PXE network + kickstart + HTTP (sudo) =="
PAYLOAD=almalinux ./setup-pxe-net.sh

echo "== [2/6] define node: 10G disk, 4G RAM, on vbmc-pxe (sudo) =="
DISK_SIZE=10G NET=vbmc-pxe MEMORY_MB=4096 ./create-node.sh

echo "== [3/6] BMC: build + up + add (sudo podman) =="
./vbmc-lab.sh build
./vbmc-lab.sh up
./vbmc-lab.sh add

echo "== [4/6] netboot: IPMI bootdev=pxe + power on (install runs unattended) =="
ipmi chassis bootdev pxe
ipmi chassis power on

echo "== [4/6] waiting for Anaconda to finish (kickstart ends in poweroff) =="
end=$(( $(date +%s) + 1800 ))     # 30-minute cap
while :; do
    st=$($VIRSH domstate alpine-node 2>/dev/null || echo unknown)
    printf '   %s  domstate=%s\n' "$(date +%T)" "$st"
    [ "$st" = "shut off" ] && { echo "   install complete (node powered off)"; break; }
    [ "$(date +%s)" -gt "$end" ] && { echo "   TIMEOUT — check the install"; exit 1; }
    sleep 20
done

echo "== [5/6] boot from disk: IPMI bootdev=disk + power on =="
ipmi chassis bootdev disk
ipmi chassis power on

echo "== [6/6] capturing the installed-OS serial login =="
sleep 5
python3 capture-login.py 2>&1 | tee -a "$LOG"

echo
echo "==> done.  Captured transcript: $(pwd)/$LOG"
