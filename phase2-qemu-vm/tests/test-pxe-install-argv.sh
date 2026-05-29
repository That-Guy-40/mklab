#!/usr/bin/env bash
# Unit test: build_qemu_argv attaches the install_target disk for EVERY backend
# shape — WITHOUT booting QEMU.  Sources lab-vm.sh (via its sourcing guard) and
# inspects the QEMU_ARGV global.
#
# This pins the bug where the `pxe-install` backend (an install_target but NO
# iPXE-ROM `image`) left the target disk UNATTACHED: the whole disk block was
# gated on the ROM `$disk` being present, so the guest booted diskless and
# d-i/Anaconda died at "No root file system is defined".  That silently broke
# every UEFI-PXE lab (e.g. vm-almalinux-uefi-pxe.toml).

# render() sets globals consumed by the *sourced* build_qemu_argv via dynamic
# scope; shellcheck can't follow that, so SC2034 here is a false positive.
# shellcheck disable=SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# build_qemu_argv calls `have qemu-system-<arch>` and dies if the binary is absent.
require_cmd qemu-system-x86_64

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

# shellcheck disable=SC1090
source "$LAB_VM"

# render DISK INSTALL_TARGET → QEMU_ARGV (space-joined).  firmware="" keeps the
# arg-gen host-independent (no OVMF needed); disk attachment is independent of it.
render() {
    name=disktest arch=x86_64 microvm=false accel=tcg cpus=1 memory=256M \
        kernel="" initrd="" append="" seed="" mac="" ssh_port=2222 \
        firmware="" pxe_dir="" pxe_bootfile="" \
        disk="$1" install_target="$2"
    mkdir -p "$(vm_dir "$name")"
    build_qemu_argv
    printf '%s' "${QEMU_ARGV[*]}"
}
has() { grep -Fq -- "$2" <<<"$1"; }

# ── pxe-install: install_target ONLY, no iPXE ROM image (the regression) ─────
note "pxe-install (install_target only) → target attached as virtio-blk disk0"
a="$(render "" /tmp/target.qcow2)"
has "$a" 'file=/tmp/target.qcow2,if=none,id=disk0' \
    || fail "pxe-install: install_target NOT attached (the bug): $a"
has "$a" 'virtio-blk-pci,drive=disk0' \
    || fail "pxe-install: no virtio-blk device for the target disk: $a"
if has "$a" 'id=disk1'; then fail "pxe-install: unexpected second disk"; fi

# ── two-disk BIOS boot-loop: target=disk0 bootindex0 + iPXE ROM=disk1 bootindex1
note "two-disk (image + install_target) → target disk0/bootindex0, ROM disk1/bootindex1"
a="$(render /tmp/ipxe.qcow2 /tmp/target.qcow2)"
has "$a" 'file=/tmp/target.qcow2,if=none,id=disk0'   || fail "two-disk: target not disk0: $a"
has "$a" 'virtio-blk-pci,drive=disk0,bootindex=0'    || fail "two-disk: target missing bootindex=0: $a"
has "$a" 'file=/tmp/ipxe.qcow2,if=none,id=disk1'     || fail "two-disk: ROM not disk1: $a"
has "$a" 'virtio-blk-pci,drive=disk1,bootindex=1'    || fail "two-disk: ROM missing bootindex=1: $a"

# ── plain disk-image: a single disk, no bootindex ───────────────────────────
note "plain disk-image (image only) → single disk0, no bootindex"
a="$(render /tmp/vm.qcow2 "")"
has "$a" 'file=/tmp/vm.qcow2,if=none,id=disk0' || fail "plain: disk not attached: $a"
has "$a" 'virtio-blk-pci,drive=disk0'          || fail "plain: no virtio-blk: $a"
if has "$a" 'id=disk1'; then fail "plain: unexpected second disk"; fi

pass "build_qemu_argv attaches install_target for pxe-install + two-disk + plain shapes"
