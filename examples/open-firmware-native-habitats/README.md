# open-firmware-native-habitats — where the `ok` prompt actually shipped

The other three labs in this family run Open Firmware somewhere it was a
curiosity: on a PC. **This one goes where it shipped.** Sun put an IEEE 1275
prompt on every SPARC box for two decades; Apple shipped Open Firmware on every
PowerMac from 1994 to the Intel transition, reachable by holding **Cmd-Opt-O-F**
at the chime. Two tracks, one lab, because they differ in *topology and idiom*,
not in *mechanism*.

```text
$ ./smoke-habitat.sh nvramrc ppc
  - the vocabulary loaded from NVRAM before probe-all and before the banner
  - its words survived into the interactive dictionary (device-end held)
PASS: nvramrc (ppc): the diagnostic vocabulary is resident in NVRAM and self-installs at power-on
```

That line is the lab in one sentence. A boot-forensics vocabulary lives **in the
machine's NVRAM chip**, installs itself before the firmware has probed a single
device, and is waiting at the prompt:

```text
>> CPU type PowerPC,750
ofdiag loaded: dev-head diag-open why-no-boot        ← from NVRAM, pre-probe
Welcome to OpenBIOS v1.1
Trying hd:,\\:tbxi...
0 > why-no-boot
OFDIAG: boot-device = hd:,\\:tbxi hd:,\ppc\bootinfo.txt hd:,%BOOT
OFDIAG target: hd:,\\:tbxi
OFDIAG-1: not a path, and no such devalias          ← there is no `hd` on a diskless Mac
```

The x86 sibling needed a rebuilt ROM, three source edits and an attached floppy
to reach the equivalent. Here it is `-prom-env` and a reset.

## The naming trap (the family's third)

The family already teaches **OFW ≠ OpenBIOS**. This lab adds **OpenBIOS ≠
OpenBoot**, and the distinction is not pedantry — it decides what you can
legally run:

| | what it is | can you build it? |
|---|---|---|
| **OpenBoot** | Sun's (now Oracle's) proprietary IEEE 1275 firmware, on SPARC hardware for ~20 years | **no** — ROM images off real machines only |
| **Apple Open Firmware** | the ROM in a real PowerMac | **no** |
| **OpenBIOS** | the independent open reimplementation of the same standard — and **what `qemu-system-sparc`/`-ppc` boot** | yes, and this lab runs the stock blob |
| **OFW** | Bradley's original, which the [first](../open-firmware-forth-to-boot/README.md) and [fourth](../open-firmware-debugs-itself/README.md) labs build | yes — but it has **no SPARC support at all** (`cpu/` is `arm i8051 mips ppc x86`) |

So the `ok` prompt here is *standards-identical* to the one on a Sun box and is
**not Sun's code**. And because OFW has no SPARC port, this lab cannot be a port
of the sibling's *firmware* — only of its *vocabularies*.

## The thesis: native, not bolted on

An earlier draft of the plan justified this lab by claiming the x86 sibling
*couldn't* demonstrate `nvramrc` or a warm reboot. It has since done both, so
that argument is dead and is [recorded as dead](../../OPEN_FIRMWARE_NATIVE_HABITATS_LAB_PLAN.md).
What survives is better:

| | SPARC / PPC | x86 emu (the sibling) |
|---|---|---|
| NVRAM | a **real device** — an mk48t08 chip, an Apple `nvram@60000` node | a **file on an attached floppy** |
| availability | present at power-on, always | opt-in build switch, upstream ships it **off** |
| upstream's view | the normal case | *"not particularly useful for real hardware platforms"* — Bradley |
| cost to reach it | none | 3 source edits, a rebuild, an isolated ROM, `-fda` |

UEFI keeps its variables in an SPI-flash region — the same *species* of device as
these two. **OFW-on-x86 is the odd one out**, borrowing a filesystem because the
platform gives firmware no NV region it can own.

## Each habitat has exactly one door — and they are different doors

This is the lab's central, and entirely unplanned, finding. A vocabulary has to
get *into* the firmware somehow. There are four conceivable ways in; **no single
one works on both tracks**, and the two machines fail on opposite ones:

| | how it works | SPARC (sun4m) | PPC (g3beige) |
|---|---|---|---|
| **NVRAM, from outside** | `-prom-env nvramrc=…` — QEMU writes the chip at machine init | ✅ | ✅ |
| **NVRAM, from inside** | `setenv` + flush + reset, at the prompt | ❌ never reaches the chip | ✅ |
| **Media** | `load cdrom:\FILE` + `load-base load-size evaluate` | ✅ ISO9660/ext2/UFS/FFS | ❌ no filesystem compiled |
| **Just type it** | paste at the `0 >` prompt | ❌ dies at 80 columns | ❌ same |

Every cell is measured, and each ❌ has a specific cause in the source. The full
derivation, with the code references and the two silent-failure traps that cost
the most time, is in **[DELIVERY.md](DELIVERY.md)**.

## Three things everyone "knew" that turned out to be false

Written down because the [standing bias](../../OPEN_FIRMWARE_NATIVE_HABITATS_LAB_PLAN.md#9-standing-bias-to-correct-for)
this family records is *"the firmware was more capable than assumed, every
time"* — and this lab ran into the opposite bias three times in one afternoon.
All three came from **checks that were too shallow**:

| the claim | how it was checked | what a deeper check showed |
|---|---|---|
| "11 of 11 debugging words present" | `' <word> .` resolves | `see patch` → `: patch ;`. **`patch`, `.calls`, `dl`, `$sift`, `sifting`, `nvedit`, `nvstore`, `nvrun` are empty stubs.** A tick proves a *name*, not a behaviour |
| "NVRAM is writable on both tracks" | `setenv` then `printenv` in the same session | that reads back the in-memory `/options` property. Across a **reset**, sun4m loses it entirely |
| "the vocabulary loaded — see, it printed its banner" | the banner printed | a device node is active when `nvramrc` runs, so `:` compiled **methods**, not words. Everything was gone by the prompt |

The middle one matters most: *"it stuck"* within one session is not evidence of
non-volatility. The x86 lab learned the same lesson in a different costume.

## The payoff: one question, three shapes

`boot-device` is a **list** on all three architectures, which is why
`why-no-boot` walks rather than tests. The same word, unchanged, on three
machines:

| | `boot-device` default | device idiom |
|---|---|---|
| **x86** ([sibling](../open-firmware-debugs-itself/README.md)) | `disk net` | `/pci/pci-ide@1,1/ide@1/cdrom@0` |
| **SPARC** | `disk:a disk` | SBus — `/iommu/sbus/espdma/esp/sd@2,0` |
| **PPC** | `hd:,\\:tbxi hd:,\ppc\bootinfo.txt hd:,%BOOT` | `/pci@80000000/mac-io@10/…`, ADB, CUDA, ESCC |

The Apple entries are the boot policy itself, spelled out: an HFS+ file blessed
with type `tbxi`, then a CHRP boot script, then `%BOOT`. Note also that Sun's
path idiom takes **no comma** (`cdrom:\FILE`) where Apple's does (`cd:,\file`) —
a one-character difference that silently returns an empty buffer if you get it
backwards.

## Run it

```bash
./stage-dsl.sh                      # ISO9660 disc + the one-line NVRAM form
./smoke-habitat.sh all sparc32      # 4 PASS + 1 SKIP
./smoke-habitat.sh all ppc          # 4 PASS + 1 SKIP
./run-habitat.sh ppc                # interactive: land at 0 > with ofdiag resident
```

Everything is verified on this host (Ubuntu 24.04, QEMU 8.2.2) against the
**stock** OpenBIOS blob QEMU ships — this lab builds no firmware, deliberately:
[`../openbios-the-rival-that-shipped/`](../openbios-the-rival-that-shipped/README.md)
already owns the "compile it yourself" story, and this one is about the habitat.
Exact commands and real transcripts: [MANUAL_TESTING.md](MANUAL_TESTING.md).
What ported and what didn't: [PORTING.md](PORTING.md). Roadmap and what is
deliberately not done yet: [PLAN.md](PLAN.md). Guided tour: [RUNBOOK.md](RUNBOOK.md).

## Where this sits

| lab | firmware | thesis |
|---|---|---|
| [`open-firmware-forth-to-boot/`](../open-firmware-forth-to-boot/README.md) | OFW | the `ok` prompt, fixed live |
| [`openbios-the-rival-that-shipped/`](../openbios-the-rival-that-shipped/README.md) | OpenBIOS | the other survival strategy — **build** it |
| [`openbios-clib-hello-to-emacs/`](../openbios-clib-hello-to-emacs/README.md) | OpenBIOS | C **client programs** calling the firmware back |
| [`open-firmware-debugs-itself/`](../open-firmware-debugs-itself/README.md) | OFW | a Forth **DSL** for boot forensics |
| **this lab** | OpenBIOS | the same DSL, in the **habitats where the standard shipped** |

The vocabulary here is a *port* of the fourth lab's, and deliberately not a copy
— same word names, same four fault classes, different implementation, plus one
rung the native device-argument idiom forces. That is the lesson: **a vocabulary
is portable; an implementation is not.**
