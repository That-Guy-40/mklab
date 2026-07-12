#!/usr/bin/env bash
# stage-netboot.sh — Spike E, Tier A: build the NixOS netboot installer inside
# nix-build-box and stage it (kernel + initrd + a hand-written boot-nixos.ipxe)
# into the repo's netboot dir (~/netboot) for iPXE serving on :8181.
#
# The installer AUTO-INSTALLS the target system onto the pxe-install VM's /dev/vda
# and reboots into it (see image/installer.nix). Offline install (target closure
# baked into the initrd), so the only network use is iPXE's HTTP fetch.
#
#   ./stage-netboot.sh
#   phase4-podman/lab-podman.sh up --config examples/systemd261-nixos-measured-boot/nixos-pxe-install.toml
#   phase2-qemu-vm/lab-vm.sh create --config …/nixos-pxe-install.toml && lab-vm.sh start nixos261-pxe
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG_DIR="$HERE/image"
NETBOOT="${LAB_NETBOOT_DIR:-$HOME/netboot}"
BOX="${NIX_BUILD_BOX_IMAGE:-localhost/nix-build-box}"
SERVER="http://10.0.2.2:8181"

command -v podman >/dev/null || { echo "FAIL: podman not found" >&2; exit 1; }
podman image exists "$BOX" || { echo "FAIL: build box '$BOX' missing (build examples/nix-build-box first)" >&2; exit 1; }

mkdir -p "$NETBOOT/nixos"
echo "==> building netboot installer (kernel + initrd; bakes the target closure) in $BOX"
# Build inside the box, copy the artifacts to the host netboot dir (mounted rw).
podman run --rm \
    -v "$IMG_DIR:/work:Z" -v "$NETBOOT:/netboot:Z" -w /work \
    "$BOX" sh -c '
        set -e
        nix build .#installer-kernel --out-link /tmp/k --print-build-logs
        nix build .#installer-initrd --out-link /tmp/i --print-build-logs
        cp -L /tmp/k/bzImage  /netboot/nixos/bzImage
        cp -L /tmp/i/initrd   /netboot/nixos/initrd
        chmod 644 /netboot/nixos/bzImage /netboot/nixos/initrd
        # The init= path the installer must boot with (from the netboot config).
        nix eval --raw .#nixosConfigurations.installer.config.system.build.toplevel > /netboot/nixos/.toplevel
        printf "%s" "$(cat /netboot/nixos/.toplevel)/init" > /netboot/nixos/.initpath
        echo "installer toplevel: $(cat /netboot/nixos/.toplevel)"
    '

INIT="$(cat "$NETBOOT/nixos/.initpath")"
echo "==> writing $NETBOOT/nixos-boot.ipxe (init=$INIT)"
# A plain iPXE script (BIOS: QEMU's native iPXE NIC ROM TFTP-runs it directly).
# The kernel params mirror NixOS's own generated netboot.ipxe (initrd=initrd,
# root=fstab, nohibernate, lsm=…) PLUS ip=dhcp — the slirp DHCP lease iPXE got is
# NOT inherited by the booted kernel, so the installer must re-DHCP in-kernel.
cat > "$NETBOOT/nixos-boot.ipxe" <<EOF
#!ipxe
:start
dhcp || goto retry
kernel ${SERVER}/nixos/bzImage init=${INIT} initrd=initrd console=ttyS0,115200 console=tty0 nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf ip=dhcp || goto retry
initrd ${SERVER}/nixos/initrd || goto retry
boot || goto retry
:retry
echo iPXE boot step failed -- retrying in 3s
sleep 3
goto start
EOF
chmod 644 "$NETBOOT/nixos-boot.ipxe"

echo "PASS: staged → $NETBOOT/nixos/{bzImage,initrd} + $NETBOOT/nixos-boot.ipxe"
echo "  serve:  phase4-podman/lab-podman.sh up --config examples/systemd261-nixos-measured-boot/nixos-pxe-install.toml"
