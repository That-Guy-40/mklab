# open-firmware-forth-to-boot — the firmware that answers back

Boot **Open Firmware** — Mitch Bradley's IEEE 1275 implementation, the Forth
firmware of Sun / PowerPC-Mac / OLPC fame — on QEMU in 2026, meet the `ok`
prompt, walk the live device tree, and then make the firmware **boot Linux to a
u-root shell**, fixing its 2015-era assumptions *live at its own prompt* along
the way. Then do it again with the same firmware entered the coreboot way, as
an ELF payload.

```text
Track 1 (emu):        QEMU -bios emuofw.rom ──► ok prompt ──► boot ──► Linux 6.3 ──► u-root shell
Track 2 (coreboot):   QEMU -bios coreboot.rom ──► coreboot ramstage ──► ofwlb.elf ──► ok prompt ──► Linux ──► u-root
```

**Everything below is verified end-to-end on this host** (Ubuntu 24.04, QEMU
8.2.2, KVM), driven deterministically over serial — the feasibility spikes are
written up blow-by-blow with real transcripts:
[POC-1-BUILD-BOX.md](POC-1-BUILD-BOX.md) (a 2015 tree meets gcc-14),
[POC-2-OK-PROMPT.md](POC-2-OK-PROMPT.md) (serial `ok` + the five-act Linux
boot saga), [POC-3-COREBOOT-PAYLOAD.md](POC-3-COREBOOT-PAYLOAD.md) (the
payload matryoshka). The pre-work roadmap is [PLAN.md](PLAN.md); exact
commands + success signatures live in [MANUAL_TESTING.md](MANUAL_TESTING.md);
the guided tour is [RUNBOOK.md](RUNBOOK.md).

## The lesson (why this sits next to linuxboot)

Not a lineage — a rivalry. Open Firmware, UEFI, and LinuxBoot are three
answers to the same question: *how does firmware stay modular as boards and
devices multiply?*

| Answer | Mechanism |
|---|---|
| **Open Firmware** (1988→) | a small Forth system: board support and drivers are words/packages in a **live, introspectable device tree**; drivers ship as ISA-independent **FCode bytecode**, even on the option card itself |
| **UEFI** (1998→) | PE executables + protocol GUIDs — the same modularity goal, a heavier take |
| **LinuxBoot** (2017→) | stop maintaining a firmware platform; let **Linux** be the driver environment — [`../linuxboot-uefi-kexec/`](../linuxboot-uefi-kexec/README.md) |

Track 2 uses coreboot exactly as coreboot intends — bare hardware init that
hands off to a payload — to boot into a **pre-boot Forth environment that then
boots the OS itself**.

And the interactivity is not a gimmick: every era-gap this lab hit was fixed
**from the running firmware's own prompt** — re-pointing a `defer`, hand-placing
an initrd with `move`, poking the kernel handoff page from a boot hook. On
UEFI or BIOS each of those is a recompile-and-reflash. Watching the fixes go
in at the `ok` prompt *is* the argument for firmware-as-REPL.

## OFW ≠ OpenBIOS (the naming trap)

The wiki lives at `openfirmware.info` but titles itself "OpenBIOS
documentation". They are different things: **OFW** is Bradley's original
Firmworks implementation (MIT/BSD, 2006; this lab builds it); **OpenBIOS** is
an independent reimplementation of the same IEEE 1275 standard — it's what
QEMU boots *by default* on ppc/sparc. Which enables a zero-build teaser:

```console
$ qemu-system-ppc -nographic       # stock QEMU, no lab artifacts at all
...
0 > 3 4 + . 7  ok
```

Ten seconds to an IEEE 1275 prompt, and a concrete grip on the distinction.

## Quick start

```console
$ ./build-ofw.sh                  # container build: emuofw.rom + ofwlb.elf (~1 min)
$ ./smoke-ofw.sh emu              # PASS: OFW (emu) answered 7 at the ok prompt ...
$ ./run-ofw-qemu.sh               # interactive ok prompt on this terminal (Ctrl-A X quits)
$ ./showcase-forth-to-boot.sh     # PASS: OFW hand-staged the initrd and booted Linux to u-root
$ ./build-coreboot-ofw.sh         # wrap ofwlb.elf in a coreboot ROM (~1 min on the cached tree)
$ ./smoke-ofw.sh coreboot         # PASS: OFW (coreboot) answered 7 ...
$ ./run-ofw-qemu.sh coreboot      # coreboot → OFW, interactively
```

Prereqs: podman, qemu-system-x86_64, python3, genisoimage (showcase only).
The showcase borrows the linuxboot lab's cached kernel + u-root cpio
(`~/linuxboot-lab/`; override with `KERNEL=`/`INITRD=`). No sudo anywhere.

## What's here

| file | role |
|---|---|
| [`Containerfile`](Containerfile) | the build box: Debian 13 + 32-bit toolchain, one comment per prereq |
| [`build-ofw.sh`](build-ofw.sh) | clone + container-build both flavors (serial/physical config baked in) |
| [`build-coreboot-ofw.sh`](build-coreboot-ofw.sh) | isolated `DOTCONFIG=`/`obj=` coreboot build — never touches the linuxboot lab's `.config`/ROM |
| [`run-ofw-qemu.sh`](run-ofw-qemu.sh) | interactive boot, either track, `ok` prompt on your terminal |
| [`smoke-ofw.sh`](smoke-ofw.sh) | one-verdict smoke: banner → `3 4 + .` → `7` → device-tree walk |
| [`showcase-forth-to-boot.sh`](showcase-forth-to-boot.sh) | the finale, unattended: OFW → hand-staged initrd → Linux → u-root, single verdict |
| [`RUNBOOK.md`](RUNBOOK.md) | the guided Forth/ok-prompt tour + the OpenBIOS teaser |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | exact commands + real success signatures |
| [`PLAN.md`](PLAN.md) · POC-[1](POC-1-BUILD-BOX.md)/[2](POC-2-OK-PROMPT.md)/[3](POC-3-COREBOOT-PAYLOAD.md) | roadmap + blow-by-blow spike write-ups |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | byte-exact archive of the three wiki pages + provenance |

The serial driver the lab extracted,
[`tools/drive-serial-repl.py`](../../tools/drive-serial-repl.py), is repo-wide
infrastructure: a scripted `--expect`/`--send` conversation over a QEMU serial
socket, slow-send per the house serial doctrine.

## Era deviations from the wiki (all justified, all in the POCs)

| Wiki says | 2026 reality | Where |
|---|---|---|
| `svn co svn://openfirmware.info/openfirmware` | endpoint dead → `git clone github.com/openbios/openfirmware` (tree frozen Dec 2015) | POC-1 |
| `make` just works | gcc-14 errors on C89 implicit declarations → `-std=gnu89` (harmless here: all `-m32`) | POC-1 |
| boots in framebuffer graphics | serial-console config is the lab's primary (headless harness); graphics documented for humans | POC-2 |
| `-hda fat:.` and go | 2015 ATA disk probes fail on QEMU 8.2 IDE (both flavors' disk paths differ!); ATAPI/ISO9660 and the legacy ISA-IDE + FAT16 image work | POC-2/3 |
| — (predates x86_64 kernels) | `virtual-mode` (MMU on) triple-faults the 64-bit entry → physical mode; e801-era memory map needs `memmap=`; initrd must be hand-placed high | POC-2 |
| coreboot v2/v3 as payload host | modern coreboot master loads `ofwlb.elf` unmodified (i440fx board; `resident-packages` added) | POC-3 |

## Security posture

Everything runs as your user in QEMU/TCG-or-KVM and rootless podman; no sudo,
no host services, no ports. The 2015 firmware is run for study, not trust.
