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
| **M4** | **self-contained drive** — one medium holds the hook *and* the payload | no | **yes (one)** | **yes** | **yes** |

All four are built and smoked. None is deprecated.

**M4 is a composition, not a new primitive** — it is M3's hook pointing at an M1
payload, with both on the *same* writable medium. It earns its own row because it
has a property none of M1–M3 has alone: **the vocabulary auto-loads with no ROM
dropins at all**, so the firmware needs nothing but the NVRAM switch. Swap the
disk, get a different machine. See below for the ordering rule that constrains it.

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

### The store is 4 KB, whatever the medium

The 1.44 MB of the floppy is irrelevant, and so was the 64 MB of the hard disk.
`filenv.fth` caps the store at `/nvram` in two independent places:

```forth
h# 1000 constant /nvram                                  \ filenv.fth:9
: seek  ( d.offset -- status )
   0<>  over /nvram u>  or  if  …  true exit  then       \ rejects past the cap
: clip-size  ( adr len -- adr len' )
   nvram-ptr +   /nvram min  nvram-ptr -                 \ truncates every r/w
```

`nvopen` also pre-creates the file at exactly that size (`/nvram alloc-mem`,
`erase`, `fputs`) — which is why a working store shows `NVRAM.DAT` at precisely
**4096** bytes on a `dir`. A bigger medium buys nothing; that was true of the disk
route before it turned out not to be dependable anyway. So the budget for an
`nvramrc` line is 4 KB *minus* whatever `boot-device`, `nvalias` entries and other
variables already occupy — comfortable for a `fload` line, hopeless for a
vocabulary.

That makes M3 **complementary rather than competing**: it is the only mechanism
that auto-runs *without a rebuild*. The strong combination is **M3 + M2** — the
vocabulary lives in the ROM, and NVRAM decides per-machine whether to load it.
Change your mind, `setenv use-nvramrc? false`, no rebuild.

**Prefer it when** you want per-machine behaviour on a fleet sharing one ROM.

**Costs:** needs the NVRAM store (below), so it is not available on the stock ROM.

### The rule that governs what an `nvramrc` line may reference

`nvramrc` is evaluated **before probing**. From emu's `startup` (`fw.bth:288`):

```forth
use-nvramrc?  if  nvramrc safe-evaluate  then   \ ← nvramrc runs HERE
auto-banner?  if
   " Probing" ?type  probe-all                  \ ← report-disk creates `c` HERE
```

So an autoload line can only reach devices that exist **pre-probe**:

| target | works? | why |
|---|---|---|
| `fload /dropin-fs:\…` | **✔** | ROM-resident pseudo-filesystem; no probing involved |
| `fload a:\…` | **✔** | `devalias a /isa/fdc/disk@0` is declared **statically** at build time |
| `fload c:\…` | **✘** | PCI IDE; the `c` alias is created by `report-disk` *during* `probe-all` |

All three were tested, and the `c:` failure is real: `' diag-open .` still answers
`diag-open ?` after a cold cycle.

**This is not a defect.** `nvramrc` runs early *by design* — on a real SPARC that is
the whole point, so it can install `nvalias` entries and patch device handling
*before* the tree is built. The constraint is inherent to what the hook is for.

## M4 — a self-contained drive

One writable medium carries **both** `nvram.dat` (the hook) and `ofdiag.fth` (the
payload), against a ROM with **no dropins**:

```forth
ok " fload a:\ofdiag.fth" to nvramrc
ok setenv use-nvramrc? true
═══ cold power cycle, nothing typed ═══
ok ' diag-open .
1c8d7a8                       \ loaded itself, from the same floppy
```

Per the rule above this works on the **floppy** and not on a PCI disk. That suits
it: `-fda` needs no partition on the boot drive, no IDE controller, and nothing in
the ROM beyond the NVRAM switch. It is the closest thing here to "hand someone a
disk and their machine behaves differently" — which is how these boxes were
actually administered.

**Prefer it when** you want a *portable, per-machine* configuration with a stock
ROM, or when the point is conceptual: the whole mechanism, on one medium you can
inspect with `mdir`.

**Costs:** the medium must be attached and writable, and it is subject to the
pre-probe rule, so a hard-disk variant is not available.

`smoke-nvram.sh selfcontained` is the standing proof.

## Which to prefer

1. **Iterating on the DSL** → M1. Fastest loop, no rebuild.
2. **Want it always present, or on coreboot** → M2.
3. **Want it to auto-run, and NVRAM is available** → **M3 + M2**. This is the
   closest to how a real SPARC or PowerPC Mac is administered, and it is what the
   native-habitats tracks will use.
4. **Want the autoboot itself traced** → M2 `--boot-hook`. Add `--reboot-hook` for
   the combined ROM, the only build that can trace a **warm** reboot.
5. **Want a portable, per-machine setup with no dropins in the ROM** → **M4**, the
   self-contained floppy. Also the best one for *teaching* the mechanism, since the
   hook and the payload are both visible on one medium with `mdir`.

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
| `build-nvram-rom.sh` | `nvram-emuofw.rom` | NVRAM on a **floppy**, no dropins — the **M4 host**, and the **control arm** |
| `build-nvram-rom.sh --disk` | `nvram-disk-emuofw.rom` | reproducer for a **nondeterministic** result — emu probes a primary-channel `disk@0` only ~2 boots in 18; see below |
| `build-nvram-rom.sh --reboot-hook` | `nvram-reboot-emuofw.rom` | NVRAM + reachable warm reboot |
| `build-dropin-rom.sh --boot-hook --reboot-hook` | `autotrace-nvram-reboot-emuofw.rom` | **combined** — tracers *and* a warm reboot |

`nvram-emuofw.rom` is the one that needs **only `-fda`** — no partition on the boot
drive, no IDE controller, nothing in the ROM but the NVRAM switch. That is both a
hardware-availability answer and the clearest one to reason about, and since the
disk route turned out to be nondeterministic (below), it is the only **dependable**
store. `--disk` is kept solely as the reproducer for that result.

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

## The `c:` store — attempted, **NEGATIVE RESULT**, and the premise was wrong twice

This section used to be deferred work, on the theory that *"emu never declares the
`c` alias."* **That was false.** `report-disk` declares it
(`devices.fth:261`: `" c" " /pci-ide/ide@0/disk@0" $devalias`). No new alias was
needed at all.

The real obstacle is **ordering**, and it is the same shape as the warm-reboot
finding — a flavor-local `startup` doing less than the generic one:

- `report-disk` runs inside **`probe-all`**, which `startup` calls *long after*
  `stand-init: Pseudo-NVRAM` has already tried to open the store.
- **PCI is unprobed** at stand-init, so no PCI-IDE path could resolve then even
  with an alias present.
- The floppy escapes this only because `devalias a /isa/fdc/disk@0` is declared
  **statically at build time** — its node exists immediately.

Upstream already solved it: `biosload`'s `stand-init` calls **`reread-config-vars`**
(`biosload/devices.fth:213`), a `config-valid?`-guarded retry, precisely because it
boots off USB/disk. emu calls `init-config-vars` once and gives up.

`build-nvram-rom.sh --disk` adds that retry after `probe-all`. **It is still not
enough**, and the reason is a layer below everything above.

### The actual blocker: the disk node is probed only *sometimes*

Usually, at the `ok` prompt with a 64 MB drive on `-drive if=ide,index=0`:

```
ok dev /pci/pci-ide@1,1/ide@0 ls device-end
ok                                   ← NO CHILDREN. disk@0 was not created.
ok dir c:\
Can't open directory
```

Occasionally, from an **identical** invocation:

```
ok dev /pci/pci-ide@1,1/ide@0 ls device-end
91028 disk@0                         ← probed this time
ok dir c:\
fat-file-system
--A-rwxrwxrwx      4096  ...  NVRAM.DAT      ← and the store opened, and works
```

The `c` alias resolves fine either way (`c → /pci-ide/ide@0/disk@0`) and `ide@0`
always exists. What varies is whether emu's PCI-IDE probe creates a **child node
for a primary-channel hard disk**. It creates `cdrom@0` under `ide@1` reliably —
which is why [`check-oracle.sh`](check-oracle.sh) and every media smoke can read a
CD without trouble. When `disk@0` is absent the config layer reports *"Can't read
the configuration memory"* twice: once at stand-init, once at the retry.

**Measured: about 2 successes in 18 identical boots** on this host — 0/13 in a
controlled loop, plus two one-off successes. Not "broken", not "working":
**nondeterministic**.

Ruled out as the variable (each tried on both sides of the result):

- plain FAT16 with no MBR (`mkfs.vfat -F16`, the `stage-dsl.sh` idiom)
- a proper **MBR + type-06 FAT16 partition** (`sfdisk` + `mkfs.vfat --offset 2048`),
  addressed as both `c:\` and `c:1\`
- `media=disk` on the QEMU drive; `cache=writethrough`; fresh vs. reused image

The remaining suspect is a **timing-dependent probe** — an IDENTIFY wait in the
IDE driver that a hard disk sometimes loses and an ATAPI device does not. That is a
firmware-driver question, not an NVRAM one, and it is left open.

### Corrections I owe the record

This page said two wrong things on the way here, both worth keeping visible:

1. First it claimed the disk store **worked**, on the strength of a single run. It
   did not reproduce.
2. Then it claimed the store **could not work**, and shipped a smoke that
   *asserted* the empty `ide@0`. That assertion promptly failed on a run where the
   probe succeeded — the "regression" it reported was the real behaviour.

Both errors have the same root: **treating one boot as evidence about a
nondeterministic system.** The fix was to measure over many boots.

Consequently `smoke-nvram.sh diskstore` **asserts nothing**. It observes one boot,
reports which case it saw, and exits **SKIP (77)**. A test that fails at random is
worse than no test, because a flaky red is indistinguishable from a real
regression. It is also excluded from `smoke-nvram.sh all` so it cannot swallow the
aggregate verdict. `--disk` is kept as the reproducer; its post-probe retry is
upstream's own idiom, correctly implemented, and simply is not the binding
constraint.

Two things this does *not* change:

- **No capacity gain was ever available.** `/nvram` is `h# 1000` (`filenv.fth:9`),
  so a 64 MB disk would store exactly as many config variables as a 1.44 MB floppy.
- **M4 was never going to extend to disk** regardless, because of the pre-probe
  rule above. Self-contained delivery is a floppy mechanism by construction.

Open, if anyone wants it: find why the IDE probe skips a primary-channel hard disk
(FCode driver? `probe-pci` ordering? an IDENTIFY path that only handles ATAPI?).
That is a firmware-driver question, not an NVRAM one.

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
