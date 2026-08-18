# X86-64-FEASIBILITY.md — could this firmware run in long mode?

> **VERDICT: OpenBIOS — feasible, and the expensive half is already done.
> OFW — not feasible as a lab.**
>
> First written 2026-08-18 as a study; **audited the same day, and Spike 0 —
> which the first version explicitly had not attempted — has now been run.**
> The verdict survived. Seven claims did not survive unchanged; they are
> corrected in place and listed in
> [§ What the audit corrected](#what-the-audit-corrected). The spike's build
> patches ship in [`patches/`](patches/) so every number below is
> reproducible.

A feasibility study, not a port: no firmware was made to run in long mode
here. What *was* done is measurement — both upstream trees were cloned at
their pinned commits and **built** to establish what exists today, because the
central claim ("`arch/amd64` is not a port") is the kind of thing a reading of
the source can get wrong and a build cannot. The audit then went one step
further: it gave `arch/amd64` a real build description and compiled every file
at 64-bit, so the estimates in the first version could be replaced with a
**measured failure census**.

## The question, disambiguated

Three different things can be meant by "port the Open Firmware labs to x86-64",
and two of them are already true:

| reading | status |
|---|---|
| run the labs **on** an x86-64 host | **already true** — [`run-openbios-qemu.sh`](run-openbios-qemu.sh), [`smoke-openbios.sh`](smoke-openbios.sh) and [`showcase-rival-boots-linux.sh`](showcase-rival-boots-linux.sh) all invoke `qemu-system-x86_64 -M pc` |
| boot a 64-bit **OS** from the firmware | **already true** — [POC-4](POC-4-BOOT-LINUX.md) boots an x86_64 Linux 6.3 bzImage to a u-root shell; the kernel's own `startup_32` performs the mode switch, and the firmware never leaves protected mode |
| run the **firmware itself** in long mode | **the open question** — everything below |

So the port is not about the host, the emulator, or the guest OS. It is about
the arch layer — ~1,300 lines of 32-bit-assuming code in `arch/x86`, and the
1,858 lines of `arch/amd64` that turn out to be its never-compiled twin.

## OpenBIOS: `arch/amd64` looks like a port and isn't one

The directory exists, carries `boot.c`, `linux_load.c`, `multiboot.c`,
`segment.c`, `context.c`, a `ldscript` and a `switch.S`, and appears in
upstream CI ("OpenBIOS build for amd64 ppc sparc32 sparc64 x86"). None of that
survives contact:

| evidence | what it says |
|---|---|
| `config/examples/amd64_config.xml` | the config the build **actually uses** requests `CONFIG_IMAGE_ELF_MULTIBOOT=true` — upstream's own amd64 config *asks for a bare-metal multiboot image*. (`arch/amd64/defconfig`, which the first version of this doc cited, is referenced by **nothing** in the build system — a vestige of an abandoned Kconfig attempt) |
| `arch/amd64/build.xml` | declares a `<dictionary>` and **nothing else** — no `<library>`, no `<executable>`. This, not the config, is why no image is ever produced: the config asks; the build description has no rule to answer (compare `arch/x86/build.xml`: a `libx86.a` plus three executables) |
| `arch/amd64/ldscript` | `OUTPUT_FORMAT(elf32-i386)` / `OUTPUT_ARCH(i386)` — a copy of the 32-bit script, while `switch-arch` compiles this arch **without** `-m32`. The two have never been asked to agree |
| `arch/amd64/switch.S` | *"It is assumed that CPU is in 32-bit protected mode and all segments are 4GB and base zero"*, and the entry point is `pushl %cs` — 116 lines of 32-bit assembly in the 64-bit arch directory |
| no `arch/amd64/entry.S` | `arch/x86` has one (315 lines). amd64 has no bare-metal entry path at all |
| `git log -- arch/amd64` | last amd64-specific commit **2016-08-26** (`f275232`, `amd64: introduce arch_init_program()`). Four commits touch the directory after that — ELF boot-notes (2016-08-27, 13 files), the `start_elf` signature (2016-08-28, 9 files), spelling (2017-02-02, 20 files), the `malloc` signature (2024-02-24, 7 files) — every one a repo-wide sweep landing on amd64 only because the file exists |

The CI job name is the trap: upstream CI runs `switch-arch amd64 ppc sparc32
sparc64 x86`, and its published artifact list for amd64 is
`obj-amd64/openbios-unix` plus dictionaries — the **host userspace** target,
which is what this lab already ships as its fourth track. It builds
`arch/unix`, not `arch/amd64`.

This also explains a detail [POC-2](POC-2-OK-PROMPT.md) found and called
"poetic": the correct `load_dictionary()` flow that x86's multiboot path was
missing sits in `arch/amd64/openbios.c`, unused. It is unused because **nothing
compiles that file**.

## What the build actually produces (measured, not read)

```console
$ git clone --depth 1 https://github.com/openbios/openbios.git ob   # e5ac46d
$ git clone --depth 1 https://github.com/openbios/fcode-utils.git fu && make -C fu
$ PATH="$PWD/fu/toke:$PATH"; cd ob
$ ./config/scripts/switch-arch builtin-amd64
Configuring OpenBIOS on amd64 for builtin-amd64
Initializing build tree .../obj-amd64...ok.
$ grep 'IMAGE' obj-amd64/config.xml
<option name="CONFIG_IMAGE_ELF_EMBEDDED" type="boolean" value="true" />
  <option name="CONFIG_IMAGE_ELF_MULTIBOOT" type="boolean" value="true"/>
$ make
Building OpenBIOS for amd64
Building...
ok.
$ find obj-amd64/target -path '*arch/amd64*' -name '*.o' | wc -l
0
$ find obj-amd64 -maxdepth 1 \( -name '*.elf' -o -name '*multiboot*' \) | wc -l
0
```

Note the `grep`: the generated config carried **two** enabled image types —
`ELF_EMBEDDED` injected by the `builtin-` prefix, `ELF_MULTIBOOT` from
upstream's own example config — and the build still **succeeded, reported
"ok", and emitted only dictionaries**. Zero object files compiled from
`arch/amd64`; zero firmware images produced. A green build that builds no
firmware is this repo's own favourite bug class
([CLAUDE.md](../../CLAUDE.md), *"a scan that matches nothing and a scan that
is broken print the same green ✓"*).

The contrast is now measured too, not read (the audit installed the 32-bit
multilib the first version lacked): on the **same tree, same toolchain, same
command shape**,

```console
$ ./config/scripts/switch-arch builtin-x86 && make
$ file obj-x86/openbios-builtin.elf obj-x86/openbios.multiboot
obj-x86/openbios-builtin.elf: ELF 32-bit LSB executable, Intel 80386 ...   # 358,896 bytes
obj-x86/openbios.multiboot:   ELF 32-bit LSB executable, Intel 80386 ...   #  97,436 bytes
```

x86 answers with two firmware images. amd64 answers with none.

## The expensive half is already done

The portable core — the Forth engine, the dictionary format with its relocation
bitmap, the device tree, the packages — is already 64-bit clean: **sparc64**
proves it in production (a shipping upstream-CI target and the firmware
`qemu-system-sparc64` boots by default), and a ppc64 build config exists
besides (though ppc64 is in neither upstream CI nor the lab's scope).
`arch/amd64` even has the type layer written:

```c
/* include/arch/amd64/types.h */
typedef int64_t     cell;
typedef uint64_t    ucell;
typedef __int128_t  dcell;
```

And it runs. Building the *hosted* amd64 target and feeding it the amd64
dictionary:

```console
$ ./config/scripts/switch-arch unix-amd64 && make
$ printf '3 4 + . cr -1 u. cr\nbye\n' | ./obj-amd64/openbios-unix ./obj-amd64/openbios-unix.dict
0 > 3 4 + . cr -1 u. cr 7
ffffffffffffffff
 ok
```

`-1 u.` printing `ffffffffffffffff` (Open Firmware's default base is hex) is a
**64-bit cell**, in the real dictionary, through the real engine. Nothing about
the Forth side of a long-mode port is speculative.

## Spike 0, now run: the measured failure census

The first version of this document ended with an estimate and the admission
that Spike 0 — flip the build on, fix nothing, enumerate what breaks — had not
been attempted. The audit ran it. Two patches reproduce it (applied to the
pinned clone by hand; [`build-openbios.sh`](build-openbios.sh) applies
`01-x86-revival.patch` **by name**, so these are never picked up by the lab's
normal build):

| patch | contents |
|---|---|
| [`patches/02-amd64-spike0-build-on.patch`](patches/02-amd64-spike0-build-on.patch) | a real `arch/amd64/build.xml` — `libamd64.a` from the nine existing sources + an `openbios.multiboot` executable, mirroring x86's stanzas — and the 2-line ldscript retarget to `elf64-x86-64` |
| [`patches/03-amd64-spike0-drift-fixes.patch`](patches/03-amd64-spike0-drift-fixes.patch) | the nine-line mechanical pass described below — every hunk copies what `arch/x86` already has |

One harness note for reproducers: the build's `quiet-command` wrapper prints a
bare `error:` and swallows the compiler's actual message — `make V=1` (or the
per-file `gcc` invocations below) is required to see what failed. Silence
about *what* failed, from a build that failed: the bug class again.

**The census, per file, at 64-bit, with the build's own `-Werror` wall
(gcc 13.3.0):**

| file | lines | errors | first diagnosis |
|---|---|---|---|
| `sys_info.c` | 58 | **0** | compiles clean at 64-bit today |
| `multiboot.c` | 125 | **0** | compiles clean at 64-bit today |
| `lib.c` | 56 | 1 | `void *` arithmetic — the exact line x86's twin later fixed with a cast; amd64 kept the pre-fix line |
| `segment.c` | 134 | 2 | local `extern char _start[]` conflicting with `include/arch/*/io.h` — a stale declaration x86 deleted; after deleting it the surrounding code is byte-identical to x86's |
| `console.c` | 417 | 11 | every error from **one missing `#include "libopenbios/console.h"`** — the 2013 console refactor (`d66a99d`) added it to every *compiled* arch; amd64 wasn't compiled |
| `openbios.c` | 108 | 9 | missing includes from the same era (`console.h`, `drivers/drivers.h`, `drivers/pci.h`, `video.h`) plus two stale local declarations |
| `boot.c` | 41 | fatal | `#include "libopenbios/elfload.h"` — **a header that no longer exists anywhere in the tree**; x86's current twin is 23 lines against today's API |
| `linux_load.c` | 647 | fatal | `#include "loadfs.h"` — same: deleted tree-wide; x86's twin reads through `libc/diskio.h` |
| `context.c` | 156 | 8 | six `cast from pointer to integer of different size` in the initial-context frame — **the only true 64-bit C errors in the directory** |
| `switch.S` | 116 | 15 | `pushal`/`popal`/segment-register `pushl` — instructions that do not exist in 64-bit mode; total rewrite, as estimated |

### The category the estimate missed: API drift

The first version's model was two buckets — "travels" vs "64-bit rewrite".
The census shows a third, and it dominates the C errors: **shared-layer
refactors from 2008–2013 that every compiled arch absorbed and the
never-compiled arch didn't.** The console include, the `loadfs.h` → `diskio.h`
migration, deleted `elfload.h`, the stale externs. This is
[CLAUDE.md](../../CLAUDE.md)'s *record that outlives the thing it describes*,
in source form: `arch/amd64` is a cached copy of `arch/x86` circa 2006, still
readable, merely false — and nothing errored for eighteen years because
nothing compiled it.

To size that bucket, the audit applied a **drift-only** pass
(`03-amd64-spike0-drift-fixes.patch`): nine changed lines across four files,
every one copying what the x86 twin already does — one include in
`console.c`, four in `openbios.c`, the one-line cast in `lib.c`, the deleted
stale extern in `segment.c`. No 64-bit work of any kind. Re-census:

| file | errors before | after drift-only fixes | what remains |
|---|---|---|---|
| `lib.c`, `segment.c` | 1, 2 | **0, 0** | nothing |
| `console.c` | 11 | 3 | three `arch_*char` functions want `static` (x86 has it) — more drift |
| `openbios.c` | 9 | 5 | two stale local declarations (`setup_timers`, `collect_sys_info`) — more drift |
| `boot.c`, `linux_load.c` | fatal | fatal (untouched) | re-port against today's API from the 23-line / x86 twins — **mode-independent** work |
| `context.c` | 8 | 8 (untouched) | the pointer-width frame — real 64-bit work |
| `switch.S` | 15 | 15 (untouched) | the rewrite — real 64-bit work |

**The headline the estimate could not have produced: after nine mechanical
lines, the entire 64-bit compile debt in `arch/amd64`'s existing C is
`context.c`'s eight errors.** Everything else is either drift (mechanical,
copy the x86 twin), a dead-API re-port (`boot.c`/`linux_load.c` — needed at
*any* bit width), or assembly. The real work is where the first version put
it — the asm layer: `switch.S` rewritten for long mode, an entry trampoline
that doesn't exist, an `exception.c` that doesn't exist (x86's is 92 lines).
But the C side measured **smaller** than estimated.

### A known bug, waiting verbatim

`arch/amd64/multiboot.h` defines `MULTIBOOT_HEADER_FLAGS 0x00010003` over the
same three-word header struct — **bit 16 set, no address fields: the exact
spec-invalid header that was bug #1 of
[`patches/01-x86-revival.patch`](patches/01-x86-revival.patch)**, the one that
makes QEMU `-kernel` load at address 0 and jump to 0. Spike 1 would hit it on
the first boot; the one-line fix travels as-is. (Bug #2 — `load_dictionary()`
never called — does *not* travel: its x86 fix was backported **from** amd64's
`openbios.c`, so the amd64 fossil is the one file that already has that flow
right.)

## What is actually missing — estimates re-graded by the census

The first version estimated from `arch/x86`'s line counts. Measured against
`arch/amd64`'s own files:

| layer | first version said | the census says |
|---|---|---|
| entry trampoline | "rewrite entry.S (315)" | confirmed: **nothing to rewrite — it doesn't exist**; multiboot enters via `switch.S`'s 32-bit `entry:` |
| `switch.S` / `context.c` | "rewrite" | confirmed by measurement: 15 + 8 errors, the only true 64-bit compile debt |
| `exception.c` | "rewrite (92)" | still to author from scratch — amd64 never had one |
| `segment.c` | "rewrite — the GDT changes shape" | **compiles clean** after a one-line drift fix — but see the honesty note: its GDT entries are still 32-bit-era descriptors; the *semantic* rewrite stands, just smaller than "rewrite the file" |
| `ldscript` | "rewrite" | a 2-line retarget sufficed to configure — but the link stage was never reached (see below), so this is unproven beyond parsing |
| `linux_load.c` | "port, and it gets simpler" | **two-step**: first a mode-independent re-port off the dead `loadfs.h` API (the x86 twin shows the shape), *then* the 64-bit entry work — see the corrected claim below |
| `boot.c` | "travels" | re-port: 41 lines against a deleted header; x86's current twin is 23 lines |
| `console.c`, `openbios.c` | "travels" | travels after ~6 drift lines each — measured, not assumed |
| `sys_info.c`, `multiboot.c` | "mostly travels" | **zero errors**, better than estimated |

**The corrected `linux_load.c` claim** (the first version got this wrong
twice): the 64-bit bzImage entry at `+0x200` does **not** dispense with the
zero page — `boot_params` still has to be built and handed over (in `%rsi`),
and the modern header fields whose absence was revival-patch bug #7
(`init_size`, `kernel_alignment`) are still read. Nor did "the zero-page
dance" produce "five of the eight bugs" — it produced **two** (#6, the context
frame; #7, the missing fields); #3 is NVRAM, #5 is grubfs, #8 is coreboot
tables, all mode-independent and all still waiting for a 64-bit port too. What
the `+0x200` entry genuinely buys a *long-mode* firmware is avoiding the
**64→32 mode drop**: entering at the 32-bit `0x100000` entry from long mode
would mean leaving long mode first, only for the kernel's `startup_32` to
climb straight back.

## The structural wrinkle: every entry path hands off in 32-bit

There is no way to be handed control in long mode on this machine class:

- **multiboot1** (`-kernel openbios.multiboot`) specifies 32-bit protected
  mode with paging **off** — the whole reason bug #1 in the revival patch was
  about a.out-kludge address fields.
- **coreboot payload** (`-bios coreboot.rom`, [POC-3](POC-3-COREBOOT-PAYLOAD.md))
  enters the payload in 32-bit protected mode too (coreboot's experimental
  64-bit ramstage exists, but the payload handoff this lab uses is 32-bit).
- QEMU's plain `-bios` on the `pc` machine wants a legacy BIOS image entered in
  **real mode** at the reset vector, which is why this lab reaches long-mode-
  capable territory only by way of coreboot in the first place.

So the port is unavoidably shaped as: a 32-bit stub that builds a PML4
identity-mapping the low 4 GB, sets PAE + EFER.LME + CR0.PG, far-jumps through
a 64-bit code descriptor, and lands in a C `main()` compiled
`-mcmodel=small -fno-pic` (the firmware sits identity-mapped at 1 MB, squarely
in the small model's range — the first version said `-mcmodel=kernel`, which
is for the top-2GB negative space and simply the wrong model here). That is
well-trodden ground — 200–300 lines — but it means the firmware keeps a
32-bit head forever, which is worth saying out loud before anyone imagines a
pure-64-bit build.

## What it buys — honestly, not much

| gained | notes |
|---|---|
| memory above 4 GB | `claim`/`release` over the whole map; today's firmware simply cannot address it |
| an honest device tree | `#address-cells 2`, a `/cpus` node that isn't lying about the mode the CPU is in |
| a simpler kernel handoff | no 64→32 drop; the `+0x200` entry, per the corrected claim above |
| an upstream-shaped patch | OpenBIOS would plausibly take a real `arch/amd64` target: its own example config already requests the image, and the drift fixes are exactly the sweeps upstream applies anyway |

And what it does *not* buy: any new boot capability. The 32-bit firmware
already boots a 64-bit kernel. On the client-interface side the honest
statement is narrower than the first version's "not consumed by Linux on x86
at all": mainline Linux does carry one real x86 IEEE 1275 client —
`arch/x86/platform/olpc/` calls OFW client services on the (32-bit, OFW-only)
OLPC XO machines — but no generic x86 boot, and nothing x86-64, consumes it,
so widening `prom_arg_t` changes nothing for any client this lab could run.
The value here is the bring-up itself — which, in a repo whose thesis is that
firmware is knowable, is a legitimate reason, but it should not be sold as a
feature.

## The remaining spikes

Spike 0 is done (above). Each remaining spike keeps an observable checkpoint,
per the repo's learning-path rule:

| spike | work | checkpoint |
|---|---|---|
| **1 — the trampoline** | apply the drift fixes + the bug-#1 header fix (both already written); rewrite `switch.S`; author the 32→64 stub; stub out `boot.c`/`linux_load.c` to get a link | `0 >` on the serial socket, and `-1 u.` answering `ffffffffffffffff` from the *bare metal* rather than from `openbios-unix` |
| **2 — context + exceptions** | the 64-bit context frame (`context.c`'s eight errors), a 64-bit IDT in a new `exception.c` | a deliberate `0 0 !` reports a named fault instead of triple-faulting; the client-program context still switches back to the prompt |
| **3 — boot Linux** | re-port `boot.c`/`linux_load.c` off the dead API (x86's twins show the shape), then the `+0x200` entry | the existing [`showcase-rival-boots-linux.sh`](showcase-rival-boots-linux.sh) success signature, unchanged, from the 64-bit firmware |

Known failure mode worth planning for in 1–2: a triple fault under
`-no-reboot` exits QEMU with **rc=0** ([POC-2](POC-2-OK-PROMPT.md)'s pitfall
list), so the harness must assert the prompt, never merely a clean exit.

## OFW / OpenBoot: why this one is a no

Different situation entirely, and the answer is not "harder" but "a different
project". (The audit re-verified every row of this table against the clone;
all held.)

| evidence (`openfirmware` @ d5cc657) | consequence |
|---|---|
| `cpu/x86/kerncode.fth` — 1,677 lines | the Forth kernel primitives are **hand-written x86-32 assembly, expressed in Forth** |
| `cpu/x86/assem.fth` — 893 lines | ...via an **x86 assembler written in Forth**, which has no 64-bit encodings |
| `cpu/x86/kerncode.fth:723` — `/l constant /n` | the cell is nailed to 4 bytes at the root of the metacompiler |
| `cpu/x86/mmu.fth` (311) + `cpu/x86/pc/paging.fth` | 32-bit paging, rewritten for 4-level from scratch |
| `grep -i 'long.mode\|x86-64\|amd64\|rax' cpu/x86/*.fth` | **one** hit, an unrelated MSR comment |
| `cpu/` = `arm i8051 mips ppc x86` | no 64-bit port of *any* target exists to copy from — even `cpu/ppc` is 32-bit-cell |
| HEAD is **2015-12-18** | there is no upstream to take the patch; whoever ports it owns it forever |

So the work is: write an x86-64 assembler in Forth, re-author the kernel
primitives against it, widen the cell through the metacompiler and every
`l@`/`l!` that assumes four bytes, and redo the MMU layer — with no reference
port and no upstream. That is a multi-month firmware project whose output is a
second, unmaintained 64-bit Forth system.

It is also, precisely, the one class of bitrot the sibling lab's thesis cannot
absorb. [`../open-firmware-forth-to-boot/`](../open-firmware-forth-to-boot/README.md)
argues that a frozen self-hosting firmware stays usable because you fix it
**live at its own `ok` prompt**. You can re-point a dead `defer` from the
prompt. You cannot retarget a CPU from it.

## What would travel free

The Forth vocabularies. [`../open-firmware-native-habitats/PORTING.md`](../open-firmware-native-habitats/PORTING.md)
already established that `ofdiag`'s diagnosis ladder ports across
*implementations* (OFW → OpenBIOS) because it is written against IEEE 1275
contracts — `expand-alias`, `find-package`, `open-dev`, `left-parse-string` —
none of which mention a cell width. A 64-bit OpenBIOS is a smaller step than
that one: same implementation, same dictionary source, wider cell. The place to
look for breakage is any word that assumes `/n = 4` (a literal `4 +` where `na+`
was meant), which is a grep, not a port.

## What the audit corrected

The verdict and the shape of the work survived the audit; these seven claims
did not, and per house style they are named rather than silently rewritten:

1. **The `defconfig` evidence row cited a file the build never reads.**
   `arch/amd64/defconfig` is referenced by nothing; the operative
   `config/examples/amd64_config.xml` actually *requests* a multiboot image.
   The corrected claim is stronger — the config asks and the build description
   can't answer — but the first version's evidence was the wrong file.
2. **"The only change since \[2016\] is a malloc-signature sweep in 2024" was
   false.** Four repo-wide sweeps touched the directory after 2016-08-26, not
   one. The substance (zero amd64-specific commits) holds.
3. **ppc64 was called a "shipping target"; it is in neither upstream CI nor
   QEMU's shipped set.** sparc64 carries the 64-bit-clean-core proof alone.
4. **"The `+0x200` entry instead of the zero-page dance" was wrong** — the
   zero page is mandatory at the 64-bit entry too; what's avoided is the
   64→32 mode drop. And **"five of the eight bugs" over-attributed**: the
   dance produced two (#6, #7).
5. **`-mcmodel=kernel` was the wrong memory model** for firmware
   identity-mapped at 1 MB; `-mcmodel=small -fno-pic` is correct.
6. **"The client interface is not consumed by Linux on x86 at all"
   overstated** — `arch/x86/platform/olpc/` is a real in-tree consumer, on
   32-bit OLPC hardware only.
7. **The "context.c + switch.S — 162 lines" row conflated files**: 162 was
   `context.c` alone; `arch/x86` has no `switch.S` (its context switch lives
   in `entry.S`); amd64's `switch.S` is 116 further lines.

## What this document did NOT prove

Restated after the audit, because the list changed — two of the original
bullets were discharged by measurement, and the measurement created new ones:

- **Nothing was linked, and nothing booted.** The census is compile-only:
  `switch.S` fails before `ld` ever runs, so the retargeted ldscript is
  unexercised and "compiles clean" has not been promoted to "links" for any
  file. Spike 1 owns that.
- **Compiling clean is not semantic correctness.** `segment.c`'s GDT entries
  are still 32-bit-era descriptors; `sys_info.c` passing the compiler says
  nothing about its tables being right in long mode. The census measures
  compile debt, deliberately nothing more.
- **The error counts are one compiler's.** gcc 13.3.0 with the build's own
  `-Werror` wall; a different gcc or clang would bin some diagnostics
  differently. The *categories* (drift / dead-API / pointer-width / illegal
  instructions) are compiler-independent; the integers are not.
- **The hosted build still needs a waiver.** `unix-amd64` fails on this
  host's gcc 13.3.0 (`-Werror=unused-result` in `arch/unix/unix.c:422`);
  every local build here carried `-Wno-error=unused-result`. A host-toolchain
  artifact (the lab's [`Containerfile`](Containerfile) pins its own), not a
  finding about the port.
- **Nothing was tested on real hardware.** Everything here is a build; QEMU
  was not involved in any command in this document.

## Provenance

| | |
|---|---|
| OpenBIOS | https://github.com/openbios/openbios @ `e5ac46d` (2026-06-29) — the same commit [README.md](README.md) pins |
| fcode-utils | https://github.com/openbios/fcode-utils @ `6e563ee` (2026-06-29) |
| OFW | https://github.com/openbios/openfirmware @ `d5cc657` (**2015-12-18** — HEAD) |
| first measured | 2026-08-18, gcc 13.3.0 (Ubuntu 24.04), rootless, no QEMU involved |
| audited + Spike 0 | 2026-08-18, same host and pins; `gcc-multilib` added for the x86 contrast build; spike patches in [`patches/`](patches/) |
