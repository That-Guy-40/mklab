#!/usr/bin/env bash
# stage-deploy.sh — build + stage the reusable iPXE-deploy DEMO into ~/netboot/demo.
# Everything builds inside nix-build-box (host needs no Nix).
#
#   ./stage-deploy.sh            # Tier A (BIOS install): bzImage+initrd + demo-install.ipxe
#   ./stage-deploy.sh --tier-b   # Tier B (UEFI image):   deployer + custom ipxe.efi + demo raw
#
# The Tier-A install is offline (target closure baked into the installer initrd).
# For your OWN payload, import the modules from a consumer flake (see README) and
# adapt this script's `nix build .#…` targets + the served paths.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NETBOOT="${LAB_NETBOOT_DIR:-$HOME/netboot}"
BOX="${NIX_BUILD_BOX_IMAGE:-localhost/nix-build-box}"
SERVER="http://10.0.2.2:8181"

MODE=tier-a
[[ "${1:-}" == "--tier-b" ]] && MODE=tier-b

command -v podman >/dev/null || { echo "FAIL: podman not found" >&2; exit 1; }
podman image exists "$BOX" || { echo "FAIL: build box '$BOX' missing (build examples/nix-build-box first)" >&2; exit 1; }
mkdir -p "$NETBOOT/demo"

if [[ "$MODE" == tier-a ]]; then
    echo "==> [Tier A] building demo installer (kernel + initrd; bakes the demo target) in $BOX"
    podman run --rm -v "$HERE:/work:Z" -v "$NETBOOT:/netboot:Z" -w /work "$BOX" sh -c '
        set -e
        nix build .#installer-kernel --out-link /tmp/k --print-build-logs
        nix build .#installer-initrd --out-link /tmp/i --print-build-logs
        cp -L /tmp/k/bzImage /netboot/demo/bzImage
        cp -L /tmp/i/initrd  /netboot/demo/initrd
        chmod 644 /netboot/demo/bzImage /netboot/demo/initrd
        nix eval --raw .#nixosConfigurations.demo-installer.config.system.build.toplevel > /netboot/demo/.itop
    '
    INIT="$(cat "$NETBOOT/demo/.itop")/init"
    cat > "$NETBOOT/demo-install.ipxe" <<EOF
#!ipxe
:start
dhcp || goto retry
kernel ${SERVER}/demo/bzImage init=${INIT} initrd=initrd console=ttyS0,115200 console=tty0 nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf ip=dhcp || goto retry
initrd ${SERVER}/demo/initrd || goto retry
boot || goto retry
:retry
echo iPXE boot step failed -- retrying in 3s
sleep 3
goto start
EOF
    chmod 644 "$NETBOOT/demo-install.ipxe"
    echo "PASS: [Tier A] staged → $NETBOOT/demo/{bzImage,initrd} + $NETBOOT/demo-install.ipxe"
else
    command -v qemu-img >/dev/null || { echo "FAIL: qemu-img needed to convert the demo image to raw" >&2; exit 1; }
    echo "==> [Tier B] building demo deployer + custom ipxe.efi + demo image in $BOX"
    podman run --rm --device /dev/kvm -v "$HERE:/work:Z" -v "$NETBOOT:/netboot:Z" -w /work "$BOX" sh -c '
        set -e
        nix build .#deployer-kernel --out-link /tmp/dk --print-build-logs
        nix build .#deployer-initrd --out-link /tmp/di --print-build-logs
        nix build .#ipxe-efi        --out-link /tmp/ix --print-build-logs
        nix build .#demo-image      --out-link /tmp/im --print-build-logs
        cp -L /tmp/dk/bzImage  /netboot/demo/deployer-bzImage
        cp -L /tmp/di/initrd   /netboot/demo/deployer-initrd
        cp -L /tmp/ix/ipxe.efi /netboot/demo-deploy.efi
        cp -L /tmp/im/*.qcow2  /netboot/demo/demo-image.qcow2
        chmod 644 /netboot/demo/deployer-* /netboot/demo-deploy.efi /netboot/demo/demo-image.qcow2
    '
    echo "==> [Tier B] converting demo image → raw for dd"
    qemu-img convert -f qcow2 -O raw "$NETBOOT/demo/demo-image.qcow2" "$NETBOOT/demo/demo-image.raw"
    rm -f "$NETBOOT/demo/demo-image.qcow2"
    chmod 644 "$NETBOOT/demo/demo-image.raw"
    echo "PASS: [Tier B] staged → $NETBOOT/demo/{deployer-bzImage,deployer-initrd,demo-image.raw} + $NETBOOT/demo-deploy.efi"
fi
