#!/usr/bin/env bash
#
# install-zfs-root.sh — install Debian onto root-on-ZFS with ZFSBootMenu as the
# UEFI bootloader, so the system gains FreeBSD-style boot environments.
#
# ┌───────────────────────────────────────────────────────────────────────────┐
# │  AUTHOR-RUN, UNDER KVM.  This is NOT run on the mklab host: it needs a      │
# │  loaded ZFS kernel module (/dev/zfs), a whole blank disk to ERASE, root,    │
# │  and a UEFI boot.  Run it INSIDE a Debian live/rescue VM booted in UEFI     │
# │  mode with a blank second disk — see RUNBOOK-install.md for the full walk   │
# │  and how to boot that environment via phase2-qemu-vm/lab-vm.sh.             │
# └───────────────────────────────────────────────────────────────────────────┘
#
# It follows the upstream ZFSBootMenu "Debian" install guide (single pool,
# unencrypted, UEFI) — see UPSTREAM.md for the citation.  Kept deliberately
# linear and commented so you can also run it a block at a time by hand.
#
#   DISK=/dev/vdb SUITE=bookworm sudo ./install-zfs-root.sh
#
# Defaults assume the lab's blank disk is /dev/vdb.  DOUBLE-CHECK `DISK` — this
# script repartitions it and destroys everything on it.
#
# ── Dry run ──────────────────────────────────────────────────────────────────
# INSTALL_DRYRUN=1 prints the exact plan and changes NOTHING — no root, no ZFS,
# no disk, no UEFI needed, so you can read the whole install on your laptop
# before pointing it at a disk:
#
#   INSTALL_DRYRUN=1 DISK=/dev/vdb ./install-zfs-root.sh
#
# Every effectful command goes through run(), and every file write through
# write_file(); the preflight checks and the confirmation prompt are skipped
# because they gate on a machine the dry run is deliberately not on.  A PARTIAL
# dry run would be worse than none — someone would trust it and still lose the
# disk — so tests/test-install-dryrun.sh runs the whole script with refusing
# stubs on PATH and fails if ANY real tool is reached.
#
set -euo pipefail

DISK="${DISK:-/dev/vdb}"
SUITE="${SUITE:-bookworm}"
POOL="${POOL:-rpool}"
BE_NAME="${BE_NAME:-debian}"
HOSTNAME_="${HOSTNAME_:-zbm-debian}"
MNT="${MNT:-/mnt}"
# Debian mirror (contrib carries zfs-dkms).
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
# ZFSBootMenu release EFI — dropped straight onto the ESP.  Override to pin a
# version; see RUNBOOK-install.md for the generate-zbm (build-from-source) path.
ZBM_EFI_URL="${ZBM_EFI_URL:-https://get.zfsbootmenu.org/efi}"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

DRYRUN="${INSTALL_DRYRUN:-0}"

# run — the single choke point for every command with an effect.  Same shape as
# be.sh's: in dry run it echoes a copy-pasteable line with a leading "+ ".
run() {
    if [[ "$DRYRUN" == 1 ]]; then
        printf '+'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

# write_file PATH — content on stdin.  File writes are effects too, and a
# redirection cannot be routed through run(), so they get their own choke point.
# Dry run shows the destination and the content it WOULD write, prefixed '|'.
write_file() {
    local path="$1"
    if [[ "$DRYRUN" == 1 ]]; then
        printf '+ write %s\n' "$path"
        sed 's/^/|   /'
    else
        cat > "$path"
    fi
}

# append_file PATH — same, for >>.
append_file() {
    local path="$1"
    if [[ "$DRYRUN" == 1 ]]; then
        printf '+ append %s\n' "$path"
        sed 's/^/|   /'
    else
        cat >> "$path"
    fi
}

# ── Preflight ────────────────────────────────────────────────────────────────
# Skipped entirely in a dry run: every one of these asserts a property of the
# install machine (root, /dev/zfs, a real block device, UEFI), and the point of
# the dry run is to read the plan somewhere that has none of them.
if [[ "$DRYRUN" != 1 ]]; then
[[ "$(id -u)" -eq 0 ]]          || die "run as root"
[[ -e /dev/zfs ]]               || die "/dev/zfs missing — is the zfs module loaded? (modprobe zfs)"
command -v zpool >/dev/null     || die "zpool not found — install zfsutils-linux (Debian contrib)"
command -v debootstrap >/dev/null || die "debootstrap not found — apt install debootstrap"
command -v sgdisk >/dev/null    || die "sgdisk not found — apt install gdisk"
[[ -b "$DISK" ]]                || die "DISK '$DISK' is not a block device"
[[ -d /sys/firmware/efi ]]      || die "not booted in UEFI mode — ZFSBootMenu here needs UEFI"

log "About to ERASE $DISK and install Debian $SUITE root-on-ZFS (pool '$POOL')."
read -r -p "Type the disk path again to confirm: " confirm
[[ "$confirm" == "$DISK" ]] || die "confirmation mismatch — aborting"
else
log "DRY RUN — no command below is executed and nothing is written."
log "Would ERASE $DISK and install Debian $SUITE root-on-ZFS (pool '$POOL')."
fi

# ── 1. Partition: p1 = EFI System Partition, p2 = the ZFS pool ────────────────
log "Partitioning $DISK (1: 512M ESP, 2: rest for ZFS)"
run sgdisk --zap-all "$DISK"
run sgdisk -n1:1M:+512M -t1:EF00 -c1:EFI "$DISK"
run sgdisk -n2:0:0      -t2:BF00 -c2:zfs "$DISK"
run partprobe "$DISK" 2>/dev/null || true
run sleep 2
# Partition device names: /dev/vdb1 vs /dev/nvme0n1p1 — insert 'p' for the latter.
if [[ "$DISK" == *[0-9] ]]; then P1="${DISK}p1"; P2="${DISK}p2"; else P1="${DISK}1"; P2="${DISK}2"; fi

# ── 2. Create the pool with the ZFSBootMenu-recommended properties ────────────
# canmount=off + mountpoint=/ on the pool root: the pool itself never mounts,
# but its children inherit '/' as the base.  acltype/xattr/relatime are the
# standard root-fs choices; ashift=12 for 4K-sector disks.
log "Creating pool '$POOL' on $P2"
run zpool create -f -o ashift=12 -o autotrim=on \
    -O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on \
    -O canmount=off -O mountpoint=/ -R "$MNT" \
    "$POOL" "$P2"

# ── 3. Datasets: the BE container, the first BE, and persistent data ──────────
log "Creating datasets (BE container + first boot environment '$BE_NAME')"
# ROOT is the boot-environment container: no mount of its own.
run zfs create -o canmount=off -o mountpoint=/ "$POOL/ROOT"
# The first boot environment.  canmount=noauto → only the booted BE mounts /.
run zfs create -o canmount=noauto -o mountpoint=/ "$POOL/ROOT/$BE_NAME"
run zfs mount "$POOL/ROOT/$BE_NAME"
# Persistent data lives OUTSIDE ROOT so it is shared across every BE.
run zfs create -o mountpoint=/home "$POOL/home"
# Make this BE the default ZFSBootMenu boots.
run zpool set "bootfs=$POOL/ROOT/$BE_NAME" "$POOL"

# ── 4. Base system ────────────────────────────────────────────────────────────
log "debootstrap $SUITE → $MNT"
run debootstrap "$SUITE" "$MNT" "$MIRROR"

log "Mounting the ESP and pseudo-filesystems into the new system"
run mkdir -p "$MNT/boot/efi"
run mkfs.vfat -F32 -n EFI "$P1"
run mount "$P1" "$MNT/boot/efi"
for fs in proc sys dev; do run mount --rbind "/$fs" "$MNT/$fs"; done

# Seed config the chroot needs.
printf '%s\n' "$HOSTNAME_" | write_file "$MNT/etc/hostname"
printf '127.0.1.1\t%s\n' "$HOSTNAME_" | append_file "$MNT/etc/hosts"
write_file "$MNT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR ${SUITE}-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free-firmware
EOF
# The ESP entry for fstab (by-UUID so it survives device renames).
if [[ "$DRYRUN" == 1 ]]; then EFI_UUID="<esp-uuid-read-at-install-time>"; else
EFI_UUID="$(blkid -s UUID -o value "$P1")"; fi
printf 'UUID=%s /boot/efi vfat umask=0022,fmask=0022,dmask=0022 0 1\n' "$EFI_UUID" \
    | write_file "$MNT/etc/fstab"

# Ship the example generate-zbm config.
run install -Dm644 "$(dirname "$(readlink -f "$0")")/config.yaml" \
    "$MNT/etc/zfsbootmenu/config.yaml"
# The kernel command line for the booted OS.  Two rules that make the BE
# workflow correct:
#   * NO root= here — ZFSBootMenu injects the right root=zfs:<be> for whatever
#     BE it boots.  A hard-coded root= would pin the wrong dataset.
#   * Set it on the ROOT *container*, not one BE, so every boot environment
#     (including future clones) inherits it.
run zfs set "org.zfsbootmenu:commandline=quiet loglevel=4 rw" "$POOL/ROOT"

# ── 5. Inside the chroot: kernel, ZFS, ZFSBootMenu ────────────────────────────
log "Configuring the new system in a chroot"
write_file "$MNT/root/inside-chroot.sh" <<CHROOT
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y locales console-setup
# Kernel + headers (zfs-dkms builds against the headers), the ZFS userland +
# initramfs hook, EFI tooling, and fetch tools.
apt-get install -y linux-image-amd64 linux-headers-amd64 \
    zfsutils-linux zfs-initramfs zfs-dkms \
    dosfstools efibootmgr curl ca-certificates
systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target 2>/dev/null || true
# Root password (lab throwaway) — change or lock for anything real.
echo 'root:zbmlab' | chpasswd
# Rebuild the OS initramfs so it can import the pool and mount the BE.
update-initramfs -c -k all
CHROOT
run chroot "$MNT" bash /root/inside-chroot.sh
run rm -f "$MNT/root/inside-chroot.sh"

# ── 6. Install ZFSBootMenu onto the ESP + register an EFI boot entry ──────────
# Simplest path: drop the upstream release EFI at \EFI\zbm\vmlinuz.EFI.  The
# from-source alternative is `generate-zbm` using /etc/zfsbootmenu/config.yaml
# (RUNBOOK-install.md walks both).
log "Installing ZFSBootMenu EFI onto the ESP"
run mkdir -p "$MNT/boot/efi/EFI/zbm"
run curl -fL -o "$MNT/boot/efi/EFI/zbm/vmlinuz.EFI" "$ZBM_EFI_URL" \
    || die "could not fetch ZFSBootMenu EFI from $ZBM_EFI_URL — see RUNBOOK-install.md for the generate-zbm build-from-source path"
DISK_ID="$(basename "$DISK")"
run efibootmgr --create --disk "$DISK" --part 1 \
    --label "ZFSBootMenu" \
    --loader '\EFI\zbm\vmlinuz.EFI' \
    || die "efibootmgr failed to register the ZFSBootMenu boot entry for $DISK_ID"

# ── 7. Teardown: unmount, export, reboot ──────────────────────────────────────
log "Unmounting and exporting the pool"
run umount -Rl "$MNT" 2>/dev/null || true
run zpool export "$POOL"

log "Done.  Remove the installer media and reboot — the firmware will launch"
log "ZFSBootMenu, which imports '$POOL' and boots the '$BE_NAME' boot environment."
log "Then craft boot environments with ./be.sh — see RUNBOOK-boot-environments.md."
