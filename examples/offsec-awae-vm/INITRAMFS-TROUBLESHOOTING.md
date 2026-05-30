# Inspecting & rebuilding the initramfs (dracut / lsinitrd)

A user-driven field guide for the `lsinitrd` + `dracut` toolset: how to look
*inside* an initramfs, how to rebuild one correctly, and how to use both to
diagnose a VM that drops to the **dracut emergency shell**. Written against the
`offsec-awae-vm` lab (a Kali `kali-rolling` chroot imaged into a BIOS/virtio VM),
but the technique applies to any dracut system.

---

## 1. What the initramfs actually is (and why a missing driver bricks boot)

When the kernel finishes loading, it can't yet read your real root filesystem —
it doesn't know *how* to talk to the disk. So the bootloader hands the kernel a
second file alongside it: the **initramfs** (a.k.a. initrd), a tiny gzip/zstd
cpio archive containing a minimal userspace + a pile of kernel modules. The
kernel unpacks it into RAM and runs its `/init`. That `/init` has exactly one
job:

1. load the **storage + transport** drivers needed to *see* the root device,
2. assemble it (LVM/RAID/LUKS if needed), mount the real `/`,
3. `switch_root` onto it and exec the real `/sbin/init` (systemd).

If step 1 is missing the right driver, step 2 never finds the root device, and
dracut gives up into an **emergency shell**. The kernel booted fine — it's the
*initramfs* that couldn't reach your disk. This is the single most common cause
of "it boots but drops to a prompt."

In our lab the missing driver is the **virtio transport** (`virtio_pci` +
`virtio_blk`): the chroot's initramfs was built on a host with SATA/NVMe disks,
so it never included virtio, so the QEMU VM's `/dev/vda` is invisible inside the
initramfs → emergency shell.

---

## 2. Two initramfs ecosystems — don't cross the streams

Debian-family distros ship **one of two** initramfs generators, with **different
archive formats** and **non-interchangeable readers**:

| | initramfs-tools | dracut |
|---|---|---|
| Default on | Debian, Ubuntu | **Kali**, Fedora, RHEL, SUSE |
| Generator | `update-initramfs` | `dracut` |
| Reader | `lsinitramfs` | **`lsinitrd`** |
| Host-only by default? | no (`MODULES=most` = generic) | **yes** |

**The trap we hit:** `lsinitramfs` (initramfs-tools' reader) cannot correctly
read a *dracut* initrd — it walks the wrong format and reports **0** for
everything. That's why an early diagnostic showed `grep -c virtio_blk = 0` with
`lsinitramfs` but `1` with `lsinitrd` on the *same* file. **Always match the
reader to the generator.** Kali = dracut = `lsinitrd`.

Quick way to tell which generated a given initrd:

```bash
lsinitrd /boot/initrd.img-* >/dev/null 2>&1 && echo "dracut" || echo "initramfs-tools (try lsinitramfs)"
```

---

## 3. host-only vs generic — the setting that bit us

dracut defaults to **host-only** (`hostonly=yes`): at build time it probes *this
machine* and bakes in **only** the drivers/filesystems/modules this machine is
currently using. Smaller initrd, faster boot — perfect when the box that builds
the initramfs is the same box that boots it.

It is a **disaster** when build-host ≠ boot-host:

- Build inside a chroot on a physical box (SATA/NVMe, real NIC), then boot the
  image as a **virtio** QEMU VM → no virtio in the initrd → no root device.
- Move a disk image between hypervisors with different virtual hardware.
- Build on one machine, restore onto different hardware.

The fix is to make the initramfs **generic** (`hostonly=no`) and, to be safe,
*explicitly name* the drivers the target needs.

---

## 4. Looking inside an initrd with `lsinitrd`

`lsinitrd` is dracut's archive reader. With no extra args it dumps the version,
the embedded kernel command line, the list of dracut modules, and the full file
tree:

```bash
lsinitrd /boot/initrd.img-$(uname -r)        # on a running system
lsinitrd /boot/initrd.img-*                  # in a chroot (one kernel installed)
```

The high-value queries:

```bash
# Is a specific driver present? (count > 0 == yes)
lsinitrd /boot/initrd.img-* | grep -c virtio_pci

# Show all virtio bits at once
lsinitrd /boot/initrd.img-* | grep virtio

# Just the kernel modules baked in
lsinitrd -m /boot/initrd.img-*

# Dump one embedded file's contents (e.g. the baked-in kernel cmdline)
lsinitrd -f /etc/cmdline.d/*.conf /boot/initrd.img-*

# What filesystems can it mount?
lsinitrd /boot/initrd.img-* | grep -E 'fs/.*(ext4|xfs|btrfs)'
```

> In this lab, run these through the chroot (where `/proc /sys /dev` are
> bind-mounted by `lab-chroot enter`, so the tools behave):
> ```bash
> sudo phase1-chroot/lab-chroot.sh enter offsec-awae -- sh -c 'lsinitrd /boot/initrd.img-* | grep -c virtio_pci'
> ```
> Wrap a pipe/glob in `sh -c '…'` so the redirection runs *inside* the chroot.

---

## 5. Rebuilding with `dracut`

```bash
# One specific kernel (positional: <output> <kernel-version>):
dracut --force /boot/initrd.img-6.19.14+kali-amd64 6.19.14+kali-amd64

# Every installed kernel:
dracut --regenerate-all --force
```

### Force generic + add drivers, one-shot (no config file)

This is the command that un-bricks our VM — `-N` makes it generic and
`--add-drivers` force-includes virtio even though the build host doesn't use it:

```bash
dracut -N --add-drivers "virtio_blk virtio_pci virtio_scsi virtio_net" --regenerate-all --force
```

(`-N` is short for `--no-hostonly`.) Plain `dracut --regenerate-all` would
**not** fix it — without `-N` it just rebuilds another host-only initrd.

### Make it permanent via config (survives future kernel upgrades)

A one-shot fixes *today's* initrd, but the next `apt upgrade` that pulls a new
kernel will regenerate a host-only initrd again. To make every future build
generic, drop a config file in `/etc/dracut.conf.d/` (this is what the lab's
TOML does, as `90-lab-vm.conf`):

```ini
hostonly=no
add_drivers+=" virtio_blk virtio_pci virtio_scsi virtio_net "
filesystems+=" ext4 "
```

Two non-obvious bits:
- The **leading/trailing spaces** inside the `+=` quotes are required — dracut
  *concatenates* these values, so the spaces keep tokens from gluing together.
- **Order matters:** write the config *before* the kernel package's postinst
  runs (the kernel postinst is what generates the initramfs on install). If the
  kernel is already in, just regenerate afterward with `dracut --regenerate-all --force`.

---

## 6. Scenario A — drop to the dracut emergency shell (our case)

**Symptoms on the console:**
```
dracut-initqueue[…]: Warning: dracut-initqueue: timeout, starting timeout scripts
Generating "/run/initramfs/rdsosreport.txt"
Entering emergency mode. Exit the shell to continue.
Cannot open access to console, the root account is locked.
```

**Read it correctly:** that "root account is locked" is the **initramfs's** root,
offered via `sulogin` — *not* your installed system's root. The real root isn't
mounted yet, so unlocking your system's root password wouldn't help; the problem
is upstream of login.

**Diagnose — from the emergency shell itself:**
```bash
ls /dev/vd*                 # empty?  → the virtio block driver never loaded
lsmod | grep virtio         # no virtio modules == confirmed
dmesg | grep -i virtio      # nothing about virtio devices
cat /run/initramfs/rdsosreport.txt   # dracut's auto-dumped diagnostic bundle
```
…or, *before* you ever boot it, from the chroot:
```bash
sudo phase1-chroot/lab-chroot.sh enter offsec-awae -- sh -c 'lsinitrd /boot/initrd.img-* | grep -c virtio_pci'
# 0 == host-only, will fail to boot in the VM
```

**Fix:** regenerate generic with virtio (§5), re-verify ≥ 1, then re-image the VM.

---

## 7. Scenario B — changed the storage layout (LVM / RAID / LUKS / new fs)

Same emergency shell, different missing piece. If you move root onto **LVM**, a
**mdadm RAID**, a **LUKS**-encrypted volume, or reformat root as **XFS/Btrfs**,
a host-only initrd built before the change won't carry the assembly tooling or
the filesystem driver.

```bash
# What's in there now?
lsinitrd /boot/initrd.img-* | grep -E 'lvm|dm-|mdraid|crypt'
lsinitrd /boot/initrd.img-* | grep -E 'fs/.*(xfs|btrfs)'
```

Fix by adding the relevant **dracut module** (not just a kernel driver) and/or
filesystem:
```bash
dracut --add lvm   --regenerate-all --force      # logical volumes
dracut --add mdraid --regenerate-all --force     # software RAID
dracut --add crypt --regenerate-all --force      # LUKS root (also needs a crypttab)
# or in /etc/dracut.conf.d/: add_dracutmodules+=" lvm crypt "  /  filesystems+=" xfs "
```

Same `lsinitrd`-to-diagnose, `dracut`-to-fix loop — only the missing component
differs.

---

## 8. Scenario C — stale / truncated initrd after an interrupted kernel upgrade

A power loss or a full disk *during* a kernel install can leave the initrd
half-written or out of sync with `/lib/modules/<ver>`. Symptoms range from boot
failure to "module not found" spam.

```bash
# Does it even read, and does it match the kernel it claims?
lsinitrd /boot/initrd.img-6.19.14+kali-amd64 >/dev/null && echo OK || echo "corrupt"
diff <(lsinitrd -m /boot/initrd.img-6.19.14+kali-amd64 | sort) \
     <(ls /lib/modules/6.19.14+kali-amd64/kernel -R | sort)   # rough sanity check
```

Fix is just a clean rebuild of that one kernel's initrd:
```bash
dracut --force /boot/initrd.img-6.19.14+kali-amd64 6.19.14+kali-amd64
```

---

## 9. Scenario D — boots, but the serial console is blank (adjacent failure)

Not strictly initramfs, but the same "it boots and I can't *see* it" family, and
`lsinitrd` still helps. A headless VM needs `console=ttyS0,115200` on the kernel
command line; if it's missing you get a black serial console even though the
system is up. Check what cmdline the bootloader/initrd actually carries:

```bash
lsinitrd /boot/initrd.img-* | grep -i cmdline       # any baked-in cmdline?
lsinitrd -f /etc/cmdline.d/*.conf /boot/initrd.img-* # dump it if present
# and on the booted system: cat /proc/cmdline
```

In this lab `lab-vm` puts `console=ttyS0,115200` in the extlinux `APPEND`, and
the chroot enables `serial-getty@ttyS0` — so the fix lives in the bootloader
config / unit enablement, not the initrd, but you confirm the cmdline the same way.

---

## 10. Quick reference

| Want to… | initramfs-tools (Debian/Ubuntu) | dracut (Kali/Fedora/RHEL) |
|---|---|---|
| list contents | `lsinitramfs <initrd>` | `lsinitrd <initrd>` |
| list modules | `lsinitramfs <initrd>` | `lsinitrd -m <initrd>` |
| dump one file | — | `lsinitrd -f <path> <initrd>` |
| rebuild one kernel | `update-initramfs -u -k <ver>` | `dracut --force /boot/initrd.img-<ver> <ver>` |
| rebuild all | `update-initramfs -u -k all` | `dracut --regenerate-all --force` |
| make generic | already generic (`MODULES=most`) | `-N` / `hostonly=no` |
| force a driver | add to `/etc/initramfs-tools/modules` | `--add-drivers "…"` / `add_drivers+=" … "` |
| add a subsystem | (modules + hooks) | `--add lvm\|crypt\|mdraid` / `add_dracutmodules+=" … "` |

**The loop, every time:** `lsinitrd` to see what's missing → `dracut … --force`
to put it back → `lsinitrd | grep -c` to confirm → reboot / re-image.

See also `README.md` ("How the chroot is made self-bootable") and the
troubleshooting table in `MANUAL_TESTING.md`.
