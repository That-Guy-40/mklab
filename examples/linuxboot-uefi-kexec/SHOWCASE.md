# 🪆 SHOWCASE — *Boot Linux to Boot Linux*

> A guided, run-it-yourself tour of the **linuxboot-uefi-kexec** lab. Four stops,
> each one notch closer to the metal, ending with a real firmware booting a real OS.
> Everything below was verified on this host; the "👀 what you'll see" blocks are the
> actual serial output, trimmed. Grab a coffee — the last stop boots Debian *off a
> disk, out of a coreboot ROM*.

---

## The one-breath pitch

A normal PC boots **firmware → GRUB → Linux**. **LinuxBoot** rips out GRUB *and most
of the firmware's boot brain* and drops in **a whole Linux kernel** whose init —
**[u-root](https://github.com/u-root/u-root)**, a Go userland — *is the bootloader*.
It probes the machine, picks an OS, and **`kexec`s** into it. The punchline the
entire lab exists to land:

> ### 🔥 *Firmware is just software.*

You'll prove it four ways, from a 5-second sanity loop to a coreboot ROM that boots
the operating system on a disk.

---

## 🗺️ The map

```
                  ┌──────────────── one Linux kernel + u-root ───────────────┐
   FIRMWARE  ─►   │  kernel boots, PID 1 = u-root /init  ─►  policy  ─► kexec │ ─►  the next OS
                  └──────────────────────────────────────────────────────────┘
   Stop ①  Tier C — qemu -kernel        (no firmware)      the bare mechanic, fast
   Stop ②  Tier B — OVMF / UEFI         (a single UKI)     LinuxBoot on genuine UEFI
   Stop ③  Tier A — coreboot ROM        (qemu -bios)       the CANONICAL firmware swap
   Stop ④  THE FINALE — Tier A + a disk                    kexec the real installed OS
```

| Stop | Firmware in front | Time | Verified |
|---|---|---|---|
| ① Tier C | none (`-kernel`) | seconds | ✅ |
| ② Tier B | **OVMF / EDK II UEFI** | seconds | ✅ |
| ③ Tier A | **real coreboot ROM** | ~20 min build (once) | ✅ |
| ④ Finale | coreboot ROM **+ a disk** | seconds (after ③) | ✅ |

---

## 🎬 Curtain up — the one-time setup

```bash
cd examples/linuxboot-uefi-kexec
./deps.sh            # Go, kexec, qemu, OVMF, mtools (+ ukify/stub/pefile, no sudo)
./fetch-kernel.sh    # a world-readable EFISTUB + kexec vmlinuz (AlmaLinux 9)
./build-uroot.sh     # the u-root userland: plain + a stage-1 image that kexecs stage 2
```

Three scripts, and you're holding a Linux kernel and a Go "bootloader." Onward.

> 🧠 *Already a lesson:* `build-uroot.sh` quietly defuses the trap that cost the most
> time — `go install u-root@latest` silently grabs Go 1.25 and explodes
> (`package core is not in std`). The fix baked in: `GOTOOLCHAIN=local` + build from
> the u-root tree. (Full autopsy: [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md) §2.)

---

## ① Tier C — the bare mechanic ⚡

*Skip the firmware entirely; let QEMU hand the kernel straight to u-root, and watch
one Linux `kexec` a second into its place.*

```bash
./run-linuxboot.sh
```

👀 **what you'll see** — the matryoshka, in miniature:

```
2026/… Welcome to u-root!                              ← u-root is now the bootloader
=== LINUXBOOT_STAGE1: u-root init is now the bootloader; kexec-ing stage 2 ===
[    0.000000] Linux version 5.14.0-…                  ← a SECOND kernel — clock reset to zero!
[    0.005] Kernel command line: … LINUXBOOT_STAGE2=reached
2026/… Welcome to u-root!                              ← and it's up
```

**The tell:** that `[ 0.000000]` timestamp *resetting*. A fresh kernel started its
own clock — not a userspace trick. **Linux booted, and Linux booted Linux.** ✅

---

## ② Tier B — LinuxBoot on *genuine UEFI* 🧬

*Now delete QEMU's `-kernel` shortcut and put real UEFI firmware in front. The trick:
fold the kernel + u-root + command line into **one** EFI file — a **Unified Kernel
Image** — that the firmware boots like any `\EFI\BOOT\BOOTX64.EFI`.*

```bash
./build-uki.sh                  # ukify fuses kernel + initramfs + cmdline into one .efi
./run-uefi-linuxboot.sh kexec   # OVMF launches it off a FAT ESP — no GRUB, no -kernel
```

👀 **what you'll see** — *real* firmware, then the same handoff:

```
BdsDxe: starting Boot0001 "UEFI Non-Block Boot Device" …      ← EDK II boot manager
EFI stub: Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID …    ← the UKI served its OWN initramfs
[    0.000000] efi: EFI v2.7 by Ubuntu distribution of EDK II ← genuine UEFI firmware
… Welcome to u-root! … kexec-ing stage 2 … STAGE2=reached … Welcome to u-root!
```

One self-contained `.efi` file held the entire OS-to-be. That single-blob shape —
firmware boots *one Linux artifact* — **is** LinuxBoot's "the kernel is the firmware
payload." Want to know how the blob is welded together? The
[`WALKTHROUGH.md`](WALKTHROUGH.md) takes apart **`ukify`** and **`pefile`** screw by
screw. ✅

> 🧠 *Lesson trophy:* the whole UKI toolchain (`ukify`, the systemd stub, `pefile`)
> was obtained **without `sudo`** — `apt-get download` + `dpkg-deb -x`, sidestepping
> PEP 668. Reusable on any locked-down box.

---

## ③ Tier A — the *canonical* LinuxBoot: a real coreboot ROM 🏆

*This is the real thing. Not a kernel behind a firmware — a kernel **as** the
firmware. We build an actual **coreboot** ROM whose payload is Linux + u-root, and
boot it with `qemu -bios`.*

```bash
./build-coreboot.sh           # builds coreboot's own toolchain + the ROM (~20 min, NO sudo)
./run-coreboot-linuxboot.sh   # qemu -bios coreboot.rom
```

👀 **what you'll see** — coreboot's stages scroll by, then it *jumps into Linux*:

```
coreboot-e95bdb7e … x86_32 bootblock starting …      ← REAL coreboot firmware (not OVMF, not SeaBIOS)
   … romstage … ramstage …
Jumping to boot code at 0x00040000                   ← coreboot hands off to its CBFS payload
Linux version 6.3.0 (coreboot@reproducible) …        ← the kernel coreboot itself compiled
Welcome to u-root!                                   ← u-root, as the machine's firmware
```

Read that `coreboot-… bootblock starting` line again: **that is the firmware**, and
its entire job was to bring up the silicon and launch Linux. The 16 MB ROM you're
booting *contains* a kernel and a Go userland. Firmware. Is. Just. Software. ✅

> 🧠 *Lesson trophy:* coreboot's `crossgcc` builds **from source** (gcc + binutils,
> ~15 min) and every dep was already present → **no sudo at all**. And coreboot's own
> `u-root.mk` runs `go build`, so the build re-uses the `GOTOOLCHAIN=local` trick from
> setup. The traps compound; so do the fixes.

---

## ④ 🎆 THE GRAND FINALE — coreboot boots a *real OS off a disk*

*Everything so far kexec'd a kernel **we** packed. Now do what LinuxBoot does on a
production server: let u-root find the **installed operating system on a disk** and
boot it.*

```bash
./fetch-os-disk.sh            # a real GRUB-installed OS disk (Debian 12 genericcloud)
./run-coreboot-boot-disk.sh   # coreboot ROM + that disk; drives u-root's `boot`
```

👀 **what you'll see** — the full lifecycle, two distinct kernels and a real login:

```
coreboot-… bootblock starting …                                   ← ① firmware: coreboot
Linux version 6.3.0 (coreboot@reproducible) …                     ← ② coreboot's kernel + u-root
Welcome to u-root!                          ← (u-root's `boot` runs)
01. Debian GNU/Linux
02. Debian GNU/Linux, with Linux 6.1.0-49-cloud-amd64             ← ③ u-root PARSED the disk's GRUB menu
Linux version 6.1.0-49-cloud-amd64 (debian-kernel@lists.debian.org) … ← ④ the disk's OWN kernel, via KEXEC
Welcome to Debian GNU/Linux 12 (bookworm)!                        ← ⑤ real Debian systemd
Debian GNU/Linux 12 localhost ttyS0                               ← ⑥ a login prompt. 🎉
```

Sit with that. A **coreboot ROM** booted a **Linux kernel** whose **Go init** read a
**disk's GRUB config**, picked **Debian's own kernel**, and **`kexec`'d into a full
Debian system** — to a login prompt. Firmware → Linux → the installed OS. **That is
LinuxBoot doing its real job**, reproduced on your desk. ✅

> 🧠 *Two honest stage-notes (the lab tells the truth):* the minimal payload kernel
> needs disk/fs/partition drivers added so u-root can *see* the disk (handled in
> `build-coreboot.sh`); and `boot` is **typed** at the u-root shell (a real human at
> a LinuxBoot prompt) because coreboot's auto-`uinit` is gated to u-root *main* /
> Go ≥ 1.23. The script types it for you over the serial line.

---

## 🧰 The capabilities this lab adds to the repo

Beyond the boot magic, the lab leaves behind a kit of reusable, hard-won techniques:

- **Build a UKI by hand** (`ukify`/`pefile`, or raw `objcopy`) — single-file
  EFI-bootable Linux.
- **Grab gated toolchains without root** — `apt-get download` + `dpkg-deb -x` beats
  both "I won't install that" and PEP 668.
- **Build a coreboot ROM from scratch** — crossgcc-from-source + the LinuxBoot
  payload, fully scripted, author-run, no sudo.
- **Drive a fussy serial console** — wait for the *editor-ready* prompt (not just the
  banner), type slow (no flow control). ([`drive-boot.py`](drive-boot.py).)
- **The `GOTOOLCHAIN=local` u-root recipe**, the **EFISTUB = a PE executable** fact,
  and an honest map of where each tier's fidelity ends.

…and a paper trail to match: two spike PoCs
([Tier C](POC-MATRYOSHKA.md) · [Tier B](POC-UEFI-MATRYOSHKA.md)), a tool-deep
[walkthrough](WALKTHROUGH.md), a by-hand [RUNBOOK](RUNBOOK.md), real
[transcripts](MANUAL_TESTING.md), and the [design + decisions](PLAN.md).

---

## 🧭 Where to wander next

- **The "close to the metal" family** this caps: compile-a-kernel-in-RAM
  ([`tiny-linux-experiments/`](../tiny-linux-experiments/)), the `kexec` mechanic
  solo ([`kdump-kexec-lab/`](../kdump-kexec-lab/)), and the *normal* boot chain
  LinuxBoot replaces ([`root-password-reset/`](../root-password-reset/)).
- **Push the finale further:** `pxeboot` (the network twin of `localboot`), or a
  hands-off `uinit=boot` by building with u-root *main* on a newer Go.

> **Bravo — you booted Linux to boot Linux, four ways.** Now go tell someone that
> firmware is just software. 🪆
