# POC-1 — the build box (or: what "CI-green" buys you)

**Goal:** reproduce OpenBIOS's build environment as a Containerfile and build
every image this lab needs. **Result: PASSED** — first `make` succeeded on the
first try, a one-command contrast with the sister lab's POC-1, which fought
gcc-14 for an afternoon. The interesting decisions were all about *packaging*.

## The thinking

The OFW lab's biggest unknown was "does a 2015-frozen tree build on a 2026
toolchain at all?" Here that risk was retired **before writing any code** by
reading upstream's CI: `.github/workflows` builds `amd64 ppc sparc32 sparc64
x86` on every push, inside a builder image whose Dockerfile is in-tree
(`docker/Dockerfile.builder`). When upstream hands you their build box recipe,
your Containerfile is mostly a transcription exercise. Two deliberate
deviations:

1. **`toke` from source, not from ghcr.** Upstream's builder pulls
   `ghcr.io/openbios/fcode-utils:master` — a prebuilt toolchain image. House
   rules (and reproducibility taste) say build it ourselves: fcode-utils is
   plain C, maintained in lockstep (last commit the same day as openbios's),
   and `make && make install` puts `toke` in `/usr/local/bin`. This matters
   because `config/scripts/switch-arch` **hard-aborts** without it:

   ```
   Unable to locate toke executable from the fcode-utils package - aborting
   ```

2. **No native `gcc-multilib`.** First image build failed twice, instructively:

   ```
   E: Unable to locate package libc6-dev-ppc-cross        # it's libc6-dev-powerpc-cross
   ...
   gcc-14-powerpc-linux-gnu:amd64 Conflicts gcc-multilib  # the real trap
   ```

   Debian's cross-gcc **conflicts** with native `gcc-multilib`. Upstream's
   builder solves it the same way we ended up doing: install
   `gcc-multilib-powerpc-linux-gnu` (the multilib *cross* compiler) and rely
   on bare `gcc` + `libc6-dev-i386` for the `-m32` x86 images — their CI
   proves that combination suffices.

## The live commands

```console
$ mkdir -p ~/openbios-lab && cd ~/openbios-lab
$ git clone https://github.com/openbios/openbios.git      # e5ac46d, 2026-06-29
$ git clone https://github.com/openbios/fcode-utils.git   # 6e563ee, same day
$ podman build -t openbios-build -f Containerfile .       # context = the clones' parent
$ podman run --rm -v ~/openbios-lab/openbios:/src --userns=keep-id -w /src \
    localhost/openbios-build sh -c 'config/scripts/switch-arch x86 && make'
Configuring OpenBIOS on amd64 for x86
Initializing build tree /src/obj-x86...ok.
Building OpenBIOS for x86
Building...
ok.
```

`rc=0`, ~40 s. The same for `switch-arch qemu-ppc` (the exact config QEMU's
shipped ppc blob uses — that name choice matters in POC-5) and `unix-amd64`.

## What fell out (the artifact zoo)

```
obj-x86/openbios.multiboot       97 KB   multiboot ELF: "boot from GRUB or LinuxBIOS" — the dict rides as a module
obj-x86/openbios.dict           102 KB   the full Forth system as ONE dictionary file (header + reloc table)
obj-x86/openbios-x86.dict         a trap: only the arch overlay (init.fs + VGA FCode) — see POC-2
obj-x86/openbios-builtin.elf    350 KB   dict EMBEDDED — self-contained: the coreboot-payload shape
obj-ppc/openbios-qemu.elf       661 KB   what /usr/share/qemu/openbios-ppc is built from
obj-amd64/openbios-unix                  the same Forth engine as a host executable
```

The split is the architecture lesson of the codebase: **one C engine, one
dictionary, several packagings.** OFW is Forth all the way down and builds
itself; OpenBIOS is a C program that *hosts* Forth — which is why it can also
run as a Unix process:

```console
$ printf '3 4 + .\nbye\n' | obj-amd64/openbios-unix obj-amd64/openbios-unix.dict
0 > 3 4 + . 7  ok
0 > bye
Farewell!
```

The firmware, as a shell one-liner. Ten seconds after the build, the `0 >`
prompt has already answered — before any QEMU is involved. (The `0` is the
stack depth; it's the same prompt the teaser in the OFW lab's RUNBOOK showed.)

## Pitfalls checklist

- `switch-arch` **requires toke** — bake fcode-utils into the image.
- `libc6-dev-powerpc-cross`, not `-ppc-cross` (Debian naming).
- cross-gcc **conflicts** with native `gcc-multilib` — never install both;
  `libc6-dev-i386` + plain gcc covers the `-m32` links.
- `xsltproc` is load-bearing: the whole Makefile is generated from XML.
- Build products are timestamped (`built on <date>` banner) — byte-identical
  rebuilds are not expected, and POC-5 turns that "flaw" into the proof.
