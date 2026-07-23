#!/usr/bin/env bash
# deps.sh — install everything Tiers B & C need on Ubuntu 24.04 (noble).
#
# Two kinds of dependency:
#   1. apt packages (need sudo): Go (u-root), kexec-tools, qemu+OVMF, FAT tooling.
#   2. the UKI toolchain (NO sudo): systemd's `ukify` + `linuxx64.efi.stub` +
#      python3 `pefile`. These are NOT installed system-wide — `pip install pefile`
#      is blocked by PEP 668 and we don't want to pull systemd-boot onto the host —
#      so we `apt-get download` the .debs and `dpkg-deb -x` them into $WORKDIR/debs.
#      build-uki.sh then runs ukify straight out of that tree via PYTHONPATH.
#
# Tier A (coreboot) deps are NOT installed here — that's a separate, author-run
# ~hour crossgcc build (see PLAN.md §4 / build-coreboot.sh).
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
mkdir -p "$WORKDIR/debs"

echo "==> apt packages (Go, kexec, qemu, OVMF, FAT/mtools, cpio)"
sudo apt-get update -qq
sudo apt-get install -y \
  golang-go kexec-tools \
  qemu-system-x86 ovmf \
  dosfstools mtools cpio git

echo "==> UKI toolchain WITHOUT sudo (download + extract .debs into $WORKDIR/debs)"
( cd "$WORKDIR/debs"
  apt-get download systemd-boot-efi systemd-ukify python3-pefile
  for d in *.deb; do dpkg-deb -x "$d" extracted/; done )

echo
echo "==> checkpoints"
go version
command -v kexec qemu-system-x86_64 mkfs.vfat mcopy
ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd
ls "$WORKDIR"/debs/extracted/usr/bin/ukify \
   "$WORKDIR"/debs/extracted/usr/lib/systemd/boot/efi/linuxx64.efi.stub
PYTHONPATH="$WORKDIR/debs/extracted/usr/lib/python3/dist-packages" \
  python3 -c 'import pefile; print("pefile", pefile.__version__)'
echo "==> deps OK.  Next: ./fetch-kernel.sh   then   ./build-uroot.sh"
