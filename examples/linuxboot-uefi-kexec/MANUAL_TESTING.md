# MANUAL_TESTING — captured transcripts

Real output from the lab's own scripts on **Ubuntu 24.04 + QEMU/KVM**, run
**2026-06-30**. ANSI escapes stripped, trimmed for length. The deeper blow-by-blow
(including the build gotchas) is in [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md) (Tier C)
and [`POC-UEFI-MATRYOSHKA.md`](POC-UEFI-MATRYOSHKA.md) (Tier B); this file shows the
**lab scripts** producing those results.

Environment for the run below:

```
$ export WORKDIR=/media/sqs/COLD_STORAGE/lb-labtest KERNEL=/home/sqs/netboot/vmlinuz
```

(`KERNEL` pre-set to a kernel already on disk to skip the download; otherwise
`./fetch-kernel.sh` fetches the AlmaLinux 9 pxeboot `vmlinuz`.)

---

## fetch-kernel.sh — the kernel is a kexec-able EFISTUB

```
$ ./fetch-kernel.sh
==> checkpoint: is it a kexec-able EFISTUB (PE) bzImage?
/home/sqs/netboot/vmlinuz: Linux kernel x86 boot executable bzImage ... version 5.14.0-687.5.3.el9_8.x86_64 ...
    DOS/PE signature: MZ=4d5a  PE=5045  (EFISTUB ✓)
```

## build-uroot.sh — the userland + the embedded payload

```
$ ./build-uroot.sh
00:08:45 INFO Successfully built ".../initramfs.cpio" (size 16515728 bytes -- 16 MiB).
00:08:49 INFO Successfully built ".../initramfs-stage1.cpio" (size 48207700 bytes -- 46 MiB).
==> checkpoints
-rw-r--r-- 1 sqs sqs 16M ... initramfs.cpio
-rw-r--r-- 1 sqs sqs 46M ... initramfs-stage1.cpio
    /init + kexec present in the userland:
init -> bbin/init
    payload embedded in stage-1:
-rwxrwxr-x   0 root  root      1656 ... bin/dokexec.sh
-rw-r--r--   0 root  root  15173808 ... boot/bzImage
-rw-r--r--   0 root  root  16515728 ... boot/initramfs2.cpio
```

The stage-1 image carries the kernel, the second-stage initramfs, and the boot
policy — everything u-root needs to act as a bootloader.

---

## Tier C — `run-linuxboot.sh` (the bare mechanic)

```
$ ./run-linuxboot.sh
==> Tier C boot (45s cap, accel=kvm) → .../tierC.log
qemu-system-x86_64: terminating on signal 15 from pid ... (timeout)     ← expected (u-root idles)
==> proof (expect 2 u-root banners + STAGE1→STAGE2 cmdlines):
    u-root banners: 2
[    0.008929] Kernel command line: console=ttyS0 LINUXBOOT_STAGE1=boot
[    0.005304] Kernel command line: console=ttyS0 LINUXBOOT_STAGE2=reached
LINUXBOOT_STAGE1=boot
LINUXBOOT_STAGE2=reached
```

The handoff in the serial log (`tierC.log`), in order:

```
[    0.000000] Linux version 5.14.0-687.5.3.el9_8.x86_64 ...           ← kernel #1
[    0.008929] Kernel command line: console=ttyS0 LINUXBOOT_STAGE1=boot
[    0.428318] Run /init as init process
2026/06/30 04:09:01 Welcome to u-root!                                 ← u-root = the bootloader
=== LINUXBOOT_STAGE1: u-root init is now the bootloader; kexec-ing stage 2 ===
[    0.000000] Linux version 5.14.0-687.5.3.el9_8.x86_64 ...           ← kernel #2 — clock reset!
[    0.005304] Kernel command line: console=ttyS0 LINUXBOOT_STAGE2=reached
[    0.378611] Run /init as init process
2026/06/30 04:09:02 Welcome to u-root!                                 ← second kernel up
```

---

## Tier B — `build-uki.sh` + `run-uefi-linuxboot.sh` (genuine UEFI)

```
$ ./build-uki.sh
Wrote unsigned .../uki-kexec.efi
==> checkpoints
.../uki-kexec.efi: PE32+ executable (EFI application) x86-64 (stripped to external PDB)
  6 .osrel    00000053  000000014dfa5000 ...
  7 .cmdline  00000023  000000014dfa6000 ...
  9 .initrd   02df9754  000000014dfa8000 ...
 10 .linux    00e788b0  0000000150da2000 ...
```

One `BOOTX64.EFI` carrying the kernel (`.linux`), the u-root initramfs (`.initrd`)
and the boot args (`.cmdline`).

```
$ ./run-uefi-linuxboot.sh kexec
==> Tier B boot (kexec, 65s cap, accel=kvm) → .../tierB-kexec.log
qemu-system-x86_64: terminating on signal 15 from pid ... (timeout)     ← expected
==> proof (genuine UEFI launch + the handoff):
BdsDxe: starting Boot0001 "UEFI Non-Block Boot Device" from PciRoot(0x0)/Pci(0x3,0x0)
EFI stub: Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID device path
[    0.000000] efi: EFI v2.7 by Ubuntu distribution of EDK II
    u-root banners: 2
[    0.017248] Kernel command line: console=ttyS0 LINUXBOOT_STAGE1=boot
[    0.014698] Kernel command line: console=ttyS0 LINUXBOOT_STAGE2=reached
```

The full chain in the serial log (`tierB-kexec.log`), in order:

```
BdsDxe: starting Boot0001 "UEFI Non-Block Boot Device" ...             ← EDK II boot manager
EFI stub: Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID device path   ← UKI serves its own initrd
[    0.000000] efi: EFI v2.7 by Ubuntu distribution of EDK II          ← genuine UEFI firmware
[    0.017248] Kernel command line: console=ttyS0 LINUXBOOT_STAGE1=boot ← from the UKI's .cmdline
[    0.344721] Run /init as init process
2026/06/30 04:09:47 Welcome to u-root!                                 ← u-root, downstream of UEFI
=== LINUXBOOT_STAGE1: u-root init is now the bootloader; kexec-ing stage 2 ===
[    0.000000] Linux version 5.14.0-687.5.3.el9_8.x86_64 ...           ← kernel #2 — clock reset!
[    0.014698] Kernel command line: console=ttyS0 LINUXBOOT_STAGE2=reached
[    0.323560] Run /init as init process
2026/06/30 04:09:48 Welcome to u-root!                                 ← second kernel up
```

Programmatic confirmation:

```
$ grep -c 'EDK II'            tierB-kexec.log     # both kernels see the same UEFI firmware
2
$ grep -c 'Welcome to u-root' tierB-kexec.log     # two u-root inits — the handoff
2
```

A simpler `./run-uefi-linuxboot.sh shell` drops straight to a u-root **shell** under
OVMF (one banner, no kexec) — handy to confirm the firmware path in isolation.

---

## Tier A — `build-coreboot.sh` + `run-coreboot-linuxboot.sh` (real coreboot ROM)

Verified at coreboot `e95bdb7e`, host gcc 13.3, 32 cores. The build fetches gcc/
binutils source for coreboot's toolchain, then downloads+compiles linux-6.3 and
builds u-root v0.14.0, assembling a 16 MB ROM:

```
$ ./build-coreboot.sh
==> building coreboot crossgcc-i386 (CPUS=32) — this is the long part
... You can now run IASL ACPI compiler from .../xgcc.
==> building coreboot.rom (kernel + u-root + assembly)
    WWW        linux-6.3.tar.xz          ← coreboot downloads the kernel
... Built emulation/qemu-q35 (QEMU x86 q35/ich9)
==> checkpoints
-rw-rw-r-- 1 sqs sqs 16M ... build/coreboot.rom
    fallback/payload   0x1ee00   simple elf   5812913 none   ← the LinuxBoot kernel+u-root
```

```
$ ./run-coreboot-linuxboot.sh
==> Tier A boot (45s cap, accel=kvm) → .../tierA.log
==> proof (real coreboot firmware → Linux payload → u-root):
```

The serial log (`tierA.log`), in order (ANSI stripped):

```
[NOTE ]  coreboot-e95bdb7eee0a ... x86_32 bootblock starting (log level: 7)...   ← coreboot, not OVMF/SeaBIOS
[NOTE ]  coreboot-e95bdb7eee0a ... x86_32 romstage starting ...
[NOTE ]  coreboot-e95bdb7eee0a ... x86_32 ramstage starting ...
[DEBUG]  Jumping to boot code at 0x00040000(0x7fe98000)                          ← coreboot → CBFS payload
Linux version 6.3.0 (coreboot@reproducible) (gcc (Ubuntu 13.3.0-...) 13.3.0 ...   ← kernel coreboot compiled
Kernel command line: console=ttyS0
Run /init as init process
2026/06/30 04:48:02 Welcome to u-root!                                           ← u-root as PID 1
```

Real firmware in the ROM, booting Linux + u-root: the canonical LinuxBoot.

---

## Tier A finale — `run-coreboot-boot-disk.sh` (boot a real OS off disk)

After [`build-coreboot.sh`](build-coreboot.sh) (which now adds disk/fs/partition
drivers) + [`fetch-os-disk.sh`](fetch-os-disk.sh) (Debian 12 genericcloud). The
ROM boots Linux+u-root; the driver types `boot`; u-root's localboot parses the
disk's GRUB config and kexecs Debian's own kernel. Captured (ANSI stripped):

```
coreboot-e95bdb7e … x86_32 bootblock starting …                       ← firmware
Linux version 6.3.0 (coreboot@reproducible) …                         ← kernel #1 (coreboot-built)
2026/… Welcome to u-root!                          ← we type `boot`
01. Debian GNU/Linux
02. Debian GNU/Linux, with Linux 6.1.0-49-cloud-amd64                  ← u-root parsed the disk's grub.cfg
Linux version 6.1.0-49-cloud-amd64 (debian-kernel@lists.debian.org) … ← kernel #2 = the disk's OS, via KEXEC
Welcome to Debian GNU/Linux 12 (bookworm)!                            ← real Debian systemd
Debian GNU/Linux 12 localhost ttyS0                                   ← login prompt
```

Two distinct kernels (coreboot-built `6.3.0` → the disk's `6.1.0-49-cloud-amd64`),
the disk's GRUB menu parsed by u-root, and a real Debian login. coreboot → Linux +
u-root → **the installed OS**: the real LinuxBoot lifecycle.

---

## Summary

| Step | Result |
|---|---|
| `fetch-kernel.sh` — EFISTUB+kexec kernel | ✅ `MZ`/`PE` signature confirmed |
| `build-uroot.sh` — u-root + embedded payload | ✅ both initramfs images, payload present |
| **Tier C** `run-linuxboot.sh` — `-kernel` + u-root + kexec | ✅ 2 banners, `STAGE1→STAGE2` |
| `build-uki.sh` — UKI on a FAT ESP | ✅ `PE32+` with `.linux/.initrd/.cmdline/.osrel` |
| **Tier B** `run-uefi-linuxboot.sh kexec` — OVMF → UKI → u-root → kexec | ✅ `BdsDxe`+`EDK II`, 2 banners, `STAGE1→STAGE2` |
| `build-coreboot.sh` — coreboot toolchain + ROM | ✅ 16 MB `coreboot.rom`, LinuxBoot payload |
| **Tier A** `run-coreboot-linuxboot.sh` — `qemu -bios` → coreboot → Linux → u-root | ✅ coreboot stages, `Linux 6.3`, u-root banner |
| **Tier A finale** `run-coreboot-boot-disk.sh` — coreboot → u-root → `boot` → kexec a real OS | ✅ Debian `6.1.0` kexec'd off disk, systemd + login |
