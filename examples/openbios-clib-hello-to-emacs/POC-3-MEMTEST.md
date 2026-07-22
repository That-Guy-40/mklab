# POC-3 — a RAM tester with no operating system (ppc)

**Goal:** climb the ladder from `hello` to something that *does* work — a
memtest client that finds its own memory and tests it. **Result: PASSED.** On
stock `qemu-system-ppc`, the client asks the firmware how much RAM exists,
`claim`s a 4 MiB block, runs the classic memtest patterns over it, and reports
`memtest: PASS` — all with no OS, every line a `write` back through the client
interface.

## The thinking

`hello` proved the interface answers. memtest proves the interface is *useful*:
a real program needs memory, and with no operating system there is no
`malloc` — so the client asks the **firmware** for it. That is exactly what the
IEEE 1275 client interface is for. Two services carry the whole feature:

- **`/memory` "reg"** — walk the memory node's `reg` property to learn how much
  RAM is installed (`clib_ram_bytes`).
- **`claim`** — ask the firmware to reserve a block and hand back its address
  (`clib_claim`); `release` gives it back.

So this rung is really a **clib growth** exercise: the `hello`-era library only
did console output; memtest adds the memory half. That is the same shape OFW's
`clients/lib` has — `malloc.c` next to `printf.c` — except our "malloc" is one
firmware call deep.

## The clib additions

```c
void *clib_claim(unsigned int size)          /* of1275_claim(0, size, 0x1000, &base) */
void  clib_release(void *p, unsigned int n)  /* of1275_release(p, n) */
unsigned int clib_ram_bytes(void)            /* finddevice("/memory") + getprop("reg") */
```

`clib_claim` passes `virt = 0` so the firmware *chooses* a page-aligned block
(the 1275 semantics when `align != 0`) and returns it. `clib_ram_bytes` reads
`/memory`'s `reg` as `(base, size)` cell pairs and sums the sizes — the cells
are big-endian by 1275 convention, so it runs them through `ntohl` (a no-op on
ppc, a byte-swap on x86, which is why the same clib will work on both arches
after the Phase-3 revival).

## The live transcript

```console
$ ./smoke-client.sh ppc memtest
  - booting stock qemu-system-ppc + our memtest CD, driving boot cd:\MEMTEST.;1
PASS: OpenBIOS-ppc loaded our C client 'memtest' and it ran the RAM tester to a clean PASS over the IEEE 1275 client interface
```

The client's console output, all served by firmware:

```
0 > boot cd:\MEMTEST.;1  >> switching to new context:
OpenBIOS memtest client -- a RAM tester with no OS, served by the firmware.
  /memory reports 256 MiB of RAM
  claimed 4 MiB at 0xf858000
  address test ......... ok
  pattern 0x0 ... ok
  pattern 0xffffffff ... ok
  pattern 0xaaaaaaaa ... ok
  pattern 0x55555555 ... ok
  walking-bit test ..... ok
memtest: PASS -- all patterns verified
EXIT
1 >
```

`256 MiB` matches `-m 256` exactly — the `/memory` walk read the real map. The
`claimed … at 0xf858000` is the firmware's allocator answering. Then three
families of pattern (address-uniqueness, the four data fills, walking-bit)
verify every cell, and the client exits cleanly back to `1 >`.

## Honesty: PASS is the point, not a surprise

Emulated RAM is perfect, so memtest *will* pass — this lab is not going to catch
a bad DIMM in QEMU. The verdict that matters is the **mechanism**: a
memory-testing program running on the bare machine, sourcing its RAM from the
firmware, with no kernel underneath. (The smoke still guards the *other*
direction: a `memtest: FAIL` line would mean the clib's `claim`/verify path
regressed, and it's reported as a specific `REGRESSION:`, not a timeout.)

## Pitfalls checklist

- **`claim` with `virt = 0`, `align = 0x1000`** — let the firmware place the
  block; a non-zero `align` makes `virt` a hint the firmware ignores.
- **`/memory` "reg" cell format** — this assumes one address cell + one size
  cell, true on `qemu-system-ppc`; a machine with `#size-cells = 2` would need
  the pair width read from the root node first.
- **Big-endian cells** — property cells are network-order; use `ntohl` so the
  same clib is correct on x86 too (Phase 3).
- **Strict C89 in the client** — `-std=gnu89` (for the K&R clib) wants all
  declarations at the top of a block; mixed decl/code warns. memtest keeps its
  `static const pats[]` and locals up top.
- **TCG timing** — the ppc client runs under TCG on an x86 host; 4 MiB × several
  passes is a second or two, but the smoke allows a longer deadline for memtest
  than for hello.
