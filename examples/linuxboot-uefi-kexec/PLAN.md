# PLAN — LinuxBoot lab: boot Linux to boot Linux, as close to the metal as possible

> Status: **DRAFT plan** (pre-spike). Authored 2026-06-29. The build feasibility is
> not yet proven — a spike (see §8) gates the breadth. Directory name
> `linuxboot-uefi-kexec/` is tentative.

## 1. Goal & the lesson

Operationalize **[LinuxBoot](https://www.linuxboot.org/)**: replace the firmware's
boot logic with **a Linux kernel + a tiny userland whose `init` *is* the
bootloader**, which then **`kexec`s into the target OS**. "Boot Linux to boot
Linux." The educational payoff is the punchline *firmware is just software* — and a
hands-on tour of the earliest, closest-to-the-metal moments of a Linux boot:
firmware → kernel → custom `init` → `kexec` handoff.

This is the **firmware-level capstone** to the repo's existing "close to the metal"
labs and should cross-link them:

- [`tiny-linux-experiments/`](../tiny-linux-experiments/) (micro-linux) — compile a
  kernel + tiny userspace, boot it in RAM. LinuxBoot = this, but *as firmware*.
- [`kdump-kexec-lab/`](../kdump-kexec-lab/) — the **`kexec`** mechanic in isolation.
  LinuxBoot = kexec used as the *bootloader*.
- The netboot family ([`debian-http-boot/`](../debian-http-boot/), the `chroot-netboot-*`
  tiers) — Linux-as-rootfs-in-RAM, the userland half of the story.

## 2. What LinuxBoot actually is (scoping it precisely)

LinuxBoot replaces the **DXE/BDS** phase of UEFI firmware (or is a **coreboot
payload**) with a Linux kernel whose initramfs is **[u-root](https://github.com/u-root/u-root)**
— a Go userland (busybox-like tools + Go bootloaders: `systemboot`, `localboot`,
`pxeboot`) whose `init` runs a boot *policy* and `kexec`s the chosen OS kernel.
Real deployments **flash this into the SPI ROM**; we reproduce it in QEMU.

Two host firmwares exist, and they pull differently on the user's "using UEFI" ask:

- **coreboot + LinuxBoot payload** — the canonical demo (`coreboot.rom` →
  `qemu -bios`). Not UEFI; it's coreboot. Truest "firmware replacement".
- **UEFI/edk2 + Linux payload** — LinuxBoot literally replacing edk2 DXE
  (`UefiPayloadPkg` / the edk2 LinuxBoot build). Honors "UEFI"; heaviest to build.

## 3. Fidelity tiers (the central design decision — proposed split)

Mirror the repo's proven pattern (micro-linux's tiers; the FreeBSD lab's
verified-core + author-run-finish): a **faithful primary** + a **fully-verifiable
companion**, with an honest build-vs-boot split.

| Tier | What | Fidelity | Build cost | Verifiable here? |
|---|---|---|---|---|
| **A (primary)** | **coreboot `qemu-q35` ROM** embedding a Linux kernel + **u-root** initramfs; `qemu -bios coreboot.rom`; u-root `init` boots (kexec finale optional) | The canonical LinuxBoot — real firmware replacement | High: coreboot crossgcc (from source) + Go/u-root | **✅ verified end-to-end in QEMU** — build author-run (~20 min, no sudo); `MANUAL_TESTING.md` |
| **B (companion)** | **OVMF/UEFI** boots an **EFISTUB Linux** "boot kernel" + u-root initramfs (fused into a **UKI**) → `kexec` the target | LinuxBoot *in spirit, on genuine UEFI* (the user's literal framing) | Moderate (no firmware rebuild; reuse lab-vm.sh OVMF) | **✅ verified end-to-end** ([POC-UEFI-MATRYOSHKA](POC-UEFI-MATRYOSHKA.md)) |
| **C (optional fast loop)** | `qemu -kernel/-initrd` a small kernel + custom `init` that `kexec`s a 2nd kernel | The *mechanic* only; not firmware/UEFI | Low | Fully verifiable; a quick inner-loop sanity tier |

**Userland: u-root** (Go) over a hand-rolled BusyBox/C `init` — u-root *is*
LinuxBoot's userland and ships `kexec`/`boot`/`localboot` built in. (A hand-rolled
init is the micro-linux story; using it here would be inauthentic.) We may *also*
show a tiny hand-rolled `init` in Tier C as a teaching contrast.

**What it kexecs into ("kexec further"):** start by kexec-ing a **second kernel**
(simplest, fully verifiable: prove the handoff + `/proc/cmdline` of the new
kernel), then graduate to **kexec-ing a real installed OS** by reusing one of the
repo's existing disks (Debian/AlmaLinux from the VM/PXE labs) — u-root `localboot`
finds the disk's kernel and boots it.

## 4. Prerequisites / tooling (Ubuntu 24.04, verified against apt)

A `deps.sh` in the lab will install these; the heavy `crossgcc` build is author-run.

- **Go** (u-root): `apt install golang-go` → 1.22 (≥1.21 ✓), or `snap install go --classic` (1.26).
- **kexec**: `apt install kexec-tools` (host-side; u-root carries its own Go kexec).
- **coreboot crossgcc + cbfstool** (Tier A): build deps `build-essential git gnat
  flex bison libncurses-dev libelf-dev zlib1g-dev libssl-dev acpica-tools m4 curl
  pkg-config nasm uuid-dev python3 device-tree-compiler`, then
  `git clone https://github.com/coreboot/coreboot && make crossgcc-i386 CPUS=$(nproc)`
  (~30–60 min, from source — *not* a blocked prebuilt-toolchain fetch) and
  `make -C util/cbfstool`. coreboot **requires `gnat`** (Ada) on the host.
- **OVMF** (Tier B): already used by `lab-vm.sh` (`ovmf` package).

## 5. Architecture (Tier A, the load-bearing one)

```
QEMU q35  --bios coreboot.rom
   └─ coreboot (SEC/PEI-ish: minimal hw init)
        └─ CBFS payload = LinuxBoot:  bzImage (Linux)  +  u-root initramfs
             └─ Linux boots, PID 1 = u-root /init  (the "bootloader")
                  └─ probe devices; pick a target; kexec
                       └─ target kernel boots  (2nd kernel, or a disk's OS)
```

- coreboot config (`make menuconfig` / a saved `defconfig`): mainboard =
  *Emulation → QEMU x86 q35*; payload = *LinuxBoot*; supply our `bzImage` +
  `u-root.cpio`. Output: `build/coreboot.rom`.
- u-root initramfs: `u-root -build=bb -o u-root.cpio core boot` (+ a custom
  `/init` or a `uinit` that runs our boot policy and `kexec`).
- Serial console (`-nographic`/`-serial`) for verification, like the other VM labs.

Tier B reuses `lab-vm.sh`'s OVMF path: an EFISTUB kernel as the EFI boot file +
u-root initramfs; same u-root `init` → kexec.

## 6. Deliverables (file shape, per repo conventions)

```
examples/linuxboot-uefi-kexec/
├── PLAN.md                      # this file
├── README.md                    # concept, the boot chain, tier table, quick start
├── RUNBOOK.md                   # by-hand walk: build u-root, build coreboot, boot, kexec
├── MANUAL_TESTING.md            # real captured serial transcripts (verified vs author-run)
├── deps.sh                      # install Go/kexec/coreboot build-deps (Ubuntu 24.04)
├── build-uroot.sh               # build the u-root initramfs (+ our /init boot policy)
├── build-coreboot.sh            # configure + build coreboot.rom with the LinuxBoot payload (author-run)
├── run-linuxboot.sh             # Tier A: qemu -bios coreboot.rom  (serial)
├── run-uefi-linuxboot.sh        # Tier B: OVMF + EFISTUB kernel + u-root  (verifiable)
├── uroot/                       # our custom uinit / boot-policy Go (or shell) + kexec target
├── coreboot-defconfig           # pinned coreboot config (qemu-q35 + LinuxBoot payload)
└── upstream-tutorial/           # cite linuxboot.org (don't mirror); vendor a specific build page IF we follow one
```

## 7. Verification plan (honest split)

- **Machine-verified here:** u-root initramfs builds; Tier B OVMF→EFISTUB→u-root→
  kexec boots end-to-end (capture serial: u-root shell, then the kexec'd kernel's
  `/proc/version` + `/proc/cmdline`); Tier C `-kernel/-initrd` kexec sanity.
- **Author-run (toolchain gate):** the coreboot crossgcc build + `coreboot.rom`
  assembly. I **author** `build-coreboot.sh` + the pinned defconfig; the user runs
  the ~hour build; then `run-linuxboot.sh` boots the ROM and **that boot is
  verified** (serial transcript). Same shape as the from-source / FreeBSD labs.
- `tools/link_check.py` green; 00-INDEX row in the Phase-2 QEMU table.

## 8. Implementation sequencing (spike-first — gates the breadth)

0. **SPIKE — ✅ DONE for Tier C** (written up as [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md)):
   install Go; `u-root -build=bb`; boot the
   resulting initramfs with a stock kernel under QEMU to a **u-root shell**; then
   prove **kexec** from u-root into a 2nd kernel (Tier C, fast). If Go/u-root/kexec
   work here, Tiers B/A are unlocked. THEN attempt a coreboot `qemu-q35` +
   LinuxBoot ROM build (the big unknown) — or hand it to the user if the build is
   too long/blocked, and verify the boot of whatever ROM results.
1. **Tier B (OVMF) — ✅ DONE** (written up as [`POC-UEFI-MATRYOSHKA.md`](POC-UEFI-MATRYOSHKA.md)):
   genuine OVMF/EDK II UEFI boots a **UKI** (systemd-stub + EFISTUB kernel +
   u-root initramfs + cmdline) off an ESP at `\EFI\BOOT\BOOTX64.EFI` → u-root
   PID 1 → **kexec** into a 2nd kernel. Verified end-to-end (EDK II banner,
   `EFI stub: Loaded initrd`, two u-root banners, `STAGE1→STAGE2` cmdlines, clock
   reset). UKI toolchain (`ukify`/stub/`pefile`) obtained **without `sudo`** via
   `apt-get download` + `dpkg-deb -x`.
2. **Tier A — ✅ DONE**: `build-coreboot.sh` + `coreboot-qemu-q35-linuxboot.config`
   build a real coreboot q35 ROM whose CBFS payload is linux-6.3 + u-root v0.14.0;
   `run-coreboot-linuxboot.sh` boots it. **Verified end-to-end** (coreboot bootblock
   /romstage/ramstage → Jumping to boot code → Linux 6.3 → u-root banner). Build is
   author-run (~20 min) but needs **no sudo** — all coreboot deps were present.
   **Finale ✅ verified**: with disk/fs/partition drivers added to the payload
   kernel, u-root's `boot` parses a real Debian 12 disk's GRUB config and **kexecs
   the installed OS** to a login prompt (coreboot → Linux 6.3 + u-root → kexec →
   Debian 6.1) — the production LinuxBoot lifecycle. `run-coreboot-boot-disk.sh` +
   `drive-boot.py`. (`boot` is *typed* at the u-root shell; the auto-uinit is gated
   to u-root main / Go ≥ 1.23.)
3. Docs (README/RUNBOOK/MANUAL_TESTING/WALKTHROUGH), 00-INDEX, link_check, memory,
   vendoring. ✅

## 9. Upstream / vendoring

- **linuxboot.org** + the u-root and coreboot docs are official multi-page
  doc-sites → **cite with a retrieved-date, don't mirror** (per CLAUDE.md).
- If the lab follows **one specific build tutorial** (e.g. a particular u-root or
  coreboot-LinuxBoot QEMU how-to page), **vendor that page byte-exact** under
  `upstream-tutorial/` with provenance + sha256, like the other labs.

## 10. Risks & open questions

- **Coreboot build time/space** (~hour, from source) — the main cost; mitigated by
  author-run + caching the crossgcc.
- **coreboot ≠ UEFI** — Tier A is coreboot; Tier B is the genuine-UEFI answer to
  "using UEFI". Doing both resolves the tension. *(Decision: do both.)*
- **u-root Go version drift** — noble's Go 1.22 should satisfy current u-root;
  pin/note the u-root commit.
- **kexec under coreboot/qemu** — verify the payload kernel has `CONFIG_KEXEC`; the
  stock Ubuntu/Debian kernels do.
- **Open Q1:** kexec target — 2nd kernel only, or also boot a real installed OS
  disk via u-root `localboot`? *(Proposed: both — 2nd kernel for the verified core,
  a disk OS as the "kexec further" finale, possibly author-run.)*
- **Open Q2:** also document the **edk2 LinuxBoot (DXE-replacement)** path as prose,
  or leave it as a "further reading" pointer? *(Proposed: pointer only.)*

## 11. Decisions (proposed, to confirm)

- Primary = **Tier A (coreboot+u-root)**, companion = **Tier B (OVMF/UEFI)**,
  optional **Tier C** fast loop. ✅ proposed
- Userland = **u-root**. ✅ proposed
- Build author-run, **boot verified**. ✅ proposed (matches repo convention)
- Name: `linuxboot-uefi-kexec/` (tentative — alt: `linuxboot-coreboot-uroot`).
