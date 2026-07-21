# POC-4 — booting Linux from a loader nobody had used since zImage

**Goal:** type one `boot` line at the `0 >` prompt and land in a u-root shell.
**Result: PASSED on both x86 tracks** — after a six-bug chain through the
Linux loader, plus one bug the author *introduced and then revoked*. This is
the lab's centerpiece: the sister lab worked around its firmware's era-gaps
live at the prompt because it had to; here every gap was a fixable C bug,
because the rival that shipped can still take a patch.

The through-line: `arch/x86/linux_load.c` carries a header saying "2003-09 by
SONE Takeshi." It was written to load **zImage** (loads low, at 0x10000). It
has never successfully loaded a modern relocatable **bzImage**, and almost
every bug below is a place where a 2003 assumption meets a 2026 kernel.

## Bug #0 (policy) — the auto-boot that detonates

Before any `boot` command, attaching an IDE disk at all crashes the firmware:

```console
$ qemu-system-i386 ... -drive file=disk.img,if=ide,index=0 ...
Trying disk...
load-base:
Unexpected Exception: general protection fault @ 08:1efcaf02 - Halting
pc=0x0(dict+0xffee8520)
```

`main.fs` runs `auto-boot?` unconditionally (no interrupt window — a lab wants
the prompt regardless), and the boot attempt walks into a corrupted state
(`pc=0`). Rather than chase a crash in a path the lab doesn't want anyway, the
patch sets `auto-boot?` **false on x86** — land at the prompt, boot by hand.
(The crash's proximate cause is bug #3 below; even fixed, the lab prefers the
prompt.) *Documented, deliberately not "fixed."*

## Bug #3 — `load-base` undefined (the GPF above, root cause)

`forth/admin/nvram.fs` defines `load-base` for ppc, sparc32, sparc64... and
**not x86**. The generic `$load` path does `" load-base" evaluate` — executing
an undefined word, hence the `pc=0` GPF. Every other arch has the config var;
x86 just never did. One line adds it (`4000000`, i.e. 64 MB).

## Bugs #1–#2 recap

These were POC-2's (multiboot header, dictionary-module loading) — the same
patch file. Needed before any of the below could run.

## The filesystem layer — bug #5, in two parts

With a disk attached and the firmware not crashing, the partition opens but
the filesystem probe fails:

```console
0 > dir /ide@1/cdrom@0:0,\    pc-parts: Unable to determine filesystem
```

Raw block reads work (`" read" ih $call-method` returns bytes), so the device
stack is fine; the *file* layer is broken. Reading `libc/diskio.c`:
`file_size()` does `seek_io(fd, -1)` (seek to EOF) then `tell()`. In grubfs:

- **`seek` clamps a negative offset to 0** — so "seek to EOF" seeks to the
  start.
- **there is no `tell` method at all** — so `tell()` returns −1.

Result: `file_size()` returns garbage (−1 → ~4 GB unsigned), and every loader
that sizes a file before reading it computes an insane length. The
multiboot-track symptom was the memorable one:

```console
0 > boot /ide@1/cdrom@0:\vmlinuz console=ttyS0
Found Linux version 6.3.0 ... (protocol 0x20f) bzImage.
Loading kernel... Can't read kernel
```

Header parsed fine (so the file opened and the first 1 KB read), then the
bulk read of a "4 GB" kernel failed. Fix: negative seek → EOF, and add a
`tell` method (the deblocker's `PUSH lo; PUSH hi` stack pattern). Both in
`fs/grubfs/grubfs_fs.c`.

*Path-spelling aside (real time sink, no code fix):* OpenBIOS's device
resolver treats a leading `/` after the `:` as a **node path**, so
`cdrom@0:/vmlinuz` opens nothing but `cdrom@0:\vmlinuz` (backslash) opens the
file. `-r` on genisoimage lowercases names (`VMLINUZ`→`vmlinuz`). Found by
bisecting `open-dev` at the prompt.

## Bug #4 — the `boot` word is a stub

Even with files readable, `boot` did nothing useful. `arch/x86/boot.c`:

```c
void boot(void) { /* No platform-specific boot code */ return; }
```

`linux_load.c` is compiled into the image but **never called**. Where does the
call live? `arch/amd64/boot.c` — which still prints `"[x86] Booting file..."`,
a fossil proving this *was* x86's boot code before amd64 split off and took it
along. Ported back verbatim (elf_load then linux_load).

## Bug #6 — the jump frame with no stack

Now `Loading kernel... ok / Loading initrd... ok / Jumping to entry point...`
— then a fault, in *firmware* code (CS=0x18, the relocated segment), with
**ESP=0**. `start_linux()` builds a `struct context` with `init_context()`
(which zeroes it) but never sets `ctx->esp`; the generic loaders set it in
`arch_init_program()`, a path linux_load doesn't take. `switch_to()` pops the
segment/flags/eip jump-frame from `ctx->esp` — from address 0. One line:
`ctx->esp = virt_to_phys(ESP_LOC(ctx))`.

## Bug #7 — the zero page the kernel actually reads

Past the jump, into the kernel's decompressor — page fault in `startup_64`,
`CR2` above 4 GB, before the first kernel `printk`. The `-d int` log put the
fault at a stack address the relocation math invented. `init_linux_params()`
copies a handful of named header fields into the zero page, but a modern
bzImage decompression stub reads `kernel_alignment`, `init_size`,
`pref_address`, `handover_offset`... — fields this 2003 struct doesn't even
name, left as zeros. The boot protocol's actual rule: **copy the entire setup
header** (offset 0x1f1 to its end) verbatim into the zero page. Extend the
struct through protocol 2.15 and `memcpy` the whole header. (Loader-owned
fields get overwritten afterward as before.)

```console
$ ./showcase-rival-boots-linux.sh multiboot
Loading kernel... ok
Loading initrd... ok
Jumping to entry point...
Linux version 6.3.0 ... #0 PREEMPT_DYNAMIC ...
Run /init as init process
2026/07/21 06:51:44 Welcome to u-root!
```

**Multiboot track: booted.**

## The bug the author introduced, then revoked

Between #5 and #6 the working theory was that the *kernel's home at 1 MB*
collides with the live Forth dictionary (~0x117000), so an early attempt
staged the kernel 32 MB high and memcpy'd it down "as the last act before the
jump." It was wrong — the read failure was bug #5 (file_size), not an
overwrite — and once #5 was fixed the staging was dead weight touching a load
path that already worked. **Reverted before the patch was finalized.** Noted
here because a POC that only shows the fixes that stuck is lying about how
debugging feels: the honest artifact includes the hypothesis you paid for and
discarded.

## Bug #8 — coreboot lied about the RAM (the forwarding table)

The multiboot track was green; the **coreboot** track failed one step later:

```console
Unpacking initramfs...
Initramfs unpacking failed: invalid magic at start of compressed archive
```

The initrd landed corrupted. Upstream of that, `RAM 32 MB` in the log — on a
512 MB VM. `set_memory_size()` fell back to the hardcoded 640K+31MB default
because `read_lbtable()` found no memory record. Why: since ~2009 coreboot
puts only a **stub** table in low memory whose single record is
`LB_TAG_FORWARD` (0x11) pointing at the real table up in CBMEM. The 2003
parser doesn't chase it. So the firmware placed the initrd inside the 32 MB it
thought existed, the kernel (seeing real memory via e820) unpacked from
elsewhere, and they disagreed. Fix: follow the forward tag, re-validate at the
new address (reusing the existing `find_lb_table` checksum logic), then parse.
Now `RAM 510 MB`, initrd placed high:

```console
$ ./showcase-rival-boots-linux.sh coreboot
RAM 510 MB
RAMDISK: [mem 0x1f027000-0x1fb25fff]
Run /init as init process
2026/07/21 07:08:47 Welcome to u-root!
```

**Coreboot track: booted.** And note what did *not* appear anywhere in this
POC: `memmap=`, a hand-placed initrd, a `fix-zp` poke. Every one of those was
a live-at-the-prompt workaround in the OFW lab. Here the loader was the bug,
so the loader got fixed.

## Pitfalls checklist

- `file_size()` = seek(-1)+tell; a filesystem missing `tell` or clamping
  negative seeks makes every large read fail. Verify raw reads work first to
  localize the break to the file layer.
- Device args: `:\file` (backslash) is a filename; `:/file` is a node path.
- A fault in firmware CS with ESP=0 after "Jumping" = an uninitialized
  context stack, not a kernel bug. `-d int -D log` (TCG) gives the first
  faulting EIP; `check_exception old: 0xffffffff` marks the first fault.
- Modern bzImage needs the WHOLE setup header in the zero page, not a curated
  subset — missing `init_size`/`pref_address` faults the decompressor.
- `RAM <small> MB` from coreboot on a big VM = unchased LB_TAG_FORWARD.
- Keep the boot line ≤ ~80 chars: the firmware input buffer silently drops
  the tail (the `.img` vanished off the end once — the showcase line is
  exactly 78).
