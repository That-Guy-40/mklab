#!/usr/bin/env bash
# fetch-kernel.sh — get one world-readable bzImage to boot (and to kexec into).
#
# LinuxBoot needs a kernel with two features, both standard on distro kernels:
#   * CONFIG_EFI_STUB — so genuine UEFI (Tier B) can launch it as an EFI app, and
#   * CONFIG_KEXEC    — so u-root's init can kexec it (Tiers B & C).
# The AlmaLinux 9 installer (pxeboot) kernel has both (it's the same kernel the
# repo's netboot/PXE labs fetch). The host's own /boot/vmlinuz-* is mode 0600
# (root-only), so we fetch a readable one instead.
#
# Any modern vmlinuz works — point KERNEL= at one to skip the download:
#   KERNEL=/path/to/vmlinuz ./build-uroot.sh
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
KERNEL="${KERNEL:-$WORKDIR/vmlinuz}"
MIRROR="${MIRROR:-https://repo.almalinux.org/almalinux}"
REL="${REL:-9}"
URL="$MIRROR/$REL/BaseOS/x86_64/os/images/pxeboot/vmlinuz"

mkdir -p "$WORKDIR"
if [[ -f "$KERNEL" ]]; then
  echo "kernel already present: $KERNEL"
else
  echo "==> fetching AlmaLinux $REL pxeboot vmlinuz"
  echo "    $URL"
  curl -fSL -o "$KERNEL" "$URL"
fi

echo "==> checkpoint: is it a kexec-able EFISTUB (PE) bzImage?"
file "$KERNEL" | sed 's/,.*version/ ... version/'
mz=$(xxd -l2 "$KERNEL" | awk '{print $2}')         # 4d5a = "MZ"
pe=$(xxd -s 0x40 -l2 "$KERNEL" | awk '{print $2}') # 5045 = "PE"
echo "    DOS/PE signature: MZ=$mz  PE=$pe  $( [[ $mz == 4d5a && $pe == 5045 ]] && echo '(EFISTUB ✓)' || echo '(NOT a PE image!)' )"
echo "==> kernel ready at $KERNEL.  Next: ./build-uroot.sh"
