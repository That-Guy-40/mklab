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
Track 1 (multiboot):  qemu -kernel openbios.multiboot -initrd openbios.dict ──► 0 > ──► boot ──► Linux 6.3 ──► u-root
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
| [`run-openbios-qemu.sh`](run-openbios-qemu.sh) | interactive boot, any track, `0 >` on your terminal |
| [`smoke-openbios.sh`](smoke-openbios.sh) | one-verdict smokes; the ppc one proves the running blob is OURS by build-date banner |
| [`showcase-rival-boots-linux.sh`](showcase-rival-boots-linux.sh) | the finale: one `boot` line at the prompt → Linux 6.3 → u-root, either x86 track |
| [`RUNBOOK.md`](RUNBOOK.md) | guided tour: `0 >` semantics, device tree, the unix-process firmware, rival-vs-rival exercises |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | exact commands + real success signatures |
| [`PLAN.md`](PLAN.md) · POC-[1](POC-1-BUILD-BOX.md)/[2](POC-2-OK-PROMPT.md)/[3](POC-3-COREBOOT-PAYLOAD.md)/[4](POC-4-BOOT-LINUX.md)/[5](POC-5-PPC-SWAP-IN.md) | roadmap + blow-by-blow spike write-ups |

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
