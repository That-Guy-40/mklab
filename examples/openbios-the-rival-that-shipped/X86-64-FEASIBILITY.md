# X86-64-FEASIBILITY.md — could this firmware run in long mode?

> **VERDICT: OpenBIOS — feasible, and the expensive half is already done.
> OFW — not feasible as a lab.**
>
> **Spike 1 is now RUN: the firmware reaches its own `0 >` prompt in long mode
> on bare metal, and `-1 u.` answers `ffffffffffffffff` there.** See
> [§ Spike 1, run](#spike-1-run-the-firmware-runs-in-long-mode--measured-2026-08-23).
>
> First written 2026-08-18 as a study; **audited the same day, and Spike 0 —
> which the first version explicitly had not attempted — has now been run.**
> The verdict survived. Nine claims did not survive unchanged; they are
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
| the one persistence story that needs long mode | a file-backed **pmem region**, measured at exactly `0x100000000` on `-M pc` — the only NVRAM backing a 32-bit firmware cannot address. CMOS, a drive file and pflash are all reachable in 32-bit today (whether they *work* is a separate question: the drive-file row has no write path at any layer). Long mode is the cheapest third of that story — ACPI discovery and the multiboot map filter block it in either mode. See *Persistence* below |
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
| **1 — the trampoline** ✅ **DONE** | apply the drift fixes + the bug-#1 header fix (both already written); rewrite `switch.S`; author the 32→64 stub; stub out `boot.c`/`linux_load.c` to get a link | `0 >` on the serial socket, and `-1 u.` answering `ffffffffffffffff` from the *bare metal* rather than from `openbios-unix` |
| **2 — context + exceptions** ⚠️ **half done** | the 64-bit context frame (`context.c`'s eight errors), a 64-bit IDT in a new `exception.c` | a deliberate `0 0 !` reports a named fault instead of triple-faulting; the client-program context still switches back to the prompt |
| **3 — boot Linux** | re-port `boot.c`/`linux_load.c` off the dead API (x86's twins show the shape), then the `+0x200` entry | the existing [`showcase-rival-boots-linux.sh`](showcase-rival-boots-linux.sh) success signature, unchanged, from the 64-bit firmware |
| **P0–P2 — persistence** | *(runs in parallel, on the 32-bit firmware — see [the persistence spikes](#the-persistence-spikes--a-ladder-that-does-not-wait-for-the-port))* | a config variable that survives a power cycle, asserted on the **host's** backing file |
| **P3 — the pmem store** | the only persistence work that needs long mode, and it depends on spike 1 | `/nvram` answering at a physical address ≥ `0x100000000` |

**Ordering.** Spikes 1–3 and P0–P2 are independent: the persistence rungs need
no 64-bit anything, and P3 needs spike 1 (a firmware that runs in long mode)
before it needs anything of its own. Doing P0–P2 first is the cheaper order —
it lands a working NVRAM on the firmware that already boots, so the port is not
being asked to debug two unfinished subsystems at once.

Known failure mode worth planning for in 1–2: a triple fault under
`-no-reboot` exits QEMU with **rc=0** ([POC-2](POC-2-OK-PROMPT.md)'s pitfall
list), so the harness must assert the prompt, never merely a clean exit.

## Spike 1, run: the firmware runs in long mode — measured 2026-08-23

The remaining-spikes table asked for `0 >` on the serial socket and `-1 u.`
answering `ffffffffffffffff` **from the bare metal** rather than from
`openbios-unix`. Both, from
[`patches/08-amd64-spike1-trampoline.patch`](patches/08-amd64-spike1-trampoline.patch):

```console
0 > 3 4 + . 7  ok
0 > -1 u. ffffffffffffffff  ok
0 > dev / ls
13a248 aliases
13a370 openprom
...
147a70 memory
147b98 cpus
149ef0 ide@0
 ok
```

`arch/amd64` had never produced a firmware image. This document's own measured
census recorded *"x86 answers with two firmware images. amd64 answers with
none."* It answers now, and it boots.

### The ten things that had to be true, in the order the machine insisted

The estimate said the work was the asm layer. It was — and then it was nine
other things, most of which are the same bug this lab keeps finding: **a
condition, a guard or a struct that names the targets somebody actually built.**

| # | what stopped it | why it is interesting |
|---|---|---|
| 1 | **`switch.S`** — 116 lines of 32-bit assembly in the 64-bit arch dir | replaced by a trampoline: PML4 identity-mapping the low 4 GiB with 2 MiB pages, `CR4.PAE`, `EFER.LME`, `CR0.PG`, far jump through an `L=1` descriptor |
| 2 | **SSE was not enabled** | SSE2 is *baseline* for x86-64, so gcc emits it unasked. The first fault was `#UD` on a `movups %xmm0` gcc generated to copy a 16-byte struct. Firmware has to opt in: `CR0.MP`, clear `CR0.EM`, `CR4.OSFXSR\|OSXMMEXCPT`, `fninit` |
| 3 | **the multiboot handoff was destroyed** | `%eax`/`%ebx` carry the magic and the info pointer, and building page tables is the first thing that clobbers them. The old code saved them by pushing a context frame that does not exist yet |
| 4 | **`multiboot.h` used `unsigned long` for wire-format structs** | 4 bytes on x86, **8 here** — every field after the first read at double its offset. A struct describing bytes somebody else wrote must name its widths |
| 5 | **`dict_end - dict_start` is pointer subtraction** | on `unsigned long *` that is an **eighth** of the byte count; the dictionary checksummed over ⅛ of itself. `arch/x86` casts to `char *` first |
| 6 | **`relocate()`** | see below — the biggest finding |
| 7 | **libgcc's 128-bit helpers were `condition="SPARC64"`** | directly under a comment reading `CONDITION="CONFIG_64BITS"`. Someone knew the right condition and hard-coded the only 64-bit arch that shipped. `dcell` is 128-bit on amd64 too |
| 8 | **`elf_load.c`'s ofmem guard** | `#if !defined(CONFIG_SPARC32) && !defined(CONFIG_X86)` — the list named the arches that were built |
| 9 | **`auto-boot?` defaulted true** | the firmware printed its banner, tried to boot nothing, and stopped **without a prompt** — which reads exactly like a hang and is not one |
| 10 | **QEMU appears to refuse an ELF64 multiboot image** | `Cannot load x86-64 image, give a 32bit one.` — and this turned out to be the most interesting item of the ten. It is one line deep, on the ELF path only, and the multiboot **a.out kludge** goes round it. QEMU boots this firmware as a real ELF64. See below |

### Item 10, re-investigated: QEMU's ELF64 refusal is real, narrow, and bypassable

The first draft of this section recorded that QEMU *"refuses an ELF64 multiboot
image"* and wrapped the image in ELF32 headers with `objcopy` to get past it.
That worked, and it was the wrong conclusion. **QEMU boots this firmware as a
64-bit ELF, unmodified.** What follows is why, because the answer corrects
something else in this document.

**The check exists and is exactly one line deep.** In `hw/i386/multiboot.c`:

```c
if (((struct elf64_hdr*)header)->e_machine == EM_X86_64) {
    error_report("Cannot load x86-64 image, give a 32bit one.");
    exit(1);
}
```

**It sits only on the ELF path.** When the multiboot header sets bit 16 — the
**a.out kludge**, declaring `load_addr`/`load_end_addr`/`bss_end_addr`/
`entry_addr` valid — QEMU takes the other branch, loads the file flat from
those addresses, and never parses the ELF at all. `e_machine` is never read.

That is not a trick. The Multiboot specification provides the address fields
precisely for an image *"in some other format"*, and to a 32-bit-only loader an
ELF64 is exactly that.

**Measured, with the kludge and no `objcopy`:**

```console
$ file obj-amd64/openbios.multiboot
… ELF 64-bit LSB executable, x86-64 …
$ qemu-system-x86_64 -M pc -m 512 -kernel obj-amd64/openbios.multiboot \
      -initrd obj-amd64/openbios-amd64.dict
Welcome to OpenBIOS v1.1 built on Aug 23 2026 23:21

0 >
```

The one prerequisite is that the loaded image be **contiguous in the file**, so
those addresses can describe it: `.initctx` moved ahead of `.bss` in the
ldscript, and `_load_end` marks the boundary.

#### This corrects "A known bug, waiting verbatim"

That section reads amd64's `MULTIBOOT_HEADER_FLAGS 0x00010003` as *"the exact
spec-invalid header that was bug #1"* of the x86 revival, with the one-line fix
travelling as-is. **Half of that is wrong, and it is the interesting half.**

- For **x86**, an ELF32, clearing bit 16 is right: the ELF path works and the
  address fields are redundant.
- For **amd64**, an ELF64, bit 16 is the **only** documented way past a loader
  that refuses the ELF path. The original header was reaching for the correct
  mechanism; it was invalid solely because its three-word struct carried **none
  of the five address fields the bit promises**.

Whoever wrote `0x00010003` into a 64-bit arch directory in 2006 may have known
exactly what they were doing. The fix is to *finish* that header, not remove it.

#### Why the refusal is there at all

Worth knowing before anyone files it as a QEMU bug — it is a **contested policy
choice**, not a technical limit:

| when | what |
|---|---|
| Aug 2010 | Adam Lackorzynski proposes the check: an x86_64 ELF supplied via `-kernel` "is being started in 32bit mode" |
| | Avi Kivity **objects** — `kvm-unit-tests` relies on the existing behaviour: 64-bit ELF binaries "loaded in 32-bit mode [that] switch immediately to 64-bit" |
| | Alexander Graf: *"I'm in full sympathy to stick to whatever grub does, as that's the reference implementation"* |
| Jan 2019 | [qemu#243](https://gitlab.com/qemu-project/qemu/-/issues/243) reports the refusal, noting the premise was mistaken: **both GRUB and Syslinux load 64-bit ELF kernels** |

GRUB loads an ELF64 whenever the physical load addresses fit in 32 bits. So the
check was adopted to match a reference implementation that does not behave that
way, over a live objection from a project doing the same thing this spike does.
Two patches to lift it (2010, 2017) went nowhere.

**None of which had to be litigated to boot this firmware** — the specification
already provided the door, and it was the one amd64's own header was pointing at.


### The finding that outranks the rest: relocation cannot survive the port

`arch/x86` relocates itself to the top of RAM by **rebasing the GDT data
segment** — copy the image, rewrite the base fields of the code and data
descriptors, `lgdt`, far-jump to reload `CS`. Every address Forth then hands
around is segment-relative, and `virt_offset` is what the CPU adds to reach
physical memory. (That mechanism is precisely why `load-base` had to be computed
in C: a constant in `nvram.fs` resolved to *physical + virt_offset* and landed
past the end of RAM.)

**In long mode, segment bases are ignored for CS, DS, ES and SS.** The
descriptor fields that code rewrites have no effect on address translation at
all, and `ljmp` does not even assemble. So this is not a routine that needs
porting — it is a **strategy that does not survive the port**. Spike 1 therefore
runs in place at the 1 MiB the loader chose, with `virt_offset = 0`, and says so
on the console every boot:

```
relocate: skipped (long mode ignores segment bases) -- running in place
```

A 64-bit firmware that wants to move itself must copy the image and then use
RIP-relative addressing or paging. That is a design change, not a port, and it
is the one item here that should be costed before anyone commits to Spike 2.

### What is stubbed, and why it halts rather than returns

`__switch_context` and `__exit_context` **halt**. Context switching between the
firmware and a client program is Spike 2's work, and a switch that silently did
nothing would hand control back with none of the state a switch is supposed to
have restored — corrupting whatever ran next, at a distance. `linux_load()`
likewise reports that it is stubbed rather than returning a quiet
`LOADER_NOT_SUPPORT`; re-porting it off the deleted `loadfs.h` API is Spike 3's.

### Kept honest by

`./smoke-openbios.sh amd64` asserts the prompt, the `ffffffffffffffff`, the
relocation-skip line and a device tree — **never a clean exit**, because a
triple fault under `-no-reboot` exits QEMU with `rc=0`, which this lab has
written down since POC-2 and which is exactly how the first broken trampoline
presented. Its control points the track at the 32-bit x86 image: the prompt
answers, and the cell assertion fails by name.


## Spike 2, first half: exceptions — measured 2026-08-23

The spike asks for two things: a 64-bit IDT so a fault is *named* instead of
triple-faulting, and a client-program context that switches back to the prompt.
**The first is done. The second is not**, and is still stubbed.

```console
0 > 0 100000000 !
Unexpected Exception: page fault @ 08:0000000000101d50
Code: 2  rflags: 0000000000010046
Faulting address: 0000000100000000
rax: 0000000000000000 rbx: 000000000018a240 rcx: 0000000100000000 …
dict=0x11f020 here=0x14d040(dict+0x2e020) pc=0x1880c8(dict+0x690a8)
dstackcnt=0 rstackcnt=22
```

Before this, `arch/amd64` had no IDT at all — the census recorded `exception.c`
as *"still to author from scratch"* — so the **first** exception was a triple
fault and the machine simply vanished. That is not hypothetical: it is exactly
how Spike 1's SSE bug presented, and it cost a debugging session to find.

**A 64-bit gate is sixteen bytes, not eight**, with the handler offset split
across three separate fields. An IDT built by the 32-bit routine looks
plausible and dispatches every vector into garbage, so `init_exceptions` is new
code rather than a port.

### The null-pointer trap that had to be given back

The checkpoint as written says `0 0 !`. The first attempt earned that literally:
the low 2 MiB was re-mapped as 4 KiB pages with **page 0 left absent**, so a
null write would fault. It faulted — during boot, before the prompt existed:

```
Unexpected Exception: page fault @ 08:00000000001034c3
Faulting address: 0000000000000000
rdx: 3f8   rsi: 3d5
```

Those two registers name the culprit. `0x3d5` is the VGA CRTC data port, and
the console finds its address by reading the **BIOS Data Area at 0x400–0x463**
— which is *inside page 0*. On a PC, page zero is not spare: it holds the
real-mode interrupt vector table and the BDA, and this firmware legitimately
reads the latter.

So a null trap is buyable, but the price is teaching the video code to stop
reading the BDA — a real change with a real benefit, and not this spike's
question. The identity map stays whole and the checkpoint faults **above 4 GiB**
instead, which demonstrates rather more: `0x100000000` is an address a 32-bit
firmware cannot even form.

### The known limit, stated rather than glossed

The machine **survives** the fault — it is named, dumped, and does not triple
fault — but the outer interpreter does **not accept further input** afterwards.
It prints ` ok` and stops listening: alive, and not listening.

The recovery mechanism is inherited from `arch/x86/exception.c`, which resets
the Forth stacks, points `PC` at `outer-interpreter` and returns through a
do-nothing function. Two observations, and the second is a claim rather than a
measurement:

- `arch/x86`'s version omits an offset the engine's own equivalent path keeps:
  `kernel/forth.c:686` reads `PC = findword("outer-interpreter") + sizeof(ucell)`
  — `findword()` returns the word's *header*, and the interpreter has to be
  entered at its *body*. Adding it here did not fix the wedge, so it is not the
  whole story, but the asymmetry is real.
- **That path has probably never been exercised on x86.** `arch/x86` runs
  unpaged with flat 4 GB segments, so provoking a fault at its prompt is
  genuinely difficult — a stray write goes to real memory and returns. This may
  be the first time the recovery has actually been asked to work.

`./smoke-openbios.sh amd64-fault` asserts the fault is named, that CR2 reports
`0x100000000`, and that the engine state is dumped — **and asserts the limit is
still the limit**, failing if the prompt ever does resume, so that fixing it
cannot slip by leaving a stale "known limit" in the record. Its control removes
the `init_exceptions()` call: the fault then produces no message at all and the
track fails, which is the shape this layer exists to end.

### Still open in Spike 2

`__switch_context` and `__exit_context` remain stubs that halt. Client-program
context switching — the checkpoint's second clause — is untouched, and the SSE
enable from Spike 1 adds a requirement to it: the xmm registers are now live, so
a switch must preserve them or the build must move to `-mgeneral-regs-only`.


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

## Persistence: what would back an NVRAM on x86-64 — measured 2026-08-23

Asked because the 64-bit port's clearest gain is *an honest device tree*, and the
obvious next question is whether that tree could carry a node whose **contents
outlive a boot**. The short answer: OpenBIOS x86 has no NVRAM at all today; only
one of the four ways to give it one has anything to do with long mode; and that
one is *also* the only one blocked by two things that have nothing to do with
long mode.

### Today: the package is compiled and never instantiated

| evidence | what it says |
|---|---|
| `nm obj-x86/libpackages.a` | `nvram_init` **is** in the x86 build — `packages/nvram.c` is compiled unconditionally |
| `grep -rn nvram_init --include='*.c'` | its only callers are `arch/ppc/pearpc/init.c`, `arch/ppc/mol/init.c` and `drivers/macio.c`. **No x86 caller** |
| `grep arch_nvram_*` over **`*.c` only** | said "defined only in three ppc files; x86 and amd64 define none" — **and that was wrong about x86**, see the row below. It is also incomplete on the other side: `arch/ppc/pearpc/pearpc.c`, `drivers/obio.c` (sparc32) and `arch/sparc64/openbios.c` define them too |
| the same grep including **`*.S`** | `arch/x86/entry.S:306` defines **all three** — `.globl arch_nvram_size, arch_nvram_get, arch_nvram_put`. They are not missing. They are **stubs that lie**: `size` is `xor %eax,%eax` (returns 0) and `get`/`put` are a bare `ret`. A caller would get silent success and an empty store. Nothing noticed for years because nothing called `nvram_init()`. amd64 defines none — it has no `entry.S` at all |
| live `dev / ls` (multiboot, QEMU) | `aliases openprom options chosen builtin packages pci8086,1237@0 ide@0..3 console` — **there is no `/nvram`** |
| live `devalias` | prints nothing: no aliases are defined |
| live `dev /options .properties` | exactly three: `name`, `screen-#columns`, `screen-#rows` |
| live `nvramrc` | the **word exists** — it pushes a string (the prompt goes `0 >` → `2 >`) |

That last pair is the distinction worth holding: the *config-variable vocabulary*
from `forth/admin/nvram.fs` is in the dictionary and answers, while the *device*
that would give it a backing store does not exist. Every value it returns is
dictionary state, so a reset loses all of it. **Bug #3 (`load-base`) was about that
vocabulary, not about storage** — and the boot log still prints
`vga-driver-fcode:load-base isn't unique.`, which is the fix meeting an existing
definition.

So "add NVRAM to x86" is precisely: **replace** three lying stubs, call
`nvram_init(path)` once, and decide what the three functions talk to. That last
decision is the whole problem — and the stubs are the reason the missing piece
was never visible: a firmware whose NVRAM hooks return success is
indistinguishable, from the inside, from one that has no NVRAM.

**This is [CLAUDE.md](../../CLAUDE.md)'s *fix the liar first* in the subject
rather than in the tooling**, and it was found the only way it could be — by
building. The `.c`-only grep in the row above is the cheap check: a question
about *symbols* answered by searching one language.

### The contract all four have to satisfy

Before comparing them, read what `packages/nvram.c` actually asks its arch for
([`include/arch/common/nvram.h`](https://github.com/openbios/openbios/blob/master/include/arch/common/nvram.h)):

```c
extern int  arch_nvram_size( void );
extern void arch_nvram_get( char *buf );
extern void arch_nvram_put( char *buf );
```

**No offset, no length — `get` fills a buffer with the whole store and `put`
writes the whole store back.** That is easy for something memory-mapped and
awkward for anything that has to be seeked to, and it is the single fact that
reorders the table below.

The *format* matters too, and it is not a flat byte array: `nvram.c` implements
the **Mac partitioned NVRAM** — a 16-byte header per partition (checksummed over
bytes 2–15), lengths counted in **16-byte granules**, free space named
`77777777777`. Size references from the targets that actually run it:
`briq` declares `static char nvram[2048]`, and new-world macio reports
`NW_IO_NVRAM_SIZE 0x00004000` — **16 KiB**.

### The four candidate backings, re-graded against that contract

| backing | survives firmware reset | survives an OS boot / power cycle | reachable in 32-bit | code missing today |
|---|---|---|---|---|
| **CMOS/RTC, 128 bytes** | yes | **no** — QEMU offers no file backing | yes | a CMOS driver, and the format does not fit |
| **A file on an attached drive** | yes | yes | yes | for a *file*, a write path at five layers; for **raw sectors**, one — see the reframe below |
| **`-drive if=pflash`** | yes | yes | yes — vars unit at `0xffbe0000` | a small CFI driver, plus a 4 MiB pflash0 image — **configuration booted** |
| **NVDIMM / pmem** | yes | yes | **no — measured at `0x100000000`** | ACPI discovery, a memory-map fix, *then* long mode |

Only the last row needs the port — and row 3 has been booted, so the recommended
order is not the order the table is written in. What follows is what each row
costs.

#### 1. CMOS/RTC — the one that is genuinely "the PC's NVRAM", and it is a dead end

QEMU's RTC takes exactly three options, and none of them is a file:

```
rtc options:
  base=<str>
  clock=<str>
  driftfix=<str>
```

So it survives a firmware reset and nothing else — which fails the only survival
that motivated the question. It is also far too small: 128 bytes is **8 granules**,
one 16-byte partition header leaves **112 bytes** for the entire store, against
briq's 2 KiB and macio's 16 KiB. `nvramrc` alone is meant to hold a Forth
program.

And there is no driver to extend: the whole x86 tree touches ports `0x70`/`0x71`
**once**, and not as storage —

```c
arch/x86/linux_load.c:570:    outb(0x80, 0x70);
```

— which is the NMI-disable idiom on the way out to Linux, not a CMOS access.

#### 2. A file on an attached drive — the row that looked easiest and has the most missing code

This is what OFW actually does: its `pseudo-nvram` is *a file on a drive*, the odd
one out in [`../open-firmware-debugs-itself/DELIVERY-MECHANISMS.md`](../open-firmware-debugs-itself/DELIVERY-MECHANISMS.md)'s
comparison table, because a generic PC gives firmware no NV region it can own, so
it borrows a filesystem.

The first draft of this table graded it *easy* on the reasoning that "OpenBIOS x86
already has `ide@0..3` nodes to build on." That is this repo's standing mistake in
miniature — **nodes to build on is not a question about writing.** Asking the
real question, layer by layer:

| layer | methods it exports | write? |
|---|---|---|
| `drivers/ide.c` (the disk node) | `open close read-blocks block-size max-transfer dma-*` | **no `write-blocks`** |
| `packages/pc-parts.c` (the x86 partition package) | `probe open seek read load dir get-info block-size` | **no `write`** |
| `packages/disk-label.c` | `load read write seek tell dir` | present, and a **stub**: `dlabel_write` drops its argument and pushes `-1` |
| `packages/deblocker.c` | `read write seek tell` | a real implementation — which forwards to a parent `write` the IDE node does not have |
| `fs/` — ext2, grubfs, iso9660, hfs, hfsplus | consumers only | **none registers a `write` method** |

So the stack is read-only from the filesystem down to the ATA command layer. This
lab has already booted a client program off ext2, which proves the *read* half
end to end and says nothing about the other one. Writing a file back means
implementing `write-blocks` in the IDE driver, a `write` in `pc-parts`, replacing
the `disk-label` stub, and teaching one filesystem to write — and the
whole-image `arch_nvram_put` contract means it must be a full rewrite of the
region every time, so no append trick shortens it.

#### 3. `-drive if=pflash` — the best fit for the contract, and the one configuration that has actually been booted

Measured on QEMU 8.2.2, `-M pc`, with both units attached:

```
00000000ffbe0000-00000000ffbfffff (prio 0, romd): system.flash1
00000000ffc00000-00000000ffffffff (prio 0, romd): system.flash0
```

A **128 KiB vars store at a fixed `0xffbe0000`**, directly below the 4 MiB code
unit, both squarely inside the 32-bit address space — and eight times macio's
16 KiB, so the format has room to spare. This is the EFI-shaped answer
(`OVMF_VARS.fd` is precisely this pairing): a real NV region the firmware owns
rather than borrows.

**The `-kernel` boot path and pflash0 are mutually exclusive in practice**, which
is not what the command line says. QEMU accepts `-kernel` alongside a pflash0
without a murmur — that is the cheap check — so the question had to be asked by
booting. Baseline against variants, same tree, same command shape:

| configuration | last lines on the serial console |
|---|---|
| `-kernel openbios.multiboot` (the lab's path today) | `Welcome to OpenBIOS v1.1 …` then `0 >` |
| + `-drive if=pflash,file=<4 MiB of zeros>,unit=0` | **nothing at all** |
| + a `unit=1` vars image as well | **nothing at all** |

pflash0 *is* the BIOS: supplying an empty one removes the SeaBIOS that loads the
multiboot image in the first place, and the machine goes dark. (The passing
baseline is the control — without it, "no output" would be indistinguishable
from a broken harness.)

Populate it and the configuration works. SeaBIOS written to the **top** of a
4 MiB image, so the reset vector lands in it, with the vars unit beside it:

```console
$ truncate -s 4M seabios-flash.img
$ dd if=/usr/share/seabios/bios.bin of=seabios-flash.img bs=1 \
     seek=$(( 4*1024*1024 - 131072 )) conv=notrunc
$ truncate -s 128k vars.img
$ qemu-system-i386 -M pc -m 256 -display none -serial stdio \
     -kernel obj-x86/openbios.multiboot -initrd obj-x86/openbios.dict \
     -drive if=pflash,format=raw,file=seabios-flash.img,unit=0 \
     -drive if=pflash,format=raw,file=vars.img,unit=1
vga-driver-fcode:load-base isn't unique.
Welcome to OpenBIOS v1.1 built on Jul 23 2026 03:04

0 >
```

So row 3 is buildable today, on the 32-bit firmware, and the boot-path change it
costs is **one 4 MiB image, measured, not guessed**.

**One correction to make before anyone writes the code**: an earlier draft of this
section said `arch_nvram_get`/`put` would be "two `memcpy`s against a fixed
address." The read half is right; the write half is not, and `romd` in the
mapping above is the tell — a ROM-device region serves reads straight from the
backing but sends **writes to the device model**. Asked directly:

```
dev: cfi.pflash01, id ""
  sector-length = 4096 (0x1000)
  width = 1 (0x1)
```

`cfi.pflash01` is the **Intel command set**, so `arch_nvram_put` is an unlock /
block-erase / program / poll-status / read-array sequence over 4 KiB sectors at
one byte per bus cycle — 32 sectors for a whole-store rewrite, which the
no-offset contract makes mandatory every time. And there is nothing to reuse:
grepping the tree for a CFI or flash driver finds **none** — only a PCI class
string in `pci_database.c` and macio's `compatible = "nvram,flash"` property.
That small driver, not the three functions, is the real content of row 3.

#### 4. NVDIMM / pmem — measured above 4 GB, and long mode is the *third* blocker, not the first

The placement is no longer a design claim. `-M pc,nvdimm=on -m 512,slots=2,maxmem=2G`
with a 64 MiB `memory-backend-file`, asked over the monitor:

```
Memory device [nvdimm]: "nv1"
  addr: 0x100000000
  slot: 0
  size: 67108864
```

**Exactly 4 GiB** — and identically under `qemu-system-i386` and
`qemu-system-x86_64`. QEMU's device-memory window starts there *by construction*,
not because the guest is large: a 512 MiB guest with `maxmem=2G` still puts it at
`0x100000000`. There is no "keep the machine small" escape hatch, which is what
makes this row a real argument for the port.

But long mode is **necessary and nowhere near sufficient**. Three blockers stack
up, and only the last is about mode:

1. **Discovery.** An NVDIMM is advertised through ACPI (the NFIT). Grepping the
   whole tree for ACPI finds **no parser** — every hit is the *Linux boot
   protocol's* own `e820entry` / `E820_ACPI` constants in
   `arch/x86/linux_load.c` and its sparc32 twin. OpenBIOS never looks for an RSDP.
2. **The map it does read throws the range away.** `arch/x86/multiboot.c` keeps
   one type and drops the rest:

   ```c
   if (mbmem->type == 1) { /* Only normal RAM */
   ```

   which is where a persistent-memory range would arrive.
3. **Two explicit 4 GiB truncations in the x86 code**, both in the source
   verbatim — `set_memory_size()` in `linux_load.c`:

   ```c
   if (end < (1ULL << 32)) { /* don't count memory above 4GB */
   ```

   and `arch/x86/segment.c:61`:

   ```c
   if (info->memrange[i].base >= 1ULL<<32)
       continue;
   ```

Blockers 1 and 2 are work you would do in **either** mode. So the honest form of
the headline is: *a pmem NVRAM is the only backing that long mode unlocks, and
long mode is the cheapest third of it.*

### The reframe: `arch_nvram_*` never touches the filesystem stack

Everything above about row 2 answers the question *"can OpenBIOS write a **file**?"*
— and NVRAM never asks it. The five read-only layers are real, and they are
**irrelevant to this contract**: `arch_nvram_get`/`put` are *arch* code. They do
not go through the device tree, `disk-label`, `pc-parts`, or a filesystem. The
ppc implementations prove it — macio's is plain MMIO against a hardware window,
with no package in sight.

What the contract actually needs is **raw bytes at a fixed place**. That deletes
four of row 2's five layers and leaves exactly one: *can this driver put a
sector back?* Asked that way, the backings re-grade — and the recommendation
inverts.

| backing | data path | what is actually missing | new subsystems |
|---|---|---|---|
| **IDE, raw sectors** | PIO — and `ob_ide_pio_outsw` is **already used to send bulk data** (the ATAPI packet path, `ide.c:560`) | `WIN_WRITE 0x30` in `ide.h`, and an `ob_ide_write_ata` mirroring the 16-line `ob_ide_read_sectors` | **none** |
| **Floppy, raw sectors** | PIO — the driver polls `STATUS_NON_DMA`, so no ISA DMA controller is involved | flip a config switch; author a write path; add an ED geometry for 2.88 MB | the FDC |
| **pflash / CFI** | MMIO | a CFI driver written from scratch; the 4 MiB pflash0 image | CFI, plus a boot-path change |

**IDE is the cheapest by a clear margin**: no new bus, no config switch, no
boot-path change, and its read twin is the code this lab already boots a client
program with. `ide.h` defines `WIN_READ`, `WIN_READ_EXT`, `WIN_IDENTIFY`,
`WIN_PACKET` and `WIN_IDENTIFY_PACKET` — **no write command at all** — so the
delta is a constant and one function whose mirror image is sixteen lines away.

The natural shape is a **dedicated small `-drive if=ide` image whose entire
contents are the store**: no partition table, no filesystem, nothing for the
read-only stack to be read-only about. That is OFW's borrow-a-file idea with the
filesystem removed.

#### The floppy, graded

Worth its own note, because it is the option that looks most like OFW's and
because the repo already has form here — [`floppinux-2.88mb/`](../tiny-linux-experiments/floppinux/floppinux-2.88mb/)
boots QEMU with `fd0 is 2.88M`, verified end to end.

The good news is better than expected: **OpenBIOS ships a full 1,185-line FDC
driver, and x86 already calls it** —

```c
/* arch/x86/openbios.c:202 */
#ifdef CONFIG_DRIVER_FLOPPY
	ob_floppy_init("/isa", "floppy0", 0x3f0, 0);
```

— behind a switch that is **off for x86 and on for both sparcs**:

```
config/examples/x86_config.xml:62:     CONFIG_DRIVER_FLOPPY  value="false"
config/examples/sparc32_config.xml:69: CONFIG_DRIVER_FLOPPY  value="true"
config/examples/sparc64_config.xml:67: CONFIG_DRIVER_FLOPPY  value="true"
```

That is the same shape as [`../open-firmware-debugs-itself/`](../open-firmware-debugs-itself/README.md)'s
x86 `pseudo-nvram` finding: **a disabled switch, not absent code.**

Two corrections to expectations, both measured:

- **It is 1.44 MB, not 2.88.** The driver hard-codes a single geometry, `H1440` —
  `SECT 18`, `HEAD 2`, `TRACK 80` = 2880 *sectors* × 512 B = **1.44 MB**. There
  is no extended-density row, so 2.88 MB means adding one (36 sectors/track, a
  500 kbps→1 Mbps rate change). Not a blocker in the slightest: 1.44 MB is
  already **92×** macio's 16 KiB, and the store needs kilobytes.
- **There is no dormant write path.** `FD_WRITE 0xC5` is defined at
  `floppy.c:100` and **referenced nowhere else in the file** — a constant carried
  over from the Linux driver this one descends from. The method table exports
  `open close read-blocks block-size max-transfer`, the same read-only shape as
  IDE.

So the floppy is a real option and a good one for *fidelity* — it is the most
period-correct answer, and a 1.44 MB image is a thing a human can mount and read
on the host. It is simply not the cheapest, because IDE needs no switch and no
new controller.

### The persistence spikes — a ladder that does not wait for the port

The single most useful consequence of the table above is a scheduling one:
**three of the four backings are 32-bit-reachable, so persistence is not blocked
on long mode.** It can be built, and each rung proved, on the firmware this lab
already boots — which also means the eventual 64-bit port inherits a *working*
NVRAM instead of debugging two unfinished things at once.

Each rung keeps an observable checkpoint, per the repo's learning-path rule, and
each one's checkpoint is chosen to be an **outcome rather than a mechanism** —
"the bytes on the host changed", not "the word returned what I set".

| rung | work | observable checkpoint | mode |
|---|---|---|---|
| **P0 — a node that exists** ✅ **DONE** | implement `arch_nvram_size/get/put` in `arch/x86` over a plain static buffer; call `nvram_init()` once | `dev / ls` lists **`nvram`**, and `dev /nvram .properties` answers — the exact probe that comes back without it today | 32-bit |
| **P1 — survives a firmware reset** ✅ **DONE** | `WIN_WRITE 0x30` + an `ob_ide_write_ata` mirroring the read twin; a dedicated raw `-drive if=ide` image as the store | set a config variable, then **`cmp` the host's image before and after** — it must differ | 32-bit |
| **P2 — survives an OS boot, then a power cycle** ✅ **DONE** | nothing new — P1's store, exercised | set a value, boot Linux with the existing [`showcase-rival-boots-linux.sh`](showcase-rival-boots-linux.sh), exit QEMU entirely, start a **fresh process**, read it back | 32-bit |
| **P3 — the pmem store** | an NFIT reader (or, as a first step, a hard-coded region); lift `multiboot.c`'s type-1 filter; then the 64-bit addressing | `/nvram` answering at a physical address **≥ `0x100000000`**, with the backing file changing on the host | **needs the port** |

#### P0 — RUN, and it passes

[`patches/04-x86-nvram-p0.patch`](patches/04-x86-nvram-p0.patch) (applied by hand
on top of `01-x86-revival.patch`, exactly like spikes 02/03) does three things:
deletes the lying stubs from `entry.S`, implements the hooks over an 8 KiB static
buffer in `arch/x86/openbios.c`, and calls `nvram_init("/")` + `nvconf_init()`.

The checkpoint, driven over the serial socket by the lab's own
[`tools/drive-serial-repl.py`](../../tools/drive-serial-repl.py):

```console
0 > dev / ls
127c10 aliases
127cb4 openprom
127e5c options
127ed4 chosen
127f84 builtin
12da24 packages
130320 pci8086,1237@0
131a1c ide@0
131ce4 ide@1
1323f4 ide@2
1326bc ide@3
132984 console
132af0 nvram
 ok
0 > dev /nvram .properties
name                      "nvram"
 ok
```

Compare the same probe recorded before the code existed, at the top of this
section: identical down to `console`, and then it stopped. **The negative control
was measured first, and it is what makes this line mean anything.**

Two things the boot log shows on the way, both predicted from reading
`nvconf_init()` and both worth keeping:

```
vga-driver-fcode:invalid nvram partition length
nvram error detected, zapping pram
```

A zeroed store fails the partition scan, `zap_nvram()` formats it (a free part
plus an `NV_SIG_SYSTEM` "common" partition), and the `for(;;)` retry terminates
on the second pass. **That message appears on every boot, and that is the point**
— the buffer is volatile, so the store is blank every time. P0 persists nothing
by design, and this line is the standing proof of it: when P1 lands, it must stop
appearing. It is P2's control, visible from the first run.

Sized 8 KiB because `nvconf_init()` asks for a `DEF_SYSTEM_SIZE` of `0xc10`
(3,088 bytes); anything smaller is silently clamped by `create_nv_part()` — which
is what happens to briq's 2,048.

**Two things P0 does not claim.** The node's `open` method is
`nvram_open() { RET(-1); }` upstream — it exists and refuses — so nothing has
opened this device; and `#bytes`, which macio publishes, is not set here, so
`.properties` shows only `name`. Both are P1's business.

#### P1 + P2 — RUN, and they pass

[`patches/05-x86-nvram-p1-ide-backing.patch`](patches/05-x86-nvram-p1-ide-backing.patch)
gives the store a real backing, and the reframe above is what made it small:

| layer | change |
|---|---|
| `drivers/ide.h` | `WIN_WRITE 0x30` — **absent upstream**, which defined only `READ`, `READ_EXT`, `IDENTIFY`, `PACKET`, `IDENTIFY_PACKET` |
| `drivers/ide.c` | `ob_ide_pio_data_out()` — the mirror of `data_in`, identical up to the transfer, because `ob_ide_pio_outsw` already existed and was already used by the ATAPI packet path |
| `drivers/ide.c` | an LBA28 write, and a by-number drive registry: the channels are `malloc`'d inside `ob_ide_init()` and kept nowhere a caller could reach, so `arch_nvram_*` had nothing to talk to |
| `arch/x86/openbios.c` | `get`/`put` read and write **raw sectors on ide@3** |

**Nothing in `disk-label`, `pc-parts` or `fs/` is touched.** They are still
read-only, and none of them is in the path — which is the reframe made concrete.

Two deliberate refusals, both *before* the irreversible step:

- **The write path refuses anything outside LBA28** rather than silently falling
  through to a CHS or LBA48 path nobody has exercised.
- **The store refuses a drive that is carrying someone else's data.** It accepts
  a blank first 8 KiB or one already bearing `nvram.c`'s partition names, and
  otherwise keeps the volatile buffer and says so on the console. Pointing this
  at a real boot disk would eat it, and a gate after the `write` is a post-mortem.

The write also waits for `READY` with no error before reporting success —
otherwise "the write succeeded" is a claim about the **bus**, not about storage.

##### The checkpoint, and why the control is half of it

`./smoke-openbios.sh persist` boots three times:

1. **write** — `setenv boot-file <nonce>`, then
   `" /nvram" " update-nvram" execute-device-method`, which answers `-1`; the
   host image's sha256 must change.
2. **read back** — a **brand-new QEMU process**, same image: the nonce must be
   there, and `zapping pram` must *not* (the store has to arrive already valid).
3. **control** — the identical boot with **no drive attached**: the nonce must be
   absent, and the firmware must say `no drive at ide@3`.

Step 3 is not decoration. The first hand-run of this check used `auto-boot?`,
whose x86 default is **already `false`** — so it "passed" while measuring the
default, and the control printed the identical line, which is the only reason it
was caught. Hence the nonce, which no default can equal.

All three assertions were then watched to bite, by planting the defect:

| planted defect | verdict |
|---|---|
| wipe the image between write and read-back | `FAIL: REGRESSION: boot-file did not survive a power cycle` |
| restore the image after the write, so the write reports success and lands nothing | `FAIL: REGRESSION: update-nvram reported success and the host image is byte-identical` |
| give the "no drive" control a drive | `FAIL: REGRESSION: the control saw <nonce> with no drive attached — this check cannot fail` |

##### P2's other half: a power cycle with an **OS in between**

The three survivals this section separates are not the same question, and the
ladder had only answered two of them. `qemu exit; qemu start` never asks the
third: **while an OS runs, it owns the machine** — it enumerates the disks, and
anything it decides to reuse is gone.

`./smoke-openbios.sh persist-os` boots three times: write the store, **boot
Linux**, read it back.

```
0 > printenv boot-file
boot-file                 "OS-SURVIVED"
```

— after a full `boot /ide@1/cdrom@0:\vmlinuz … initrd=…` into u-root, with no
`zapping pram` on the way back. The store survived.

**The assertion that makes it mean something is not the banner.** An OS that
booted but never saw the disk has not spared it; it simply never met it. So the
track reads the kernel's own enumeration out of the boot log:

```
ata2.01: ATA-7: QEMU HARDDISK, 2.5+, max UDMA/100
ata2.01: 2048 sectors, multi 16: LBA48
```

**2048 sectors is 1 MiB — this track's store, not any disk.** Binding the
assertion to the size is what stops it passing on a machine that happened to
have some other drive attached. And reading it from the kernel log means no
interactive shell has to be driven, which matters: u-root's shell opens by
querying the terminal (`ESC]10;?`, `ESC[6n`, then `ESC]11;?`) and blocks until
something answers, so scripting it is a chain of escape replies that would rot
the first time the shell changed.

**Both writable backings were run through it**, and the two claims are not equally
strong — which the track says out loud rather than flattening:

| track | survives an OS boot | did the OS *see* the store? |
|---|---|---|
| `persist-os` (ide@3) | **yes** | **yes, asserted** — the kernel enumerated it by size |
| `persist-os-flash` (pflash) | **yes** | **not shown** — Linux does not enumerate a vars pflash as a block device |

The flash row is weaker *on purpose and by construction*: a region the firmware
**owns** is one the OS never meets. That is the backing's whole appeal, and it
also means that run proves *"survived an OS boot"*, not *"survived an OS that
could have clobbered it."* The IDE row is the one that shows the second thing,
and it is the one to cite when the question is whether the bytes are safe from a
running system.

Three controls, planted and watched:

| planted defect | verdict |
|---|---|
| run the **flash** track against the IDE store | `this track measures pflash@0xffbe0000 but the write boot reported: nvram: backed by ide@3` |
| wipe the store between the OS boot and the read-back | `REGRESSION: boot-file did not survive a boot with an OS in between` |
| run the OS phase with the store **not attached** | `the kernel never enumerated an ATA disk — this run does not answer the OS-in-between question` |
| never boot Linux at all | `Linux did not reach u-root, so no OS ever owned the machine and this track measured nothing` |

The second and third are the ones that matter: without them this track silently
degrades into `persist` with a longer runtime, and would keep reporting a pass
for a question it had stopped asking. (A fourth attempt at the third control
failed to inject and the script ran **unmodified** — reported here because a
control that did not modify its subject is a green tick that proves nothing, and
that is exactly the failure mode this table exists to rule out.)

##### A second backing, and why it had to be an unlike one

[`patches/06-x86-nvram-cfi-flash-backing.patch`](patches/06-x86-nvram-cfi-flash-backing.patch)
adds **CFI flash** beside the IDE store. Two backings that failed the same way
would be one data point, so this one is deliberately unalike: IDE is a PIO block
device reached through I/O ports; this is **memory-mapped** flash at physical
`0xffbe0000` — QEMU's `cfi.pflash01`, Intel command set, 4 KiB sectors, byte-wide.

Selection is a **runtime probe, not a build option**: a CFI query either answers
`QRY` or it does not. Flash first, then `ide@3`, then a volatile buffer — and the
firmware prints which one it got:

```
nvram: backed by pflash@0xffbe0000
```

That line is what the test asserts on, and the reason is specific: with both
attached, flash wins, so a "flash" run could otherwise pass while quietly
measuring the IDE store. The control for that was planted and watched to bite —
`FAIL: this track measures pflash@0xffbe0000 but the firmware reported: nvram:
backed by ide@3`.

**Two traps this backing hits that the block device did not**, and both were
already written down in this repo before they were met:

- **`romd` means reads come from the backing and writes do not.** A write is
  unlock / block-erase / program / poll-status, not a store. This document's own
  earlier draft called `get`/`put` "two `memcpy`s"; the read half was right.
- **The address must go through `phys_to_virt()`.** `arch/x86` relocates itself
  by rebasing the GDT data segment, so a constant physical address used raw
  lands somewhere else entirely — the same trap that made `load-base` read back
  as zeros while every byte count looked correct.

`./smoke-openbios.sh persist-flash` runs the identical three-boot shape as the
IDE track, against `-drive if=pflash,unit=1`. It has to build a **populated**
`unit=0` first — SeaBIOS at the top of a 4 MiB image — because pflash0 *is* the
BIOS on `-M pc`, and an empty one removes the thing that loads the multiboot
image. That was measured earlier in this section and is now automated.

##### The third backing: a floppy, and it is half done

[`patches/07-x86-floppy-backing.patch`](patches/07-x86-floppy-backing.patch).
Reported as half done because that is what it is — and the half that works cost
a real upstream bug to find.

**Flipping the switch was the easy part.** `CONFIG_DRIVER_FLOPPY` is `false` for
x86 and `true` for both sparcs, and `arch/x86/openbios.c` already called
`ob_floppy_init`. Flipped, the node appears as `floppy0@0` and the controller
identifies itself: `FDC is a S82078B`.

**The read then failed, and the reason is worth keeping.** Debug output showed
`bytes_read = 9216` — the entire track had transferred correctly — followed by
`ret = -1`. The result bytes said `ST0=0x04 ST1=0x00 ST2=0x00`: **normal
termination**, on head 1. And `read_ok()` compares ST0's head field to the
**requested** head:

```c
if (((results[0] & ST0_HA) >> 2) != head)
        result_ok = 0;
```

But `floppy_read_sectors()` sets the **MT (multi-track)** bit whenever the
geometry has two heads — so the transfer starts on head 0 and legitimately
*finishes* on head 1. The driver enables MT and then validates as though it
had not. Every multi-track read was judged a failure after succeeding.

It never bit anyone because the switch was off: **a disabled switch hiding a
broken path**, which is the same shape as this lab's `pseudo-nvram` finding and
as the `arch_nvram_*` stubs two rungs ago. Fixed by accepting the requested head
*or* the last one, and `./smoke-openbios.sh floppy` guards it — its control
re-injects the strict comparison and the track fails by name.

**The write is KNOWN-BLOCKED, and stated as such rather than fudged.** All 512
bytes of a sector transfer (`sent 512 of 512`); the controller then sits at
status `0x30` (`BUSY|NON_DMA`) through 200,000 polls, never turning the bus
around, so `result()` reads no status bytes and returns `-1`. The bytes go out
and the completion never comes back. The read path works on the same controller,
so this is specific to the non-DMA write turnaround.

What was fixed is the *dishonesty*, not the gap:

| before | after |
|---|---|
| an **unbounded** `do { } while (status != READY\|NON_DMA)` copied from the read path — the firmware hung silently, the store's first sector on disk and the machine mute until the harness killed it | bounded waits, a named `floppy: write never entered execution phase` message, and `nvram: WRITE FAILED to floppy0` from the arch layer |

And one bug in that path *was* mine: the read's result loop drains `FD_DATA` to
clear FIFO residue, and copying it verbatim into the write **ate the result
bytes** — a failure the cleanup manufactured. Removed.

**A second unbounded wait, found by the other tracks going red.** Enabling the
driver made every boot *without* a floppy attached hang silently, right after
`vga-driver-fcode:` — because `floppy_read_sectors()`'s execution-phase wait is
an unbounded `do/while` upstream, and with no media the controller never enters
that phase. Four green tracks turned red the moment the patch landed, which is
exactly what they are for; an ad-hoc check of only the floppy would have shipped
a firmware that hangs on every machine with an empty drive. Bounded, and the
read now returns `-1` so the arch layer falls through to the volatile buffer.

**Also: it is 1.44 MB, not 2.88.** The driver hard-codes a single geometry
(`H1440`: 18 sectors × 2 heads × 80 tracks). 2.88 MB would need an
extended-density row. Immaterial to the store, which needs kilobytes.

So the ladder's floppy variant stands at: **read proven, write blocked, failing
honestly.** `persist-floppy` is deliberately *not* shipped as a permanently-red
track — the `floppy` track asserts the read works *and* that the write gap is
still the gap, so that closing it does not slip by unnoticed.

##### The refusal gate, watched firing

The store refuses a drive carrying someone else's data. That gate was written
before it was tested, which makes it a claim rather than a guarantee, so it was
aimed at 1 MiB of `/dev/urandom`:

```
nvram: ide@3 holds data that is not an nvram store -- refusing to write to it
nvram: not backed -- this change will NOT survive a reset
```

and the foreign image came back **byte-identical**. The refusal happens on the
read, before any write is attempted — a gate after the write is a post-mortem.

##### The harness's own bug, caught on its first regression run

The `nvram` track originally derived its expectation with
`git apply --reverse --check patches/04`, i.e. *"is exactly that diff present"*.
It broke the moment P1 edited the same file: P0 was still in effect, the node was
still there, and the check insisted it should be absent. **A patch is a diff,
which is a cache of a state.** Both tracks now derive from the *cause* — whether
`arch/x86/openbios.c` calls `nvram_init(`, and whether it calls
`ob_ide_write_blocks_nr` — which survives later patches to the same file.

Three notes on why the rungs are cut here and not elsewhere:

- **P0 is worth its own rung even though it persists nothing.** It is the step
  that turns *"the vocabulary answers while the device does not exist"* into its
  opposite, and it is the only rung whose before-picture has already been
  measured — the `dev / ls` output at the top of this section **is** P0's
  negative control, recorded before the code exists.
- **P1's checkpoint deliberately ignores the Forth.** Reading a variable back
  inside one firmware session proves nothing about storage: dictionary state
  answers identically, which is precisely today's illusion. The assertion has to
  land on the host's file.
- **P2 needs no new code, and that is the point.** If P1 is real, P2 is free; if
  P2 fails after P1 passed, the store is RAM-shaped and P1's checkpoint was
  measuring the wrong thing. It is P1's control as much as its successor — and
  a RAM-backed P0 must **fail** P2, which is the way to find that out cheaply.

**P1 deliberately picks the cheapest backing, not the most interesting one.**
The other two stay on the table as *variants* of the same rung, each buying
something the raw-IDE store does not, and each costing exactly one thing:

| variant | what it buys | what it costs |
|---|---|---|
| **floppy** ⚠️ **half done** | period fidelity, and a 1.44 MB image a human can mount on the host | switch flipped and **read proven** (an upstream MT bug fixed); the **write is known-blocked** on QEMU's FDC — see below |
| **pflash** ✅ **DONE** | a region the firmware *owns* rather than borrows — the EFI shape | a CFI driver; the 4 MiB pflash0 image — both built, see below |

What the ladder deliberately does **not** do is build a writable **filesystem**.
That is a genuinely large project (five layers) and — per the reframe above —
nothing in the persistence story needs it. It is worth doing only for full *OFW
parity*: `pseudo-nvram` as a file the booted OS can also read. Named here rather
than left implicit, per the rule about coverage lists that under-cover in
silence.

### "Data survives an OS boot" is three different questions

Worth separating before any of it is built, because the OFW lab already paid for
conflating two of them — its x86 warm-reboot gap turned out to have a **second
cause**:

1. **Across a firmware reset**, no OS involved — the easy one; any of the four backings does it.
2. **Across a boot, with the OS in between** — the OS owns the machine, so the bytes must live somewhere it will not reuse: a declared-reserved e820 region, a pmem device it is told about, or a file it never touches. **Measured: survives** — see *P2's other half* below, where Linux enumerates the very disk holding the store and leaves it alone.
3. **Across a power cycle** — rules out anything RAM-shaped that is not file-backed, which is what makes the middle two rows above the pragmatic choices.

### What this section did NOT prove

No `arch/amd64` target was built, no `arch_nvram_*` was implemented, and **no
NVDIMM was ever attached to OpenBIOS**. The claims above are of three kinds, and
they are not equally strong:

| kind | what it covers | strength |
|---|---|---|
| source reads of the pinned clone | the missing callers, the absent `write` methods, the two 4 GiB truncations, the multiboot type filter, the `arch_nvram_*` contract | quoted verbatim; re-derivable at the pin |
| live probes of the running 32-bit firmware | `dev / ls`, `devalias`, `/options .properties`, `nvramrc` | quoted verbatim from the pty |
| live probes of **QEMU**, not of OpenBIOS | `rtc options`, `system.flash0` at `0xffc00000`, `pflash1 requires pflash0`, the NVDIMM at `0x100000000` | measured on QEMU 8.2.2 — these say where a backing *would* live, not that the firmware can use it |

The third row is the one to hold loosely. The pmem placement is now a
**measurement** rather than the design claim it was in the first draft, but it is
a measurement about QEMU's address map; nothing here has shown OpenBIOS
enumerating an NVDIMM at all, in either mode, and blocker 1 (no ACPI parser) says
it currently cannot.

## What the audit corrected

The verdict and the shape of the work survived the audit; these eight claims
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
8. **The persistence table graded "a file on an attached drive" as the easy row,
   on the evidence that "OpenBIOS x86 has `ide@0..3` nodes to build on."** That
   is this repo's standing mistake — *nodes to build on* is not a question about
   *writing*. Asked properly, the stack is read-only at **every** layer: no
   `write-blocks` in `drivers/ide.c`, no `write` in `pc-parts.c`, and
   `disk-label.c`'s `write` is a stub that pushes `-1`. It is now the row with the
   most missing code, not the least. The corresponding over-claim in the other
   direction is also fixed: the pmem row was a *design* claim and its placement is
   now measured at `0x100000000`.
9. **And then the corrected row 2 was itself answering the wrong question.** The
   five read-only layers are real, but they gate writing a **file** — which
   `arch_nvram_get`/`put` never do. They are arch code: macio's implementation is
   plain MMIO with no package in sight. NVRAM needs raw bytes at a fixed place,
   which deletes four of the five layers and leaves one — *can this driver put a
   sector back?* On that question **IDE is the cheapest backing of the three**,
   not the most expensive, and the recommendation in the ladder inverted
   accordingly. Correction 8 was right about the layers and wrong about which
   question they answered.

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
- **Nothing was tested on real hardware.** Every claim here comes from a build
  or from an emulator.
- **"QEMU was not involved in any command in this document" was true when
  written, and stopped being true on 2026-08-23.** The *census* is still
  build-only — but the persistence section boots the firmware, drives its prompt
  over a pty, and reads QEMU's own address map. A did-not-prove list is exactly
  the kind of present-tense claim that keeps being served after its subject
  changes, so it is corrected here rather than quietly deleted. What remains
  true, and is the load-bearing part: **nothing in the 64-bit story has been
  booted.** Spikes 1–3 and P3 are all unexercised.

## Provenance

| | |
|---|---|
| OpenBIOS | https://github.com/openbios/openbios @ `e5ac46d` (2026-06-29) — the same commit [README.md](README.md) pins |
| fcode-utils | https://github.com/openbios/fcode-utils @ `6e563ee` (2026-06-29) |
| OFW | https://github.com/openbios/openfirmware @ `d5cc657` (**2015-12-18** — HEAD) |
| first measured | 2026-08-18, gcc 13.3.0 (Ubuntu 24.04), rootless, no QEMU involved |
| audited + Spike 0 | 2026-08-18, same host and pins; `gcc-multilib` added for the x86 contrast build; spike patches in [`patches/`](patches/) |
| persistence section | 2026-08-23, same host and pins — the first work here to run QEMU |
| QEMU | **8.2.2** (Debian `1:8.2.2+ds-0ubuntu1.17`) — the flash and NVDIMM addresses, the `-rtc` option list and the `pflash1 requires pflash0` refusal are all this version's, and are the claims most likely to move under another |
| SeaBIOS | `/usr/share/seabios/bios.bin`, 131,072 bytes — the pflash0 image built in row 3 |
