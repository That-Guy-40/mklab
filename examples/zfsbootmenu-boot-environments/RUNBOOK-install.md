# RUNBOOK — install Debian on root-on-ZFS with ZFSBootMenu

A by-hand walk of putting Debian onto a ZFS root and making **ZFSBootMenu**
(ZBM) the UEFI bootloader. When you finish, the machine boots ZBM off the EFI
System Partition, ZBM imports your pool, and it `kexec`s into the Debian kernel
stored *inside* a ZFS boot environment. That is the foundation the
[boot-environment workflow](RUNBOOK-boot-environments.md) builds on.

> **The lesson.** GRUB struggles to read modern ZFS. ZFSBootMenu sidesteps it
> entirely: it *is* a small Linux kernel + a ZFS-capable initramfs packaged as
> an EFI executable. Because it has real OpenZFS, it reads your kernels straight
> off ZFS and `kexec`s them — so the OS kernel never has to live on the ESP, and
> every ZFS snapshot/clone becomes a bootable system image.

This is the faithful counterpart to [`install-zfs-root.sh`](install-zfs-root.sh),
which automates exactly these steps. Upstream source is cited in
[`UPSTREAM.md`](UPSTREAM.md) (ZFSBootMenu's official *Debian* guide).

> ⚠️ **Where this runs.** The install needs a **loaded ZFS kernel module**, a
> **whole blank disk to erase**, **root**, and a **UEFI** boot — none of which
> exist on the mklab host. Run it **inside a Debian live/rescue VM booted in
> UEFI mode** with a blank second disk. On a KVM-capable host you can build that
> environment with `phase2-qemu-vm/lab-vm.sh` (below). It was authored and is
> meant to be verified there, not on the mklab controller. Lab creds only
> (`root`/`zbmlab`).

---

## 0. Bring up a UEFI Debian live environment with ZFS  *(on a KVM host)*

You need a booted Linux with `zpool`/`zfs`, `debootstrap`, and `sgdisk`, plus a
blank target disk. Two options:

- **A Debian live ISO** (the `-live` image ships an installer you can drop to a
  shell in) with `contrib` enabled, then `apt install zfsutils-linux zfs-dkms
  debootstrap gdisk dosfstools`. ZFS DKMS must build against the running
  kernel's headers — install `linux-headers-$(uname -r)` first.
- **A ready Debian cloud VM** from this repo, given a second blank disk:

  ```bash
  # from the repo root, on a KVM-capable host
  phase2-qemu-vm/lab-vm.sh create --config examples/vm-examples/vm-debian-amd64.toml
  phase2-qemu-vm/lab-vm.sh start vm-debian
  # ...then attach a blank disk and install ZFS userland inside; the ISO route
  #    is simpler because the live kernel already matches the DKMS build.
  ```

Confirm you are in UEFI mode and ZFS is live:

```bash
[ -d /sys/firmware/efi ] && echo "UEFI ✓"
modprobe zfs && ls -l /dev/zfs        # /dev/zfs must exist
```

## 1. Partition the target disk — an ESP and a ZFS partition

`DISK` is the blank disk (here `/dev/vdb`). **This erases it.**

```bash
DISK=/dev/vdb
sgdisk --zap-all "$DISK"
sgdisk -n1:1M:+512M -t1:EF00 -c1:EFI "$DISK"   # EFI System Partition
sgdisk -n2:0:0      -t2:BF00 -c2:zfs "$DISK"   # the rest → ZFS
partprobe "$DISK"
```

`EF00` is the ESP (where ZBM's `.EFI` lives); `BF00` is the Solaris/ZFS type.
Partition names: `/dev/vdb1`,`/dev/vdb2` here (NVMe would be `…p1`,`…p2`).

## 2. Create the pool with the recommended properties

```bash
zpool create -f -o ashift=12 -o autotrim=on \
    -O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on \
    -O canmount=off -O mountpoint=/ -R /mnt \
    rpool /dev/vdb2
```

The *why* of each: `ashift=12` matches 4K-sector disks; `compression=lz4` is
free space + speed; `acltype=posixacl`+`xattr=sa` are what a Linux root FS
wants; `relatime` cuts write amplification. `canmount=off` + `mountpoint=/`
means the pool root itself never mounts but hands `/` down to its children.
`-R /mnt` sets a temporary *alternate root* so everything mounts under `/mnt`
during install and reverts to real `/` on the target.

## 3. Datasets — the boot-environment container, first BE, and shared data

```bash
# The BE container: no filesystem of its own, just the '/' base for BEs.
zfs create -o canmount=off -o mountpoint=/ rpool/ROOT
# The first boot environment.  canmount=noauto is the crux — see below.
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian
zfs mount rpool/ROOT/debian
# Persistent data OUTSIDE ROOT so every BE shares one /home.
zfs create -o mountpoint=/home rpool/home
# Tell ZFSBootMenu which BE to boot by default.
zpool set bootfs=rpool/ROOT/debian rpool
```

> **Why `canmount=noauto` on each BE.** Every boot environment claims
> `mountpoint=/`. If they all auto-mounted, they would fight over `/`.
> `noauto` means *nothing* mounts automatically; the initramfs mounts only the
> one BE you booted. This is the single most important property in the layout —
> get it wrong and a second BE breaks the first.

## 4. debootstrap the base system + mount the ESP

```bash
debootstrap bookworm /mnt http://deb.debian.org/debian
mkdir -p /mnt/boot/efi
mkfs.vfat -F32 -n EFI /dev/vdb1
mount /dev/vdb1 /mnt/boot/efi
for fs in proc sys dev; do mount --rbind "/$fs" "/mnt/$fs"; done
```

Seed the identity + apt sources (note **`contrib`**, where `zfs-dkms` lives),
and put the ESP in `fstab` by UUID:

```bash
echo zbm-debian > /mnt/etc/hostname
cat > /mnt/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free-firmware
EOF
EFI_UUID=$(blkid -s UUID -o value /dev/vdb1)
echo "UUID=$EFI_UUID /boot/efi vfat umask=0022,fmask=0022,dmask=0022 0 1" > /mnt/etc/fstab
```

Record the kernel command line as a ZFS property — this is what ZBM passes to
the kernel it `kexec`s. Set it on the **`rpool/ROOT` container** so every boot
environment inherits it, and **omit `root=`**:

```bash
zfs set org.zfsbootmenu:commandline="quiet loglevel=4 rw" rpool/ROOT
```

> **Never put `root=` in this property.** ZFSBootMenu injects the correct
> `root=zfs:<the BE it is booting>` on its own. If you hard-code
> `root=zfs:rpool/ROOT/debian`, a clone that *inherits* that value would boot
> the **original** dataset instead of itself — silently breaking the whole
> boot-environment workflow. Setting it on the container (not one BE) is what
> lets clones inherit the right args with no per-BE `root=`.

## 5. In the chroot — kernel, ZFS, initramfs

```bash
chroot /mnt bash
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y linux-image-amd64 linux-headers-amd64 \
    zfsutils-linux zfs-initramfs zfs-dkms dosfstools efibootmgr curl ca-certificates
systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target
echo 'root:zbmlab' | chpasswd            # lab throwaway — change/lock for real use
update-initramfs -c -k all               # OS initramfs must import rpool + mount the BE
exit
```

`zfs-initramfs` is what lets the *OS's own* initramfs import the pool and mount
the booted BE as `/`. `zfs-dkms` builds the module against the installed kernel
headers.

## 6. Install ZFSBootMenu onto the ESP + register the EFI entry

**Simplest (the release EFI).** Drop the upstream pre-built ZBM executable
straight onto the ESP and point an EFI boot entry at it:

```bash
mkdir -p /mnt/boot/efi/EFI/zbm
curl -fL -o /mnt/boot/efi/EFI/zbm/vmlinuz.EFI https://get.zfsbootmenu.org/efi
efibootmgr --create --disk /dev/vdb --part 1 \
    --label "ZFSBootMenu" --loader '\EFI\zbm\vmlinuz.EFI'
```

**Build-from-source alternative (`generate-zbm`).** If you want ZBM built from
*your* kernel + config (the maintainable path), install the ZFSBootMenu source
and run `generate-zbm`, which reads [`config.yaml`](config.yaml) and writes
`vmlinuz.EFI` into the ESP for you:

```bash
# inside the chroot, contrib + the ZBM perl deps installed per UPSTREAM.md
install -Dm644 config.yaml /etc/zfsbootmenu/config.yaml
generate-zbm            # honours EFI.Enabled → /boot/efi/EFI/zbm/vmlinuz.EFI
```

The [`config.yaml`](config.yaml) in this lab is annotated line-by-line: it sets
`ManageImages: true`, enables the unified `EFI` output, points `BootMountPoint`
at `/boot/efi`, and sets ZBM's *own* command line. (That's distinct from each
BE's `org.zfsbootmenu:commandline`, which is the command line of the OS ZBM
boots.)

## 7. Export and reboot

```bash
umount -Rl /mnt
zpool export rpool
reboot                    # remove the installer media first
```

The firmware launches ZFSBootMenu, which imports `rpool` and — because
`bootfs=rpool/ROOT/debian` — boots that BE. Hold a key during ZBM's countdown
to get the **menu** (or set `zbm.show` in `config.yaml`'s `CommandLine` to show
it every boot).

### Success signature

```text
ZFSBootMenu v...  (the ZBM banner + a short countdown)
  → boots rpool/ROOT/debian
zbm-debian login:            # Debian, root on ZFS
# findmnt -no FSTYPE /        → zfs
# zfs list rpool/ROOT/debian  → the booted boot environment
```

Now go craft boot environments: **[RUNBOOK-boot-environments.md](RUNBOOK-boot-environments.md)**.

## Teardown & provenance

Destroy the VM with `phase2-qemu-vm/lab-vm.sh destroy zbm-debian --force` (or
just delete the qcow2). The install procedure follows ZFSBootMenu's official
Debian guide — cited, not mirrored, in [`UPSTREAM.md`](UPSTREAM.md).
