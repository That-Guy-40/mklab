#!/usr/bin/env bash
# build-coreboot.sh — TIER A: build a real coreboot ROM with a LinuxBoot payload.
#
# This is the canonical LinuxBoot: coreboot (the firmware itself) carries a Linux
# kernel + u-root as its CBFS payload, and `qemu -bios coreboot.rom` boots it. The
# build has two long, from-source stages — both run here, no prebuilt blobs:
#   1. coreboot's own toolchain  (`crossgcc-i386`, gcc/binutils from source, ~15 min)
#   2. the ROM: coreboot downloads + compiles linux-6.3 (shipped minimal defconfig)
#      and builds u-root v0.14.0, then assembles them into coreboot.rom.
#
# Author-run by convention (the toolchain build is long), but it needs NO sudo:
# every coreboot build prerequisite (gnat, iasl/acpica-tools, flex, bison, the dev
# libs) is checked below; install any that are missing, then re-run.
#
# Verified end-to-end at coreboot e95bdb7e on Ubuntu 24.04 (host gcc 13.3 builds the
# 6.3 kernel; GOTOOLCHAIN=local keeps u-root's `go build` on the apt Go 1.22).
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
CB="$WORKDIR/coreboot"
COREBOOT_URL="${COREBOOT_URL:-https://github.com/coreboot/coreboot.git}"
HERE="$(cd "$(dirname "$0")" && pwd)"
JOBS="$(nproc)"
mkdir -p "$WORKDIR"

# Which coreboot config to build. Default = the verified disk-finale ROM (u-root
# v0.14.0). For the NETWORK-boot ROM, pass CBCONFIG=coreboot-qemu-q35-pxeboot.config
# (u-root main) + UROOT_GOBIN=$WORKDIR/go1.25/bin — see PLAN-PXEBOOT.md / POC-PXEBOOT.md.
CBCONFIG="${CBCONFIG:-$HERE/coreboot-qemu-q35-linuxboot.config}"
[[ "$CBCONFIG" = /* ]] || CBCONFIG="$HERE/$CBCONFIG"
# u-root main needs Go >= 1.25; UROOT_GOBIN puts it ahead of the apt Go 1.22 (which
# stays default for the v0.14.0 tiers). Get it with ./fetch-go.sh.
[[ -n "${UROOT_GOBIN:-}" ]] && export PATH="$UROOT_GOBIN:$PATH"

# --- 0. prerequisites (no sudo done for you — just reported) ---
miss=""
for c in gcc g++ make git gnat flex bison m4 nasm iasl; do command -v "$c" >/dev/null || miss="$miss $c"; done
for p in build-essential libncurses-dev libelf-dev zlib1g-dev libssl-dev acpica-tools uuid-dev; do
  dpkg -l "$p" 2>/dev/null | grep -q '^ii' || miss="$miss $p"; done
if [ -n "$miss" ]; then
  echo "Missing coreboot build deps:$miss" >&2
  echo "Install with: sudo apt install build-essential git gnat flex bison m4 nasm \\" >&2
  echo "   libncurses-dev libelf-dev zlib1g-dev libssl-dev acpica-tools uuid-dev device-tree-compiler" >&2
  exit 1
fi

# --- 1. coreboot tree ---
[ -d "$CB/.git" ] || git clone --depth 1 "$COREBOOT_URL" "$CB"
cd "$CB"

# --- 2. coreboot's i386 cross toolchain (from source; ~15 min, cached after) ---
if [ ! -x util/crossgcc/xgcc/bin/i386-elf-gcc ]; then
  echo "==> building coreboot crossgcc-i386 (CPUS=$JOBS) — this is the long part"
  make crossgcc-i386 CPUS="$JOBS"
fi

# --- 3a. give the payload KERNEL disk/fs/partition drivers ---
# The shipped LinuxBoot defconfig is *very* minimal — no block, fs, or partition
# support — so it boots u-root but can't SEE a disk. Add just enough for u-root's
# `boot` to find a real OS on a virtio (or SATA/AHCI) disk and kexec it (the Tier A
# "boot a real OS" finale; see run-coreboot-boot-disk.sh / RUNBOOK §6). Idempotent.
KDC=payloads/external/LinuxBoot/x86_64/defconfig
if ! grep -q '^CONFIG_VIRTIO_BLK=y' "$KDC"; then
  cat >> "$KDC" <<'EOF'
CONFIG_VIRTIO_MENU=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_SATA_AHCI=y
CONFIG_ATA_PIIX=y
CONFIG_MSDOS_PARTITION=y
CONFIG_EFI_PARTITION=y
EOF
fi

# --- 3a-net. give the payload KERNEL a NIC + TCP/IP so u-root's `pxeboot` works ---
# The disk block above lets `boot` see a local disk (the Tier A finale). For the
# NETWORK boot policy `pxeboot` (PLAN-PXEBOOT.md P1) the payload kernel also needs
# the whole net stack — u-root does DHCP over a raw AF_PACKET socket, then fetches
# the kernel/initrd over TCP/IP (HTTP now, HTTPS at P2). The minimal defconfig has
# none of it, so add: NET/INET/PACKET + a driver for QEMU's NIC. virtio-net matches
# our `-device virtio-net`; e1000/e1000e cover slirp's default NIC too. Idempotent.
if ! grep -q '^CONFIG_VIRTIO_NET=y' "$KDC"; then
  cat >> "$KDC" <<'EOF'
CONFIG_NET=y
CONFIG_PACKET=y
CONFIG_UNIX=y
CONFIG_INET=y
CONFIG_NETDEVICES=y
CONFIG_NET_CORE=y
CONFIG_VIRTIO_NET=y
CONFIG_E1000=y
CONFIG_E1000E=y
CONFIG_IP_PNP=y
CONFIG_IP_PNP_DHCP=y
CONFIG_HW_RANDOM=y
CONFIG_HW_RANDOM_VIRTIO=y
EOF
fi
# IP_PNP_DHCP: the KERNEL does the DHCP (with `ip=dhcp`, set in the pxeboot config) —
# u-root's own DHCP client emits no packets over QEMU slirp (POC-PXEBOOT.md), but the
# kernel's in-stack client works, and `pxeboot -file` then reuses that config.
# HW_RANDOM_VIRTIO: u-root's netboot needs entropy (else "could not get random
# number") — pair with QEMU `-device virtio-rng-pci`. All harmless for the disk tiers.

# --- 3b. config: q35 + LinuxBoot payload (CBCONFIG; default = the disk-finale ROM) ---
echo "==> using coreboot config: $CBCONFIG"
cp "$CBCONFIG" .config
make olddefconfig

# --- 4. build the ROM (downloads+compiles linux-6.3, builds u-root, assembles) ---
# GOTOOLCHAIN=local: u-root's `go build` must use the apt Go 1.22, not an
# auto-downloaded 1.25 (which breaks u-root — same trap as build-uroot.sh).
echo "==> building coreboot.rom (kernel + u-root + assembly)"
GOTOOLCHAIN=local make -j"$JOBS"

echo "==> checkpoints"
ls -lh build/coreboot.rom
echo "    CBFS payload (the LinuxBoot kernel+u-root):"
./build/cbfstool build/coreboot.rom print | grep -E 'fallback/payload' || true
echo "==> ROM built at $CB/build/coreboot.rom.  Next: ./run-coreboot-linuxboot.sh"
