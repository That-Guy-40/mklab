#!/usr/bin/env bash
# stage-netboot.sh — build + stage the NixOS iPXE deploy artifacts into ~/netboot.
#
#   (default / --tier-a)  Tier A — package install: a netboot installer that
#                         auto-partitions /dev/vda + `nixos-install`s the target.
#                         BIOS PXE; stages bzImage+initrd + a hand-written
#                         nixos-boot.ipxe. Offline (target closure baked in).
#
#   --tier-b              Tier B — image lay-down: a tiny deployer that dd's the
#                         dm-verity GOLDEN image (out/nixos261-verity.qcow2) onto
#                         /dev/vda. UEFI PXE; stages the golden raw + the deployer
#                         kernel/initrd + a CUSTOM ipxe.efi (Nix-built, deploy
#                         script embedded). Run `build-nixos-image.sh --verity` first.
#
# Everything builds inside nix-build-box (host needs no Nix).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG_DIR="$HERE/image"
OUT="$HERE/out"
NETBOOT="${LAB_NETBOOT_DIR:-$HOME/netboot}"
BOX="${NIX_BUILD_BOX_IMAGE:-localhost/nix-build-box}"
SERVER="http://10.0.2.2:8181"

MODE=tier-a
[[ "${1:-}" == "--tier-b" ]] && MODE=tier-b

command -v podman >/dev/null || { echo "FAIL: podman not found" >&2; exit 1; }
podman image exists "$BOX" || { echo "FAIL: build box '$BOX' missing (build examples/nix-build-box first)" >&2; exit 1; }
mkdir -p "$NETBOOT/nixos"

if [[ "$MODE" == tier-a ]]; then
    echo "==> [Tier A] building netboot installer (kernel + initrd; bakes the target closure) in $BOX"
    podman run --rm \
        -v "$IMG_DIR:/work:Z" -v "$NETBOOT:/netboot:Z" -w /work \
        "$BOX" sh -c '
            set -e
            nix build .#installer-kernel --out-link /tmp/k --print-build-logs
            nix build .#installer-initrd --out-link /tmp/i --print-build-logs
            cp -L /tmp/k/bzImage  /netboot/nixos/bzImage
            cp -L /tmp/i/initrd   /netboot/nixos/initrd
            chmod 644 /netboot/nixos/bzImage /netboot/nixos/initrd
            nix eval --raw .#nixosConfigurations.installer.config.system.build.toplevel > /netboot/nixos/.itop
        '
    INIT="$(cat "$NETBOOT/nixos/.itop")/init"
    echo "==> writing $NETBOOT/nixos-boot.ipxe (init=$INIT)"
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
    echo "PASS: [Tier A] staged → $NETBOOT/nixos/{bzImage,initrd} + $NETBOOT/nixos-boot.ipxe"
else
    command -v qemu-img >/dev/null || { echo "FAIL: qemu-img needed to convert the golden image to raw" >&2; exit 1; }
    [[ -r "$OUT/nixos261-verity.qcow2" ]] || { echo "FAIL: $OUT/nixos261-verity.qcow2 missing — run ./build-nixos-image.sh --verity first" >&2; exit 1; }
    echo "==> [Tier B] building deployer kernel/initrd + custom ipxe.efi in $BOX"
    podman run --rm \
        -v "$IMG_DIR:/work:Z" -v "$NETBOOT:/netboot:Z" -w /work \
        "$BOX" sh -c '
            set -e
            nix build .#deployer-kernel --out-link /tmp/dk --print-build-logs
            nix build .#deployer-initrd --out-link /tmp/di --print-build-logs
            nix build .#ipxe-efi        --out-link /tmp/ix --print-build-logs
            cp -L /tmp/dk/bzImage /netboot/nixos/deployer-bzImage
            cp -L /tmp/di/initrd  /netboot/nixos/deployer-initrd
            cp -L /tmp/ix/ipxe.efi /netboot/nixos-deploy.efi
            chmod 644 /netboot/nixos/deployer-bzImage /netboot/nixos/deployer-initrd /netboot/nixos-deploy.efi
        '
    echo "==> [Tier B] converting golden image → raw for dd (served at /nixos/nixos261-verity.raw)"
    qemu-img convert -f qcow2 -O raw "$OUT/nixos261-verity.qcow2" "$NETBOOT/nixos/nixos261-verity.raw"
    chmod 644 "$NETBOOT/nixos/nixos261-verity.raw"
    echo "PASS: [Tier B] staged → $NETBOOT/nixos/{deployer-bzImage,deployer-initrd,nixos261-verity.raw} + $NETBOOT/nixos-deploy.efi"
fi
