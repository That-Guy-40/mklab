# POC-4 — reviving the x86 client ABI (DONE: all three clients run on x86)

**Goal:** make the *same* C clients that run on ppc (POC-2, POC-3, POC-5) run on
x86 — the capstone. **Result: done.** A revived OpenBIOS-x86 loads `hello`,
`memtest`, and the interactive `edit` off a CD, enters them, and serves their
callbacks:

```console
PASS: revived OpenBIOS-x86 loaded our C client 'hello' and it answered Hello world! ...
PASS: revived OpenBIOS-x86 loaded our C client 'memtest' and it ran the RAM tester to a clean PASS ...
PASS: revived OpenBIOS-x86 loaded our C client 'edit' and it ran a tiny interactive editor ...
```

It took **six** repairs, not the three originally scoped, and they all descend
from a single design decision documented below.

> **This page replaces an earlier version whose central claim was wrong.** That
> version reported that `load` "reaches none of the loaders" and blamed the
> disk-label/`interpose`/filesystem wiring. Both parts were artifacts of a
> broken instrument, not properties of the firmware. The retraction is
> [below](#what-the-first-attempt-got-wrong-and-why), kept in full because the
> way it fooled us is the most transferable thing here.

## The thinking

On ppc the client interface is the OS boot ABI, so it never rotted (POC-2). On
x86 it is a museum, and every exhibit traces back to the same thing: **x86
relocates the firmware by rebasing the GDT**, and nobody ever taught the client
path about it. The six repairs, all in
[`patches/01-x86-client-revival.patch`](patches/01-x86-client-revival.patch):

1. **`load-base` pointed past the end of RAM** — the load silently read zeros.
2. **The launched client was never handed the callback** (ppc plants it in `r5`).
3. **The loader never declared the file type**, so every dispatch on it fell
   through — including the one that plants the callback.
4. **The client was entered with flat segments**, in a firmware whose own
   pointers are segment-relative.
5. **x86 had no console device node at all** — `/chosen` stdin/stdout were `0`,
   so every client `write()` went to ihandle 0 and vanished.
6. **x86 bound no `cif-claim`**, so the `claim` service always failed.

## The root cause: x86 relocates by rebasing the GDT

Everything below follows from one design decision in
[`arch/x86/segment.c`](https://github.com/openbios/openbios/blob/master/arch/x86/segment.c).
OpenBIOS-x86 relocates itself to the top of RAM **not** by copying with
relocation fixups, but by setting the **base of the `RELOC_CODE`/`RELOC_DATA`
GDT descriptors** to `virt_offset = new_base - &_start` and reloading the
segment registers:

```c
    /* New virtual address offset */
    new_offset = new_base - (unsigned long) &_start;
    gdt[RELOC_DATA].base_0  = (unsigned short) new_offset;   /* ... */
    virt_offset = new_offset;
```

So **every address firmware C and Forth pass around is segment-relative** — the
CPU adds `virt_offset` to reach physical memory (`include/arch/x86/io.h`:
`phys_to_virt(p) = p - virt_offset`). Two consequences drive this whole page:

- **`virt_offset` scales with RAM size**, because relocation targets the *top*
  of RAM. Any hardcoded absolute address in this firmware is wrong by
  construction, and wrong *differently* on every `-m` value.
- **`arch/x86/linux_load.c` wraps every access in `phys_to_virt()`** — which is
  exactly why the Linux boot path (the rival lab's capstone) works and the
  generic client path did not. The rot is precisely where nobody translated.

Measured on `-m 512`: `_start` = `0x100010`, `new_base` = `0x1fe95a20`, so
`virt_offset` = **`0x1FD95A10`**.

## Fix #2 — `load-base` must be computed at runtime

`forth/admin/nvram.fs` defines x86's `load-base` as the constant `0x4000000`
(the rival lab added it; x86 previously had none at all, and `$load`'s
`" load-base" evaluate` crashed on an undefined word). As a *segment-relative*
address, `0x4000000` resolves to physical `0x4000000 + 0x1FD95A10` =
**`0x23D95A10` ≈ 597 MB — past the end of 511 MB of RAM.**

The failure mode is vicious: the IDE read reports complete success and the data
goes nowhere.

```
[DBG grubfs_load] enter buf=4000000 count=7748 fsys=iso9660
[DBG devread] offs=51200 len=2048 buf=4000000 n=2048 first4=00000000
[DBG devread] offs=53248 len=2048 buf=4000800 n=2048 first4=00000000
[DBG devread] offs=55296 len=2048 buf=4001000 n=2048 first4=00000000
[DBG devread] offs=57344 len=1604 buf=4001800 n=1604 first4=00000000
[DBG grubfs_load] read_func ret=7748 filepos=7748 first4=00000000
```

Correct file size (7748 = the client byte-for-byte), correct sector offsets,
correct buffer advance, `n == len` every time — **and every byte reads back
zero.** No fault, no error, no diagnostic. Reads into unbacked memory just
return zeros.

Confirmed by predicting a specific weird address before testing it: physical
4 MiB should live at virtual `0x400000 - 0x1FD95A10` = `0xE066A5F0`.

```
0 > deadbeef 4000000 l! 4000000 l@ u. 0          \ the old load-base: swallowed
0 > deadbeef e066a5f0 l! e066a5f0 l@ u. deadbeef \ same RAM, correct virtual addr
```

The fix ([`patches/01-x86-client-revival.patch`](patches/01-x86-client-revival.patch))
computes `load-base` in `arch/x86/openbios.c`'s `arch_init`, because **only C
knows `virt_offset`**:

```c
snprintf(buf, sizeof(buf), "%lx constant load-base",
         (unsigned long)(uintptr_t)phys_to_virt(LOAD_BASE_PHYS));   /* 4 MiB */
feval(buf);
```

It shadows the nvram config word rather than replacing it, so
`" load-base" evaluate` still resolves if this ever regresses. Result:

```
0 > load-base u.                                 e066a9b0
0 > " /ide@1/cdrom@0:\hello" $load
[DBG grubfs_load] read_func ret=7748 filepos=7748 first4=464c457f
0 > load-base l@ u.                              464c457f      \ \x7fELF
0 > load-size u.                                 1e44          \ 7748
```

**The file load works.** `\x7fELF` at load-base is the whole ballgame.

## Fix #3 — the client ELF was copied over the running firmware (RETIRED by #4)

`libopenbios/elf_load.c`'s plain-`elf` (client) path did:

```c
tmp  = phdr[i].p_vaddr;
addr = (char *)tmp;             /* treat p_vaddr as directly usable */
memcpy(addr, base + phdr[i].p_offset, size);
```

On x86 a "directly usable pointer" is *firmware-virtual*. Our client is linked
at `0x200000`, so the copy went to physical `0x200000 + virt_offset` =
`0x1FF95A10` — which is **inside the relocated firmware image**
(`0x1fe95a20`–`0x1ffdfff7`). We were scribbling on the running OpenBIOS, and
`go` promptly took a general protection fault.

The tell was sitting 350 lines up in the same file: the *elf-boot* path already
does `phys_to_virt(addr_fixup(phdr[i].p_paddr))` on every access. So the client
path got the same treatment — and it worked.

**It is not in the final patch.** Fix #4 changed the segments the client runs
in, which makes the client's virtual `p_vaddr` the correct destination after
all, and upstream's original line right as written. Kept here because the
*diagnosis* stands (we really were scribbling on the running firmware) and
because a fix that evaporates once you correct the design around it is worth
recognising as a symptom rather than a cure.

## The wrong turn worth recording: read the segment dump before translating

Having translated the copy, translating `e_entry` too looks obviously right. It
was wrong, and the register dump is what said so — the same dump that later
drove the whole fix-#4 decision:

```
EIP=e046b092 ...
CS =0008 00000000 ffffffff 00c09b00 DPL=0 CS32 [-RA]
DS =0010 00000000 ffffffff 00c09300 DPL=0 DS   [-WA]
```

**Segment bases of zero.** `arch_init_program` sets `ctx->cs = FLAT_CS`,
`ctx->ds = FLAT_DS` — the client is entered with **flat, base-0 segments**,
exactly as a client program expects. Its neighbours in that same function say
the same thing out loud:

```c
ctx->esp         = virt_to_phys(ESP_LOC(ctx));
ctx->return_addr = virt_to_phys(__exit_context);
```

**The firmware ran rebased; the client ran flat.** Everything the *client* saw
had to be physical, everything the *firmware* dereferenced had to be virtual —
and translating the entry point jumped to `0xe046b092` and emulation-failed out
of KVM. Fix #4 removes the split entirely by putting both in the same segment
space, which is why neither the copy nor the entry needs translating in the end.
The lesson survives the fix: **when two components disagree about what an
address means, dump the segments before you start converting.**

## Fix #4 — segments: the fork, and why it went the way it did

With the load fixed, `go` entered the client and it ran its own code — the
faulting registers held pointers into its own rodata — then died calling through
the client-interface pointer. That exposed a real design fork, because
`arch_init_program` enters clients with **flat, base-0 segments** while the
firmware itself runs rebased.

- **A. Keep the client flat, add a trampoline.** Faithful to what a client
  program normally expects. But it is not one pointer: `of_client_interface()`
  does `prom_args_t *pb = (prom_args_t*)params`, dereferences `pb->service`, and
  pushes `pb->args[i]` **straight onto the Forth stack** — and *which* of those
  args are pointers depends on the service being invoked. There is no generic
  place to translate them. A flat client means rewriting the dispatcher.
- **B. Enter the client with the firmware's `RELOC` segments.** Then client
  pointers *are* firmware pointers and nothing needs translating, anywhere.

**B, decisively** — A's cost is unbounded and touches generic code; B is a
handful of lines in one arch file. The price is one constraint: the client must
be linked into the virtual window below `_start` (`0x100010`), which maps to
physical RAM just under the relocated firmware. That window **sizes itself**,
because both ends move with `virt_offset` — so `-Ttext 0x20000` is correct at any
`-m` value.

This also *retired* fix #3 from the previous revision of this page: with the
client living at its virtual `p_vaddr`, the loader's copy needs no translation
and upstream's original line was right all along. A fix that disappears when you
correct the design around it was a symptom, not a cure.

## Fix #5 — x86 had no console node, so clients shouted into a void

With segments sorted, `hello` ran to completion and called `exit` cleanly — the
client interface was working — but printed **nothing**. `/chosen` told the story:

```
0 > dev /chosen .properties
name                      "chosen"
stdin                     0
stdout                    0
```

x86 boots with **no console device node at all**. The firmware never notices,
because its own console is the low-level serial `putchar` in
`arch/x86/console.c`; but a client reaches the console *only* through those
`/chosen` ihandles, so every `write()` went to ihandle 0 and disappeared.

`drivers/pc_serial.c` has a suitable node — but it is gated off for x86, and
enabling it collides with the `uart_init` that `arch/x86/console.c` already
defines. So the fix wraps the console this arch *already has* in a node with
`open`/`read`/`write`, and claims `/chosen` during `arch_init`. That ordering is
deliberate: `install-console` runs later and tries `output-device` (`"screen"`,
absent under `-display none`), but a failed `output` leaves `stdout` untouched
and the `CONSOLE-OUT` fallbacks skip when `stdout` is already set.

The `read` method is non-blocking and returns whatever is available, per §6.3.2 —
exactly what `clib`'s `getch()` spins on, and why `edit` is interactive on x86.

## Fix #6 — `claim`

`memtest` then ran, talked, and reported `memtest: FAIL -- claim failed`. Only
ppc and sparc64 bind a `cif-claim`; on x86 the service fell through
`ciface.fs`'s `else 3drop -1`, so every allocation failed. x86 has no ofmem, so
this is a small bump allocator over the free window — from 8 MiB (clear of
load-base at 4 MiB) up to virtual 0, which is precisely where the client's own
window begins. Both ends move with `virt_offset`, so it is correct at any RAM
size. It returns a firmware-virtual address, because that is the space the
client runs in.

```
  claimed 4 MiB at 0xe0a6ad50
  address test ......... ok
  pattern 0x0 ... ok            ( ... )
memtest: PASS -- all patterns verified
```

## Reproducing it

```console
$ ./build-firmware-x86.sh            # the rival lab's 8 fixes + this lab's 6
$ ./build-client.sh x86 hello
$ ./smoke-client.sh x86 hello
PASS: revived OpenBIOS-x86 loaded our C client 'hello' and it answered Hello world! ...
```

Verified on this host (KVM, QEMU 8.2.2) for `hello`, `memtest`, and `edit`, with
all three ppc smokes still green — the firmware work is x86-only, and the ppc
track still needs no firmware build at all.

## What the first attempt got wrong, and why

Both errors were **instrument failures that produced confident, specific, wrong
conclusions** — the most expensive kind.

- **"`load` reaches none of the loaders."** It reached them the whole time. The
  probe instrumented `fs/iso9660/iso9660_fs.c` — which is the **ppc** path. On
  x86 the filesystem package is **grubfs** (`fs/grubfs/grubfs_fs.c`, GRUB's
  code), whose `load` method is `grubfs_files_load`. Nothing was ever
  instrumented on the path actually being executed, so of course it looked
  silent. *Lesson: prove your probe is on the path before believing its silence.*
- **"The disk-label/`interpose` wiring is broken."** It works perfectly, and
  `packages/disk-label.c` has shipped a full `DPRINTF` trace of it all along —
  gated behind `//#define DEBUG_DISK_LABEL` **and routed through `printk`, which
  on x86 goes to VGA, not serial.** Enable the gate *and* swap `printk` →
  `forth_printf` and the path narrates itself in five lines:
  ```
  DISK-LABEL - dlabel_open: dlabel-open '\hello'
  DISK-LABEL - dlabel_open: Unknown or missing partition map; trying whole disk
  DISK-LABEL - dlabel_open: Located filesystem with ph 0012f388
  DISK-LABEL - dlabel_open: path: \hello length: 6
  DISK-LABEL - dlabel_open: INTERPOSE!
  ```
  *Do this first, next time. Upstream's own trace beats anything you'll write.*

The reason both stood unchallenged is the third failure: **the serial console
was dropping characters**, so every interactive probe was suspect and none felt
worth trusting. That was fixed at the tool level before this session's debugging
began — `tools/drive-pty-repl.py --echo-gate` (self-clocks on the console's
echo). A 38-byte probe that used to arrive as `lo` now lands first try.

## Pitfalls checklist

- **x86 relocates by rebasing the GDT.** Firmware addresses are virtual;
  `virt_offset` scales with RAM size. No absolute constant is safe.
- **Firmware = rebased, client = flat.** Translate what the firmware
  dereferences; do *not* translate what the client consumes.
- **Reads/writes to unbacked virtual addresses silently return zeros** — no
  fault, and the device read still reports full success.
- **Control-test your probe words before trusting a negative.** `here` *moves
  between command lines*, so `x here l! here l@ u.` proves the words work but
  says nothing about address stability; `l@`/`dump` on unmapped memory return 0
  as if it were data. Read something whose value you can predict.
- **x86 `printk` → VGA; use `forth_printf`** for serial-visible firmware debug.
  A client's `write` goes via `/chosen` stdout, which *is* serial — so the
  smoke's grep will work once a client talks.
- **Look for an existing `DPRINTF`/`DEBUG_*` gate before writing probes** — then
  check where its macro actually prints.
- **Use `--echo-gate`** for firmware prompts; a fixed `--char-delay` is a guess.
- **`open-dev` succeeding is not proof `load` will load** — but on x86 the
  divergence was never in that wiring.
- **A dispatch on an uninitialised field fails silently and looks like dead
  code.** `>ls.file-type` was never set by the ELF loader, so *both* arms of
  `arch_init_program`'s type test had been unreachable for years. If a
  conditional never fires, check that what it reads is actually written.
- **"The firmware prints fine" says nothing about `/chosen`.** The console the
  firmware uses and the console a *client* can reach are different mechanisms.
  x86 had the first and not the second.
