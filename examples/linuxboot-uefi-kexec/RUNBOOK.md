# RUNBOOK — build LinuxBoot by hand, then watch Linux boot Linux

A by-hand walk of Tiers **C** (the bare mechanic) and **B** (genuine UEFI), with
the *why* at each step. The scripts in this dir automate exactly these steps; here
we run the pieces so you understand what each one does. Everything was run on
**Ubuntu 24.04 + QEMU/KVM**; the captured output lives in
[`MANUAL_TESTING.md`](MANUAL_TESTING.md).

Set a work dir once (artifacts are large — keep them off the repo):

```bash
export WORKDIR=~/linuxboot-lab
cd examples/linuxboot-uefi-kexec
```

---

## 0. Dependencies

```bash
./deps.sh
```

This does two distinct things (see the script's header):

- **apt (needs sudo):** `golang-go` (u-root is Go), `kexec-tools`,
  `qemu-system-x86` + `ovmf` (the UEFI firmware), `dosfstools`/`mtools` (to build a
  FAT ESP without loop-mounting), `cpio`/`git`.
- **the UKI toolchain, *without* sudo:** `ukify` + `linuxx64.efi.stub` + python
  `pefile`, obtained by `apt-get download` + `dpkg-deb -x` into `$WORKDIR/debs`.
  We don't install systemd-boot onto the host, and `pip install pefile` is walled
  off by PEP 668 — extracting the `.deb`s sidesteps both. (Tier B uses these; Tier
  C doesn't.)

> **Checkpoint:** `deps.sh` prints `go version`, the tool paths, the two OVMF
> firmware files, and `pefile <version>`. All present ⇒ continue.

---

## 1. A kernel to boot (and to kexec into)

```bash
./fetch-kernel.sh
```

LinuxBoot needs a kernel with **`CONFIG_EFI_STUB`** (so UEFI can launch it, Tier B)
and **`CONFIG_KEXEC`** (so u-root can hand off to it, both tiers). Distro kernels
have both; we grab the AlmaLinux 9 *pxeboot* `vmlinuz` (the host's own
`/boot/vmlinuz-*` is mode `0600`, root-only). Any modern `vmlinuz` works —
`KERNEL=/path ./build-uroot.sh` to use your own.

> **Checkpoint:** the script confirms the `MZ…PE` signature — i.e. the kernel
> *is* a PE/EFI executable (EFISTUB), which is what makes Tier B possible:
> ```
> DOS/PE signature: MZ=4d5a  PE=5045  (EFISTUB ✓)
> ```

---

## 2. Build u-root — the init that is the bootloader

```bash
./build-uroot.sh
```

u-root is a Go "busybox" whose **`/init` is a boot policy**, not a login shell. The
script builds two initramfs images:

- **`initramfs.cpio`** — plain u-root. Boots straight to a u-root shell. This is
  "Stage A": proof a kernel can run u-root as PID 1.
- **`initramfs-stage1.cpio`** — u-root **plus** the things it will hand off to,
  baked in with `-files`: the kernel at `/boot/bzImage`, a second initramfs at
  `/boot/initramfs2.cpio` (a copy of the plain image), and our boot policy
  [`uroot/dokexec.sh`](uroot/dokexec.sh) at `/bin/dokexec.sh`. `-uinitcmd="gosh
  /bin/dokexec.sh"` wires that policy to run as init's first job.

**The gotcha worth knowing** (it cost the most time in the spike): the obvious
`go install u-root@latest` makes Go's `GOTOOLCHAIN=auto` *silently download go1.25*,
under which u-root dies with `package core is not in std`. The fix baked into the
script: **`GOTOOLCHAIN=local`** (use the apt Go 1.22) **and build from the u-root
source tree** — `core`/`boot` are u-root's own command globs and only resolve
in-tree. Full autopsy in [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md) §2.

The boot policy itself, [`uroot/dokexec.sh`](uroot/dokexec.sh), is short and is the
whole point — it's what turns u-root from a shell into a *bootloader*:

```sh
kexec -i /boot/initramfs2.cpio -c "console=ttyS0 LINUXBOOT_STAGE2=reached" /boot/bzImage
```

`kexec` here loads **and** jumps in one call (u-root's `kexec` defaults to
load+exec). A real LinuxBoot policy would *probe* for a target first; we hard-code
one so the handoff is unmistakable in the log (see "Going further").

> **Checkpoint:** two images (~16 MiB, ~46 MiB); `cpio -itv` shows
> `boot/bzImage`, `boot/initramfs2.cpio`, `bin/dokexec.sh` inside the stage-1 image.

---

## 3. Tier C — the bare mechanic (fastest loop)

```bash
./run-linuxboot.sh
```

QEMU loads the kernel and initramfs **directly** (`-kernel`/`-initrd`) — no
firmware, no bootloader. This is a debugging convenience, not how a machine boots,
but it's the quickest way to iterate on the boot policy. The kernel boots, u-root's
init runs `dokexec.sh`, and `kexec` swaps in the second kernel.

> **Checkpoint — the handoff** (from the serial log):
> ```
> 2026/... Welcome to u-root!                              ← u-root = the bootloader
> === LINUXBOOT_STAGE1: u-root init is now the bootloader; kexec-ing stage 2 ===
> [    0.000000] Linux version 5.14.0-...                  ← 2nd kernel, clock reset!
> [    0.005304] Kernel command line: console=ttyS0 LINUXBOOT_STAGE2=reached
> 2026/... Welcome to u-root!                              ← second kernel up
> ```
> Two banners, two command lines (`STAGE1=boot` → `STAGE2=reached`), and the clock
> resetting to `0.000000` — a fresh kernel. (The run is `timeout`-capped because
> u-root idles at a shell; **exit 124 is the expected success path**.)

---

## 4. Tier B — genuine UEFI boots the same thing

Now delete QEMU's `-kernel` shortcut and put a real firmware in front.

### 4a. Fuse everything into one EFI blob (a UKI)

```bash
./build-uki.sh
```

A real machine's firmware boots a **PE/EFI application off a FAT filesystem**, not a
bare kernel + a side `-initrd`. The **Unified Kernel Image** packages it the way
firmware expects: `ukify` glues the kernel, the initramfs, the cmdline and an
os-release onto **systemd's EFI stub** as PE sections (`.linux`/`.initrd`/
`.cmdline`/`.osrel`). The stub is the EFI entry point; at boot it finds those
sections in its own image, hands the initrd to the kernel over the EFI **LoadFile2**
protocol, and starts the EFISTUB kernel with the embedded cmdline. The script then
writes the UKI to a FAT ESP (built rootless with `mkfs.vfat` + `mtools`) at
**`\EFI\BOOT\BOOTX64.EFI`** — the *removable-media fallback* path UEFI auto-launches
with no NVRAM boot entry and zero interaction.

> **Checkpoint:** `uki-kexec.efi` is a `PE32+ executable (EFI application)` whose
> `objdump -h` lists `.osrel/.cmdline/.linux/.initrd`. One file, everything inside.

> Doing this with raw `objcopy` is fiddly — the stub has a high `ImageBase` and the
> section VMAs must clear it; `ukify` computes that for you. ([POC-UEFI-MATRYOSHKA.md](POC-UEFI-MATRYOSHKA.md) §2.)

### 4b. Boot it under OVMF

```bash
./run-uefi-linuxboot.sh kexec      # the full handoff
./run-uefi-linuxboot.sh shell      # or just a u-root shell under OVMF (firmware-path sanity)
```

Only a firmware (`OVMF_CODE` pflash) and a disk (the ESP) — **no `-kernel`**. EDK II
finds `\EFI\BOOT\BOOTX64.EFI` and launches it. From there it's the same u-root →
kexec chain as Tier C, but everything downstream of *genuine UEFI*.

> **Checkpoint — real UEFI, then the handoff:**
> ```
> BdsDxe: starting Boot0001 "UEFI Non-Block Boot Device" ...   ← EDK II boot manager
> EFI stub: Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID ...  ← stub serves our .initrd
> [    0.000000] efi: EFI v2.7 by Ubuntu distribution of EDK II ← genuine UEFI firmware
> [    0.017248] Kernel command line: console=ttyS0 LINUXBOOT_STAGE1=boot   ← our .cmdline
> ... Welcome to u-root!  ...  kexec-ing stage 2  ...  LINUXBOOT_STAGE2=reached  ...  Welcome to u-root!
> ```
> `BdsDxe`/`EDK II` = the firmware really ran; `EFI stub: Loaded initrd` = the UKI
> served its own initramfs; the two banners + `STAGE1→STAGE2` = the kexec handoff,
> now behind UEFI. That's LinuxBoot on genuine UEFI.

---

## 5. Tier A — the canonical coreboot ROM (real firmware replacement)

Tiers B and C put Linux *behind* an existing firmware (OVMF, or QEMU's loader).
Tier A makes Linux **the firmware**: a **coreboot** ROM whose CBFS payload *is* a
Linux kernel + u-root. `qemu -bios coreboot.rom` — coreboot does the silicon init,
then jumps straight into Linux. This is what LinuxBoot flashes onto a real server.

```bash
./build-coreboot.sh           # author-run, ~20 min, NO sudo (deps are checked, not installed)
./run-coreboot-linuxboot.sh   # qemu -bios coreboot.rom
```

`build-coreboot.sh` does two from-source builds (see its header): **(1)** coreboot's
own `crossgcc-i386` toolchain (~15 min, cached after), then **(2)** the ROM — driven
by [`coreboot-qemu-q35-linuxboot.config`](coreboot-qemu-q35-linuxboot.config), coreboot
**downloads and compiles linux-6.3** (its shipped minimal x86_64 defconfig — serial
console + `CONFIG_KEXEC` + initrd) and **builds u-root v0.14.0** as the initramfs,
then assembles them into a 16 MB `coreboot.rom`. Two notes baked into the script:

- It's **author-run by convention** (the toolchain build is long) but needs **no
  sudo** — every coreboot prereq (`gnat`, `iasl`/`acpica-tools`, flex, bison, the dev
  libs) is *checked*; install any missing and re-run.
- `GOTOOLCHAIN=local` is exported for the build — coreboot's `u-root.mk` does
  `go build`, which would otherwise grab Go 1.25 and fail (the §2 trap, again).

> **Checkpoint — real coreboot, then Linux, then u-root** (`tierA.log`):
> ```
> coreboot-e95bdb7e ... x86_32 bootblock starting     ← coreboot firmware (not OVMF/SeaBIOS)
>   ... romstage ... ramstage ...
> Jumping to boot code at 0x00040000                  ← coreboot → its CBFS payload
> Linux version 6.3.0 (coreboot@reproducible) ...     ← the kernel coreboot compiled
> Kernel command line: console=ttyS0
> Run /init as init process
> Welcome to u-root!                                  ← u-root as PID 1
> ```
> Real firmware, in the ROM, booting Linux+u-root. (`timeout`-capped; u-root idles.)

## 6. Tier A finale — boot a *real OS* off disk (the production LinuxBoot)

The truest payoff: don't kexec a toy 2nd kernel — kexec the **installed OS off a
disk**, which is exactly what LinuxBoot does on a real server. u-root's **`boot`**
command scans block devices, parses their bootloader config (GRUB), and kexecs the
found kernel.

```bash
./fetch-os-disk.sh            # a real GRUB-installed OS disk (Debian 12 genericcloud)
./run-coreboot-boot-disk.sh   # coreboot ROM + that disk; drives `boot` over serial
```

Two pieces make it work, both handled for you:

- **The kernel must *see* the disk.** The shipped LinuxBoot defconfig is so minimal
  it has no block/fs/partition drivers, so [`build-coreboot.sh`](build-coreboot.sh)
  adds `VIRTIO_BLK`/`SATA_AHCI`/`EXT4`/`VFAT`/`MSDOS`+`EFI` partitions. Without them
  u-root comes up but finds no disks.
- **We *type* `boot` at the u-root shell.** coreboot only auto-runs `boot` as the
  uinit for u-root **main** (Go ≥ 1.23); with our pinned v0.14.0 (Go 1.22) no uinit
  runs, so u-root drops to a shell — the genuine interactive LinuxBoot prompt a
  human types `boot` at. [`drive-boot.py`](drive-boot.py) does that over a serial
  socket (slow keystrokes — serial input has no flow control). Build with u-root
  main on a newer Go for the hands-off version.

> **Checkpoint — two distinct kernels + real userspace** (`tierA-boot.log`):
> ```
> coreboot-… bootblock starting                      ← firmware (coreboot)
> Linux version 6.3.0 (coreboot@reproducible) …      ← kernel #1 (coreboot-built) + u-root
> Welcome to u-root!        ← (we type `boot`)
> 02. Debian GNU/Linux, with Linux 6.1.0-49-cloud…   ← u-root `boot` parsed the disk's grub.cfg
> Linux version 6.1.0-49-cloud-amd64 (debian-kernel…)← kernel #2 — the disk's OS, via KEXEC
> Welcome to Debian GNU/Linux 12 (bookworm)!         ← real Debian systemd + login
> Debian GNU/Linux 12 localhost ttyS0
> ```
> coreboot → Linux+u-root → the **installed OS**. That's LinuxBoot doing its real job.

## 7. Going further

- **`pxeboot` instead of `localboot`.** u-root also ships `pxeboot` — the same idea
  over the network (DHCP + netboot), the other real LinuxBoot policy.
- **A synthetic 2nd-kernel matryoshka on Tier A** (parity with B/C) is awkward here:
  the clean `uinitcmd` knob is gated to u-root *main*, the minimal kernel disables
  `BINFMT_SCRIPT` (so a `#!` uinit can't exec), and injecting a script uinit hits a
  `fork/exec … resource temporarily unavailable`. The real-OS finale above is both
  easier *and* more faithful — prefer it.
- **Secure Boot.** Plain QEMU has none, so `kexec_file_load`/`kexec_load` of an
  unsigned kernel just works. On a locked-down host you'd sign the kernel (and the
  UKI) or fall back to the legacy `kexec_load` syscall (`dokexec.sh` tries `-L`).
