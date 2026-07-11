#!/usr/bin/env bash
# build-boot-rom.sh — produce the signed iPXE EFI boot ROM for this lab.
#
# Thin wrapper over ../../netboot/build-ipxe.sh (REUSE, don't duplicate the iPXE
# build).  We only need the ipxe.efi binary; the actual boot logic lives in our
# own ./boot.ipxe (a UKI chainloader), which we stage into pxe_dir separately so
# the NIC's native iPXE ROM runs it over TFTP — exactly as the almalinux UEFI
# lab serves its own boot.ipxe.
#
# [YOU-RUN-THIS] — needs Docker (build-ipxe.sh builds iPXE in a container) and
# qemu-img.  Neither runs in the lab CI container; author-run.
#
# Usage:
#   ./build-boot-rom.sh [--server http://10.0.2.2:8181] [--output-dir ~/netboot]
#
# After it runs, copy ./boot.ipxe into the SAME output dir (the VM's pxe_dir):
#   cp ./boot.ipxe ~/netboot/boot.ipxe

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_IPXE="$REPO_ROOT/netboot/build-ipxe.sh"

server="http://10.0.2.2:8181"
output_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)     shift; server="${1:?--server requires a URL}"; shift ;;
    --output-dir) shift; output_dir="${1:?--output-dir requires a path}"; shift ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

[[ -x "$BUILD_IPXE" ]] || { echo "missing $BUILD_IPXE" >&2; exit 1; }

echo "[build-boot-rom] building signed iPXE EFI ROM (server=$server)" >&2
# --sign --use-snakeoil: sign for QEMU Secure Boot testing (snakeoil key, NOT for
# real hardware).  The UKI itself is what carries the real trust chain at boot.
"$BUILD_IPXE" \
  --server "$server" \
  --output-dir "$output_dir" \
  --sign --use-snakeoil

echo "[build-boot-rom] staging our UKI-chainloading boot.ipxe into $output_dir" >&2
# Rewrite ${server} is done by build-ipxe.sh for its OWN boot.ipxe; ours is a
# hand-written chainloader, so substitute the server literal here.
sed "s|\${server}|$server|g" "$SCRIPT_DIR/boot.ipxe" > "$output_dir/boot.ipxe"

echo "[build-boot-rom] done:" >&2
echo "  $output_dir/ipxe.efi   (UEFI boot ROM; pxe_bootfile)" >&2
echo "  $output_dir/boot.ipxe  (UKI chainloader served over TFTP)" >&2
echo "Next: nix build .#installer -> serve installer.efi from $output_dir on :8181" >&2
