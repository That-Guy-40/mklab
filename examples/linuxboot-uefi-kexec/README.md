# linuxboot-uefi-kexec — boot Linux to boot Linux, as close to the metal as possible

Operationalize **[LinuxBoot](https://www.linuxboot.org/)**: replace the firmware's
boot logic with **a Linux kernel whose `init` *is* the bootloader**, which then
**`kexec`s into the target OS**. "Boot Linux to boot Linux." The payoff is the
punchline *firmware is just software* — and a hands-on tour of the earliest,
closest-to-the-metal moments of a boot: **firmware → kernel → custom `init` →
`kexec` handoff**.

The custom `init` is **[u-root](https://github.com/u-root/u-root)** — a Go userland
(busybox-like tools + Go bootloaders) whose `init` runs a *boot policy* and `kexec`s
the chosen kernel. That's literally what LinuxBoot flashes into a server's SPI ROM;
here we reproduce it in QEMU, two ways.

**Verified end-to-end on this host (Ubuntu 24.04 + QEMU/KVM).** The feasibility
spikes behind it are written up blow-by-blow with real serial logs in
[`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md) (Tier C) and
[`POC-UEFI-MATRYOSHKA.md`](POC-UEFI-MATRYOSHKA.md) (Tier B); [`MANUAL_TESTING.md`](MANUAL_TESTING.md)
has the transcripts from the lab scripts themselves.

## LinuxBoot in three sentences

A normal boot is *firmware → bootloader (GRUB) → kernel*. LinuxBoot deletes the
bootloader and most of the firmware's boot phase, and puts a **whole Linux kernel**
there instead — its initramfs `init` (u-root) probes the machine, decides what to
boot, and **`kexec`s** the real OS kernel into its place. So the thing that picks
and launches your OS is *itself Linux*, with all of Linux's drivers, networking and
scripting available at "firmware" time.

## The boot chain (what each tier proves)

```
                 ┌─────────────────────── the LinuxBoot kernel + u-root ──────────────────────┐
   firmware  ─►  │  Linux boots, PID 1 = u-root /init   ─►  boot policy  ─►  kexec  │  ─►  target kernel
                 └────────────────────────────────────────────────────────────────┘
   Tier A: coreboot ROM (qemu -bios)         the canonical LinuxBoot — real firmware  ✅ verified here
   Tier B: OVMF / UEFI  ───────────────►     a UKI the firmware launches      ✅ verified here
   Tier C: qemu -kernel (no firmware) ──►     the bare mechanic, fast loop     ✅ verified here
```

| Tier | Front-end | What it demonstrates | Status |
|---|---|---|---|
| **C** | `qemu -kernel/-initrd` (no firmware) | the bare **u-root → kexec** handoff; fastest inner loop | ✅ **verified** ([PoC](POC-MATRYOSHKA.md)) |
| **B** | **OVMF / UEFI (EDK II)** boots a **UKI** off an ESP | LinuxBoot *on genuine UEFI* — a single firmware-flashable EFI blob | ✅ **verified** ([PoC](POC-UEFI-MATRYOSHKA.md)) |
| **A** | **coreboot** `qemu-q35` ROM (`qemu -bios coreboot.rom`) | the **canonical** LinuxBoot — Linux+u-root *as the firmware payload*, real firmware replacement | ✅ **verified** (build author-run; see [PLAN.md](PLAN.md)) |

Tiers B and C are **the same u-root + kexec core**; they differ only in *how the
first kernel gets loaded*. Tier C lets QEMU cheat and load it directly (great for
iterating). Tier B makes a real UEFI firmware **find and launch** it — packaged as
a **Unified Kernel Image (UKI)**: one PE/EFI file = systemd's EFI stub + the kernel
+ the u-root initramfs + the kernel command line, dropped at the removable-media
boot path `\EFI\BOOT\BOOTX64.EFI`. That single-blob shape is exactly LinuxBoot's
"the kernel *is* the firmware payload".

> **Why a VM, not a container.** This is firmware and `kexec` — a container shares
> the host kernel and has no firmware, no `kexec`, no boot. It is inherently a
> Phase-2 (QEMU) lab.

## Quick start

```bash
cd examples/linuxboot-uefi-kexec
./deps.sh            # Go, kexec, qemu, OVMF, mtools  (+ ukify/stub/pefile, no sudo)
./fetch-kernel.sh    # a world-readable EFISTUB+kexec vmlinuz (AlmaLinux 9 pxeboot)
./build-uroot.sh     # the u-root userland: plain + a stage-1 image that kexecs stage 2

# Tier C — the bare mechanic (QEMU loads the kernel directly):
./run-linuxboot.sh                 # → 2 u-root banners, STAGE1→STAGE2 cmdlines

# Tier B — genuine UEFI boots the same thing as one EFI blob:
./build-uki.sh                     # fuse kernel+initramfs+cmdline into a UKI on an ESP
./run-uefi-linuxboot.sh kexec      # OVMF launches \EFI\BOOT\BOOTX64.EFI → u-root → kexec
./run-uefi-linuxboot.sh shell      # (or: just drop to a u-root shell under OVMF)

# Tier A — the canonical LinuxBoot: a real coreboot ROM (author-run build):
./build-coreboot.sh                # coreboot toolchain + ROM w/ Linux+u-root payload (~20 min)
./run-coreboot-linuxboot.sh        # qemu -bios coreboot.rom → coreboot → Linux → u-root
```

Each script ends by printing its own checkpoints. Artifacts (u-root clone,
initramfs, UKIs, ESPs, logs) land in `$WORKDIR` (default `~/linuxboot-lab`), **not**
in the repo — they're large and rebuildable. Override anything via env:
`WORKDIR=…  KERNEL=/path/to/vmlinuz  ./build-uroot.sh`.

The success signature (both tiers): **two** `Welcome to u-root!` banners and two
different kernel command lines — `LINUXBOOT_STAGE1=boot` then
`LINUXBOOT_STAGE2=reached` — with the `[    0.000000]` clock **resetting** between
them. That reset is a *fresh kernel* starting its own clock: the kexec handoff,
not a userspace trick. The machine booted Linux, and that Linux booted Linux.

## Files

| File | Role |
|---|---|
| [`deps.sh`](deps.sh) | install Go/kexec/qemu/OVMF/mtools; deb-extract the UKI toolchain (no sudo) |
| [`fetch-kernel.sh`](fetch-kernel.sh) | fetch a readable EFISTUB+`CONFIG_KEXEC` `vmlinuz` (`KERNEL=` to override) |
| [`build-uroot.sh`](build-uroot.sh) | build the u-root initramfs (plain + the stage-1 kexec image) |
| [`uroot/dokexec.sh`](uroot/dokexec.sh) | the **boot policy** — the script that makes u-root a *bootloader* |
| [`run-linuxboot.sh`](run-linuxboot.sh) | **Tier C** boot: `qemu -kernel` + u-root + kexec |
| [`build-uki.sh`](build-uki.sh) | **Tier B**: fuse into a UKI + stage it on a FAT ESP |
| [`run-uefi-linuxboot.sh`](run-uefi-linuxboot.sh) | **Tier B** boot: OVMF/UEFI launches the UKI |
| [`build-coreboot.sh`](build-coreboot.sh) | **Tier A**: build a coreboot ROM with a LinuxBoot payload (author-run; no sudo) |
| [`coreboot-qemu-q35-linuxboot.config`](coreboot-qemu-q35-linuxboot.config) | pinned coreboot config — q35 board + LinuxBoot payload |
| [`run-coreboot-linuxboot.sh`](run-coreboot-linuxboot.sh) | **Tier A** boot: `qemu -bios coreboot.rom` |
| [`RUNBOOK.md`](RUNBOOK.md) | by-hand walk of both tiers, with the *why* at each step |
| [`WALKTHROUGH.md`](WALKTHROUGH.md) | first-person Tier B run + deep-dives on **`ukify`** and **`pefile`** (what they are, how the UKI is grafted) |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | real captured serial transcripts |
| [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md) / [`POC-UEFI-MATRYOSHKA.md`](POC-UEFI-MATRYOSHKA.md) | the Tier C / Tier B feasibility spikes |
| [`PLAN.md`](PLAN.md) | the full design + the Tier A (coreboot) plan |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | provenance: who to cite (linuxboot.org, u-root, the UKI spec) |

## Sibling labs (the "close to the metal" family)

- [`tiny-linux-experiments/`](../tiny-linux-experiments/) — compile a kernel + tiny
  userspace and boot it in RAM. LinuxBoot is this, *as firmware*.
- [`kdump-kexec-lab/`](../kdump-kexec-lab/) — the **`kexec`** mechanic in isolation
  (a capture kernel for crash dumps). Here `kexec` is the *bootloader* instead.
- [`root-password-reset/`](../root-password-reset/) — interrupting GRUB on a serial
  console; the *normal* boot chain LinuxBoot replaces.

## Going further

All three tiers are verified. The Tiers B/C core kexecs a **second kernel**
(deterministic, unmistakable in the log); Tier A's coreboot ROM boots **coreboot →
Linux → u-root** and drops to a u-root shell (the kernel has `CONFIG_KEXEC`, so the
kexec finale applies there too — see [`RUNBOOK.md`](RUNBOOK.md) "Going further").
The natural next step is to point the boot policy at a **real installed OS** with
u-root's `localboot` (find a disk's kernel and boot it) or `pxeboot` (netboot) —
the actual LinuxBoot boot policies — reusing one of the repo's installed disks.
