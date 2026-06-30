# WALKTHROUGH — Tier B, "this is how I did it" (with `ukify` & `pefile` explained)

A first-person, checkpoint-by-checkpoint account of running **Tier B end-to-end**
on this host on **2026-06-30** — genuine OVMF/UEFI firmware booting a **Unified
Kernel Image** that contains the kernel + u-root, whose `init` then **`kexec`s** a
second kernel. Where [`RUNBOOK.md`](RUNBOOK.md) is the clean by-hand walk and
[`POC-UEFI-MATRYOSHKA.md`](POC-UEFI-MATRYOSHKA.md) is the spike, this doc is the
narrated run **plus** a proper explanation of the two tools that do the magic —
**`ukify`** and **`pefile`** — because they're the least-obvious part of the whole
thing.

Every command and output below is from the real run into `~/linuxboot-lab`.

---

## The one-paragraph picture

A real machine's firmware doesn't take `-kernel`. It reads a **PE/EFI executable**
off a FAT disk and jumps to it. So to do LinuxBoot "for real" on UEFI, our kernel
has to *be* such an executable, and it has to drag its initramfs and command line
along with it — because the firmware won't supply them. The **Unified Kernel Image
(UKI)** is the packaging that makes that work: one `.efi` file containing the
kernel, the initramfs, and the cmdline. **`ukify`** builds that file; **`pefile`**
is the library `ukify` uses to edit the PE format without corrupting it. OVMF
(EDK II) then boots the file the same way it'd boot any `\EFI\BOOT\BOOTX64.EFI`.

```
OVMF/UEFI (EDK II)  ─►  \EFI\BOOT\BOOTX64.EFI (a UKI)  ─►  EFISTUB kernel + u-root
                                                              └─► u-root init ─► kexec ─► 2nd kernel
```

---

## Background you need: a kernel is a Windows-shaped executable

This trips everyone up, so it's worth saying plainly.

**PE/COFF** (Portable Executable / Common Object File Format) is *Microsoft's*
executable format — `.exe`/`.dll` on Windows. UEFI adopted PE as **its** executable
format too: every EFI application (the boot manager, GRUB's `grubx64.efi`, the
Windows bootloader, …) is a PE file. A PE file starts with the ancient `MZ` DOS
header, which points to a `PE\0\0` signature and the "optional header" describing
where to load the image (`ImageBase`), how big it is (`SizeOfImage`), how sections
are aligned (`SectionAlignment`), and a **section table** (`.text`, `.data`, …).

Linux's `CONFIG_EFI_STUB` makes the kernel *also* a valid PE file — a real bzImage
has both its Linux boot header **and** an `MZ…PE` veneer, so UEFI will happily
`LoadImage`/`StartImage` it as if it were any EFI app. You can see both hats on our
kernel:

```
$ xxd -l2 ~/linuxboot-lab/vmlinuz ; xxd -s 0x40 -l4 ~/linuxboot-lab/vmlinuz
00000000: 4d5a                                     MZ          ← DOS header (PE)
00000040: 5045 0000                                PE..        ← PE signature
$ file ~/linuxboot-lab/vmlinuz
... Linux kernel x86 boot executable bzImage, version 5.14.0-...  ← also a Linux kernel
```

That dual identity is what makes Tier B possible at all. Now — how do we attach the
initramfs and cmdline to it? Enter the UKI, `ukify`, and `pefile`.

---

## What is `pefile`?

**`pefile` is a pure-Python library for reading and *editing* PE files.** Package:
`python3-pefile` (Debian/Ubuntu) / `pip install pefile`. It parses every structure
of the PE format into Python objects — the DOS header, the NT/optional headers, the
section table, data directories, relocations, the lot — and, crucially, lets you
**add a section and write the file back out with all the headers fixed up**.

Why does that matter here? Because building a UKI means **grafting new sections**
(`.linux`, `.initrd`, …) onto an existing PE (the systemd stub), and a PE is
*unforgiving*: if you add a section you must also

- give it a **virtual address** that doesn't overlap any existing section and
  respects `SectionAlignment`, **and lands above the stub's `ImageBase`** (the
  systemd stub's base is a high `0x14df90000`, which is exactly what makes the
  naïve `objcopy` approach misbehave — it places sections "below image base");
- grow **`SizeOfImage`** to cover the new section;
- extend the **section table** and keep the file offsets consistent;
- recompute the PE **checksum**.

`pefile` knows all of those invariants, so the tool sitting on top of it
(`ukify`) can just say "add a `.initrd` section with these bytes" and trust the
arithmetic. We never call `pefile` directly — it's the **engine inside `ukify`**.
In this lab its only job is to exist on the `PYTHONPATH` when `ukify` runs:

```
$ PYTHONPATH=~/linuxboot-lab/debs/extracted/usr/lib/python3/dist-packages \
    python3 -c 'import pefile; print("pefile", pefile.__version__)'
pefile 2023.2.7
```

(That `PYTHONPATH` is the no-sudo trick — see the last section. With a system
install, plain `import pefile` works and the `PYTHONPATH` is unnecessary.)

---

## What is `ukify`?

**`ukify` is systemd's tool for assembling a Unified Kernel Image.** Package:
`systemd-ukify`. You hand it the ingredients; it emits **one** PE/EFI file:

```
ukify build \
  --linux=vmlinuz \           # → embedded as the .linux  PE section
  --initrd=initramfs.cpio \   # → embedded as the .initrd PE section
  --cmdline="console=ttyS0 …" \   # → .cmdline section
  --os-release=@os-release.txt \  # → .osrel  section
  --stub=linuxx64.efi.stub \  # the systemd EFI stub = the PE we graft onto
  --output=uki.efi
```

The output's structure is: take **systemd-stub** (a tiny EFI program,
`linuxx64.efi.stub`, ~68 KB) and append the ingredients as **named PE sections**.
The stub is the EFI entry point — when the firmware launches the UKI, the stub runs
*first*, finds those sections inside its own loaded image, publishes the initrd to
the kernel over the EFI **LoadFile2** protocol, sets the command line, and then
boots the EFISTUB kernel carried in `.linux`. So the kernel is launched *by code
that travelled inside the same file*. (`ukify` can also sign the result for Secure
Boot and add `.uname`/`.sbat`/`.pcrsig` sections; we skip signing — plain QEMU has
no Secure Boot.)

`ukify` uses `pefile` to do the grafting. **This is the part `ukify` exists to
spare you:** before `ukify`, the documented recipe was a hand-written
`objcopy --add-section .linux=… --change-section-vma .linux=0x2000000 …`, and you
had to pick non-overlapping VMAs yourself. Against the systemd stub's high
`ImageBase` that math is treacherous — get it wrong and you get a file that either
won't load or silently hangs. `ukify`+`pefile` compute correct VMAs every time. In
our run you can see `ukify` doing one bit of its bookkeeping — autodetecting the
kernel version to fill the `.uname` section:

```
$ ./build-uki.sh
Kernel version not specified, starting autodetection 😖.
Found uname version: 5.14.0-687.5.3.el9_8.x86_64
Wrote unsigned /home/sqs/linuxboot-lab/uki-kexec.efi
```

And the proof that the grafting worked — the four sections are present, each placed
just above the stub's image base (`0x14dfa5000` = stub `ImageBase` + its
`SizeOfImage`):

```
$ objdump -h ~/linuxboot-lab/uki-kexec.efi | grep -E '\.(osrel|cmdline|linux|initrd)'
  6 .osrel    00000053  000000014dfa5000 ...
  7 .cmdline  00000023  000000014dfa6000 ...
  9 .initrd   02df9754  000000014dfa8000 ...     ← the whole u-root initramfs, inside the .efi
 10 .linux    00e788b0  0000000150da2000 ...     ← the whole kernel, inside the .efi
```

One file. Everything the firmware needs to boot Linux is in it. That is the
"firmware is just software / the kernel **is** the payload" idea made concrete.

---

## The run, step by step

`WORKDIR` defaults to `~/linuxboot-lab`; artifacts stay out of the repo.

### Step 1 — `./deps.sh`  (the only step that touches `sudo`)

Two halves (see the script header): a `sudo apt` install of Go/kexec/qemu/OVMF/
mtools (all already current on this host → no-ops), and the **no-sudo** staging of
the UKI toolchain — `ukify`, the stub, and `pefile` — via `apt-get download` +
`dpkg-deb -x` into `~/linuxboot-lab/debs`.

> **Checkpoint:** the tail prints `go version`, the tool paths, both OVMF firmware
> files, `…/ukify` + `…/linuxx64.efi.stub`, and `pefile 2023.2.7` → `deps OK`.

### Step 2 — `./fetch-kernel.sh`  (a kernel that is a kexec-able EFISTUB)

```
$ ./fetch-kernel.sh
==> fetching AlmaLinux 9 pxeboot vmlinuz
100 14.4M  100 14.4M ... 40.1M
    DOS/PE signature: MZ=4d5a  PE=5045  (EFISTUB ✓)
```

We need `CONFIG_EFI_STUB` (so UEFI can launch it) **and** `CONFIG_KEXEC` (so u-root
can hand off to it). The AlmaLinux 9 installer kernel has both. The script's
checkpoint reconfirms the `MZ…PE` signature — the "it's also a PE" fact from above.

### Step 3 — `./build-uroot.sh`  (the init that is the bootloader)

```
$ ./build-uroot.sh
Cloning into '/home/sqs/linuxboot-lab/u-root'...      ← pinned tag v0.14.0
... Successfully built ".../initramfs.cpio"         (16 MiB)   ← plain u-root
... Successfully built ".../initramfs-stage1.cpio"  (46 MiB)   ← u-root + payload
    payload embedded in stage-1:
      bin/dokexec.sh          ← the boot policy
      boot/bzImage            ← the kernel to kexec into
      boot/initramfs2.cpio    ← the 2nd-stage rootfs
```

Two images: plain u-root (boots to a shell), and a **stage-1** image that bakes in
everything `init` will hand off to, plus our [`uroot/dokexec.sh`](uroot/dokexec.sh)
wired to run as init's first job (`-uinitcmd="gosh /bin/dokexec.sh"`). The one
gotcha lives here: build under **`GOTOOLCHAIN=local`** from the **u-root source
tree**, or Go silently grabs 1.25 and u-root dies with `package core is not in std`
(full story in [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md) §2).

### Step 4 — `./build-uki.sh`  (fuse into one EFI blob, stage it on an ESP)

This is the `ukify`/`pefile` step explained above. It builds `uki-kexec.efi`, then
writes it to a FAT image at the **removable-media fallback path**
`\EFI\BOOT\BOOTX64.EFI` (built rootless with `mkfs.vfat` + `mtools` — no
loop-mount). That path is the one OVMF auto-launches with **no** NVRAM boot entry
and zero interaction.

### Step 5 — `./run-uefi-linuxboot.sh kexec`  (genuine UEFI boots it)

Only a firmware (`OVMF_CODE` pflash) and a disk (the ESP) — **no `-kernel`**.

```
$ ./run-uefi-linuxboot.sh kexec
==> Tier B boot (kexec, 65s cap, accel=kvm) → .../tierB-kexec.log
qemu-system-x86_64: terminating on signal 15 ... (timeout)    ← expected (u-root idles)
    u-root banners: 2
```

(`timeout`-capped because u-root sits at a shell after the handoff; exit via the
cap is the success path.)

---

## The proof

The serial log, in order (ANSI stripped):

```
BdsDxe: starting Boot0001 "UEFI Non-Block Boot Device" ...            ← EDK II boot manager
EFI stub: Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID device path  ← the stub served our .initrd
[    0.000000] efi: EFI v2.7 by Ubuntu distribution of EDK II         ← genuine UEFI firmware
[    0.017] Kernel command line: console=ttyS0 LINUXBOOT_STAGE1=boot  ← from the UKI's .cmdline
... Run /init as init process ... Welcome to u-root!                  ← u-root = the bootloader
=== LINUXBOOT_STAGE1: u-root init is now the bootloader; kexec-ing stage 2 ===
[    0.000000] Linux version 5.14.0-... el9_8                         ← kernel #2 — clock RESET = kexec
[    0.014] Kernel command line: console=ttyS0 LINUXBOOT_STAGE2=reached
... Run /init as init process ... Welcome to u-root!                  ← second kernel up
```

```
$ grep -c 'EDK II' tierB-kexec.log ; grep -c 'Welcome to u-root' tierB-kexec.log
2
2
```

`BdsDxe`/`EDK II` = the firmware really ran. `EFI stub: Loaded initrd` = the UKI
served its own initramfs (that's the `.initrd` section, via LoadFile2). Two banners
+ two cmdlines (`STAGE1→STAGE2`) + the `[0.000000]` clock reset = the kexec handoff.
Firmware → one Linux blob → u-root → kexec → Linux, all on genuine UEFI.

---

## Appendix: getting `ukify`/`pefile` *without* installing them

The host had neither `ukify` nor the stub, and `pip install pefile` is refused by
Ubuntu's **PEP 668** ("externally-managed-environment"). The same trick clears both
walls — **download the `.deb`s and extract them in place**, no root:

```bash
apt-get download systemd-ukify systemd-boot-efi python3-pefile   # to cwd, no sudo
for d in *.deb; do dpkg-deb -x "$d" extracted/; done             # unpack, no dpkg DB
# then run ukify straight out of the tree, handing it pefile via PYTHONPATH:
PYTHONPATH=extracted/usr/lib/python3/dist-packages \
  extracted/usr/bin/ukify build --stub=extracted/usr/lib/systemd/boot/efi/linuxx64.efi.stub …
```

- **`systemd-ukify`** → the `ukify` tool.
- **`systemd-boot-efi`** → the `linuxx64.efi.stub` (the PE we graft onto).
- **`python3-pefile`** → `ukify`'s PE-editing engine.

`deps.sh` automates exactly this. Equally fine — and simpler if you don't mind
installing — is `sudo apt install systemd-ukify systemd-boot-efi python3-pefile`;
[`build-uki.sh`](build-uki.sh) accepts **either** (it prefers `$WORKDIR/debs`, then
falls back to the system-installed tools).
