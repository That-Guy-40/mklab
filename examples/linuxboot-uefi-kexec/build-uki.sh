#!/usr/bin/env bash
# build-uki.sh — TIER B: fuse kernel + u-root initramfs + cmdline into ONE
# Unified Kernel Image (UKI) that genuine UEFI firmware boots as \EFI\BOOT\BOOTX64.EFI.
#
# A UKI is systemd's EFI stub (a tiny PE/EFI app) with the kernel, initramfs,
# cmdline and os-release glued on as extra PE sections (.linux/.initrd/.cmdline/
# .osrel). The stub is the EFI entry point; at runtime it finds those sections in
# its own image, publishes the initrd via the EFI LoadFile2 protocol, and starts
# the EFISTUB kernel with the embedded cmdline. One file = firmware-flashable Linux
# — exactly LinuxBoot's "kernel as the firmware payload". See POC-UEFI-MATRYOSHKA.md.
#
# Builds two UKIs + their ESPs in $WORKDIR:
#   uki-shell.efi / esp.img        — plain u-root → a u-root shell under OVMF
#   uki-kexec.efi / esp-kexec.img  — stage-1 u-root → kexecs a 2nd kernel under OVMF
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
KERNEL="${KERNEL:-$WORKDIR/vmlinuz}"
HERE="$(cd "$(dirname "$0")" && pwd)"

DEBS="$WORKDIR/debs/extracted"
STUB="$DEBS/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
UKIFY="$DEBS/usr/bin/ukify"
PP="$DEBS/usr/lib/python3/dist-packages"          # vendored pefile (ukify dep)
[[ -f "$STUB" && -f "$UKIFY" ]] || { echo "UKI toolchain missing — run ./deps.sh first" >&2; exit 1; }
[[ -f "$WORKDIR/initramfs-stage1.cpio" ]] || { echo "no initramfs — run ./build-uroot.sh first" >&2; exit 1; }

cat > "$WORKDIR/os-release.txt" <<'EOF'
NAME="LinuxBoot"
ID=linuxboot
PRETTY_NAME="LinuxBoot UKI (u-root)"
VERSION="tierB"
EOF

build_uki() {  # <initramfs> <cmdline> <output>
  PYTHONPATH="$PP" python3 "$UKIFY" build \
    --linux="$KERNEL" --initrd="$1" --cmdline="$2" \
    --os-release="@$WORKDIR/os-release.txt" --stub="$STUB" --output="$3"
}
make_esp() {  # <uki> <img> <size_MB> — UKI at the removable-media auto-boot path
  rm -f "$2"; truncate -s "${3}M" "$2"; mkfs.vfat -n LINUXBOOT "$2" >/dev/null
  mmd -i "$2" ::/EFI ::/EFI/BOOT
  mcopy -i "$2" "$1" ::/EFI/BOOT/BOOTX64.EFI
}

build_uki "$WORKDIR/initramfs.cpio"        "console=ttyS0 LINUXBOOT_TIER=B-shell"   "$WORKDIR/uki-shell.efi"
build_uki "$WORKDIR/initramfs-stage1.cpio" "console=ttyS0 LINUXBOOT_STAGE1=boot"    "$WORKDIR/uki-kexec.efi"
make_esp  "$WORKDIR/uki-shell.efi"  "$WORKDIR/esp.img"        96
make_esp  "$WORKDIR/uki-kexec.efi"  "$WORKDIR/esp-kexec.img" 160

echo "==> checkpoints"
file "$WORKDIR/uki-kexec.efi" | sed 's/,.*$//'
objdump -h "$WORKDIR/uki-kexec.efi" | grep -E '\.(osrel|cmdline|linux|initrd)' || true
echo "==> UKIs built.  Next: ./run-uefi-linuxboot.sh"
