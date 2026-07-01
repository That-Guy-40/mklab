#!/usr/bin/env bash
# fetch-netboot-os.sh — stage the PXE installers u-root `pxeboot` will fetch, and
# render the per-OS iPXE scripts it parses. PLAN-PXEBOOT P1.
#
# Maximum reuse: this is a thin wrapper over the repo's existing, verified PXE-lab
# fetchers — it does NOT re-implement the download/verify logic:
#   • Rocky 9 (RHEL family, Anaconda + kickstart)  ← ../rocky-pxe-lab/fetch-rocky-installer.sh
#   • Kali    (Debian family, d-i + preseed)       ← ../kali-pxe-lab/fetch-kali-installer.sh
# Then it writes boot-rocky.ipxe / boot-kali.ipxe into ~/netboot using the SAME
# kickstart/preseed cmdlines those labs use. QEMU slirp hands one of these scripts
# to the guest as the DHCP bootfile (see run-coreboot-pxe.sh); u-root pxeboot parses
# it (it speaks iPXE) and fetches the kernel/initrd over HTTP from :8181.
#
#   ./fetch-netboot-os.sh [rocky|kali|both]     (default: both)
#
# Artifacts land under ~/netboot/{rocky,kali}/ so they never clobber the AlmaLinux
# vmlinuz/initrd.img already at ~/netboot/ root.
set -euo pipefail
WHICH="${1:-both}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
NETBOOT_DIR="${NETBOOT_DIR:-$HOME/netboot}"
SRV="${SRV:-http://10.0.2.2:8181}"
mkdir -p "$NETBOOT_DIR"

render() { printf '%s\n' "$@"; }   # readability helper

stage_rocky() {
  echo "==> staging Rocky 9 installer (via rocky-pxe-lab fetcher) → $NETBOOT_DIR/rocky/"
  "$REPO/examples/rocky-pxe-lab/fetch-rocky-installer.sh" --out "$NETBOOT_DIR/rocky"
  cp -v "$REPO/examples/rocky-pxe-lab/rocky9-zerotouch.ks" "$NETBOOT_DIR/rocky/rocky9-zerotouch.ks"
  # iPXE script: Anaconda fetches stage2 + kickstart locally from :8181/rocky/.
  cat > "$NETBOOT_DIR/boot-rocky.ipxe" <<EOF
#!ipxe
:start
dhcp || goto retry
kernel $SRV/rocky/vmlinuz inst.stage2=$SRV/rocky/ inst.ks=$SRV/rocky/rocky9-zerotouch.ks inst.text console=ttyS0 ip=dhcp || goto retry
initrd $SRV/rocky/initrd.img || goto retry
boot || goto retry
:retry
echo iPXE boot step failed -- retrying in 3s
sleep 3
goto start
EOF
  echo "    wrote $NETBOOT_DIR/boot-rocky.ipxe"
}

stage_kali() {
  echo "==> staging Kali installer (via kali-pxe-lab fetcher) → $NETBOOT_DIR/kali/"
  "$REPO/examples/kali-pxe-lab/fetch-kali-installer.sh" --out "$NETBOOT_DIR/kali"
  cp -v "$REPO/examples/kali-pxe-lab/kali-preseed.cfg" "$NETBOOT_DIR/kali/kali-preseed.cfg"
  # iPXE script: d-i fetches the preseed early; auto=true priority=critical = zero-touch.
  cat > "$NETBOOT_DIR/boot-kali.ipxe" <<EOF
#!ipxe
:start
dhcp || goto retry
kernel $SRV/kali/linux auto=true priority=critical preseed/url=$SRV/kali/kali-preseed.cfg DEBIAN_FRONTEND=text console=ttyS0,115200n8 --- || goto retry
initrd $SRV/kali/initrd.gz || goto retry
boot || goto retry
:retry
echo iPXE boot step failed -- retrying in 3s
sleep 3
goto start
EOF
  echo "    wrote $NETBOOT_DIR/boot-kali.ipxe"
}

case "$WHICH" in
  rocky) stage_rocky ;;
  kali)  stage_kali ;;
  both)  stage_rocky; stage_kali ;;
  *) echo "usage: $0 [rocky|kali|both]" >&2; exit 1 ;;
esac
echo "==> done. Next: ./serve-netboot.sh up ; ./run-coreboot-pxe.sh <rocky|kali>"
