#!/usr/bin/env bash
# build-nixos-image.sh — build the lab's NixOS image INSIDE the nix-build-box.
#
# Runs `nix build .#image` (a UEFI/systemd-boot qcow2) in the reusable Nix build
# box (../nix-build-box), so the host needs NO Nix — only podman + KVM. The build
# is KVM-assisted (make-disk-image spins a throwaway build VM), so the box is run
# with `--device /dev/kvm`.
#
#   ./build-nixos-image.sh            # → out/nixos261.qcow2
#   ./build-nixos-image.sh /path/out  # custom output dir
#
# Then boot it (Spike B success = a serial login banner):
#   phase2-qemu-vm/lab-vm.sh create --config examples/systemd261-nixos-measured-boot/vm-nixos261-uefi.toml
#   phase2-qemu-vm/lab-vm.sh start  nixos261
#   phase2-qemu-vm/lab-vm.sh console nixos261     # expect: 'nixos261 login:'
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG_DIR="$HERE/image"
OUT="${1:-$HERE/out}"
BOX="${NIX_BUILD_BOX_IMAGE:-localhost/nix-build-box}"

_done=""
trap '[[ -n "$_done" ]] || printf "FAIL: build-nixos-image.sh exited early (rc=%s)\n" "$?" >&2' EXIT

command -v podman >/dev/null || { echo "FAIL: podman not found" >&2; exit 1; }
[[ -e /dev/kvm ]] || { echo "SKIP: /dev/kvm absent — this build is KVM-assisted" >&2; exit 77; }
podman image exists "$BOX" || {
    echo "FAIL: build box '$BOX' not found — build it first:" >&2
    echo "  phase4-podman/lab-podman.sh build --tag nix-build-box --backend build --context examples/nix-build-box" >&2
    exit 1
}

mkdir -p "$OUT"
echo "==> building .#image in $BOX (KVM-assisted); first run pulls a NixOS closure — be patient"

# /work = the flake (rw so flake.lock can be written back for reproducibility);
# /out  = where the finished qcow2 is copied so it survives the container.
podman run --rm --device /dev/kvm \
    -v "$IMG_DIR:/work:Z" -v "$OUT:/out:Z" -w /work \
    "$BOX" sh -c '
        set -e
        echo "--- systemd version baked into this image ---"
        nix eval --raw .#nixosConfigurations.measured.pkgs.systemd.version || true
        echo
        nix build .#image --out-link /tmp/result --print-build-logs
        # nixos-generators qcow-efi output is a dir holding nixos.qcow2.
        cp -L /tmp/result/*.qcow2 /out/nixos261.qcow2
        echo "--- built ---"; ls -lh /out/nixos261.qcow2
    '

_done=1
echo "PASS: image built → $OUT/nixos261.qcow2"
