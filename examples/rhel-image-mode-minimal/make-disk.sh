#!/usr/bin/env bash
# make-disk.sh — turn the built minimal bootc IMAGE into a bootable qcow2, by
# running `bootc install to-disk` FROM the image itself.  The automated
# equivalent of RUNBOOK.md "Boot it".
#
# Why `bootc install` and not bootc-image-builder (bib)?  bib is a wrapper around
# this same `bootc install` code; running the image's OWN bootc directly is
# simpler, has no extra osbuild moving parts, and is what we verified.  (The
# minimal-image fixes below — naming the rootfs, and adding bubblewrap so the
# bootloader-install chroot works — are needed under bib too.)  bib remains a fine
# alternative on a current podman/host.
#
# bootc install needs root + --privileged (it wipes a block device — here a
# loopback-mounted file).  Run WITHOUT sudo; it elevates itself (one password
# prompt; sudo caches it):
#
#   ./make-disk.sh [IMAGE]            # default IMAGE: localhost/bootc-minimal:centos
#
# Output: ./output/disk.qcow2         (vm-bootc-minimal.toml already points here)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${1:-localhost/bootc-minimal:centos}"
out="$here/output"
raw="$out/disk.raw"
qcow="$out/disk.qcow2"
SIZE="${SIZE:-10G}"
ROOTFS="${ROOTFS:-xfs}"          # minimal strips the install config, so name the fs explicitly

command -v podman   >/dev/null || { echo "podman not found" >&2; exit 1; }
command -v qemu-img >/dev/null || { echo "qemu-img not found (install qemu-utils)" >&2; exit 1; }

# MUST run as your normal user, NOT via `sudo`.  This script builds the disk from
# the image in YOUR rootless podman storage (`podman save` below).  If you run the
# whole script under sudo, `podman save` reads ROOT's storage instead and you can
# silently install a STALE image (e.g. one missing bubblewrap) — which fails the
# bootloader step.  The script elevates itself only where root is required.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "Do NOT run this with sudo — run it as your normal user; it calls sudo itself." >&2
    echo "  ./make-disk.sh        (you'll be prompted for your password)" >&2
    exit 2
fi

podman image exists "$IMAGE" || {
    echo "image not in your (rootless) storage: $IMAGE" >&2
    echo "build it first:  ./build-minimal.sh --base centos" >&2
    exit 1
}

# A prior root-run can leave output/ root-owned; reset it so we can write as user.
sudo rm -rf "$out"
mkdir -p "$out"

echo "==> copying $IMAGE from YOUR rootless storage into ROOT storage (bootc install runs as root)…"
podman save "$IMAGE" | sudo podman load

echo "==> preparing a blank $SIZE loopback disk: $raw"
truncate -s "$SIZE" "$raw"

# DEBUG=1 turns on bootc's verbose bootloader + Rust logging, to diagnose the
# bootupd bootloader-probe step (see MANUAL_TESTING.md "Boot gotchas").
debug_env=()
[[ -n "${DEBUG:-}" ]] && debug_env=(-e BOOTC_BOOTLOADER_DEBUG=2 -e RUST_LOG=debug)

echo "==> bootc install to-disk (--privileged, --filesystem $ROOTFS) → $raw …"
sudo podman run --rm --privileged --pid=host \
    --security-opt label=type:unconfined_t \
    "${debug_env[@]}" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$out:/output" \
    "$IMAGE" \
    bootc install to-disk \
        --generic-image --via-loopback --wipe \
        --filesystem "$ROOTFS" \
        --karg console=ttyS0 --karg console=tty0 \
        --target-imgref "$IMAGE" \
        /output/disk.raw

echo "==> converting raw → qcow2: $qcow"
sudo chown "$(id -u):$(id -g)" "$raw"
qemu-img convert -f raw -O qcow2 "$raw" "$qcow"
rm -f "$raw"

echo
echo "==> done:"
ls -la "$qcow"
echo "Next:  ../../phase2-qemu-vm/lab-vm.sh create --config vm-bootc-minimal.toml && … start bootc-minimal"
echo "       then attach the serial console and log in:  root / lab"
