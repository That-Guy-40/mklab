# POC-1 — the build box and the clib (or: a libc that is one callback deep)

**Goal:** stand up a cross-toolchain that compiles a freestanding C client for
both target arches, and shape the `of1275` example into a real support library.
**Result: PASSED.** Both `hello-ppc` and `hello-x86` build; the ppc one runs
(POC-2). The interesting part is that a "libc" for the bare machine is almost
nothing — every function bottoms out in one firmware callback.

## The thinking

A client program is not Forth. It is machine code the firmware `load`s and
enters, which then calls *back* into the firmware through the single
`client_interface_handler` it was handed at `_start`. So the toolchain question
is just "cross-compile a freestanding ELF," and the library question is "wrap
the callback so C code can use it." OpenBIOS already ships both halves —
`utils/ofclient/of1275.{c,h}` (wrappers for all 25 §6.3.2 services) and
`of1275_io.c` (`write`/`read`/`exit` over `/chosen`'s ihandles). We **vendor**
those as the clib seed and grow a thin layer on top (`clib.c`: `puts`,
`put_udec`, `put_hex`), which is this lab's answer to OFW's `clients/lib`
(`printf.c`, `string.c`, `malloc.c`). No OS is assumed because there isn't one;
the "system call" is the firmware.

Crucially, **the ppc track needs no OpenBIOS build at all** — the stock
`qemu-system-ppc` firmware already wires the client interface (POC-2), so the
box stays lean: a cross-gcc and nothing else. (Phase 3's x86 revival will add
`toke`/`xsltproc` to build the firmware itself — deferred until then.)

## The build box

```dockerfile
FROM docker.io/debian:13
RUN apt-get install -y make gcc libc6-dev libc6-dev-i386 binutils \
                       gcc-multilib-powerpc-linux-gnu
```

One deliberate choice, inherited from the sibling lab's POC-1: **no native
`gcc-multilib`** — it *conflicts* with the ppc cross gcc. Plain `gcc` +
`libc6-dev-i386` covers the `-m32` x86 client; `gcc-multilib-powerpc-linux-gnu`
is the big-endian ppc cross.

## Three cross-compile gotchas (each cost an iteration)

1. **`-std=gnu89`.** The `of1275` sources are K&R (`_start` with no return type,
   implicit `exit`). GCC 14 promoted implicit-int and implicit-function-decl to
   **hard errors**, so a stock compile dies. `-std=gnu89` returns them to
   warnings — the same lever the OFW lab pulled for a 2015 tree.

2. **`-lgcc` on ppc.** At `-Os`, GCC emits *out-of-line* GPR save/restore
   helpers and calls them:

   ```
   undefined reference to `_restgpr_29_x'
   ```

   They live in `libgcc`, which `-nostdlib` drops. Add `-lgcc` back (the gcc
   driver knows the path). x86 `-Os` has no such helpers.

3. **One segment, `_start` at the base.** A naive freestanding link scattered
   the ppc image across three `PT_LOAD`s including a stray one at `0x100000f4`
   (a small-data anchor). `-G0 -mno-sdata` kills small-data; a tiny linker
   script (`clib/client-ppc.ld`) puts everything in one segment at
   `0x01000000` and — with `-ffunction-sections` — pins `_start` to the very
   base. That matters because the ppc firmware enters a `-kernel` at the load
   *base*, and it keeps the `boot cd:` path (which enters at `e_entry`) correct
   too. x86 uses the upstream recipe: `ld -N -Ttext 0x200000 -e _start`.

## The live commands

```console
$ ./build-client.sh all hello
==> ppc: hello-ppc (big-endian, entered by stock qemu-system-ppc)
  Data:      2's complement, big endian
  Machine:   PowerPC
  Entry point address: 0x1000000           # _start, pinned to the load base
==> x86: hello-x86 (runs only after the Phase-3 revival)
  Machine:   Intel 80386
  Entry point address: 0x2006e2
```

## The clib, in one screen

`clib.c` is the whole "standard library," and it is tiny because it delegates
everything to the firmware:

```c
void puts(const char *s)   { write(1, (char *)s, clib_strlen(s)); }
void put_udec(unsigned v)  { /* itoa into a stack buffer, then puts() */ }
void put_hex(unsigned v)   { /* 0x + nibbles, then puts() */ }
```

`write()` (from `of1275_io.c`) issues the 1275 `write` service against the
`stdout` ihandle it looked up once in `/chosen`. That's the entire stack: C →
clib → `write` → `of_client_interface("write")` → the console. POC-2 shows all
of it firing on a real machine.

## Pitfalls checklist

- `-std=gnu89` or GCC 14 refuses the K&R `of1275` sources.
- ppc `-Os` needs `-lgcc` for `_restgpr_*`; forgetting it is a link error, not
  a runtime one (so at least it's loud).
- Keep the client in one segment with `_start` at the base — scattered
  `PT_LOAD`s or a mis-placed entry make the firmware jump into the wrong bytes.
- The clib is allocation-free on purpose; a `claim`-backed `malloc` arrives in
  Phase 2 when memtest needs it, not before.
