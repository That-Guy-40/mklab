# OpenBIOS Lab Family — A Guided Demo

*A walkthrough of the firmware labs in this repo, written for someone who knows
networks and systems but hasn't lived inside boot firmware. Every command below
was run on the authoring machine on **2026-10-06**; the lines marked
**✅ verified here** are real output from that run, and the ones marked
**📖 run it yourself** are documented from each lab's own self-test (which you
run on your clone — see [Preflight](#0-preflight-getting-your-clone-ready)).*

> **All paths are relative to the repo root.** `cd` into your clone first:
> ```sh
> cd ~/mklab            # wherever you cloned it; the examples below assume $PWD is the repo root
> ```
> Whenever the tour jumps to another lab it gives the **full path from the repo
> root**, e.g. `examples/openbios-modern-filesystems/smoke-grub2fs.sh`.

> **Prefer to read rather than run?** There's a single-page, self-contained version
> of this tour at [`DEMO-OPENBIOS-TOUR.html`](DEMO-OPENBIOS-TOUR.html) — open it in
> any browser (no server needed). It's the "look at the breadth" companion to this
> runnable runbook.

---

## What this is, in one breath

Firmware is the code that runs *before* the operating system — it's what brings
the hardware up, finds something bootable, and hands off to the kernel. When
firmware is wrong, the machine doesn't boot, and you **can't SSH in to fix it**,
because there's no OS yet to SSH into. That's the 3 a.m. problem this project is
about.

Most firmware (UEFI, a PC BIOS) is a sealed binary blob. **Open Firmware** — the
IEEE-1275 standard Sun, Apple, and IBM shipped for twenty years — is different:
it boots to an interactive **Forth prompt** (`ok` or `0 >`), a tiny programming
language you can type at *while the machine is sitting there, pre-OS*. These labs
use that prompt as a workbench.

Two firmwares appear throughout:

- **OpenBIOS** — the open-source IEEE-1275 implementation **QEMU actually ships**
  for PowerPC and SPARC. The lab [`examples/openbios-the-rival-that-shipped/`](examples/openbios-the-rival-that-shipped/README.md)
  builds it, revives its broken x86 path, and makes it boot Linux.
- **Open Firmware (OFW)** — Mitch Bradley's *original*, the one that was on every
  SPARC box and PowerMac. Frozen in 2015; the labs boot it on QEMU in 2026.

On top of the firmware sits a **toolkit**: a set of Forth programs (under
`examples/openbios-the-rival-that-shipped/dsl/`) that *read and edit the binary
formats a boot chain is made of* — a Linux `bzImage`, a UKI, an `initrd`, a
device tree, an ELF, a coreboot ROM. Reading them is useful; **editing them in
place, from the firmware prompt, with no OS underneath, is the headline.**

### A 60-second glossary (skip if you know it)

| Term | What it means here |
|---|---|
| **`bzImage`** | A compiled, compressed Linux kernel — the file your bootloader loads. It carries a small "boot protocol" header (the *zero page* / `boot_params`) describing itself. |
| **`initrd` / `initramfs`** | A small root filesystem (a `cpio` archive) the kernel mounts first, before the real disk — it holds the scripts and drivers needed to get the real root mounted. |
| **UKI** (Unified Kernel Image) | One signed `.efi` file with the kernel, the initrd, *and* the kernel command line glued on as named sections. Modern distros boot this. |
| **kernel command line** | The string of options the kernel is handed at boot (`root=/dev/sda1 quiet …`). A wrong or missing option here is a classic "won't boot." |
| **Forth / the `ok` prompt** | The interactive language built into Open Firmware. You type words; it runs them immediately. The prompt is `ok` (OFW) or `0 >` (OpenBIOS — the number is the stack depth). |
| **device tree (FDT)** | A binary description of a machine's hardware (CPUs, memory, buses) that firmware hands the kernel. Ubiquitous in networking/embedded gear (switches, routers, SBCs). |
| **QEMU** | The machine emulator all of this runs inside — no physical hardware needed. |
| **OVMF** | Open-source UEFI firmware for QEMU — used where a lab needs a *real* UEFI boot (the UKI and TPM demos). |
| **TPM / PCR** | A security chip that records a tamper-evident hash of exactly what booted, into registers called PCRs. |
| **foreign oracle** | An *independent, third-party* tool used to check the firmware's answer (`dtc`, `objdump`, `cpio`, `readelf`, `tpm2_eventlog`). The firmware is never its own judge — see [§5](#5-why-you-can-trust-any-of-this). |

---

## 0. Preflight: getting your clone ready

Everything runs in QEMU as your normal user — **no root, no real hardware.** You
need the host tools and a couple of built artifacts.

**Host tools** (Debian/Ubuntu names): `qemu-system-x86_64 qemu-system-ppc
qemu-system-sparc dtc ukify objdump binutils cpio file genisoimage python3` and a
container engine (`podman` or `docker`, for the firmware build), plus for the
UEFI/TPM demos `ovmf swtpm tpm2-tools sbsigntool mtools`. `cbfstool` is **only**
needed for the coreboot/CBFS tracks and the grand finale (§4) — everything else
SKIPs it by name. Each lab's `deps.sh` installs its own set.

**Build the firmware once** (runs in a container; builds OpenBIOS *and* the `toke`
FCode tool from source — you don't install `toke` yourself):

```sh
examples/openbios-the-rival-that-shipped/build-openbios.sh all
# → ~/openbios-lab/openbios/obj-{x86,ppc,amd64}/...  (the firmware the smokes boot)
```

> *Dry-run checked 2026-10-06: a clean from-scratch `build-openbios.sh` on this
> host cloned its sources and built with no missing dependency and no error noise.
> The container image builds once (an `apt` step inside the container); later
> builds reuse it.*

**Get the Linux payloads** the rescue demo boots (a kernel, a u-root initramfs,
an EFI-stub kernel for the UEFI act):

```sh
examples/linuxboot-uefi-kexec/fetch-kernel.sh    # → ~/linuxboot-lab/vmlinuz (EFI-stub)
examples/linuxboot-uefi-kexec/build-uroot.sh     # → the u-root initramfs
```

Every script honors env-var overrides so you can point at your own files instead
— `KERNEL=`, `INITRD=`, `KERNEL_EFI=`, `OPENBIOS_WORKDIR=`, `COREBOOT_DIR=`,
`OVMF_CODE=`/`OVMF_VARS=`. And every script follows the house rule: **exit `0`
PASS, `1` FAIL, `77` SKIP**, and when a prerequisite is missing it SKIPs *by
name* ("SKIP: needs swtpm") rather than crashing — so a half-ready clone tells
you exactly what to install, it doesn't just explode.

---

## 1. The centerpiece — rescue a machine that won't boot, with no USB stick and no chroot

This is the demo to open with. A boot artifact is **deliberately broken** so the
machine hangs, then **repaired in place** using the toolkit — the kind of fix you
normally do by pulling the disk, booting a rescue USB, `chroot`-ing in, and
editing files. Here the *firmware itself* does the surgery, pre-OS.

```sh
examples/openbios-the-rival-that-shipped/showcase-rescue.sh all
```

It runs four independent acts, each on a **different** kind of boot artifact, and
**the negative control is the whole point**: each act first boots the *un-repaired*
artifact and shows it genuinely failing, so when the repaired one comes up you
know the edit is what rescued it — not an artifact that would have booted anyway.

| Act | Broken thing | The surgery | Proven by |
|---|---|---|---|
| **initrd** | boot with *no* initrd | supply the good initrd on the boot line | the machine boots to a u-root shell |
| **config** | a bad line in a config file *inside* the initramfs | firmware edits the file in place, same length, archive stays valid (`dsl/cpio-edit.fth`) | the fixed image boots to a rescue shell |
| **cmdline** | a UKI whose command line lacks the rescue flag | `uki-edit.sh` *grows* the `.cmdline` section to add it | the grown UKI boots to a shell **under real UEFI (OVMF)** |
| **bzImage** | a kernel's *runtime* command line in RAM | firmware follows the `bzImage`'s `cmd_line_ptr` and rewrites the line in place (`dsl/bootparams-edit.fth`) | an independent decoder confirms the new bytes |

**✅ verified here** — real output from the run:

```
- initrd BREAK failed as designed: Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
- initrd RESCUE reached the u-root shell
- config BREAK failed as designed: RESCUE-FAIL: /etc/rescue.conf MODE=die is not runnable -- boot is blocked; fix the config
- config: firmware patched etc/rescue.conf in place (2192896 bytes, valid cpio); host confirms MODE=run
- config RESCUE reached the rescue shell (RESCUE-OK)
- cmdline BREAK failed as designed: RESCUE-FAIL: kernel cmdline lacks rescue_ok=1 -- boot is blocked; add the param
- cmdline: .cmdline grown 13 -> 25 bytes, foreign objcopy confirms rescue_ok=1
- cmdline RESCUE reached the rescue shell (RESCUE-OK)      # booted under genuine OVMF
- bzimage RESCUE: dsl/bootparams-edit.fth rewrite cmd_line_ptr in place -> 'init=/bin/bash single'
- bzimage: a FOREIGN little-endian decoder confirms '...SENTINEL_CMDLINE_7=orig' -> 'init=/bin/bash single' in the bytes
PASS: Spike 11 (rescue capstone): the toolkit's THREE in-place editors, each turned on its native
      artifact type, each rescuing a broken boot with no USB stick and no chroot.
```

You can run any single act — `showcase-rescue.sh bzimage`, `… config`, etc. The
`cmdline` act needs OVMF; it SKIPs by name if OVMF isn't installed.

> **Why three different editors?** Because the three artifacts are structurally
> different. A `cpio` config edit must keep the archive's framing intact; a UKI
> `.cmdline` edit must update the PE section's declared size; a `bzImage` runtime
> edit must follow a pointer the bootloader planted in RAM. Same idea — *patch
> the bytes in place and prove it with an outside tool* — three real formats.

### Editing a config file inside a UKI (David's second ask), on its own

The UKI-specific version lives in the UKI lab:

```sh
examples/uki-workbench/smoke-uki-rescue.sh
```

It grows a UKI's `.cmdline` to add `rd.break` **and** reaches *inside* the UKI's
`.initrd` to flip a config value — then checks both edits with `objcopy`/`cpio`
(outside tools), and proves the safety rails bite: an edit that would run past
the section is refused *by name*, writing nothing.

---

## 2. The reader toolkit — understand any boot artifact, graded against an outside tool

Before you can safely edit a boot artifact you have to read it correctly. The
toolkit has a Forth reader for each format, and each is checked field-for-field
against the standard third-party tool — on **four** CPU architectures at once
(x86, x86-64, PowerPC, and the firmware-as-a-plain-process build), because byte
order is exactly the kind of thing that's right on one CPU and silently wrong on
another.

```sh
examples/openbios-the-rival-that-shipped/smoke-openbios.sh bootparams   # a bzImage's boot header
examples/openbios-the-rival-that-shipped/smoke-openbios.sh pe           # a UKI's section table
examples/openbios-the-rival-that-shipped/smoke-openbios.sh cpio         # an initrd's members
examples/openbios-the-rival-that-shipped/smoke-openbios.sh fdt          # the live device tree
```

**✅ verified here** (verdict excerpts):

- **bootparams** — *"an x86 boot-protocol reader … every numeric field equals
  python's explicit little-endian decode on every arch … refuses by name a
  zeroed boot_flag → `BAD-BOOTFLAG`, a buffer cut before the header →
  `TRUNCATED`."* (It reads the exact header a bootloader writes into a `bzImage`.)
- **pe** — *"section names, VirtualSizes and file offsets equal `objdump -h`'s,
  in order, on every arch … `pe-find .initrd` is read out of the UKI and
  `cpio.fth` walks its members."* (Reading a UKI's internal layout.)
- **cpio** — *"member names and sizes equal the host's own `cpio -itv`, in order,
  on every arch."* (Reading an initrd.)
- **fdt** — *"the firmware's LIVE device tree, flattened by `dsl/fdt.fth` and
  **accepted by `dtc`, the device-tree compiler itself**, on all four arches;
  `fdtdump`'s node and property counts equal the firmware's."*

The **fdt** one tends to land with network engineers: it's the same flattened
device tree that describes the hardware inside switches, routers, and SBCs — and
here the firmware *generates* it live and a real `dtc` signs off on it.

---

## 3. Breadth tour — what else the family does

Seven more labs, each self-contained, each with a headline you can run. Full
paths given so you can jump straight in.

### 🗄️ Read modern filesystems the frozen firmware can't — and fix a file on one

```sh
examples/openbios-modern-filesystems/smoke-grub2fs.sh
```

OpenBIOS reads disks through a **vendored GRUB 0.97**, which predates ext4 — so a
modern `mke2fs` image reads as `File not found`. This lab lifts **GRUB 2's**
filesystem drivers into the firmware as a new `/packages/grub2fs`, so it can read
ext4 / FAT / ISO-9660 made by current tools.

**✅ verified here:**
```
PASS: grub2fs … read /HELLO byte-for-byte equal to grub-fstest from THREE
      filesystems: a MODERN ext2 image that the shipped 0.97 grubfs cannot read
      (File not found), plus a FAT and an ISO 9660 image …
- CONTROL A: the stock grubfs firmware on the SAME modern image -> File not found
- CONTROL B: the stock grubfs firmware reads the CLASSIC image == its grub-fstest oracle
```
The payoff — [`examples/openbios-modern-filesystems/smoke-fs-edit-inplace.sh`](examples/openbios-modern-filesystems/smoke-fs-edit-inplace.sh)
— **breaks a config on a real ext4 root, repairs it in place at the firmware
prompt, runs `fsck` clean, and boots the fixed image.** Rescue with no OS, no USB,
no chroot — on a modern filesystem.  📖 *run it yourself*

### 🔬 Point GNU poke at a *running* firmware's RAM — and edit it live

```sh
examples/pacme-inspects-the-firmware/smoke-pacme-live-ram.sh     # see also: TOUR.md
```

**The showstopper.** `pacme` (GNU poke's structured-binary editor) is bridged to a
**running** OpenBIOS over QEMU's gdbstub: poke **reads and writes the live guest's
physical RAM while the firmware is executing**, and the firmware's own reader sees
poke's overwrite (a *live* view) where a snapshot taken a moment earlier still
shows the old value. It's a debugger's x-ray into firmware memory, with a
structure-aware editor on top. Start with
[`examples/pacme-inspects-the-firmware/TOUR.md`](examples/pacme-inspects-the-firmware/TOUR.md).  📖 *run it yourself*

### 🖥️ Run the firmware where it actually shipped — SPARC and PowerMac

```sh
examples/open-firmware-native-habitats/smoke-habitat.sh nvramrc ppc
examples/open-firmware-native-habitats/smoke-habitat.sh all sparc32
```

The same IEEE-1275 prompt Sun put on every SPARC box and Apple put on every
PowerMac (hold **Cmd-Opt-O-F** at the chime). Here NVRAM is a **real chip**, so
the lab writes a boot-forensics vocabulary *into NVRAM* that **self-installs at
power-on, before the firmware has probed a single device** — the hook that makes
`nvramrc` the oldest "configuration as code" there is.  📖 *run it yourself*

### 🩺 Firmware that diagnoses and repairs its own failed boot

```sh
examples/open-firmware-debugs-itself/showcase-diagnose-a-broken-boot.sh
```

Three Forth vocabularies loaded off a CD turn `Can't open boot device` into a
*specific per-entry diagnosis*, repair it live with a `devalias`, and confirm the
device now opens — and the firmware **decompiles itself** (`see`) to show you how
its own words are built. No OS, no JTAG, no external debugger.  📖 *run it yourself*

### 🐧 Boot Linux on 2015-frozen Open Firmware, fixing the gaps live

```sh
examples/open-firmware-forth-to-boot/showcase-forth-to-boot.sh
```

Mitch Bradley's original Open Firmware, booted on QEMU in 2026, made to boot a
modern Linux to a u-root shell by **hand-placing the initrd high in memory and
re-pointing the firmware's internal hooks at the live `ok` prompt** — each fix a
one-liner typed at the prompt, where on UEFI it would be a recompile-and-reflash.  📖 *run it yourself*

### ✍️ A text editor running as bare-metal firmware, no OS underneath

```sh
examples/openbios-clib-hello-to-emacs/smoke-client.sh x86 emacs
```

Open Firmware's *other* extension mechanism: **client programs** — freestanding
machine-code C binaries the firmware `load`s and jumps into, which call *back*
into the firmware for I/O. The ladder climbs from `hello` to a **MicroEMACS-style
multi-line screen editor** (buffer, keymap, mode line, a preloaded tutorial)
running on bare metal with no operating system beneath it.  📖 *run it yourself*

### 🔐 A measured boot into a real TPM — a secret that unlocks only if the boot is right

```sh
examples/uki-workbench/smoke-uki-attest-boot.sh     # needs OVMF + swtpm
examples/uki-workbench/smoke-uki-pcr-unlock.sh
```

A UKI boots under **genuine UEFI (OVMF) and a real software TPM 2.0 (swtpm)**; the
boot stub measures the UKI's sections into **PCR 11**; the guest reads that live
register, and an independent `tpm2_eventlog` replay lands on **exactly** that
value. Change one section and PCR 11 moves (the control bites). The unlock demo
then seals a secret to that PCR state: tamper with the boot and the TPM **refuses
to release the key** — "a key that exists only when the boot measures as
expected," which is the whole idea behind measured boot and remote attestation.  📖 *run it yourself*

---

## 4. If you want the "firmware does everything" grand finale

```sh
examples/openbios-the-rival-that-shipped/showcase-preboot-toolkit.sh   # 8 acts in ONE boot
examples/openbios-the-rival-that-shipped/showcase-rival-boots-linux.sh # boots Linux to u-root in one typed line
```

The first dissects the firmware's own coreboot tables, CBFS, and option ROMs,
authors and replays a TPM event log, and hands its live device tree off as a DTB
— **eight demonstrations in a single boot**. The second is the one-line Linux
boot the whole rival lab exists to make possible.

---

## 5. Why you can trust any of this

This is the part worth lingering on with an engineer, because it's the difference
between a demo and a result. The project's testing discipline is deliberately
paranoid:

- **Every claim is graded against a *foreign* oracle.** The firmware is never its
  own judge. A device tree is accepted by `dtc`; a UKI's sections match
  `objdump`; an initrd matches `cpio -itv`; a TPM measurement matches
  `tpm2_eventlog`. "The firmware printed the right answer" is never the test —
  "an independent tool agrees" is.
- **Every test carries a negative control that is *watched to bite*.** A checker
  that only ever passes is indistinguishable from one that checks nothing, so each
  test also breaks the thing under test and confirms the assertion *fails*. In the
  rescue demo, the un-repaired artifact is shown failing first — every single time.
- **UNKNOWN is a verdict, distinct from PASS.** A prerequisite that's missing
  SKIPs *by name* (exit 77). "I couldn't check this" never silently becomes "this
  is fine."
- **Assert the outcome, not the mechanism.** The symbol-poke demo doesn't check
  "the firmware found the symbol table" — it pokes a function and checks the
  running program *emits the poked value*.

> **A live example from building this very demo:** verifying the rescue showcase
> surfaced a real bug — the `bzImage` fixture capture did `os.replace()` from a
> `/tmp` scratch file to an on-disk workdir, which throws `EXDEV` when (as on most
> laptops) `/tmp` is a separate filesystem. The run **failed honestly** with the
> traceback instead of silently skipping the act. It's fixed now
> (`examples/openbios-the-rival-that-shipped/fixtures/cmdline-ptr/capture-bootparams.py`
> copies beside the destination then atomically renames), and the fix was watched
> working across the real device boundary before this sentence was written. That's
> the ethos in miniature: **run it, don't reason about it; and fix the thing that
> lies before the thing that merely breaks.**

---

## Quick reference — one command per lab

```sh
# THE RESCUE STORY (start here)
examples/openbios-the-rival-that-shipped/showcase-rescue.sh all

# READ ANY BOOT ARTIFACT (graded vs an outside tool, 4 architectures)
examples/openbios-the-rival-that-shipped/smoke-openbios.sh fdt     # or: bootparams | pe | cpio

# BREADTH
examples/openbios-modern-filesystems/smoke-grub2fs.sh              # read modern ext4/FAT/ISO
examples/pacme-inspects-the-firmware/smoke-pacme-live-ram.sh       # edit a running firmware's RAM
examples/open-firmware-native-habitats/smoke-habitat.sh all sparc32  # the firmware on real SPARC/PPC
examples/open-firmware-debugs-itself/showcase-diagnose-a-broken-boot.sh  # firmware fixes its own boot
examples/open-firmware-forth-to-boot/showcase-forth-to-boot.sh     # Linux on 2015 Open Firmware
examples/openbios-clib-hello-to-emacs/smoke-client.sh x86 emacs    # a text editor as bare-metal firmware
examples/uki-workbench/smoke-uki-attest-boot.sh                    # measured boot into a real TPM

# THE GRAND FINALE
examples/openbios-the-rival-that-shipped/showcase-preboot-toolkit.sh
```

Each lab's own `README.md` is the deep dive; this tour is the map.
