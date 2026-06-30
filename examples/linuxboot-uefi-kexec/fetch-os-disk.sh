#!/usr/bin/env bash
# fetch-os-disk.sh — download a real, GRUB-installed OS disk for the Tier A finale
# (u-root's `boot` finds its kernel via grub.cfg and kexecs it). Debian 12
# genericcloud is ideal: it ships GRUB + a real kernel and configures a serial
# console, so we see the whole thing under -nographic.
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
DISK="${DISK:-$WORKDIR/debian-os.qcow2}"
URL="${URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
mkdir -p "$WORKDIR"
if [[ -f "$DISK" ]]; then
  echo "OS disk already present: $DISK"
else
  echo "==> fetching $URL"
  curl -fSL -o "$DISK" "$URL"
fi
echo "==> checkpoint:"; qemu-img info "$DISK" | grep -E 'file format|virtual size'
echo "==> OS disk ready at $DISK.  Next: ./run-coreboot-boot-disk.sh"
