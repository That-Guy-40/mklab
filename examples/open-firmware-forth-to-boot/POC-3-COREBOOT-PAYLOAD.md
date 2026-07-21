# POC 3 — OFW as a coreboot payload: the full matryoshka

> **Status: PASSED** (2026-07-21, agent-verified end-to-end, host QEMU 8.2.2 +
> KVM). Final chain: **modern coreboot (2026 master) → `ofwlb.elf` (2015 Open
> Firmware payload) → `ok` prompt → Linux 6.3.0 → `Welcome to u-root!`** — with
> three live fixes performed at the firmware's own prompt. Prereqs:
> [POC-1-BUILD-BOX.md](POC-1-BUILD-BOX.md), [POC-2-OK-PROMPT.md](POC-2-OK-PROMPT.md).
> The linuxboot lab's coreboot artifacts were untouched throughout
> (sha256-guarded before/after: `.config: OK`, `build/coreboot.rom: OK`).

## The question this spike answers

The wiki ([OFW as a coreboot Payload](https://www.openfirmware.info/OFW_as_a_coreboot_Payload.html))
targets coreboot **v2/v3** (~2008). Can `ofwlb.elf` ride a 2026 coreboot master?
Era-mismatch in the coreboot tables was the named risk. **Thinking:** the repo
already owns a coreboot tree with crossgcc built (`~/linuxboot-lab/coreboot`,
hours of toolchain time banked by the linuxboot lab) — so the spike costs
minutes *if* we can build in it without disturbing the linuxboot artifacts.
coreboot's `DOTCONFIG=` + `obj=` make that possible.

## Step 1 — build the payload

The wiki's recipe, svn swapped for the git clone from POC 1:

```console
$ cd ~/ofw-lab/openfirmware/cpu/x86/pc/biosload
$ cp config-coreboot.fth config.fth
$ podman run ... -w /src/cpu/x86/pc/biosload/build localhost/ofw-build \
    make 'CFLAGS=-O -g -m32 -DTARGET_X86 -std=gnu89'
--- Saving as ofwlb.elf - Coreboot payload format
$ file build/ofwlb.elf
ELF 32-bit LSB executable, Intel 80386, statically linked   # 348 KB
```

A pleasant surprise in `config-coreboot.fth`: `serial-console` already **on**,
`virtual-mode` already **off** — the exact two knobs POC 2 had to fight for.
The upstream authors ran this pairing; the config remembers.

## Step 2 — coreboot build, isolated inside the shared tree

Board = **i440fx**, not q35: OFW's device set is PIIX-era (its IDE lives at the
i440fx's `pci-ide@1,1` / legacy ports). Guard first, then an isolated config
and object directory:

```console
$ cd ~/linuxboot-lab/coreboot
$ sha256sum .config build/coreboot.rom > ~/ofw-lab/linuxboot-guard.sha
$ printf '%s\n' 'CONFIG_VENDOR_EMULATION=y' \
    'CONFIG_BOARD_EMULATION_QEMU_X86_I440FX=y' \
    'CONFIG_COREBOOT_ROMSIZE_KB_4096=y' \
    'CONFIG_PAYLOAD_ELF=y' \
    'CONFIG_PAYLOAD_FILE=".../biosload/build/ofwlb.elf"' > .config-ofw
$ make DOTCONFIG=.config-ofw obj=build-ofw olddefconfig
$ make DOTCONFIG=.config-ofw obj=build-ofw -j$(nproc)      # ~1 min, crossgcc cached
Built emulation/qemu-i440fx (QEMU x86 i440fx/piix4)
```

## Step 3 — first boot: it just works (mostly)

```
coreboot-...-dirty x86_32 bootblock starting...
... romstage ... postcar ... ramstage ...
Jumping to boot code at 0x019800a0
Generic PC, Serial #0, 0 MiB memory installed
Open Firmware  Built 2026-07-21 ...
ok
```

**The era-mismatch fear was unfounded** — modern coreboot loads and enters the
2015 ELF on the first try. Three observations that drove everything after:

1. **"0 MiB memory installed"** — OFW doesn't parse modern coreboot's memory
   tables; `/memory@0` shows `reg 0 0` and `available` = [1 MB, 26 MB) only.
2. **`Jumping to boot code at 0x019800a0`** — the payload runs *in place* at
   **25.5–32 MB** (IDT at 0x1dfa350). Remember that range.
3. First keystrokes after the prompt got eaten — the harness now sends a bare
   `\r` settle first. And `d# 40 2 + .` printed `2a`: **the ok prompt thinks
   in hex**. (The math was right; the expectation wasn't.)

## Step 4 — pitfall chain to a readable disk

| Symptom | Diagnosis (live, at the prompt) | Fix |
|---|---|---|
| `Can't open deblocker package` | `/packages` had no support packages — the coreboot config ships them as dropins the payload lacks | `create resident-packages` in `config.fth`, rebuild both (the −8-byte ELF diff was a red herring; `/packages` gained `deblocker`, `fat-file-system`, …) |
| Still `Can't open deblocker` | `h# 4000 allocate-dma .` → `0`, while `mem-claim` works. Tree-wide grep: `allocate-dma` is a defer aimed at `null-allocate-dma` — **nothing ever re-points it**; only the emu flavor's PCI parent chain provides the `dma-alloc` it falls back from | `: my-dma h# 1000 mem-claim ;  ' my-dma to allocate-dma` — re-point the defer live |
| `dir /isa/ide@i1f0/disk@0:\` | — | **`fat-file-system` lists VMLINUZ** — the 2015 legacy ISA-IDE driver reads QEMU 8.2 fine (the emu flavor's dead disk was its *PCI-IDE FCode probe*, a different driver) |

## Step 5 — pitfall chain to a booted OS

- **`load` self-destructs the firmware:** loading the 11.5 MB cpio to
  `load-base` (16 MB) writes straight through the payload's home at 25.5 MB —
  KVM dies with EIP inside OFW's own (now overwritten) code. Beautifully
  self-inflicted.
- **`setenv load-base` is a mirage twice over:** the value parses as *decimal*
  (30000000 → 28.6 MB — inside the firmware again), and then
  `use-null-nvram` answers honestly: `Out of NVRAM environment space`.
- **Flank #1 — smaller kernel:** `payload-bzImage` (3.2 MB) loads 16→19.2 MB,
  clear of the firmware.
- **Flank #2 — skip `load` entirely:** open the file and `read` it *directly*
  to its final high address:
  ```
  ok " /isa/ide@i1f0/disk@0:\uroot.img" open-dev to ih
  ok h# 3d000000 h# afedfc " read" ih $call-method .
  ok ih close-dev
  ```
- **The shadow dictionary:** the kernel booted (`Linux version 6.3.0
  (coreboot@reproducible)`) but saw no initrd. Cause: biosload carries a
  *second* `linux.fth` ("Linux startup hacks") whose `ramdisk-adr`/`/ramdisk`
  **shadow** the resident ones at the prompt — writes hit the dead copy; the
  live `set-parameters` read zeros. Even `initrdmem=` on the cmdline is
  discarded, because the kernel's `reserve_initrd()` bails when
  `type_of_loader` is 0.
- **The last resident hook:** `linux-hook` (a defer, unshadowed) runs *after*
  the zero page is written, *before* the jump. Poke the zero page there:
  ```
  ok : fix-zp  h# ff h# 90210 c!            \ type_of_loader = 0xff
               h# 3d000000 h# 90218 l!      \ ramdisk_image
               h# afedfc  h# 9021c l!  ;    \ ramdisk_size
  ok ' fix-zp to linux-hook
  ok boot /isa/ide@i1f0/disk@0:\vmlinuz2 console=ttyS0 memmap=1023M@1M
  ```

```
RAMDISK: [mem 0x3d000000-0x3dafefff]
Unpacking initramfs...
Run /init as init process
Welcome to u-root!
```

**coreboot → Forth → Linux → shell**, driver rc=0.

## Deviations from the wiki (all documented, all justified)

- coreboot v2/v3 → modern master with `CONFIG_PAYLOAD_ELF` (works unmodified).
- `qemu -L coreboot-v3/build …` → `qemu-system-x86_64 -M pc -bios coreboot.rom`.
- One config addition beyond the wiki: `create resident-packages` (the wiki's
  own caveat — "the default configuration lacks drivers for QEMU devices" —
  made concrete: it lacks the *support packages* too).
- The wiki stops at the `ok` prompt; the OS boot on top is this lab's
  extension, using the POC-2 techniques plus three prompt-level fixes.

## What the failures teach

Every fix in this POC was applied **from the running firmware's own prompt** —
re-pointing a defer, reading a file with a package method, hooking the boot
path, patching the kernel handoff page by hand. On UEFI or a legacy BIOS, each
of these would be a recompile-and-reflash cycle. That asymmetry *is* the
lesson the lab exists to teach.
