# Three ways to get a vocabulary into the firmware

The DSL is a few hundred lines of Forth. Getting it *in front of the `ok` prompt*
turns out to be the interesting part, and this lab now ships **three** mechanisms.
They are not redundant — each trades a different thing, and the third only became
available once [`NVRAM-ON-X86.md`](NVRAM-ON-X86.md) switched the config-variable
store on.

| | mechanism | rebuild? | media? | auto-runs? | carries the vocabulary? |
|---|---|---|---|---|---|
| **M1** | staged media — `fload <cd>:\ofdiag.fth` | no | **yes** | no | **yes** |
| **M2** | ROM dropin — `fload /dropin-fs:\ofdiag.fth` | **yes** | no | only as `banner-` | **yes** |
| **M3** | `nvramrc` autoload line | no | no | **yes** | **no — 4 KB, see below** |

All three are built and smoked. None is deprecated.

## M1 — staged media

[`stage-dsl.sh`](stage-dsl.sh) builds an ISO (emu) and a FAT16 image (coreboot);
you `fload` from it at the prompt.

**Prefer it when** you are iterating on the vocabulary itself. Edit, re-stage,
reboot — no firmware rebuild, seconds per cycle. This is the development loop.

**Costs:** the media must be attached, OFW's ISO9660 reader is **8.3-only**, and on
the coreboot flavor nothing can be read at all until `allocate-dma` is re-pointed —
*the repair that enables file loading cannot itself be loaded from a file*.

## M2 — a dropin inside the ROM

[`build-dropin-rom.sh`](build-dropin-rom.sh) adds one `$add-deflated-dropin` line
per file, putting the vocabularies in `/dropin-fs`. `fload /dropin-fs:\ofdiag.fth`
then needs **no CD, no floppy, no staged media at all**, and sidesteps the coreboot
`allocate-dma` bootstrap entirely because `/dropin-fs` is not a disk.

`--boot-hook` additionally ships `autotrace.fth` as the **`banner-`** dropin, which
OFW executes from `banner()` — and `startup` calls `banner` before `auto-boot` on
**every** path, so the power-on autoboot traces itself with nothing typed.

**Prefer it when** the vocabulary is stable and you want it always present, or when
you are on the coreboot flavor.

**Costs:** a firmware rebuild per change, and `--boot-hook` changes boot output for
every consumer — which is why it builds to an isolated ROM with a sha-guard on the
sister lab's artifact.

## M3 — an `nvramrc` autoload line

The canonical Open Firmware answer, and the one SPARC and PPC users actually reach
for. [`FULL-BOOT-TRACING.md`](FULL-BOOT-TRACING.md) called it dead; it is not.

```forth
ok " fload /dropin-fs:\ofdiag.fth" to nvramrc
ok setenv use-nvramrc? true
═══ cold power cycle, nothing typed, no media ═══
ok ' diag-open .
1c8d7ac                       \ the word is already there
```

**M3 is an autoload hook, not a payload carrier.** NVRAM is `h# 1000` = **4096
bytes** total (`filenv.fth:9`), shared with every other config variable, while
`ofdiag.fth` alone is **4959 bytes**. It cannot hold the vocabulary. What it holds
is the one line that loads it.

That makes M3 **complementary rather than competing**: it is the only mechanism
that auto-runs *without a rebuild*. The strong combination is **M3 + M2** — the
vocabulary lives in the ROM, and NVRAM decides per-machine whether to load it.
Change your mind, `setenv use-nvramrc? false`, no rebuild.

**Prefer it when** you want per-machine behaviour on a fleet sharing one ROM.

**Costs:** needs the NVRAM store (below), so it is not available on the stock ROM.

## Which to prefer

1. **Iterating on the DSL** → M1. Fastest loop, no rebuild.
2. **Want it always present, or on coreboot** → M2.
3. **Want it to auto-run, and NVRAM is available** → **M3 + M2**. This is the
   closest to how a real SPARC or PowerPC Mac is administered, and it is what the
   native-habitats tracks will use.
4. **Want the autoboot itself traced** → M2 `--boot-hook`. Add `--reboot-hook` for
   the combined ROM, the only build that can trace a **warm** reboot.

**NVRAM is preferred when the emulator can carry a writable drive** — which under
QEMU means `-fda`, and is essentially always true. Where it is not (no writable
drive attached), `stand-init` prints *"The configuration EEPROM is not working"*,
behaviour falls back to stock, and **M1/M2 still work unchanged**. That fallback is
the reason all three are kept: M3 is preferred, not required.

## The ROMs, and why both are kept

| build | output | what it is for |
|---|---|---|
| `build-dropin-rom.sh` | `ofdiag-emuofw.rom` | M2, no behaviour change |
| `build-dropin-rom.sh --boot-hook` | `autotrace-emuofw.rom` | autoboot tracing, **stock NVRAM behaviour** |
| `build-nvram-rom.sh` | `nvram-emuofw.rom` | NVRAM only — the **control arm** |
| `build-nvram-rom.sh --reboot-hook` | `nvram-reboot-emuofw.rom` | NVRAM + reachable warm reboot |
| `build-dropin-rom.sh --boot-hook --reboot-hook` | `autotrace-nvram-reboot-emuofw.rom` | **combined** — tracers *and* a warm reboot |

`autotrace-emuofw.rom` is deliberately **kept alongside** the combined ROM rather
than replaced. It is the artifact the existing `smoke-dsl.sh autotrace` verifies,
it keeps stock NVRAM behaviour, and a lab that changes the baseline it audits stops
being able to audit it. The control arm (`nvram-emuofw.rom`) is kept for the same
reason: `smoke-nvram.sh reboot` asserts it does *not* take the warm-reboot branch,
which is what proves the two causes independent.

## The first traced warm reboot

The combined ROM closes the last gap. Same floppy, two boots:

```
boot 1 (normal)                     boot 2 (warm reboot)
#T autotrace armed (banner- dropin) #T autotrace armed (banner- dropin)
Type any key to interrupt …         Rebooting with command: boot
6 5 4 3 2 1  #T open disk           #T open disk
Boot device: /pci/ethernet          Boot device: /pci/ethernet
#T open /pci/ethernet               #T open /pci/ethernet
```

Boot 2 has **no countdown** — `do-auto-boot` never ran — yet the `#T` lines are
there. On that path `" boot-" do-drop-in` is never reached, so a `boot-`-hooked
tracer would have emitted **nothing at all**. The choice of `banner-` over `boot-`
was argued from source for two increments; it is now observed.

`smoke-nvram.sh warmtrace` is the standing proof.

---

## Deferred work — a `c:` devalias and NVRAM on a FAT partition

Today the store is a file on a **floppy** (`a:\nvram.dat`, `-fda`). That works and
is fully smoked, but it is the weakest part of the design: it burns the floppy
controller, caps the store at a 1.44 MB medium the lab otherwise has no use for,
and means every NVRAM-dependent run needs `-fda`.

**The improvement:** define a `c:` devalias pointing at a FAT partition on a hard
disk and retarget `nv-file` to `c:\nvram.dat`. Upstream already anticipates this —
`biosload/devices.fth` defines `fd-nv-file`/`hd-nv-file`/`usb-nv-file` for exactly
`a:`/`c:`/`u:`, and emu's block *already says* `c:\nvram.dat`. Emu simply never
declares the `c` alias (`devices.fth:127` declares only `a` and `b`, both floppies),
which is why [`build-nvram-rom.sh`](build-nvram-rom.sh) retargets to `a:`.

Sketch: `devalias c /pci/pci-ide@1,1/ide@0/disk@0:1` (partition 1), a FAT16 image
attached with `-hda`, and `' hd-nv-file to nv-file`. OFW's FAT driver already has
full write support and a partition package (`ofw/fs/fatfs/partition.fth`), so the
pieces exist. Unknowns worth a spike: whether the partition package resolves `:1`
the way the ISO path does, and whether `stand-init` runs early enough for the IDE
node to be usable.

**Why it is deferred, not done:** the floppy path is verified end-to-end and nothing
depends on the improvement. Doing it would change every NVRAM smoke's fixture at
once, so it deserves its own increment with its own control.

### Does EFI do this? No — and the answer is worth getting right

**UEFI does not store variables on the ESP.** Non-volatile UEFI variables —
`BootOrder`, `Boot0001`, Secure Boot keys — live in a dedicated region of the
**SPI flash chip**, the same physical part that holds the firmware. That is
structurally the *same kind of thing* as PPC's `/pci@…/mac-io@10/nvram@60000` and
SPARC's NVRAM/TOD chip: a small dedicated non-volatile device the firmware owns.

The **ESP** is a FAT32 partition holding *bootloader files*
(`\EFI\BOOT\BOOTX64.EFI`). Its analogue in Open Firmware is the **boot device and
path** — what `boot-device` points at — not NVRAM. The two stores are genuinely
separate: `efibootmgr` writes variables to flash through `efivarfs`, while the
`.efi` binaries it points at live on the ESP.

Under QEMU this stays honest: `OVMF_VARS.fd` is attached as a **pflash** device, an
emulated flash chip, not a filesystem.

So the ranking is:

| firmware | variable store | kind |
|---|---|---|
| SPARC OpenBoot | NVRAM/TOD chip | dedicated NV device |
| PPC Open Firmware | `nvram@60000` under mac-io | dedicated NV device |
| UEFI | SPI flash region (`OVMF_VARS.fd` = pflash) | dedicated NV device |
| **OFW on x86 (this lab)** | **a file on an attached drive** | **filesystem — the odd one out** |

OFW's `pseudo-nvram` is a *fallback*, and Bradley's comment in `config.fth` says as
much: generic PCs give the firmware no NV region it can own, so it borrows a
filesystem instead. Moving from a floppy to a FAT partition makes it tidier; it
does **not** make it more like EFI. The genuinely EFI-shaped move would be an
`-drive if=pflash` region owned by the firmware — a much larger change, and out of
scope for this lab.
