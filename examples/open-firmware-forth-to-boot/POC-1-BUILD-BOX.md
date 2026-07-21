# POC 1 — the build box: a 2015 Forth firmware tree meets a 2026 toolchain

> **Status: PASSED** (2026-07-20, agent-verified end-to-end in a rootless podman
> container). Artifact: `emuofw.rom`, 524 288 bytes. This doc is the blow-by-blow:
> every command live, every pitfall, and the *thinking* at each step — the
> [POC-MATRYOSHKA](../linuxboot-uefi-kexec/POC-MATRYOSHKA.md) style.

## The question this spike answers

The wiki ([Building OFW for QEMU](https://www.openfirmware.info/Building_OFW_for_QEMU.html),
QEMU-0.9.1-era) says: `svn co svn://openfirmware.info/openfirmware`, then
`cd cpu/x86/pc/emu/build && make` → `emuofw.rom`. Between us and that sentence
stood three unknowns:

1. The svn endpoint is **dead**. Is the GitHub mirror (`openbios/openfirmware`)
   complete and buildable?
2. The tree is frozen at **December 2015** ("ARM Simulator - Oops…"). Does its C
   bootstrap compile under gcc-14, eleven years of `-Werror`-creep later?
3. The build self-hosts a **Forth interpreter** (`cpu/x86/Linux/forth`) as a
   32-bit x86 binary. Does the whole `-m32` path still exist on a modern distro?

**Thinking:** spike this with the *fewest moving parts* — no coreboot in the
loop, no QEMU yet, just "does the tree build". The `emu` flavor was chosen
because the wiki itself warns the coreboot flavor "lacks drivers for QEMU
devices"; `emu` is the one with a device set matched to QEMU.

## Step 1 — clone and case the joint

```console
$ mkdir -p ~/ofw-lab && cd ~/ofw-lab
$ git clone --depth 1 https://github.com/openbios/openfirmware.git
$ git -C openfirmware log -1 --format='%h %ad %s'
d5cc657 Fri Dec 18 19:09:57 2015 +0000 ARM Simulator - Oops. ...
$ du -sh openfirmware
29M     openfirmware
```

Layout matches the wiki exactly: `cpu/x86/pc/emu/build/Makefile` (QEMU flavor)
and `cpu/x86/pc/biosload/` with `config-coreboot.fth` (payload flavor) both
exist. Bonus discovered in-tree: `cpu/x86/pc/biosload/HOWTO_QEMU.txt` — a
*third* boot method (OFW's own 2-sector FAT12 floppy bootloader) the wiki never
mentions.

Reading `cpu/x86/pc/emu/build/Makefile` before running anything (the repo habit:
map the blast radius first) revealed the build shape:

- `emuofw.rom` is built by **Forth itself**: `./build $@` where `build` is a
  symlink to `../../../Linux/forth` running `builder.dic`.
- That `forth` binary comes from `cpu/x86/Linux/Makefile`:
  `MFLAGS = -m32`, wrapper C from `forth/wrapper/wrapper.c` (+ a bundled zlib),
  and `inflate.bin` linked with `ld -melf_i386`.

So the *entire* toolchain requirement is: `make`, `gcc` with working `-m32`,
32-bit libc headers, `binutils`. Everything else is the tree bootstrapping
itself in Forth. No fetches, no prebuilt blobs — fully verifiable in a
container.

## Step 2 — the Containerfile

One prereq per line, each tied to the build step that needs it
(`~/ofw-lab/Containerfile`, later vendored into the lab as `Containerfile`):

```dockerfile
FROM docker.io/debian:13
RUN apt-get update && apt-get install -y --no-install-recommends \
        make gcc gcc-multilib libc6-dev-i386 binutils \
    && rm -rf /var/lib/apt/lists/*
# make            — drives cpu/x86/pc/emu/build/Makefile
# gcc + multilib  — wrapper.o etc. are built -m32 (MFLAGS in cpu/x86/Linux/Makefile)
# libc6-dev-i386  — 32-bit libc headers/CRT for that -m32 build
# binutils        — ld -melf_i386 for inflate.bin, objcopy -O binary
```

```console
$ podman build -t ofw-build -f ~/ofw-lab/Containerfile ~/ofw-lab
$ podman run --rm -v ~/ofw-lab/openfirmware:/src --userns=keep-id \
    -w /src/cpu/x86/pc/emu/build localhost/ofw-build make
```

## Pitfall #1 (the only one): gcc-14 made 1989 illegal

First build died in the wrapper:

```
wrapper.c:1962:22: error: implicit declaration of function 'ioctl'
wrapper.c:2139:9:  error: implicit declaration of function 'time'
```

**Thinking:** gcc-14 promoted implicit function declarations from warning to
hard error. Two candidate fixes: (a) patch `wrapper.c` (add `#include`s), or
(b) build in `gnu89` mode where implicit declarations are legal language.
Chose **(b)** — the upstream tree stays byte-pristine (verbatim-vendor
discipline), and on this specific build implicit-int is *actually harmless*:
everything is `-m32`, where `int` == `long` == pointer == 32 bits — precisely
the 1989 assumption the code was written under. (On a 64-bit build the same
warning would be a real truncation bug. Here it is not.)

The Makefile assigns `CFLAGS` with `=` (not `?=`), so an environment variable
won't override it — but a **make command-line variable** propagates through the
recursive `make -C` chain via MAKEFLAGS:

```console
$ podman run --rm -v ~/ofw-lab/openfirmware:/src --userns=keep-id \
    -w /src/cpu/x86/pc/emu/build localhost/ofw-build \
    make 'CFLAGS=-O -g -m32 -DTARGET_X86 -std=gnu89'
```

## Success — the tree self-hosts

One flag was the entire fight. The wrapper compiled, the Forth kernel came up,
and then *Forth built the firmware*: every FCode driver compiled by
`builder.dic` (`ne2kpci`, `vmlance`, `cirrus`, `bga`, `usbserial`,
`usbstorage`, `pcibridg`…), then:

```
--- Rebuilding emuofw.rom
--- Cmd: /src/cpu/x86/Linux/forth /src/cpu/x86/Linux/../build/builder.dic ../emuofw.bth
--- Saving as emuofw.rom - Binary ROM image format for emulator
```

```console
$ ls -la cpu/x86/pc/emu/build/emuofw.rom
-rwxr-xr-t 1 sqs sqs 524288 ... emuofw.rom      # exactly 512 KiB
```

Build time: ~40 s cold. The ROM sha256 changes per rebuild (build timestamp is
baked into the banner), so the *build log*, not the hash, is the reproducibility
witness.

## Config knobs that matter later (found by reading `emu/config.fth`)

| Knob | Default | Why we care |
|---|---|---|
| `\ create serial-console` | **off** (framebuffer console) | POC 2 flips this on — our harness is headless serial |
| `create debug-startup` | on | early boot narrates on COM1 even in graphics builds — free diagnostics |
| `create virtual-mode` | on (OFW runs with MMU on) | **POC 2 flips this off** — it triple-faults the 64-bit Linux handoff |
| `create linux-support` | on | ext2 + bzImage loader compiled in |

## Verdict

- **PASSED, fully agent-verified**: clone → container → `emuofw.rom` with zero
  patches to the upstream tree; one build-flag deviation (`-std=gnu89`),
  recorded as an erratum.
- The wiki's recipe survives 2026 with exactly two substitutions: `svn co` →
  `git clone https://github.com/openbios/openfirmware`, and
  `make` → `make 'CFLAGS=-O -g -m32 -DTARGET_X86 -std=gnu89'`.

Next: [POC-2-OK-PROMPT.md](POC-2-OK-PROMPT.md) — booting it, driving the `ok`
prompt over serial, and the five-act debugging saga of making it boot Linux.
