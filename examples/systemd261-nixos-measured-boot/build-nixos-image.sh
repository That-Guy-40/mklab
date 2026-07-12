#!/usr/bin/env bash
# build-nixos-image.sh — build the lab's NixOS image INSIDE the nix-build-box.
#
# Two images (host needs NO Nix — only podman + KVM):
#   (default)  .#image        → a plain systemd-boot qcow2 (Spike B)
#                              → out/nixos261.qcow2
#   --verity   .#image-verity → a dm-verity /nix/store + UKI raw image (Spike D),
#              converted to    → out/nixos261-verity.qcow2
#
# The build is KVM-assisted (make-disk-image / repart), so the box runs with
# `--device /dev/kvm`.
#
#   ./build-nixos-image.sh              # → out/nixos261.qcow2
#   ./build-nixos-image.sh --verity     # → out/nixos261-verity.qcow2
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG_DIR="$HERE/image"
OUT="$HERE/out"
BOX="${NIX_BUILD_BOX_IMAGE:-localhost/nix-build-box}"

MODE=plain
[[ "${1:-}" == "--verity" ]] && MODE=verity

_done=""
trap '[[ -n "$_done" ]] || printf "FAIL: build-nixos-image.sh exited early (rc=%s)\n" "$?" >&2' EXIT

command -v podman  >/dev/null || { echo "FAIL: podman not found" >&2; exit 1; }
command -v qemu-img >/dev/null || { echo "FAIL: qemu-img not found (needed for raw→qcow2)" >&2; exit 1; }
[[ -e /dev/kvm ]] || { echo "SKIP: /dev/kvm absent — this build is KVM-assisted" >&2; exit 77; }
podman image exists "$BOX" || {
    echo "FAIL: build box '$BOX' not found — build it first:" >&2
    echo "  phase4-podman/lab-podman.sh build --tag nix-build-box --backend build --context examples/nix-build-box" >&2
    exit 1
}

mkdir -p "$OUT"

if [[ "$MODE" == plain ]]; then
    echo "==> building .#image (plain systemd-boot qcow2) in $BOX; first run pulls a closure"
    podman run --rm --device /dev/kvm \
        -v "$IMG_DIR:/work:Z" -v "$OUT:/out:Z" -w /work \
        "$BOX" sh -c '
            set -e
            echo "--- systemd version ---"; nix eval --raw .#nixosConfigurations.measured.pkgs.systemd.version || true; echo
            nix build .#image --out-link /tmp/result --print-build-logs
            cp -L /tmp/result/*.qcow2 /out/nixos261.qcow2
        '
    _done=1
    echo "PASS: image built → $OUT/nixos261.qcow2"
else
    echo "==> building .#image-verity (dm-verity + UKI raw image) in $BOX; first run pulls a closure"
    # Build the RAW image inside the box, copy it out, then convert on the host.
    podman run --rm --device /dev/kvm \
        -v "$IMG_DIR:/work:Z" -v "$OUT:/out:Z" -w /work \
        "$BOX" sh -c '
            set -e
            echo "--- systemd version ---"; nix eval --raw .#nixosConfigurations.verity.pkgs.systemd.version || true; echo
            nix build .#image-verity --out-link /tmp/result --print-build-logs
            raw="$(nix eval --raw .#nixosConfigurations.verity.config.image.filePath)"
            cp -L "/tmp/result/$raw" /out/nixos261-verity.raw
            echo "--- raw copied: $raw ---"; ls -lh "/out/nixos261-verity.raw"
        '
    echo "==> converting raw → qcow2 on the host"
    qemu-img convert -f raw -O qcow2 "$OUT/nixos261-verity.raw" "$OUT/nixos261-verity.qcow2"
    rm -f "$OUT/nixos261-verity.raw"
    _done=1
    echo "PASS: verity image built → $OUT/nixos261-verity.qcow2"
fi
