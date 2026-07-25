#!/usr/bin/env bash
# Build a tiny, self-contained BOOTABLE ISO for the vmedia/SOL demos: isolinux (BIOS)
# boots a kernel whose command line carries a unique MARKER. The kernel echoes
# "Command line: …" on console=ttyS0 in early boot, so any consumer of the node's
# serial (Redfish vmedia boot, or ipmi_sim SOL) sees the marker — proof the node
# booted THIS media. (syslinux SAY/DISPLAY don't reliably mirror to serial; the
# kernel-cmdline echo does.)
#
#   make-proof-iso.sh [--kernel /path/vmlinuz] [--marker STR] [--out proof.iso]
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${HOME}/netboot/vmlinuz"
MARKER="BMC_TOOLKIT_MEDIA_BOOT_PROOF=1"
OUT="${HERE}/proof.iso"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel) KERNEL="$2"; shift 2;;
    --marker) MARKER="$2"; shift 2;;
    --out)    OUT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v genisoimage >/dev/null || { echo "missing: genisoimage (apt install genisoimage)" >&2; exit 1; }
ISOLINUX_BIN="/usr/lib/ISOLINUX/isolinux.bin"
LDLINUX="/usr/lib/syslinux/modules/bios/ldlinux.c32"
[[ -f "$ISOLINUX_BIN" ]] || { echo "missing $ISOLINUX_BIN (apt install isolinux syslinux-common)" >&2; exit 1; }
[[ -r "$KERNEL" ]] || { echo "kernel not readable: $KERNEL (pass --kernel)" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/isolinux"
cp "$ISOLINUX_BIN" "$work/isolinux/"
[[ -f "$LDLINUX" ]] && cp "$LDLINUX" "$work/isolinux/"
cp -L "$KERNEL" "$work/vmlinuz"
cat > "$work/isolinux/isolinux.cfg" <<EOF
SERIAL 0 115200
PROMPT 0
TIMEOUT 10
DEFAULT proof
LABEL proof
  KERNEL /vmlinuz
  APPEND console=ttyS0,115200 ${MARKER}
EOF

genisoimage -quiet -o "$OUT" \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table -J -R -V BMCPROOF "$work"
echo "built $OUT (marker: ${MARKER})"
