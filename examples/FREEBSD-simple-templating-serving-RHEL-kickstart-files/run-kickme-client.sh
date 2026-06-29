#!/usr/bin/env bash
# run-kickme-client.sh — launch the AlmaLinux "kickme" client VM that installs
# unattended from the FreeBSD server.
#
# *** AUTHOR-RUN ***: the FreeBSD server + templating + OEMDRV + repo-serving are
# verified in this lab (see MANUAL_TESTING.md); this final Anaconda install was
# NOT run in the build session — it is provided ready-to-run and faithfully
# documented (the repo's almalinux-pxe-lab proves the Anaconda mechanics).
#
# The client boots the AlmaLinux boot ISO (CD0) with the OEMDRV kickstart ISO
# (CD1) attached. Anaconda auto-scans any volume labelled OEMDRV for /ks.cfg, so
# NO inst.ks= is needed on the kernel line — that is vermaden's whole trick. It
# joins the qemu socket LAN, gets 10.0.10.199 from the kickstart, and pulls
# packages from http://10.0.10.210/almalinux/9/... served by the FreeBSD box.
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/freebsd-kickstart-lab}"
LAN_PORT="${LAN_PORT:-12377}"
DISK="$WORKDIR/kickme-disk.qcow2"
BOOT_ISO="${BOOT_ISO:-$WORKDIR/almalinux-boot.iso}"        # from fetch-almalinux.sh
OEMDRV_ISO="${OEMDRV_ISO:-$WORKDIR/kickme.oemdrv.iso}"     # from kickstart.sh
SERIAL="$WORKDIR/kickme-console.log"
DISPLAY_MODE="${DISPLAY_MODE:-none}"                       # 'gtk'/'sdl' to watch the installer

[[ -f "$BOOT_ISO"   ]] || { echo "missing boot ISO: $BOOT_ISO (run fetch-almalinux.sh)" >&2; exit 1; }
[[ -f "$OEMDRV_ISO" ]] || { echo "missing OEMDRV ISO: $OEMDRV_ISO (run templating/kickstart.sh)" >&2; exit 1; }

# OVMF (UEFI) firmware — the kickstart creates a /boot/efi partition.
OVMF_CODE="$(ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
               /usr/share/edk2/x64/OVMF_CODE.4m.fd 2>/dev/null | head -1 || true)"
OVMF_VARS_SRC="$(ls /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
                   /usr/share/edk2/x64/OVMF_VARS.4m.fd 2>/dev/null | head -1 || true)"
[[ -n "$OVMF_CODE" ]] || { echo "OVMF firmware not found (install 'ovmf')" >&2; exit 1; }
cp -n "$OVMF_VARS_SRC" "$WORKDIR/kickme-OVMF_VARS.fd"

[[ -f "$DISK" ]] || qemu-img create -f qcow2 "$DISK" 20G >/dev/null

echo "==> booting kickme (AlmaLinux installer). Serial -> $SERIAL"
echo "    NOTE: with DISPLAY_MODE=none the install runs on the (hidden) VGA console."
echo "    To watch / drive the boot menu, re-run with DISPLAY_MODE=gtk, or at the"
echo "    boot menu append 'inst.text console=ttyS0' to get the installer on serial."
exec qemu-system-x86_64 \
    -name kickme -machine q35 -accel kvm -cpu host -m 4096 -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$WORKDIR/kickme-OVMF_VARS.fd" \
    -drive file="$DISK",if=virtio,format=qcow2 \
    -drive file="$BOOT_ISO",media=cdrom,index=0,bootindex=0 \
    -drive file="$OEMDRV_ISO",media=cdrom,index=1 \
    -netdev socket,id=lan,connect=127.0.0.1:"$LAN_PORT" \
    -device virtio-net-pci,netdev=lan,mac=52:54:00:10:10:99 \
    -display "$DISPLAY_MODE" -serial file:"$SERIAL"
