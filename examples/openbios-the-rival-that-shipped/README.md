# openbios-the-rival-that-shipped — the other IEEE 1275

Build **OpenBIOS** — the *second*, independent implementation of IEEE 1275
(Open Firmware) — and meet the same `ok` prompt three ways: started by QEMU's
own **multiboot** loader, entered the coreboot way as an **ELF payload**
(OpenBIOS's literal birthplace: it began life as a LinuxBIOS payload), and
swapped in as the firmware **QEMU itself ships** for PowerPC. Then make the
x86 firmware **boot Linux 6.3 to a u-root shell** — which takes resurrecting
five bitrotted code paths with an eight-part patch, because nobody had booted
Linux from OpenBIOS-x86 since the zImage era.

```text
Track 1 (multiboot):  qemu -kernel openbios.multiboot -initrd openbios-x86.dict ──► 0 > ──► boot ──► Linux 6.3 ──► u-root
Track 2 (coreboot):   qemu -bios coreboot.rom ──► ramstage ──► openbios-builtin.elf ──► 0 > ──► Linux ──► u-root
Track 3 (ppc):        qemu-system-ppc -bios OUR openbios-qemu.elf ──► 0 > (banner proves it's ours)
Bonus:                obj-amd64/openbios-unix — the same firmware as a host userspace process
```

**Everything below is verified end-to-end on this host** (Ubuntu 24.04, QEMU
8.2.2, KVM), driven deterministically — the spikes are written up blow-by-blow
with real transcripts: [POC-1-BUILD-BOX.md](POC-1-BUILD-BOX.md) (CI-green vs
the sister lab's archaeology), [POC-2-OK-PROMPT.md](POC-2-OK-PROMPT.md) (the
multiboot track was dead on arrival — twice), [POC-3-COREBOOT-PAYLOAD.md](POC-3-COREBOOT-PAYLOAD.md)
(first-try payload), [POC-4-BOOT-LINUX.md](POC-4-BOOT-LINUX.md) (the six-bug
Linux saga, including one bug the author introduced and revoked), and
[POC-5-PPC-SWAP-IN.md](POC-5-PPC-SWAP-IN.md) (you compiled the firmware your
emulator ships). Roadmap: [PLAN.md](PLAN.md); exact commands + signatures:
[MANUAL_TESTING.md](MANUAL_TESTING.md); guided tour: [RUNBOOK.md](RUNBOOK.md).

## The lesson (why this sits between the OFW lab and linuxboot)

The sister lab, [`../open-firmware-forth-to-boot/`](../open-firmware-forth-to-boot/README.md),
built Mitch Bradley's original Open Firmware — frozen December 2015 — and every
era-gap had to be fixed *live at the prompt*, because the code will never take
another patch. **This lab is the other survival strategy.** OpenBIOS
reimplemented the same standard in portable C with a Forth kernel, hitched
itself to QEMU, and *kept shipping*: it is the default firmware your
`qemu-system-ppc`/`-sparc` boots today, and its repo merged commits last month.

| | OFW (`openbios/openfirmware`) | OpenBIOS (`openbios/openbios`) |
|---|---|---|
| What it is | Bradley's original Firmworks implementation | independent IEEE 1275 reimplementation |
| Written in | Forth (self-hosting; builds itself) | C kernel ("BeginAgain") + Forth dictionary |
| Status | frozen Dec 2015 | active (CI green, commits Jun 2026) |
| Ships where | OLPC XO, Sun/Mac history | **QEMU's default ppc/sparc firmware**, coreboot payload |
| When it bitrots | you fix it **at its own `ok` prompt** | you fix it **in C and could send the patch upstream** |

The same fix, both ways, is the teaching moment: in the OFW lab we poked the
kernel handoff page by hand from a boot hook (`fix-zp`, POC-3); here the
loader that builds that very page at `0x90000` is
[`arch/x86/linux_load.c`](https://github.com/openbios/openbios/blob/master/arch/x86/linux_load.c)
— maintained C we could correct properly ([POC-4](POC-4-BOOT-LINUX.md)). e801
guesswork vs real e820. `memmap=1023M@1M` vs no hack at all. Hand-staged
initrd vs `initrd=` parsed by the firmware itself.

Both labs then feed the track's capstone,
[`../linuxboot-uefi-kexec/`](../linuxboot-uefi-kexec/README.md), which answers
the same modularity question by giving up on firmware platforms entirely.

This lab meets OpenBIOS as a **build** — the firmware you compiled is the one
your emulator ships. [`../open-firmware-native-habitats/`](../open-firmware-native-habitats/README.md)
meets the *same stock blob* as a **habitat**: the sun4m and g3beige machines
where IEEE 1275 was a shipping product, where NVRAM is a real chip rather than a
file, and where the debugging chapter of the standard turns out to be largely
empty stubs (`see patch` → `: patch ;`).

## The revival patch (what "shipped" doesn't mean)

"Actively maintained" means the ppc/sparc paths QEMU exercises daily. The
x86 paths last mattered when LinuxBIOS was coreboot's name, and they have
quietly rotted — every one of these was found live in this lab's spikes and
fixed in [`patches/01-x86-revival.patch`](patches/01-x86-revival.patch)
(~150 lines, applied by `build-openbios.sh`, upstream-PR-ready):

| # | Bug (all x86-path unless noted) | Effect before the fix | POC |
|---|---|---|---|
| 1 | multiboot header sets the a.out-kludge flag but carries no address fields | spec-compliant loaders (QEMU `-kernel`, GRUB) load at address 0 and jump to 0 | [2](POC-2-OK-PROMPT.md) |
| 2 | multiboot dictionary module never parsed (`load_dictionary` call exists only in arch/amd64) | `panic: no dictionary entry point` | [2](POC-2-OK-PROMPT.md) |
| 3 | `load-base` never defined for x86 (every other arch has it) | `$load` executes an undefined word → GPF at `pc=0` the moment a disk is attached | [4](POC-4-BOOT-LINUX.md) |
| 4 | `boot` word is an empty stub; `linux_load.c` is compiled in but never called (the real call sits in arch/amd64/boot.c — still printing "[x86]") | `boot hd:...` can never load a kernel | [4](POC-4-BOOT-LINUX.md) |
| 5 | grubfs has no `tell` method and clamps negative seeks to 0 | `file_size()` returns −1 → every loader sizes files at ~4 GB → "Can't read kernel" | [4](POC-4-BOOT-LINUX.md) |
| 6 | the Linux loader's context frame never gets an `esp` | `switch_to()` pops the jump frame from address 0 → fault before kernel entry | [4](POC-4-BOOT-LINUX.md) |
| 7 | zero page carries only the 2003 header fields | kernel's decompression stub reads `init_size`/`kernel_alignment` as zeros → >4 GB stack, page fault in `startup_64` | [4](POC-4-BOOT-LINUX.md) |
| 8 | coreboot **forwarding tables** (LB_TAG_FORWARD, ~2009+) not chased | table parse fails → hardcoded fallback map → firmware believes every machine has 32 MB | [4](POC-4-BOOT-LINUX.md) |

Plus one **lab-policy** change in the same patch: `auto-boot?` defaults to
false on x86 — the stock unconditional auto-boot (no interrupt window!)
detonates on a use-after-free-style corruption when IDE media is attached, and
a lab wants the prompt anyway. That crash is documented, not fixed
([POC-4](POC-4-BOOT-LINUX.md) §1).

Both x86 tracks run the firmware in **32-bit protected mode** — the machine is
x86-64, the kernel it boots is x86-64, the firmware is not.
[X86-64-FEASIBILITY.md](X86-64-FEASIBILITY.md) measures what a long-mode port
would take: `arch/amd64` turns out to be a fossil that compiles **zero** files
(its `ldscript` still says `elf32-i386`), while the Forth core is already
64-bit clean — so the missing piece is only the entry layer. The study's
Spike 0 has since been **run** (`patches/02`/`03`): the census found the
fossil's real debt is 2008–2013 **API drift**, the only true 64-bit C errors
are `context.c`'s eight, and revival-patch bug #1 sits in `arch/amd64` verbatim.
The same study finds the answer for OFW is **no**, and says why.

## Quick start

```console
$ ./build-openbios.sh              # clone + patch + container build: x86, ppc, unix (~2 min cold)
$ ./smoke-openbios.sh multiboot    # PASS: OpenBIOS (multiboot) answered 7 at the 0 > prompt ...
$ ./smoke-openbios.sh ppc          # PASS: our own openbios-ppc (built on <today>) answered 7 ...
$ ./run-openbios-qemu.sh           # interactive 0 > prompt on this terminal (Ctrl-A X quits)
$ ./showcase-rival-boots-linux.sh  # PASS: the rival boots Linux: ... reached u-root
$ ./build-coreboot-openbios.sh     # wrap openbios-builtin.elf in a coreboot ROM (~1 min, cached tree)
$ ./smoke-openbios.sh coreboot     # PASS: OpenBIOS (coreboot) answered 7 ...
$ ./showcase-rival-boots-linux.sh coreboot   # the same one-liner, entered through coreboot
$ ./build-openbios.sh amd64        # the 64-bit port
$ ./showcase-rival-boots-linux.sh amd64      # the same one-liner, from LONG MODE (Spike 3)
```

Prereqs: podman, qemu-system-x86_64, qemu-system-ppc (ppc track), python3,
genisoimage (showcase). The showcase borrows the linuxboot lab's cached
kernel + u-root cpio (`~/linuxboot-lab/`; override `KERNEL=`/`INITRD=`); the
coreboot track reuses that lab's cached coreboot tree + crossgcc with an
isolated `DOTCONFIG=.config-openbios obj=build-openbios` build — a sha guard
proves the linuxboot **and** OFW labs' kept ROMs survive. No sudo anywhere.

## What's here

| file | role |
|---|---|
| [`Containerfile`](Containerfile) | the build box: Debian 13 + xsltproc + ppc cross-gcc; **`toke` built from source** (fcode-utils — a hard prereq `switch-arch` aborts without) |
| [`patches/01-x86-revival.patch`](patches/01-x86-revival.patch) | the eight fixes above, one reviewable diff |
| [`build-openbios.sh`](build-openbios.sh) | clone + patch (idempotent) + container-build x86 / ppc / unix targets |
| [`build-coreboot-openbios.sh`](build-coreboot-openbios.sh) | isolated coreboot build carrying `openbios-builtin.elf`; sha-guards both sibling labs' artifacts |
| [`run-openbios-qemu.sh`](run-openbios-qemu.sh) | interactive boot, any track (`multiboot`/`coreboot`/`ppc`/`amd64`), `0 >` on your terminal |
| [`smoke-openbios.sh`](smoke-openbios.sh) | one-verdict smokes; the ppc one proves the running blob is OURS by build-date banner |
| [`showcase-rival-boots-linux.sh`](showcase-rival-boots-linux.sh) | the finale: one `boot` line at the prompt → Linux 6.3 → u-root, on `multiboot`, `coreboot` **or `amd64`** — the same line, unchanged, from 64-bit firmware |
| [`RUNBOOK.md`](RUNBOOK.md) | guided tour: `0 >` semantics, device tree, the unix-process firmware, rival-vs-rival exercises |
| [`tests/test-usage-is-data.sh`](tests/test-usage-is-data.sh) | CI guard: every script's `--help` prints and **runs nothing** — it found five defects the day it was first aimed here, one of which started a coreboot build |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | exact commands + real success signatures |
| [`PLAN.md`](PLAN.md) · POC-[1](POC-1-BUILD-BOX.md)/[2](POC-2-OK-PROMPT.md)/[3](POC-3-COREBOOT-PAYLOAD.md)/[4](POC-4-BOOT-LINUX.md)/[5](POC-5-PPC-SWAP-IN.md) | roadmap + blow-by-blow spike write-ups |
| [`X86-64-FEASIBILITY.md`](X86-64-FEASIBILITY.md) | could this firmware run in **long mode**? — measured, audited, **Spike 0 run**: `arch/amd64` builds zero images even with the image types enabled, and after nine mechanical drift lines the only true 64-bit C errors left are `context.c`'s eight |
| [`patches/16-x86-openbios-init-after-device-end.patch`](patches/16-x86-openbios-init-after-device-end.patch) | the same binding fix for x86 — `CONFIG_LOADER_FORTH` has been `true` there all along, over a dead path. Note what it does **not** move: `cif-claim`/`cif-release` are node methods on purpose |
| [`patches/17-amd64-enumerate-pci.patch`](patches/17-amd64-enumerate-pci.patch) | amd64 had `CONFIG_DRIVER_PCI` on and **never called `ob_pci_init()`** — compiled, linked, never run. Also: `ob_ide_init()`'s `path` argument is dead on every arch, and `include/arch/amd64/io.h` was missing the `asm/types.h` x86's copy has always had |
| [`patches/18-vga-fcode-defined-into-the-root-node.patch`](patches/18-vga-fcode-defined-into-the-root-node.patch) | `init.fs` leaves root open, so `value vga-driver-fcode` landed in root's method list — the VGA FCode driver had **never been evaluated on x86 either**, and the failure printed as the bare token `vga-driver-fcode:`, which reads as progress |
| [`patches/19-amd64-preopen-leaves-chosen-active.patch`](patches/19-amd64-preopen-leaves-chosen-active.patch) | the **second** unbalanced site in the same file: amd64's `preopen` never closed `/chosen`, so the prompt was never clean and every word defined there was silently a node method that vanished on the next `device-end`. `arch/x86/init.fs:52` has had the missing line all along |
| [`patches/20-bindings-report-their-own-failures.patch`](patches/20-bindings-report-their-own-failures.patch) | the silence all four hid behind. `feval()` has always returned the throw code and **146 of 147 call sites throw it away** (`fword()`: 969 of 969). Now they report — and stay quiet on a clean boot, proven both ways by `smoke-openbios.sh diagnostics` |
| [`patches/21-vsprintf-precision-is-a-maximum.patch`](patches/21-vsprintf-precision-is-a-maximum.patch) | found by patch 20's own diagnostic: `libc/vsprintf.c` treated `%s` precision as a **minimum**, so `%.10s` on a 3-byte string produced ten bytes. The correct `strnlen` call was one line above under an `#if 0` |
| [`patches/22-printf-number-and-truncation-fixtures.patch`](patches/22-printf-number-and-truncation-fixtures.patch) | closes the two paths patch 21 named and did not test — `number()` precision and `vsnprintf`'s buffer edge. Both correct, bar one C99 divergence (`%.0d` of 0) asserted **as itself** rather than fixed or hidden |
| [`patches/23-load-state-is-never-zeroed.patch`](patches/23-load-state-is-never-zeroed.patch) | why x86's `go` hung and amd64's did not: `create ... allot` never zeroes `load-state`, so the `0`-means-unset test read `0x30000000` of dictionary garbage and handed `evaluate` **768 MB**. amd64 had been passing by luck |
| [`patches/24-forth-trampoline-runs-in-firmware-segments.patch`](patches/24-forth-trampoline-runs-in-firmware-segments.patch) | and why it still evaluated nothing afterwards: `arch_init_program()` entered the Forth/FCode **trampolines** — which are firmware functions, not client programs — in the client's **flat** segments, so on the arch that relocates by rebasing the GDT they read the whole dictionary out of the stale, pre-relocation copy of the image. One mechanism; TODO 13.3(A) had recorded it as two. `smoke-openbios.sh client-forth` |
| [`patches/25-decode-bytes-robbed-the-return-stack.patch`](patches/25-decode-bytes-robbed-the-return-stack.patch) | TODO 13.2(d), and it is **one transposed character**: two bare `r>` and no `>r`, so `decode-bytes` took two cells off the *return* stack and **returned cleanly** with six items where four are documented. The stack comments were describing IEEE 1275 §5.3.5.2 correctly all along. `smoke-openbios.sh property-abi` asserts the DEPTH |
| [`patches/26-encode-int-refuses-what-four-bytes-cannot-hold.patch`](patches/26-encode-int-refuses-what-four-bytes-cannot-hold.patch) | TODO 13.2(b): `l!-be` wrote the low four bytes of a wider value and dropped the rest — and the tree encodes **ihandles** that way, so `/chosen`'s `stdin` could name a different object with nothing reporting it. Now refused by name, with `ffffffff` and `-1` still encoding in the same run. Also ships (a)'s **premise as a counter** rather than a claim |
| [`patches/27-encode-plus-concatenates.patch`](patches/27-encode-plus-concatenates.patch) | TODO 13.2(c): `encode+` was `nip +` — adjacency-by-assumption. And the **length was never what it got wrong**: it returns `l1+l2` correctly and hands back `a1` followed by whatever sits at `a1+l1`, so the second `decode-int` read the gap. The control disproved §13.2's own description of the defect |
| [`patches/28-pci-property-cells-are-big-endian.patch`](patches/28-pci-property-cells-are-big-endian.patch) | TODO 13.3(D): `drivers/pci.c` handed `set_property()` raw **host-order** `u32` arrays, while the whole tree reads property cells big-endian. So every child of the PCI bridge encoded as `@0` and none could be reached by path — including the one the `screen` alias names. Invisible on ppc/sparc64, which is where OpenBIOS's PCI code actually runs |
| [`patches/29-ppc32-had-no-fno-builtin.patch`](patches/29-ppc32-had-no-fno-builtin.patch) | TODO 13.3(C): ppc32 was the **only** arch in the tree without `-fno-builtin`, so GCC treated `snprintf` as a builtin and computed its **return value** per C99 while our divergent libc wrote the buffer. "Writes a byte, returns 0" was two different printfs answering one call |
| [`patches/30-eword-and-printf-surface-fixtures.patch`](patches/30-eword-and-printf-surface-fixtures.patch) | TODO 13.3(E): two of its three "unverified by construction" rows were verified-by-**nobody**. `_eword()`'s not-found branch is reachable by argument, and `%n` and `long long` were implemented and never run — 12/12 becomes 14/14 |
| [`patches/31-encode-writers-take-a-destination.patch`](patches/31-encode-writers-take-a-destination.patch) | **TODO 16**, and the first move toward what this lab is ultimately for: `encode-*` chose its own destination, so it could never be aimed at flash, MMIO or a boot-handoff page. Size and write are now separate, the writer takes the address as a parameter, and the 1275 words are redefined in terms of it — one encoding, two uses. The assertion is `here` **unchanged** |
| [`tests/test-patch-scope.sh`](tests/test-patch-scope.sh) | CI guard: a patch leaving `arch/{x86,amd64}/` must name which arches were regression-tested. It caught its first real case on the run that introduced it |
| [`patches/15-forth-loader-divergence.patch`](patches/15-forth-loader-divergence.patch) | **a divergence we carry on purpose**: `ls.file-size` is never set on the `load` path, and `eval2` — the word the loader calls to evaluate — **is defined nowhere in the tree**. Together they mean OpenBIOS's Forth-source loader has never run a byte, on any arch. Not sent upstream: our goals differ from theirs |
| [`patches/14-amd64-openbios-init-after-device-end.patch`](patches/14-amd64-openbios-init-after-device-end.patch) | one call site: **every `bind_func` before `device_end()` is invisible to `$find`**, so `(init-program)` and `(go)` were unreachable and `load` could not complete. Moving `openbios_init()` after it makes a `.fth` loadable off media |
| [`patches/13-amd64-loader-forth.patch`](patches/13-amd64-loader-forth.patch) | compiles the Forth loader into amd64 (x86 parity) — the prerequisite for loading Forth off media — inert until patch 14 made `(init-program)` reachable |
| [`patches/12-amd64-spike3-boots-linux.patch`](patches/12-amd64-spike3-boots-linux.patch) | **Spike 3**: the bzImage loader re-ported to long mode, and a handoff that copies the kernel over the firmware — because `arch/amd64` does not relocate and so *is* sitting at the 1 MiB a bzImage runs at |
| [`patches/02-amd64-spike0-build-on.patch`](patches/02-amd64-spike0-build-on.patch) · [`03-…-drift-fixes.patch`](patches/03-amd64-spike0-drift-fixes.patch) | the feasibility study's Spike 0, reproducible: a real amd64 `build.xml` + 64-bit ldscript, then the drift-only pass — **not** applied by `build-openbios.sh` (it applies `01` by name) |

The pty driver this lab extracted,
[`tools/drive-pty-repl.py`](../../tools/drive-pty-repl.py), is repo-wide
infrastructure — sibling of `drive-serial-repl.py` for consoles that only
accept input from a real terminal (OpenBIOS-ppc reads the muxed stdio but
ignores a bare `-serial unix:` socket).

## Provenance: cite, don't mirror (a deliberate deviation)

The sister lab vendored its three wiki pages byte-exact
([`../open-firmware-forth-to-boot/upstream-tutorial/`](../open-firmware-forth-to-boot/upstream-tutorial/README.md)
— shared background for both labs). This lab deliberately **doesn't**: it
follows the codebase's own in-tree docs, and upstream has already done the
archiving better than we could — commit `e7fd10c` (2025-07-27) vendored the
entire openfirmware.info MediaWiki into the repo as
`Documentation/website/*.md`. Our source of truth is therefore the pinned
clone itself:

| | |
|---|---|
| **Code + docs** | https://github.com/openbios/openbios @ `e5ac46d` (2026-06-29), retrieved 2026-07-21 |
| **toke/detok** | https://github.com/openbios/fcode-utils @ `6e563ee` (2026-06-29) |
| **Key in-tree pages** | `Documentation/website/OpenBIOS.md` (what boots what), `BeginAgain.md` (the Forth kernel), `OFW_as_a_coreboot_Payload.md` (shared with the sister lab) |

## Security posture

Everything runs as your user in QEMU (KVM or TCG) and rootless podman; no
sudo, no host services, no listening ports. The revival patch changes a
firmware run for study inside a VM — nothing on the host boots it.

## The upstream clone is pinned

`build-openbios.sh` checks out `openbios` at **`e5ac46d`** and `fcode-utils` at
**`6e563ee`**, detached. Every patch in [`patches/`](patches/) is a diff against those
commits, so an unpinned clone meant two people a month apart built different firmware from
the same repository — and every `Arch-tested:` line named a tree that no longer existed.

A **tag would not do**: a version string is not an identity and a tag can be moved. These are
SHAs.

A clone already at the pin is left completely alone, so the uncommitted divergence this lab
develops in is never disturbed. A clone that is *not* at the pin **and** has uncommitted
changes makes the build refuse by name rather than move `HEAD` under that work.

[`tools/openbios-pin-check.sh`](../../tools/openbios-pin-check.sh) reports when upstream has
moved past the pin — reading the SHAs *out of* `build-openbios.sh`, because a second copy
would be a cache of the first and stale in exactly the case it exists to detect. A weekly
cloud routine runs it. **Neither ever bumps the pin**: moving it means re-reading 30 patches
and re-running every track on three arches, which is a decision, not a build step.
