# POC-4 — reviving the x86 client ABI (root cause found; client loads and runs)

**Goal:** make the *same* C clients that run on ppc (POC-2, POC-3, POC-5) run on
x86 — the capstone. **Result: the blocker is root-caused and two of its three
repairs are written, verified, and landed as patches.** The firmware now loads
our ELF client off a CD and *enters* it, and the client executes its own code.
It dies on its first callback into the firmware, for a reason that is now
precisely understood. `smoke-client.sh x86` still `SKIP`s.

> **This page replaces an earlier version whose central claim was wrong.** That
> version reported that `load` "reaches none of the loaders" and blamed the
> disk-label/`interpose`/filesystem wiring. Both parts were artifacts of a
> broken instrument, not properties of the firmware. The retraction is
> [below](#what-the-first-attempt-got-wrong-and-why), kept in full because the
> way it fooled us is the most transferable thing here.

## The thinking

On ppc the client interface is the OS boot ABI, so it never rotted (POC-2). On
x86 it is a museum. Reviving it is **three** independent repairs, and the second
and third share one root cause that explains every symptom we chased:

1. **The firmware never hands a launched client the callback.** ✅ written
2. **`load-base` pointed past the end of RAM.** ✅ fixed — the load now works
3. **The client ELF was copied on top of the running firmware.** ✅ fixed — the
   client now runs
4. **The client-interface callback needs an x86 trampoline.** ⏳ open, scoped

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

The fix ([`patches/01-x86-load-base-and-elf-copy.patch`](patches/01-x86-load-base-and-elf-copy.patch))
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

## Fix #3 — the client ELF was copied over the running firmware

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
does `phys_to_virt(addr_fixup(phdr[i].p_paddr))` on every access. The client
path just never got the same treatment. Fixed under `#ifdef CONFIG_X86` to
match.

## The wrong turn worth recording: do NOT translate the entry point

Having translated the copy, translating `e_entry` too looks obviously right. It
is obviously wrong, and the register dump says why:

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

**The firmware runs rebased; the client runs flat. Everything the *client* sees
must be physical; everything the *firmware* dereferences must be virtual.** The
loader's `memcpy` is done by the firmware (translate); the entry point is
consumed by the client (don't). Translating it jumped to `0xe046b092` and the
CPU emulation-failed out of KVM.

## Where it stands: the client loads and runs

```
0 > " /ide@1/cdrom@0:\hello" $load  ok
0 > go switching to new context:

Unexpected Exception: invalid opcode @ 08:00000003 - Halting
eax: 00200c8d  ecx: 00200cb4  edx: 00200cb4  esp: 1ffce6b8
```

Those registers are **pointers into our own client** — `0x200c8d`/`0x200cb4` sit
in its rodata, beside the `Hello world!` string at `~0x200d34`. The firmware
loaded our C program off a CD, entered it, and it executed its own instructions.
Then it called through the client-interface pointer and landed at address `3`.

## Fix #4 — the CIF needs an x86 trampoline (open, and bigger than one pointer)

**This corrects a claim in fix #1's write-up.** The CIF-plant patch
([`patches/00-x86-cif-plant.patch`](patches/00-x86-cif-plant.patch)) was
annotated *"no asm trampoline needed, unlike ppc's `of_client_callback`."* That
is wrong, and the flat-vs-rebased split above is why:

- `ctx->param[2]` is currently the **firmware-virtual** address of
  `of_client_interface`. The client, running flat, calls it and lands in
  nowhere. It must at minimum be `virt_to_phys(of_client_interface)`.
- But that alone just relocates the crash. Firmware C compiled to reference its
  data through the rebased `DS` cannot run with the client's flat `DS`. A real
  trampoline must far-jump to `RELOC_CS`, load `RELOC_DS` **and a firmware
  stack**, call, then restore flat and return. (Both descriptors are reachable
  while the client runs: `ctx->gdt_base = virt_to_phys(gdt)` is the *same* GDT.)
- **And it is deeper than the trampoline.** Every pointer crossing the boundary
  — the `params` array itself, and each service-name and device-path string
  *inside* it — is client-physical, while `libopenbios/client.c` assumes
  pointers are directly dereferenceable. Those need translating too.

A design worth weighing before writing any asm: **enter the client with the
`RELOC` segments instead of flat ones**, so no translation is needed anywhere.
The cost is that the client's link address must then map into free RAM, and
`virt_offset` is only known at runtime — so it needs either a relocatable client
or a loader that rewrites the ELF's addresses. That trade (a trampoline plus
pointer translation, versus a runtime-relocated client) is the next decision,
not the next patch.

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
