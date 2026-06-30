# PoC "UEFI MATRYOSHKA" — the nesting dolls, now booted by *genuine UEFI firmware*

> **What this is:** the **Tier B** feasibility spike behind the
> [LinuxBoot lab plan](PLAN.md), written up as a reproducible proof-of-concept. It
> is the sequel to [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md) (Tier C), which proved
> the bare mechanic — *u-root `init` `kexec`s a second kernel* — using QEMU's
> `-kernel`/`-initrd` shortcut. Here we **delete that shortcut** and put a real
> firmware in front: **OVMF / EDK II UEFI** boots the whole thing.
>
> **What it proves:** LinuxBoot *on genuine UEFI* — the user's literal framing.
> Real firmware (`BdsDxe`, EDK II) launches a single **Unified Kernel Image** off an
> EFI System Partition, exactly as it would launch any `\EFI\BOOT\BOOTX64.EFI`. That
> UKI *is* the EFISTUB Linux kernel + the u-root initramfs + the cmdline, fused into
> one PE/EFI file. u-root comes up as PID 1 and **`kexec`s** the second kernel.
> Firmware → one Linux blob → u-root → kexec → Linux. No GRUB, no `-kernel`.
>
> This validates **Tier B** in [PLAN.md](PLAN.md) end-to-end, fully in-harness. It
> does **not** cover the coreboot ROM (Tier A), which remains an author-run build.
>
> Every command below was run on **2026-06-29**; every output block is real,
> trimmed only for length and stripped of terminal ANSI escapes. It reuses the
> artifacts built in [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md) §2/§4 (`initramfs.cpio`,
> `initramfs-stage1.cpio`, `dokexec.sh`) — do that PoC first.

---

## 0. The idea, in one breath

Tier C let QEMU itself load the kernel (`-kernel vmlinuz`). That is a debugging
convenience, **not** how a machine boots. A real machine's firmware reads a boot
executable off a disk and jumps to it. On UEFI, that executable is a **PE/COFF EFI
application** living at `\EFI\BOOT\BOOTX64.EFI` on a FAT EFI System Partition.

So the Tier-B question is: *can a Linux kernel **be** that EFI application?* Yes —
two ingredients:

1. **EFISTUB** (`CONFIG_EFI_STUB`): a modern `vmlinuz` is *already* a valid PE/EFI
   binary. UEFI can launch it directly; no GRUB required.
2. **The UKI (Unified Kernel Image):** firmware launching a bare kernel has no way
   to pass a cmdline or an initramfs. The UKI solves this by gluing the kernel,
   the initramfs, the cmdline and an os-release onto **systemd's EFI stub** as
   extra PE sections (`.linux` / `.initrd` / `.cmdline` / `.osrel`). The stub is
   the EFI entry point; at runtime it finds those sections *in its own image*,
   publishes the initrd over the EFI **LoadFile2** protocol, and chain-loads the
   EFISTUB kernel with the embedded cmdline. **One file = a firmware-flashable
   Linux.** That single-blob shape is exactly LinuxBoot's "kernel-as-firmware".

```
QEMU q35  -drive pflash=OVMF_CODE  (genuine UEFI firmware)
   └─ EDK II / BdsDxe  reads the FAT ESP, launches \EFI\BOOT\BOOTX64.EFI
        └─ BOOTX64.EFI = a UKI = systemd-stub + .linux + .initrd + .cmdline
             └─ stub installs the initrd (LoadFile2), starts the EFISTUB kernel
                  └─ kernel #1 boots, PID 1 = u-root /init      ← "the bootloader"
                       └─ /init kexecs kernel #2 (+ its initramfs)
                            └─ kernel #2 boots fresh (new cmdline, clock → 0)
```

---

## 1. Environment & prerequisites

Host: **Ubuntu 24.04.4 LTS**, x86_64, QEMU/KVM — same box as the Tier C PoC. Two
*new* things beyond Tier C's `golang-go` + `kexec-tools`:

- **OVMF** — the UEFI firmware. Already on the host (`lab-vm.sh` uses it):
  `/usr/share/OVMF/OVMF_CODE_4M.fd` + `OVMF_VARS_4M.fd`.
- **The UKI toolchain** — `systemd`'s `ukify` + the `linuxx64.efi.stub`, plus
  `pefile` (ukify's Python dep). **None are installed, and we install none.**

That last point matters and is worth dwelling on: this PoC needs **no `sudo` at
all**. `ukify`/the stub ship in `systemd-ukify` + `systemd-boot-efi`, and `pip
install pefile` is refused by Ubuntu's PEP 668 ("externally-managed-environment").
Both walls fall to the same trick — **download the `.deb` and extract it in place**:

```bash
cd /media/sqs/COLD_STORAGE/linuxboot-spike      # the Tier C work dir
mkdir -p debs && cd debs
apt-get download systemd-boot-efi systemd-ukify python3-pefile
for d in *.deb; do dpkg-deb -x "$d" extracted/; done
cd ..
```

`apt-get download` fetches to the cwd (no root); `dpkg-deb -x` unpacks the file
tree without touching dpkg's database. We then point at the binaries directly and
hand ukify its `pefile` via `PYTHONPATH`.

**Checkpoint 1 — firmware + stub + ukify all reachable without installing:**

```
$ ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd
/usr/share/OVMF/OVMF_CODE_4M.fd  /usr/share/OVMF/OVMF_VARS_4M.fd
$ ls debs/extracted/usr/lib/systemd/boot/efi/linuxx64.efi.stub debs/extracted/usr/bin/ukify
.../linuxx64.efi.stub  .../ukify
$ PYTHONPATH=debs/extracted/usr/lib/python3/dist-packages \
    python3 -c 'import pefile; print("pefile", pefile.__version__)'
pefile 2023.2.7
```

We also confirm the kernel we'll boot really *is* an EFISTUB (PE/COFF) image — the
`MZ`…`PE\0\0` DOS/PE signature an EFI loader looks for:

```
$ xxd -l2 /home/sqs/netboot/vmlinuz ; xxd -s 0x40 -l4 /home/sqs/netboot/vmlinuz
00000000: 4d5a                                     MZ
00000040: 5045 0000                                PE..
```

`MZ` at offset 0, `PE\0\0` at the offset named in the DOS header → genuine PE32+.
UEFI will accept it as an application.

---

## 2. Build the UKI — one file the firmware can boot

`ukify` does the section-gluing (doing it by hand with `objcopy` is fiddly because
the stub has a high `ImageBase` and the section VMAs must clear it — ukify computes
that for you). Feed it the kernel, the initramfs, the cmdline, the stub:

```bash
PP=debs/extracted/usr/lib/python3/dist-packages          # vendored pefile
UKIFY=debs/extracted/usr/bin/ukify
STUB=debs/extracted/usr/lib/systemd/boot/efi/linuxx64.efi.stub

printf 'NAME="LinuxBoot"\nID=linuxboot\nPRETTY_NAME="LinuxBoot UKI (u-root)"\nVERSION="tierB"\n' > os-release.txt

# (a) plain u-root → boots to a u-root shell  (proves OVMF → EFISTUB → u-root)
PYTHONPATH="$PP" python3 "$UKIFY" build \
  --linux=/home/sqs/netboot/vmlinuz --initrd=initramfs.cpio \
  --cmdline="console=ttyS0 LINUXBOOT_TIER=B-uki-shell-test" \
  --os-release="@os-release.txt" --stub="$STUB" --output=uki-shell.efi

# (b) stage-1 u-root (embeds kernel + dokexec.sh) → kexecs stage 2
PYTHONPATH="$PP" python3 "$UKIFY" build \
  --linux=/home/sqs/netboot/vmlinuz --initrd=initramfs-stage1.cpio \
  --cmdline="console=ttyS0 LINUXBOOT_STAGE1=boot" \
  --os-release="@os-release.txt" --stub="$STUB" --output=uki-kexec.efi
```

(Both are wrapped in `build-uki.sh` in the work dir — including the
`apt-get download` bootstrap from §1.)

**Checkpoint 2 — the output is a PE32+ EFI app carrying our four sections** at
addresses *above* the stub's image (so they don't collide with stub code):

```
$ file uki-kexec.efi
uki-kexec.efi: PE32+ executable (EFI application) x86-64 ... for MS Windows
$ objdump -h uki-kexec.efi | grep -E '\.(osrel|cmdline|linux|initrd)'
  6 .osrel    00000053  000000014dfa5000  ...
  7 .cmdline  0000002d  000000014dfa6000  ...
  9 .initrd   02e10290  000000014dfa8000  ...
 10 .linux    00e788b0  ...
```

`.linux` is the EFISTUB kernel, `.initrd` is our u-root cpio, `.cmdline` is the
boot args — all inside one `BOOTX64.EFI`.

---

## 3. Stage the UKI on an EFI System Partition

Firmware boots from a **FAT** filesystem. We build a raw FAT image with `mtools`
(no loop-mount, no root) and drop the UKI at the **removable-media fallback path**
`\EFI\BOOT\BOOTX64.EFI` — the path OVMF auto-launches with zero interaction and no
NVRAM boot entry:

```bash
truncate -s 160M esp-kexec.img
mkfs.vfat -n LINUXBOOT esp-kexec.img
mmd  -i esp-kexec.img ::/EFI ::/EFI/BOOT
mcopy -i esp-kexec.img uki-kexec.efi ::/EFI/BOOT/BOOTX64.EFI
```

**Checkpoint 3 — the ESP holds exactly the auto-boot file:**

```
$ mdir -i esp-kexec.img ::/EFI/BOOT
 Directory for ::/EFI/BOOT
BOOTX64  EFI  63451136 ...
```

---

## 4. Boot it under genuine UEFI

No `-kernel`, no `-initrd` this time — only a firmware and a disk. The kernel is
*found and launched by the firmware*, the way a real machine boots. OVMF's vars
store must be **writable per run**, so copy it first:

```bash
cp /usr/share/OVMF/OVMF_VARS_4M.fd vars-kexec.fd
timeout 65 qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -m 3072 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,unit=1,file=vars-kexec.fd \
  -drive file=esp-kexec.img,format=raw,if=virtio \
  -display none -serial file:ovmf-kexec.log
```

(`timeout` because stage-2 u-root idles at a shell; **exit 124 is the expected
success path**. Wrapped as `run-uefi.sh` in the work dir.)

---

## 5. The proof

**Checkpoint 4 — real UEFI firmware launched our blob.** The `BdsDxe` line is the
EDK II Boot Device Selection phase; the `EFI stub` line is the systemd-stub
publishing our `.initrd` section over LoadFile2; the EDK II banner is the firmware
identifying itself (`ovmf-kexec.log`, ANSI stripped):

```
BdsDxe: starting Boot0001 "UEFI Non-Block Boot Device" from PciRoot(0x0)/Pci(0x3,0x0)
EFI stub: Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID device path
[    0.000000] efi: EFI v2.7 by Ubuntu distribution of EDK II
[    0.016921] Kernel command line: console=ttyS0 LINUXBOOT_STAGE1=boot
```

That fourth line is decisive: the kernel's command line is **the string we baked
into the UKI's `.cmdline` section** — delivered by the stub, not by QEMU.

**Checkpoint 5 — the matryoshka handoff, now downstream of UEFI.** Continuing the
same log, in order:

```
[    0.341431] Run /init as init process
2026/06/30 03:56:50 Welcome to u-root!                              ← u-root = the bootloader
=== LINUXBOOT_STAGE1: u-root init is now the bootloader; kexec-ing stage 2 ===
[    0.000000] Linux version 5.14.0-687.5.3.el9_8.x86_64 ...        ← kernel #2, clock reset!
[    0.014251] Kernel command line: console=ttyS0 LINUXBOOT_STAGE2=reached
[    0.318132] Run /init as init process
2026/06/30 03:56:51 Welcome to u-root!                              ← second kernel up
```

As in Tier C, the tell is `[    0.000000]` **resetting** right after the kexec
banner — a *fresh kernel* zeroing its own clock, with a *different* command line
(`STAGE2=reached`). Programmatic confirmation:

```
$ grep -c 'Welcome to u-root'   ovmf-kexec.log     # two u-root inits
2
$ grep    'Kernel command line' ovmf-kexec.log
[    0.016921] Kernel command line: console=ttyS0 LINUXBOOT_STAGE1=boot
[    0.014251] Kernel command line: console=ttyS0 LINUXBOOT_STAGE2=reached
$ grep -c 'EDK II' ovmf-kexec.log                  # both kernels see the same UEFI firmware
2
```

Firmware (EDK II) → one EFI blob → EFISTUB kernel → u-root → **kexec** → a second
kernel. The machine booted Linux off UEFI, and that Linux booted Linux.

> A simpler sanity run, `uki-shell.efi`/`esp.img`, drops straight to a u-root
> **shell** under OVMF (one banner, no kexec) — handy to confirm the firmware path
> in isolation before adding the handoff. Its log (`ovmf-shell.log`) shows the same
> `BdsDxe` / `EFI stub: Loaded initrd` / `Welcome to u-root!` sequence.

---

## 6. What this establishes (and what it doesn't)

| Claim | Status |
|---|---|
| A modern `vmlinuz` is a valid **EFISTUB / PE** EFI application | ✅ proven (§1) |
| Kernel + initramfs + cmdline fuse into one **UKI** with `ukify` | ✅ proven (§2) |
| **Genuine OVMF/UEFI (EDK II)** launches that UKI off an ESP — no GRUB, no `-kernel` | ✅ proven (§5) |
| The stub delivers our **`.cmdline`** and **`.initrd`** to the kernel | ✅ proven (LoadFile2 line + cmdline) |
| u-root boots as PID 1 *downstream of UEFI* and **`kexec`s** kernel #2 | ✅ proven — **Tier B** |
| Whole toolchain obtained **without `sudo`** (deb-extract, not install) | ✅ proven (§1) |
| **Tier A** (coreboot `qemu-q35` ROM with a LinuxBoot payload) | ⏳ author-run build, not yet |
| kexec into a **real installed OS** (u-root `localboot`) | ⏳ the lab's "finale" |

Three truths worth carrying into the lab build:

- **The UKI is the honest LinuxBoot artifact on UEFI.** A single PE file the
  firmware boots = "Linux *is* the firmware payload", which is the whole thesis.
  Tier C's `-kernel` was a stand-in for this; Tier B is the real thing.
- **No root needed, even for firmware tooling.** `apt-get download` +
  `dpkg-deb -x` + `PYTHONPATH`/direct-exec gets you `ukify`, the stub and `pefile`
  on a host where you can't (or won't) install them. Reusable trick.
- **`.cmdline` is baked, not typed.** Unlike GRUB, a UKI's command line is sealed
  inside the signed blob — you change it by rebuilding (or via a signed `.cmdline`
  addon). Good for tamper-resistance, a gotcha if you expect to edit it at boot.

---

## 7. Reproduce / clean up

Prereq: the Tier C artifacts (`initramfs.cpio`, `initramfs-stage1.cpio`,
`dokexec.sh`) from [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md). Then §1 → §5 is
≈2 minutes (no compilation — just deb-extract + ukify + a FAT image + one boot),
captured by `build-uki.sh` then `run-uefi.sh esp-kexec.img` in the work dir. New artifacts
(`debs/`, `uki-*.efi`, `esp*.img`, `vars-*.fd`, `ovmf-*.log`) live alongside the
Tier C ones in `/media/sqs/COLD_STORAGE/linuxboot-spike/`. To reclaim space:

```bash
rm -rf /media/sqs/COLD_STORAGE/linuxboot-spike
```

Next in [PLAN.md](PLAN.md): fold Tiers B + C into the actual lab
(`README`/`RUNBOOK`/`MANUAL_TESTING` + `build-uki.sh`/`run-uefi-linuxboot.sh`),
then author **Tier A** (coreboot ROM; the ~hour `crossgcc` build is author-run per
the repo's toolchain convention), and wire up the 00-INDEX row + `link_check`.
