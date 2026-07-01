#!/usr/bin/env bash
# run-coreboot-pxe.sh — PLAN-PXEBOOT P1: NETWORK-boot/provision an OS from the coreboot ROM.
#
# coreboot ROM (firmware) -> Linux (kernel does DHCP via `ip=dhcp`) -> u-root ->
# [type `pxeboot -file <URL>`] -> fetch boot-<os>.ipxe (HTTP :8181) -> fetch installer
# kernel+initrd -> kexec -> the OS installer runs its automated kickstart/preseed.
# The network twin of the disk finale (run-coreboot-boot-disk.sh): same ROM shape, same
# u-root, same serial-driver — `pxeboot -file` instead of `boot`.
#
# WHY `pxeboot -file`, not bare `pxeboot`, and WHY `ip=dhcp`: u-root's own DHCP client
# emits ZERO packets over QEMU slirp (fully diagnosed — POC-PXEBOOT.md). So the *kernel*
# does the DHCP (`ip=dhcp`, baked into coreboot-qemu-q35-pxeboot.config), and
# `pxeboot -file <URI>` takes a "manual target" that SKIPS DHCP and fetches over that
# already-configured interface. `-cpu host` (RHEL9 glibc needs x86-64-v2) and
# `-device virtio-rng-pci` (u-root netboot needs entropy) are both required.
#
# Needs: the pxeboot ROM (build with CBCONFIG=coreboot-qemu-q35-pxeboot.config +
# UROOT_GOBIN=…/go1.25/bin — u-root main), the :8181 server up (./serve-netboot.sh up),
# and the staged installer + iPXE script (./fetch-netboot-os.sh <os>).
#
#   ./run-coreboot-pxe.sh [rocky|kali|alma]      (default: rocky)
#   BOOTFILE=boot.ipxe ./run-coreboot-pxe.sh alma   # reuse an existing iPXE script
set -euo pipefail
OS="${1:-rocky}"
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
ROM="${ROM:-$WORKDIR/coreboot/build/coreboot.rom}"
NETBOOT_DIR="${NETBOOT_DIR:-$HOME/netboot}"
BOOTFILE="${BOOTFILE:-boot-$OS.ipxe}"
SRV="${SRV:-http://10.0.2.2:8181}"
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$ROM" ]] || { echo "no ROM at $ROM — build the pxeboot ROM first (see header)" >&2; exit 1; }
[[ -f "$NETBOOT_DIR/$BOOTFILE" ]] || {
  echo "no $BOOTFILE in $NETBOOT_DIR — run ./fetch-netboot-os.sh $OS (or set BOOTFILE=)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "need python3 to drive the console" >&2; exit 1; }
curl -fsI "http://127.0.0.1:8181/$BOOTFILE" >/dev/null 2>&1 \
  || echo "warn: :8181 not serving $BOOTFILE — run ./serve-netboot.sh up" >&2

# A blank target disk so the installer has somewhere to land (scratch).
DISK="${DISK:-$WORKDIR/pxe-target-$OS.qcow2}"
[[ -f "$DISK" ]] || qemu-img create -f qcow2 "$DISK" 12G >/dev/null

SOCK="$WORKDIR/ttyPXE.sock"; LOG="$WORKDIR/pxe-$OS-boot.log"
rm -f "$SOCK"
# -cpu host needs KVM; fall back to a v2-capable model under TCG.
if [[ -w /dev/kvm ]]; then ACCEL=kvm; CPU="${CPU:-host}"; else ACCEL=tcg; CPU="${CPU:-Nehalem}"; fi
NIC="${NIC:-e1000}"
URL="$SRV/$BOOTFILE"

echo "==> launch pxeboot ROM (accel=$ACCEL cpu=$CPU nic=$NIC) → $LOG"
echo "    kernel does ip=dhcp; driver types \`pxeboot -file $URL\` → fetch → kexec installer"
qemu-system-x86_64 -M q35 -accel "$ACCEL" -cpu "$CPU" -m 4096 \
  -bios "$ROM" \
  -netdev "user,id=n0,tftp=$NETBOOT_DIR,bootfile=$BOOTFILE" \
  -device "$NIC,netdev=n0" \
  -device virtio-rng-pci \
  -drive file="$DISK",format=qcow2,if=virtio \
  -chardev socket,id=s0,path="$SOCK",server=on,wait=on -serial chardev:s0 \
  -display none -no-reboot >/dev/null 2>&1 &
QPID=$!
python3 "$HERE/drive-boot.py" "$SOCK" "$LOG" "pxeboot -v -ipv6=false -file $URL" 160 || true
kill "$QPID" 2>/dev/null || true           # stop the VM by PID (never by pattern)

echo "==> proof — kernel DHCP → pxeboot skips DHCP → kexec → the installer runs:"
sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r/\n/g' "$LOG" \
  | grep -iE "IP-Config: Got|Skipping DHCP|Welcome to u-root|Linux version 5\.14|anaconda|Starting automated install|debian-installer|dracut" \
  | head -20
