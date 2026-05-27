#!/usr/bin/env bash
# Unit test: build_qemu_argv emits the right machine type, firmware, and virtio
# transport for microvm on each arch — WITHOUT booting QEMU.  Sources lab-vm.sh
# (via its sourcing guard) and inspects the QEMU_ARGV global.
#
# This pins the bug the "true microvm" work fixes: QEMU's microvm machine is
# x86-only, so aarch64 + microvm must emit `-machine virt` (NOT `microvm`) with
# no UEFI pflash, while x86_64 + microvm gets the genuine microvm machine + qboot.

# render() sets a batch of globals that the *sourced* build_qemu_argv consumes via
# dynamic scope; shellcheck can't follow that across the source boundary, so its
# SC2034 "appears unused" for each would be a false positive (file-wide disable).
# shellcheck disable=SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# build_qemu_argv calls `have qemu-system-<arch>` and dies if the binary is absent.
require_cmd qemu-system-x86_64 qemu-system-aarch64

# Isolate all state under a tmpdir (LAB_STATE_DIR is consumed at source time).
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

# shellcheck disable=SC1090
source "$LAB_VM"

# Render argv for (arch, microvm) into QEMU_ARGV; echo it space-joined.
# firmware_for may die() when OVMF/AAVMF is absent (non-microvm path) — tolerate
# that so the test is host-independent; the asserts below don't need firmware.
render() {
    name=mvtest arch="$1" microvm="$2" accel=tcg cpus=1 memory=256M \
        kernel=/tmp/k initrd=/tmp/i append="console=ttyS0" \
        disk="" install_target="" seed="" mac="" ssh_port=2222
    firmware="$(firmware_for "$arch" "$microvm" 2>/dev/null || true)"
    mkdir -p "$(vm_dir "$name")"     # the OVMF path copies VARS into here
    build_qemu_argv
    printf '%s' "${QEMU_ARGV[*]}"
}
has() { grep -Fq -- "$2" <<<"$1"; }

# ── x86_64 microvm: the genuine microvm machine + qboot + mmio virtio ───────
note "x86_64 microvm → -machine microvm + virtio-mmio"
a="$(render x86_64 true)"
has "$a" '-machine microvm,pic=off,pit=off,rtc=off,accel=tcg' || fail "x86_64 microvm: wrong -machine: $a"
has "$a" 'virtio-net-device' || fail "x86_64 microvm: NIC not on the mmio bus (expected virtio-net-device)"
if has "$a" '/qboot.rom'; then note "qboot present (bypassed under -kernel, used for disk boot)"; fi

# ── aarch64 microvm: minimized virt, NOT microvm, no UEFI pflash ────────────
note "aarch64 microvm → -machine virt (no arm microvm machine exists)"
a="$(render aarch64 true)"
has "$a" '-machine virt,accel=tcg' || fail "aarch64 microvm: should be -machine virt: $a"
if has "$a" '-machine microvm'; then fail "aarch64 microvm: must NOT use the x86-only microvm machine"; fi
if has "$a" 'if=pflash';       then fail "aarch64 microvm: must boot direct -kernel with no UEFI pflash"; fi
has "$a" 'virtio-net-device' || fail "aarch64 microvm: NIC not on the mmio bus"

# ── regression: a full (non-microvm) x86_64 VM is still q35 + virtio-pci ─────
note "x86_64 full VM regression → q35 + virtio-pci"
a="$(render x86_64 false)"
has "$a" '-machine q35,accel=tcg' || fail "x86_64 full: should be q35: $a"
has "$a" 'virtio-net-pci' || fail "x86_64 full: NIC should be on PCI (virtio-net-pci)"
if has "$a" '-machine microvm'; then fail "x86_64 full: microvm leaked into a non-microvm VM"; fi

pass "build_qemu_argv: microvm/virt transports correct (x86_64 microvm, aarch64 virt, q35 regression)"
