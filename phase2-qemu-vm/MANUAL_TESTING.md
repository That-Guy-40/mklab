# Phase 2 — Manual Testing Walkthrough

A copy-pasteable, step-by-step exercise of `lab-vm.sh`. Run top-to-bottom on
a Debian / Ubuntu host with hardware virtualization enabled.

> **Set up:**
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> alias lv='phase2-qemu-vm/lab-vm.sh'        # no sudo: VMs run as your user
> ```

## 0. Preflight

```bash
sudo apt-get update
sudo apt-get install -y \
    jq curl socat genisoimage \
    qemu-system-x86 qemu-system-arm qemu-system-misc qemu-utils \
    ovmf qemu-efi-aarch64 u-boot-qemu opensbi \
    yq                       # mikefarah/yq for TOML
sudo usermod -aG kvm "$USER"
# log out and back in, or:  newgrp kvm
ls -l /dev/kvm                # should be crw-rw---- root kvm; you should be in kvm
```

> `sudo` is assumed already present on the host. **Inside the cloud-image VMs**
> sudo IS pre-installed (cloud-init relies on it for the `lab` user's NOPASSWD
> setup). `file` is not pulled in by these steps and is not used by the Phase 2
> scripts or tests.

Verify the script:

```bash
lv version             # → "lab-vm.sh 0.1.0"
lv help                # → full usage
lv list                # → empty header line
```

## 1. Validation guardrails (no QEMU launched)

Each of these should print a clear `[error]` and exit non-zero:

```bash
lv create --name x --backend bogus --arch x86_64
lv create --name x --arch m68k --distro debian --suite bookworm
lv create --name x --backend kernel+initrd --arch x86_64 \
          --kernel /tmp/no --initrd /tmp/no
lv create --name x --backend from-chroot --arch x86_64
lv create --name x --backend disk-image --arch x86_64
```

You can mechanise these with the test script:

```bash
phase2-qemu-vm/tests/test-validation.sh
phase2-qemu-vm/tests/test-arch-table.sh
```

## 2. Native x86_64 Debian VM (KVM, full UEFI)

The first run downloads the Debian cloud image (~350 MB, cached afterward).
End-to-end takes 2–4 minutes including cloud-init.

```bash
lv create --name deb1 --distro debian --suite bookworm --arch x86_64 \
          --memory 1G --cpus 1
```

**Expect:**
- `creating overlay qcow2: ... (backed by ...debian-bookworm-x86_64.qcow2)`
- `generating cloud-init seed iso`
- `accel: kvm`
- `── VM 'deb1' provisioned (not started; run: lab-vm.sh start deb1) ──`

```bash
lv list                # → deb1, stopped
lv start deb1
```

**Expect:**
- `starting deb1 (accel=kvm arch=x86_64 mem=1G cpus=1)`
- `deb1 running (pid NNNN)`
- `ssh:     ssh -p 2222 lab@127.0.0.1`
- `console: lab-vm.sh console deb1`

**Watch the console come up (Ctrl-] to detach):**

```bash
lv console deb1
```

You'll see Linux kernel boot, then cloud-init initializing the user, then a
login prompt for `deb1 login:`. Detach with `Ctrl-]`.

**SSH in:**

```bash
lv ssh deb1
# inside:
sudo apt-get update
sudo apt-get install -y htop
exit
```

Or non-interactive:

```bash
lv ssh deb1 -- 'uname -a; cat /etc/os-release'
```

**Stop gracefully** (sends `system_powerdown` via QMP, waits up to 30 s):

```bash
lv stop deb1
lv list                # → deb1, stopped
```

**Restart the same VM** (state is preserved in the qcow2 overlay):

```bash
lv start deb1
lv ssh   deb1 -- 'which htop'   # → /usr/bin/htop  (survived reboot)
lv stop  deb1
```

**Destroy:**

```bash
lv destroy deb1                # answer y
lv list                        # → empty
```

## 3. Foreign-arch aarch64 VM (TCG, AAVMF)

Slow (TCG emulation) but works on any host. ~5–10 min to first SSH.

```bash
lv create --name arm1 --distro debian --suite bookworm --arch aarch64 \
          --memory 1G --cpus 1
lv start arm1
lv console arm1                # watch the boot; Ctrl-] to detach when bored
```

**Verify the guest really is aarch64:**

```bash
lv ssh arm1 -- uname -m        # → aarch64
```

```bash
lv stop arm1
lv destroy arm1
```

## 4. microvm with Alpine (fastest boot path)

```bash
lv create --name alp1 --distro alpine --suite latest --arch x86_64 \
          --microvm --memory 256M --cpus 1
# `--suite latest` queries dl-cdn.alpinelinux.org/alpine/latest-stable
# at run time; pin with --suite 3.20 if you want a fixed version.
lv start alp1
```

Boot should be measurably faster (sub-second after image warm-up). SSH
availability still depends on cloud-init finishing.

```bash
lv ssh alp1 -- 'cat /etc/alpine-release'
lv destroy alp1 --force
```

## 5. TOML config equivalence

Same VM, two ways:

```bash
# CLI:
lv create --name deb-cli --distro debian --suite bookworm --arch x86_64 \
          --memory 1G --cpus 1 --ssh-port 2245
lv list

# TOML:
cat > /tmp/deb-cfg.toml <<EOF
[[vm]]
name     = "deb-cfg"
backend  = "disk-image"
distro   = "debian"
suite    = "bookworm"
arch     = "x86_64"
memory   = "1G"
cpus     = 1
ssh_port = 2246
EOF
lv create --config /tmp/deb-cfg.toml
lv list                        # → both deb-cli and deb-cfg

lv destroy deb-cli --force
lv destroy deb-cfg --force
rm -f /tmp/deb-cfg.toml
```

## 6. Direct kernel boot (`kernel+initrd`)

Boot the host's kernel inside a VM with no disk image. This is the
microvm-style fast iteration loop.

```bash
lv create --name kboot --backend kernel+initrd --arch x86_64 \
          --memory 512M --cpus 1 \
          --kernel /boot/vmlinuz-$(uname -r) \
          --initrd /boot/initrd.img-$(uname -r) \
          --append "console=ttyS0,115200 root=/dev/ram0 rdinit=/bin/sh"

lv start kboot
lv console kboot               # you should see kernel boot to a shell
# Ctrl-] to detach
lv stop kboot --force          # no init system to powerdown gracefully
lv destroy kboot --force
```

**Expect:** kernel and initrd boot under QEMU, console shows kernel logs and
drops to a shell prompt. SSH won't work in this minimal setup (no sshd in
the initrd).

## 7. Lifecycle / failure paths

### Already-running guard

```bash
lv create --name dup --distro debian --suite bookworm --arch x86_64
lv start dup
lv start dup       # → "dup is already running (pid NNNN)" (no-op)
lv stop  dup
lv destroy dup --force
```

### Already-exists guard

```bash
lv create --name dup --distro debian --suite bookworm --arch x86_64
lv create --name dup --distro debian --suite bookworm --arch x86_64
# → [error] VM 'dup' already exists.  Destroy it first
lv destroy dup --force
```

### Force-stop a stuck VM

If a guest hangs and `system_powerdown` doesn't take, the script falls back
to SIGTERM, then SIGKILL. To skip QMP entirely:

```bash
lv stop deb1 --force           # SIGTERM → SIGKILL escalation
```

### `--keep-disk` on destroy

Preserves the qcow2 in `${LAB_STATE_DIR}/orphaned-disks/` for forensics:

```bash
lv create --name probe --distro debian --suite bookworm --arch x86_64
lv start probe
# ... do something inside ...
lv stop probe
lv destroy probe --force --keep-disk
ls ~/.local/state/lab-create/orphaned-disks/   # → probe-<epoch>.qcow2
```

## 7b. Cross-phase: chroot → VM

Phase 1 builds a chroot tree; Phase 2 can boot it as a VM. Two paths,
pick based on what you care about.

### 7b.1 Automated: `backend = "from-chroot"` (x86_64 BIOS, root required)

Turns a chroot into a self-contained bootable qcow2 via MBR + extlinux
+ ext4. The chroot must already have a kernel + initrd installed — we
don't do that for you.

**Host prereqs:**

```bash
sudo apt-get install -y syslinux extlinux parted rsync   # Debian/Ubuntu/Kali
# or:
sudo dnf install -y syslinux extlinux parted rsync       # Rocky/Fedora
```

**Full walk-through** (Debian bookworm):

```bash
# 1) Build a chroot (network-bound, 1–3 min):
sudo phase1-chroot/lab-chroot.sh create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch x86_64 --target /var/chroots/vm-seed --variant minbase \
    --name vm-seed

# 2) Install a kernel + basic system + SSH inside the chroot:
sudo phase1-chroot/lab-chroot.sh enter vm-seed -- /bin/bash -c '
    apt-get update
    apt-get install -y --no-install-recommends \
        linux-image-amd64 systemd-sysv udev openssh-server \
        ifupdown isc-dhcp-client
    echo "root:lab" | chpasswd
    {
        echo "auto lo"; echo "iface lo inet loopback"
        echo "auto enp0s3"; echo "iface enp0s3 inet dhcp"
    } > /etc/network/interfaces
    systemctl enable ssh
'

# 3) Build the bootable VM:
sudo phase2-qemu-vm/lab-vm.sh create --config examples/vm-from-chroot-debian.toml

# 4) Start + console in (root/lab):
sudo phase2-qemu-vm/lab-vm.sh start   vm-from-chroot-demo
sudo phase2-qemu-vm/lab-vm.sh console vm-from-chroot-demo
# Ctrl-] to detach.

# 5) (Optional) SSH, once you've set up pubkey auth inside:
ssh -p <port-from-list> root@127.0.0.1
```

**What the backend does**, in one sentence: `qemu-img create raw`
→ `parted` MBR + bootable ext4 partition → `losetup -P` → `mkfs.ext4`
→ `rsync` the chroot in → write `/etc/fstab` + extlinux config →
`dd` the syslinux MBR → `qemu-img convert -O qcow2`.

**Troubleshooting:**

| Symptom | Fix |
|---|---|
| `no /boot/vmlinuz-* in chroot` | Step 2 wasn't run — install a kernel package inside the chroot |
| `no /boot/initrd.img-* or initramfs-*` | `sudo lc enter vm-seed -- update-initramfs -u -k all` |
| `syslinux MBR binary (mbr.bin) not found` | `sudo apt-get install syslinux-common` |
| VM boots but no console output | `console=ttyS0,115200` is already in extlinux.conf; if you changed kernel cmdline, keep it |
| VM kernel panic "unable to mount root" | Wrong root UUID — rebuild VM; the backend sets root=UUID=... from blkid |

**Limitations in v0.1:**

- x86_64 only (syslinux/extlinux is BIOS — UEFI+aarch64 is future work).
- Single ext4 partition, no swap, no LVM.
- No cloud-init: set passwords / SSH keys inside the chroot (step 2) before `lab-vm create`.
- Overlay qcow2 snapshots aren't automatic; `qemu-img create -b ...` manually if you want them.

### 7b.2 Manual workaround: kernel + initrd extraction (any arch)

If you need aarch64, UEFI, or just want to stay kernel-direct, skip the
`from-chroot` backend and use `backend = "kernel+initrd"` with vmlinuz
and initrd extracted from the chroot.

```bash
# After step 2 above (kernel installed in chroot), extract:
sudo cp /var/chroots/vm-seed/boot/vmlinuz-* /tmp/vmlinuz-vmseed
sudo cp /var/chroots/vm-seed/boot/initrd.img-* /tmp/initrd-vmseed
sudo chown $(id -u):$(id -g) /tmp/vmlinuz-vmseed /tmp/initrd-vmseed

# Option 1: host the chroot as a 9p / virtfs root.  Advanced; not covered here.
#
# Option 2: export the chroot as a disk image yourself, then use kernel+initrd
# pointing at the extracted kernel with the disk attached via --image.
#
#   # Produce a raw ext4 image as big as the chroot + 500 MB:
#   sudo bash -c '
#       SIZE=$(du -sb /var/chroots/vm-seed | awk "{print \$1}")
#       SIZE=$((SIZE + 500*1024*1024))
#       truncate -s "$SIZE" /tmp/vmseed.raw
#       mkfs.ext4 -q /tmp/vmseed.raw
#       MNT=$(mktemp -d)
#       mount /tmp/vmseed.raw $MNT
#       rsync -aAX --exclude=/proc/* --exclude=/sys/* --exclude=/dev/* \
#           /var/chroots/vm-seed/ $MNT/
#       umount $MNT; rmdir $MNT
#       chown $(id -u):$(id -g) /tmp/vmseed.raw
#   '
#   qemu-img convert -O qcow2 /tmp/vmseed.raw /tmp/vmseed.qcow2
#
#   # Now boot via kernel+initrd with the qcow2 attached:
#   phase2-qemu-vm/lab-vm.sh create \
#       --name vmseed-kerneldirect --backend kernel+initrd \
#       --arch x86_64 --memory 1G \
#       --kernel /tmp/vmlinuz-vmseed \
#       --initrd /tmp/initrd-vmseed \
#       --image  /tmp/vmseed.qcow2 \
#       --append "root=/dev/vda ro console=ttyS0,115200"
#   phase2-qemu-vm/lab-vm.sh start vmseed-kerneldirect
```

This is more finicky than the `from-chroot` backend, but it works
anywhere QEMU does (no bootloader dependency, no BIOS assumption) and
is the intended path for aarch64 / foreign-arch chroot → VM exercises
until the automated backend grows UEFI support.

## 8. State and image cache inspection

```bash
ls ~/.local/state/lab-create/vms/                     # one dir per VM
ls ~/.local/state/lab-create/vms/<name>/
# manifest.toml, disk.qcow2, seed.iso, qemu.pid (if running),
# monitor.sock, qmp.sock, serial.sock, qemu.log, vars.fd

ls -la ~/.cache/lab-create/images/                    # cached cloud images
du -sh ~/.cache/lab-create/images/*

cat ~/.local/state/lab-create/vms/<name>/manifest.toml

tail -50 ~/.local/state/lab-create/vms/<name>/qemu.log
```

To force a re-download of a cached image:

```bash
rm ~/.cache/lab-create/images/debian-bookworm-x86_64.qcow2
# next `create` for that distro/suite/arch will re-fetch
```

## 9. Run the automated suite

```bash
phase2-qemu-vm/tests/run-all.sh
```

Expect (on a fully-tooled host):

- `test-validation.sh` — pass (~1 s)
- `test-arch-table.sh` — pass (~1 s)
- `test-debian-x86_64-boot.sh` — pass (~2–4 min on KVM); skips without `/dev/kvm`

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `accel: tcg (no /dev/kvm; ...)` | KVM modules not loaded or `/dev/kvm` not present | `sudo modprobe kvm kvm_intel` (or `kvm_amd`); enable VT-x/AMD-V in BIOS |
| `accel: tcg (/dev/kvm exists but not r+w by uid=...)` | Your user not in the `kvm` group | `sudo usermod -aG kvm $USER && newgrp kvm` |
| `qemu-system-aarch64 not found` | Missing arch-specific QEMU binary | `apt-get install qemu-system-arm` |
| `no firmware found for x86_64` | OVMF not installed | `apt-get install ovmf` |
| `no firmware found for aarch64` | AAVMF not installed | `apt-get install qemu-efi-aarch64` |
| SSH never comes up | cloud-init still running, or seed iso not attached | `lv console <name>` to watch boot; check `qemu.log` |
| `download failed: https://...` | Cloud image URL changed or network issue | Check upstream image-server layout; supply `--image /path/to/qcow2` to bypass cache |
| Foreign-arch boot is glacially slow | Expected — TCG emulates everything | Reduce `--cpus 1 --memory 512M` to keep it usable |

Reach for `LAB_LOG_LEVEL=debug` to see the full QEMU argv:

```bash
LAB_LOG_LEVEL=debug lv start deb1
```
