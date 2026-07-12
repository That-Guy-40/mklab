#!/usr/bin/env bash
# build-nixos-image.sh — build the lab's NixOS image INSIDE the nix-build-box.
#
# Two images (host needs NO Nix — only podman + KVM):
#   (default)  .#image        → a plain systemd-boot qcow2 (Spike B)
#                              → out/nixos261.qcow2
#   --verity   .#image-verity → a dm-verity /nix/store + UKI raw image (Spike D),
#              converted to    → out/nixos261-verity.qcow2
#   --sealed   .#image-sealed → the measured base + TPM2-sealed-LUKS policy +
#              converted to    baked attestation demo (Spike G)
#                              → out/nixos261-sealed.qcow2
#
# The build is KVM-assisted (make-disk-image / repart), so the box runs with
# `--device /dev/kvm`.
#
#   ./build-nixos-image.sh              # → out/nixos261.qcow2
#   ./build-nixos-image.sh --verity     # → out/nixos261-verity.qcow2
#   ./build-nixos-image.sh --sealed     # → out/nixos261-sealed.qcow2
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG_DIR="$HERE/image"
OUT="$HERE/out"
BOX="${NIX_BUILD_BOX_IMAGE:-localhost/nix-build-box}"

MODE=plain
case "${1:-}" in
  --verity) MODE=verity ;;
  --sealed) MODE=sealed ;;
  "" ) ;;
  * ) echo "FAIL: unknown flag '$1' (use --verity or --sealed)" >&2; exit 1 ;;
esac

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
    # verity and sealed share the same "build RAW via config.system.build.image,
    # convert raw→qcow2" path — only the flake output / config name / basename differ.
    if [[ "$MODE" == verity ]]; then CFG=verity; OUT_ATTR=image-verity; NAME=nixos261-verity
    else                             CFG=sealed; OUT_ATTR=image-sealed; NAME=nixos261-sealed
    fi
    echo "==> building .#$OUT_ATTR ($MODE: dm-verity + UKI raw image) in $BOX; first run pulls a closure"
    # Build the RAW image inside the box, copy it out, then convert on the host.
    podman run --rm --device /dev/kvm \
        -v "$IMG_DIR:/work:Z" -v "$OUT:/out:Z" -w /work \
        "$BOX" sh -c "
            set -e
            echo '--- systemd version ---'; nix eval --raw .#nixosConfigurations.$CFG.pkgs.systemd.version || true; echo
            nix build .#$OUT_ATTR --out-link /tmp/result --print-build-logs
            raw=\"\$(nix eval --raw .#nixosConfigurations.$CFG.config.image.filePath)\"
            cp -L \"/tmp/result/\$raw\" /out/$NAME.raw
            echo \"--- raw copied: \$raw ---\"; ls -lh \"/out/$NAME.raw\"
        "
    echo "==> converting raw → qcow2 on the host"
    qemu-img convert -f raw -O qcow2 "$OUT/$NAME.raw" "$OUT/$NAME.qcow2"
    rm -f "$OUT/$NAME.raw"
    _done=1
    echo "PASS: $MODE image built → $OUT/$NAME.qcow2"
fi
