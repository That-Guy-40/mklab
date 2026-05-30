#!/usr/bin/env bash
#
# build-vm.sh — automated: OffSec AWAE kali-rolling chroot → bootable VM.
#
# One command runs the whole pipeline (all as root — debootstrap, then
# losetup/mkfs/extlinux for the from-chroot image):
#
#   1) lab-chroot create --config <toml>   build the AWAE chroot (Phase 1)
#   2) lab-vm     create --config <toml>   package it into a bootable qcow2 (Phase 2)
#   3) lab-vm     start  <vm>              boot it (headless; serial console)
#
# Usage:
#   sudo examples/offsec-awae-vm/build-vm.sh             # full AWAE build, then start
#   sudo examples/offsec-awae-vm/build-vm.sh --smoke     # lean pipeline smoke test
#   sudo examples/offsec-awae-vm/build-vm.sh --no-start  # build only, don't boot
#   sudo examples/offsec-awae-vm/build-vm.sh --config FILE
#
# The full build is large (the offsec-awae metapackage + extras — several GB and
# a good while).  Run --smoke first to confirm the chroot→VM pipeline works.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

CONFIG="$HERE/offsec-awae-vm.toml"
VM_NAME="offsec-awae-vm"
START=1
VM_ONLY=0

usage() {
  cat <<'EOF'
build-vm.sh — automated: OffSec AWAE kali-rolling chroot → bootable VM.

  1) lab-chroot create   build the AWAE chroot (Phase 1)
  2) lab-vm     create   package it into a bootable qcow2 (Phase 2, from-chroot)
  3) lab-vm     start    boot it (headless; serial console)

Usage (run as root):
  sudo build-vm.sh             # full AWAE build, then start
  sudo build-vm.sh --smoke     # lean pipeline smoke test (no AWAE toolset)
  sudo build-vm.sh --no-start  # build only, don't boot
  sudo build-vm.sh --vm-only   # skip the chroot; re-image+boot from an existing chroot
  sudo build-vm.sh --config FILE

The full build is large (offsec-awae metapackage + extras — several GB).
Run --smoke first to confirm the chroot→VM pipeline works on your host.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke)    CONFIG="$HERE/offsec-awae-vm-smoke.toml"; VM_NAME="offsec-awae-smoke-vm" ;;
    --config)   CONFIG="${2:?--config needs a path}"; shift ;;
    --no-start) START=0 ;;
    --vm-only)  VM_ONLY=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "This pipeline needs root (debootstrap + losetup/mkfs/extlinux)." >&2
  echo "Re-run: sudo $0 $*" >&2
  exit 1
fi

# Host-side prerequisites for the from-chroot backend.  Warn (don't hard-fail) so
# the chroot still builds even if only the VM-imaging tools are missing.
missing=()
for b in debootstrap extlinux parted rsync qemu-img; do
  command -v "$b" >/dev/null 2>&1 || missing+=("$b")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "WARNING: missing host tools: ${missing[*]}" >&2
  echo "  install with: sudo apt-get install -y syslinux extlinux parted rsync qemu-utils debootstrap" >&2
fi

if [[ "$VM_ONLY" -eq 1 ]]; then
  echo "==> [vm-only] skipping the chroot build; re-imaging the VM from the existing chroot"
else
  echo "==> [1/3] building the chroot   (config: $CONFIG)"
  "$REPO/phase1-chroot/lab-chroot.sh" create --config "$CONFIG"
fi

echo "==> [2/3] packaging the chroot into a bootable VM"
"$REPO/phase2-qemu-vm/lab-vm.sh" create --config "$CONFIG"

if [[ "$START" -eq 1 ]]; then
  echo "==> [3/3] starting '$VM_NAME'"
  echo "    headless/serial — log in as kali/kali (or root/toor)."
  echo "    attach the console with:  sudo $REPO/phase2-qemu-vm/lab-vm.sh console $VM_NAME   (quit: Ctrl-A X)"
  "$REPO/phase2-qemu-vm/lab-vm.sh" start "$VM_NAME"
else
  echo "==> built. start it later with:"
  echo "    sudo $REPO/phase2-qemu-vm/lab-vm.sh start   $VM_NAME"
  echo "    sudo $REPO/phase2-qemu-vm/lab-vm.sh console $VM_NAME"
fi
