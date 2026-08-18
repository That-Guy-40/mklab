# X86-64-FEASIBILITY.md — could this firmware run in long mode?

> **VERDICT: OpenBIOS — feasible, and the expensive half is already done.
> OFW — not feasible as a lab.**

A feasibility study, not a spike: nothing was ported, and no firmware was made
to run in long mode here. What *was* done is measurement — both upstream trees
were cloned at their pinned commits and **built** to establish what exists
today, because the central claim ("`arch/amd64` is not a port") is the kind of
thing a reading of the source can get wrong and a build cannot. Every command
below was run on 2026-08-18; the transcripts are the real ones.

## The question, disambiguated

Three different things can be meant by "port the Open Firmware labs to x86-64",
and two of them are already true:

| reading | status |
|---|---|
| run the labs **on** an x86-64 host | **already true** — [`run-openbios-qemu.sh`](run-openbios-qemu.sh), [`smoke-openbios.sh`](smoke-openbios.sh) and [`showcase-rival-boots-linux.sh`](showcase-rival-boots-linux.sh) all invoke `qemu-system-x86_64 -M pc` |
| boot a 64-bit **OS** from the firmware | **already true** — [POC-4](POC-4-BOOT-LINUX.md) boots an x86_64 Linux 6.3 bzImage to a u-root shell; the kernel's own `startup_32` performs the mode switch, and the firmware never leaves protected mode |
| run the **firmware itself** in long mode | **the open question** — everything below |

So the port is not about the host, the emulator, or the guest OS. It is about
~1,300 lines of `arch/x86` that assume 32-bit protected mode, flat segments,
and a 4-byte cell.

## OpenBIOS: `arch/amd64` looks like a port and isn't one

The directory exists, carries `boot.c`, `linux_load.c`, `multiboot.c`,
`segment.c`, `context.c`, a `ldscript` and a `switch.S`, and appears in
upstream CI ("OpenBIOS build for amd64 ppc sparc32 sparc64 x86"). None of that
survives contact:

| evidence | what it says |
|---|---|
| `arch/amd64/defconfig` | `CONFIG_IMAGE_ELF`, `CONFIG_IMAGE_ELF_EMBEDDED`, `CONFIG_IMAGE_ELF_MULTIBOOT` are **all unset**; the only image type enabled is `CONFIG_HOST_UNIX=y` |
| `arch/amd64/build.xml` | declares a `<dictionary>` and **nothing else** — no `<library>`, no `<executable>` (compare `arch/x86/build.xml`, which declares a `libx86.a` plus three executables) |
| `arch/amd64/ldscript` | `OUTPUT_FORMAT(elf32-i386)` / `OUTPUT_ARCH(i386)` — a copy of the 32-bit script, while `switch-arch` compiles this arch **without** `-m32`. The two have never been asked to agree |
| `arch/amd64/switch.S` | *"It is assumed that CPU is in 32-bit protected mode and all segments are 4GB and base zero"*, and the entry point is `pushl %cs` |
| no `arch/amd64/entry.S` | `arch/x86` has one (315 lines). amd64 has no bare-metal entry path at all |
| `git log -- arch/amd64` | last substantive commit **2016-08-26** (`amd64: introduce arch_init_program()`); the only change since is a mechanical `malloc`-signature sweep in 2024 |

The CI job name is the trap: upstream's "amd64" build is the **host userspace**
target (`obj-amd64/openbios-unix`), which is what this lab already ships as its
fourth track. It builds `arch/unix`, not `arch/amd64`.

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
$ make
Building OpenBIOS for amd64
Building...
ok.
$ find obj-amd64/target -path '*arch/amd64*' -name '*.o' | wc -l
0
$ find obj-amd64 -maxdepth 1 \( -name '*.elf' -o -name '*multiboot*' \) | wc -l
0
$ ls obj-amd64
... openbios-amd64.dict  openbios.dict ...
```

`builtin-amd64` — the target name that on x86 produces `openbios-builtin.elf` —
**succeeds, reports "ok", and emits only dictionaries**. Zero object files are
compiled from `arch/amd64`; zero firmware images are produced. A green build
that builds no firmware is this repo's own favourite bug class
([CLAUDE.md](../../CLAUDE.md), *"a scan that matches nothing and a scan that is
broken print the same green ✓"*), which is why this section exists at all: the
`defconfig` alone could be argued with, the empty `obj-amd64` cannot.

## The expensive half is already done

The portable core — the Forth engine, the dictionary format with its relocation
bitmap, the device tree, the packages — is already 64-bit clean, and has been
for as long as sparc64 and ppc64 have been shipping targets. `arch/amd64` even
has the type layer written:

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

## What is actually missing

Only the platform-entry layer. Line counts are `arch/x86`, the file that would
have to be re-authored rather than copied:

| file | lines | verdict for a long-mode port |
|---|---|---|
| `entry.S` | 315 | **rewrite** — the 32→64 trampoline lives here |
| `ldscript` | — | **rewrite** — `elf64-x86-64`, and pick a load address |
| `segment.c` | 133 | **rewrite** — the GDT changes shape (`L` bit, no per-segment base) |
| `context.c` + `switch.S` | 162 | **rewrite** — the saved context is 16 registers wide and the frame layout changes |
| `exception.c` | 92 | **rewrite** — a 64-bit IDT, 16-byte gate descriptors |
| `linux_load.c` | 671 | **port, and it gets simpler** — a 64-bit firmware can use the bzImage entry at `+0x200` instead of the 2003 zero-page dance that produced five of the eight bugs in [`patches/01-x86-revival.patch`](patches/01-x86-revival.patch) |
| `multiboot.c` / `plainboot.c` / `sys_info.c` | 205 | **mostly travels** — table parsing, already `ucell`-typed |
| `console.c` | 418 | **travels** — port I/O and MMIO to the VGA text buffer |
| `boot.c` / `builtin.c` / `lib.c` | 111 | **travels** |

Call it ~700 lines of real work and ~600 of carry-over. For scale: the
lab's own revival patch is ~150 lines and took four spikes.

## The structural wrinkle: every entry path hands off in 32-bit

There is no way to be handed control in long mode on this machine class:

- **multiboot1** (`-kernel openbios.multiboot`) specifies 32-bit protected
  mode with paging **off** — the whole reason bug #1 in the revival patch was
  about a.out-kludge address fields.
- **coreboot payload** (`-bios coreboot.rom`, [POC-3](POC-3-COREBOOT-PAYLOAD.md))
  enters the payload in 32-bit protected mode too.
- QEMU's plain `-bios` on the `pc` machine wants a legacy BIOS image entered in
  **real mode** at the reset vector, which is why this lab reaches long-mode-
  capable territory only by way of coreboot in the first place.

So the port is unavoidably shaped as: a 32-bit stub that builds a PML4
identity-mapping the low 4 GB, sets PAE + EFER.LME + CR0.PG, far-jumps through
a 64-bit code descriptor, and lands in a C `main()` compiled `-mcmodel=kernel`.
That is well-trodden ground — 200–300 lines — but it means the firmware keeps a
32-bit head forever, which is worth saying out loud before anyone imagines a
pure-64-bit build.

## What it buys — honestly, not much

| gained | notes |
|---|---|
| memory above 4 GB | `claim`/`release` over the whole map; today's firmware simply cannot address it |
| an honest device tree | `#address-cells 2`, a `/cpus` node that isn't lying about the mode the CPU is in |
| a simpler Linux loader | the 64-bit bzImage entry, per the table above |
| an upstream-shaped patch | OpenBIOS would plausibly take a real `arch/amd64` target; it is, after all, the arch its own CI claims to build |

And what it does *not* buy: any new boot capability. The 32-bit firmware
already boots a 64-bit kernel, and the IEEE 1275 **client interface** is not
consumed by Linux on x86 at all (only ppc/sparc have OF client support), so
widening `prom_arg_t` changes nothing for any real client. The value here is
the bring-up itself — which, in a repo whose thesis is that firmware is
knowable, is a legitimate reason, but it should not be sold as a feature.

## If it were built: four spikes

Each with an observable checkpoint, per the repo's learning-path rule:

| spike | work | checkpoint |
|---|---|---|
| **0 — flip the build on** | give `arch/amd64` a real `build.xml` (library + `openbios.multiboot`) and a 64-bit `ldscript`; do not fix anything yet | the build **fails**, and the failures are enumerated — a list of what actually breaks beats any estimate in this document |
| **1 — the trampoline** | 32-bit multiboot entry → PML4 → long mode → 64-bit C entry; serial console only | `0 >` on the serial socket, and `-1 u.` answering `ffffffffffffffff` from the *bare metal* rather than from `openbios-unix` |
| **2 — context + exceptions** | `switch.S`, `context.c`, a 64-bit IDT | a deliberate `0 0 !` reports a named fault instead of triple-faulting; the client-program context still switches back to the prompt |
| **3 — boot Linux** | `linux_load.c` on the 64-bit entry path | the existing [`showcase-rival-boots-linux.sh`](showcase-rival-boots-linux.sh) success signature, unchanged, from the 64-bit firmware |

Spike 0 is cheap and is the honest next step: it converts this document's
estimate into a measured list. Note that spikes 1–2 have a known failure mode
worth planning for — a triple fault under `-no-reboot` exits QEMU with **rc=0**
([POC-2](POC-2-OK-PROMPT.md)'s pitfall list), so the harness must assert the
prompt, never merely a clean exit.

## OFW / OpenBoot: why this one is a no

Different situation entirely, and the answer is not "harder" but "a different
project".

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

## What this document did NOT prove

Stated explicitly, because a feasibility note that only lists supporting
evidence is the same shape as a test that never runs its negative control:

- **Spike 0 was not attempted.** Nobody has yet compiled a single `arch/amd64`
  file with a 64-bit ldscript. The ~700-line estimate is derived from
  `arch/x86`'s contents, not from a failing build log.
- **No bare-metal x86 image was built here** for comparison — this container
  has no 32-bit multilib, so the `-m32` x86 target could not be built alongside
  the amd64 one. The x86 side of the comparison is read from the source and
  from this lab's existing, verified POCs.
- **The hosted build needed a waiver.** `unix-amd64` fails on this host's gcc
  13.3.0 with `-Werror=unused-result` in `arch/unix/unix.c:422`; it was built
  with `-Wno-error=unused-result` added to `CFLAGS`. That is a host-toolchain
  artifact (the lab's [`Containerfile`](Containerfile) pins its own), not a
  finding about the port.
- **Nothing was tested on real hardware.** Everything here is QEMU, or a build.

## Provenance

| | |
|---|---|
| OpenBIOS | https://github.com/openbios/openbios @ `e5ac46d` (2026-06-29) — the same commit [README.md](README.md) pins |
| fcode-utils | https://github.com/openbios/fcode-utils @ `6e563ee` (2026-06-29) |
| OFW | https://github.com/openbios/openfirmware @ `d5cc657` (**2015-12-18** — HEAD) |
| measured | 2026-08-18, gcc 13.3.0 (Ubuntu 24.04), rootless, no QEMU involved in any command above |
