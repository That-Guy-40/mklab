# PLAN — open-firmware-forth-to-boot: the firmware that answers back

> **Status: COMPLETE — all three spikes PASSED and the lab is assembled**
> (2026-07-21, agent-verified end-to-end). Outcomes, each a full write-up:
> [POC-1](POC-1-BUILD-BOX.md) — the 2015 tree builds in a Debian-13 container
> with one flag (`-std=gnu89`); [POC-2](POC-2-OK-PROMPT.md) — serial `ok`
> prompt driven deterministically, and (stretch, achieved) OFW boots Linux
> 6.3 + u-root after five era-fixes, three applied live at the prompt;
> [POC-3](POC-3-COREBOOT-PAYLOAD.md) — modern coreboot loads `ofwlb.elf`
> unmodified; that track also boots Linux to u-root. This file is preserved
> as the pre-spike roadmap; the risk register below reads as history.

## 1. Goal & the lesson

Boot **Open Firmware (OFW)** — Mitch Bradley's Firmworks implementation of IEEE
1275, the Forth-based firmware standard of Sun/PowerPC-Mac/OLPC fame — under
QEMU, meet the `ok` prompt, walk the live device tree, and then boot it again
*as a coreboot payload*.

The lesson is **not** a lineage ("OFW begat coreboot begat LinuxBoot") — it's
three rival answers to the same engineering question: *how does firmware stay
modular as boards and devices multiply?*

| Answer | Mechanism |
|---|---|
| **Open Firmware** (1988→) | a small Forth system: board support and drivers are words/packages in a **live, introspectable device tree**; drivers ship as ISA-independent **FCode bytecode** — even on the option card itself |
| **UEFI** (1998→) | PE executables + protocol GUIDs — the same modularity goal, a heavier and arguably less robust take |
| **LinuxBoot** (2017→) | give up on firmware-as-platform entirely: let **Linux** be the driver environment (see [`../linuxboot-uefi-kexec/`](../linuxboot-uefi-kexec/README.md)) |

Track 2 uses coreboot exactly as coreboot intends — bare hardware init that
hands off to a payload — to boot into a **pre-boot Forth environment** that can
(goal) itself boot an OS.

A naming trap the lab defuses on arrival: the wiki is `openfirmware.info`, but
**OFW ≠ OpenBIOS**. OpenBIOS is a separate reimplementation of the same standard
(it's what QEMU's ppc/sparc machines boot by default — which gives us a
zero-build `ok`-prompt teaser).

## 2. Source material (provenance: vendor byte-exact)

| Page | URL | Role |
|---|---|---|
| Open Firmware intro | <https://www.openfirmware.info/Open_Firmware.html> | context: IEEE 1275, implementations, capabilities |
| Building OFW for QEMU | <https://www.openfirmware.info/Building_OFW_for_QEMU.html> | Track 1: `cpu/x86/pc/emu/build` → `emuofw.rom`, `qemu -bios emuofw.rom -hda fat:.` |
| OFW as a coreboot Payload | <https://www.openfirmware.info/OFW_as_a_coreboot_Payload.html> | Track 2: `cpu/x86/pc/biosload` + `config-coreboot.fth` → `ofwlb.elf` payload |

All three retrieved 2026-07-20; to be vendored byte-exact in
`upstream-tutorial/` (HTML+CSS, provenance table, per-file sha256) at assembly —
the wiki is a decade-stale site and a prime rot candidate.

Known deviations from the sources (to be recorded as errata in the README):

- `svn://openfirmware.info/openfirmware` is **dead** → clone
  <https://github.com/openbios/openfirmware> (master, ~3.8k commits, OLPC
  lineage; MIT/BSD/GPL-mix licensing noted in provenance).
- QEMU 0.9.1-era invocation → modern `qemu-system-x86_64`/`-i386 -M pc`.
- The wiki boots OFW in framebuffer graphics mode; our harness is headless →
  the **serial-console config** build (a `config.fth` edit the wiki itself
  mentions) is our primary; graphics mode documented as the human path.
- coreboot v2/v3 → modern coreboot with `CONFIG_PAYLOAD_ELF=ofwlb.elf`;
  payload-era mismatch is Spike 3's explicit question; fallback = pin an older
  coreboot release in a separate checkout.
- Addition: the zero-build OpenBIOS teaser (`qemu-system-ppc` → `ok` prompt).

## 3. Phased spikes (out-of-tree; riskiest first)

State dir: `~/ofw-lab/` (mirrors `~/linuxboot-lab/`). Builds run in a container
(Debian base, prereqs as commented `RUN` lines — the hand-walk pattern). Each
spike ends with an honest agent-verified vs author-run statement.

- **Spike 1 — build box + `emuofw.rom`.** Does the tree build at all on a 2026
  toolchain? Containerfile + clone + `cpu/x86/pc/emu/build && make`. No prebuilt
  toolchain fetches expected → likely fully agent-verifiable. Fallback ladder
  for old-C-vs-gcc-14 breakage: older gcc package → older Debian base → patch
  (each an erratum). → `POC-QEMU-BUILD.md`.
- **Spike 2 — boot + drive the `ok` prompt.** `emuofw.rom` on modern QEMU,
  serial console; drive the REPL deterministically (banner → `3 4 + .` → `7`,
  `dev / ls`, `words`) with the house slow-send serial discipline, kill by PID.
  Extract the reusable driver as `tools/drive-serial-repl.py`. Stretch (not
  gating): `boot` a kernel from the `fat:.` disk.
- **Spike 3 — `ofwlb.elf` as a coreboot payload.** Build the `biosload` flavor
  (`cp config-coreboot.fth config.fth`); reuse the cached
  `~/linuxboot-lab/coreboot` tree + crossgcc **without clobbering the linuxboot
  artifacts** (`make DOTCONFIG=.config-ofw obj=build-ofw`). Boot: coreboot
  banner → OFW `ok` on serial → (goal) boot an OS from disk.
  → `POC-COREBOOT-PAYLOAD.md`.
- **Spike 0 (cheap, anytime) — the teaser.** `qemu-system-ppc` default firmware
  → OpenBIOS `ok` prompt, zero build. A RUNBOOK aside, not a gating spike.

## 4. Deliverables at assembly

One dir, multiple tracks (the `linuxboot-uefi-kexec` shape): build/run scripts
(`build-ofw.sh`, `run-ofw-qemu.sh`, `build-coreboot-ofw.sh`,
`run-coreboot-ofw.sh`), a `smoke-ofw.sh` single-verdict test
(`PASS: OFW answered 7 at the ok prompt`; EXIT-trap net; SKIP=77 when
ROM/QEMU absent), the build-box `Containerfile`, docs
(README / RUNBOOK / MANUAL_TESTING / POC-\*), and `upstream-tutorial/`.

Routing: 00-INDEX row (🖥️ Phase-2 section, before the linuxboot row);
`learning-paths.toml` step in `boot-and-crash` between `kdump-kexec-lab/` and
`linuxboot-uefi-kexec/` (checkpoint: "`3 4 + .` prints `7` at the `ok` prompt
over serial"); membership in `close-to-the-metal` + `provenance-vendored`;
both `tools/paths.py --check` and `tools/link_check.py` green.

## 5. Open risks

- 2008 C + Forth bootstrap vs gcc-14/multilib (Spike 1) — front-loaded.
- `ofwlb.elf` vs modern coreboot tables (Spike 3) — fallback: pinned older
  coreboot in `~/ofw-lab/`, never touching the linuxboot checkout.
- Serial-console config location differs between wiki pages
  (`cpu/x86/pc/emu/config.fth` vs `cpu/x86/emu/config.fth`) — resolve in-tree.
