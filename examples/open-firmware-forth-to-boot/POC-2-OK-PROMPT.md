# POC 2 — the `ok` prompt on serial, and five acts of making it boot Linux

> **Status: PASSED** (2026-07-20, agent-verified end-to-end on the host QEMU
> 8.2.2, KVM). Final result, driven deterministically over a serial socket:
> **`emuofw.rom` (2015 Open Firmware) boots a Linux 6.3.0 x86_64 kernel with a
> u-root initramfs to `Welcome to u-root!`** — after live-fixing the firmware's
> memory accounting *from its own `ok` prompt*. Prereq:
> [POC-1-BUILD-BOX.md](POC-1-BUILD-BOX.md).

Every transcript below is real (`~/ofw-lab/drive*.log` during the spike; the
polished reruns live in [MANUAL_TESTING.md](MANUAL_TESTING.md)).

## Step 1 — first light, stock ROM

**Thinking:** before touching config, boot the stock (framebuffer-console) ROM
headless and see what `debug-startup` says on COM1. Cost: one command.

```console
$ timeout 15 qemu-system-i386 -M pc -m 512 -bios emuofw.rom \
    -display none -serial file:serial-stock.log -no-reboot
```

The whole init sequence narrates on COM1 — `Forthmacs` → `Probing memory` →
`probe-pci` → `Install console` — and *stops* there: the console handed off to
the (invisible) framebuffer. A 2015 ROM runs on QEMU 8.2 unmodified. Good.

## Step 2 — the serial-console build

`emu/config.fth` documents the knob: `\ create serial-console` ("makes COM1 the
default OFW console device"). Uncomment, rebuild (seconds, incremental):

```console
$ sed -i 's/^\\ create serial-console$/create serial-console/' cpu/x86/pc/emu/config.fth
$ podman run ... make 'CFLAGS=-O -g -m32 -DTARGET_X86 -std=gnu89'
```

Rebooting the same way now ends with the whole point of the lab:

```
Generic PC, Serial #0, 512 MiB memory installed
Open Firmware  Built 2026-07-21 02:35:55
...
Type any key to interrupt automatic startup
6 5 4 3 2 1  Boot device: /pci/ethernet  Arguments:
Can't open boot device

ok
```

## Step 3 — driving the REPL (and the tool it produced)

**Thinking:** this repo already knows how to type at firmware
(CLAUDE.md serial doctrine: no flow control → slow-send byte-by-byte; one
client per socket; kill by PID). What it lacked was a *generic* scripted
expect/send driver — extracted here as
[`tools/drive-serial-repl.py`](../../tools/drive-serial-repl.py).

**Pitfall — the vanishing banner:** first run used
`-serial unix:...,server=on,wait=off` plus a `sleep 2` before connecting. The
driver timed out waiting for `Type any key…` — the guest had boot-narrated into
the void *before the client connected*; a unix-socket chardev drops output when
nobody is listening. Fix: leave `wait=` **on** — QEMU then holds the guest until
the client connects, so byte zero onward is captured. (This is now baked into
the tool's docstring; the connect-retry loop exists for exactly this pattern.)

**Pitfall — shell precedence, honorable mention:** `cd dir && qemu … &`
backgrounds the *whole* `&&` chain, so the foreground shell never cd'd and the
driver looked for `serial.sock` in the wrong directory. Absolute paths
everywhere after that.

The first fully green conversation (`drive2.log`, driver rc=0):

```
ok 3 4 + .
7
ok dev /
ok ls
79088 cpus
6fc74 dropin-fs
6f8e8 flash@fff80000
6a034 pci
...
2fcc0 chosen
2fc20 packages
```

Arithmetic at the firmware's own REPL, and a live walk of the device tree.
That's the lab's core checkpoint: **`3 4 + .` prints `7` at the `ok` prompt.**

One more period detail: `devalias` output *paused mid-listing* — Open Firmware
has a built-in output pager, waiting for a keypress. Firmware ships a `more`.
(Readers of the `UNIX-less-without-less` lab may feel a disturbance.)

## The stretch goal: `boot` an actual OS — in five acts

Ingredients from the shelf: the linuxboot lab's cached kernels
(`~/linuxboot-lab/urootcfg-bzImage`, Linux 6.3.0 x86_64) and its u-root cpio
(`uroot.cpio`) — built together, known-good under coreboot/LinuxBoot.

### Act 1 — the disk that wasn't there

The wiki boots with `-hda fat:.` (QEMU's vvfat). OFW answered `Can't open
directory` to every path spelling. **Thinking:** stop guessing syntax, ask the
device layer:

```
ok " /pci-ide/ide@0/disk@0" open-dev .
0                                          ← can't open: not a syntax problem
ok show-devs /pci-ide
/pci/pci-ide@1,1/ide@1
/pci/pci-ide@1,1/ide@0                     ← NO disk@0 child node
/pci/pci-ide@1,1/ide@1/cdrom@0             ← but the ATAPI probe worked!
```

The 2015 ATA disk probe fails against QEMU 8.2's IDE — with vvfat *and* with a
plain raw image (both tried) — while the ATAPI (packet) probe on the same
controller succeeds; that `cdrom@0` is QEMU's default empty CD tray. **Era
finding, and a fork in the road:** don't fight an 11-year-old ATA driver;
follow the working probe. OFW speaks ISO9660, so:

```console
$ genisoimage -o boot.iso -V OFWISO -r -J isodir/   # VMLINUZ inside
$ qemu-system-x86_64 ... -cdrom boot.iso
```
```
ok dir /pci/pci-ide@1,1/ide@1/cdrom@0:\
iso9660-file-system
----r-xr-xr-x  10226368  ...  VMLINUZ
```

### Act 2 — the triple fault (virtual-mode)

`boot …cdrom@0:\vmlinuz console=ttyS0` drew OFW's ANSI Tux splash — the
bzImage loader ran — then the VM reset. No `earlyprintk` output at all: death
*at* the kernel entry. `-d cpu_reset` confirmed a triple fault.

**Thinking:** read the loader (`cpu/x86/pc/linux.fth`). It's OLPC-era — OLPC
was 32-bit Geode; this code has plausibly *never* entered an x86_64 kernel. The
x86 boot protocol demands paging **off** at the 32-bit entry, but the emu
config sets `create virtual-mode` — OFW runs with the MMU on. A 64-bit stub
doing its PAE/long-mode transition under someone else's page tables is a
textbook triple fault. The config's own comment says virtual mode "is not
strictly necessary if you just want to boot Linux". Flip it off, rebuild:

```console
$ sed -i 's/^create virtual-mode$/\\ create virtual-mode/' cpu/x86/pc/emu/config.fth
```

Result: `Linux version 6.3.0 …` on serial. Act 2 closed in one config line.

### Act 3 — "System is deadlocked on memory"

The kernel booted into an OOM panic. Its own log names the cause:

```
BIOS-e801: [mem 0x0000000000100000-0x0000000001bfffff] usable
Memory: 13004K/51000K available
```

The kernel saw **~27 MB of the 1 GiB**. OFW fills only the legacy e801 fields
(`alt_mem_k`) — no E820 table (2006 zero page) — and computes the value with
`memory-limit`, which takes *the first free-memory piece starting at 1 MB* from
`/memory`'s `available` property. Physical-mode OFW itself resides around
28 MB, so that piece ends there. Linux has a purpose-built flag for "firmware
handed me a broken map":

```
boot ...:\vmlinuz console=ttyS0 memmap=1023M@1M
```
```
user-defined physical RAM map:
Memory: 994416K/1048184K available
```

### Act 4 — no root fs

Next panic: `VFS: Unable to mount root fs on unknown-block(0,0)` — this bzImage
carries no embedded initramfs; the linuxboot lab ships `uroot.cpio` separately.
OFW has first-class initrd support: a `ramdisk` config variable naming a file
(that was the mysterious `ramdisk ?` complaint in Act 2's log — the loader
probing for it). Add `UROOT.IMG` to the ISO, then *define the config variable
at the prompt*:

```
ok " /pci/pci-ide@1,1/ide@1/cdrom@0:\uroot.img" d# 128 config-string ramdisk
```

`Loading ramdisk image from … done`, kernel sees
`RAMDISK: [mem 0x01101204-0x01bfffff]` — and:

### Act 5 — `invalid magic`, and the fix from the `ok` prompt

`Initramfs unpacking failed: invalid magic at start of compressed archive.`

**Thinking:** who corrupted it? Two suspects: OFW's ISO read, or its placement.
OFW is a debugger that boots things — so interrogate it:

```
ok load /pci/pci-ide@1,1/ide@1/cdrom@0:\uroot.img
ok load-base d# 64 dump
 1000000  30 37 30 37 30 31 30 30 ...  0707010000000000     ← perfect cpio magic
ok .( size=) loaded . drop
size=afedfc                                                  ← exact file size
```

The read is byte-perfect — and the dump *is* the answer: `load-base` is
**0x1000000 = 16 MB**, which is also the kernel's `pref_address`. The modern
decompression stub's first act is to relocate itself and its ~20 MB work buffer
to 16 MB — directly over the initrd that OFW placed at 17 MB (just under its
false 28 MB `memory-limit` ceiling). Modern bootloaders dodge this by placing
initrd *high*; OFW can't, because `memory-limit` believes the 28 MB lie.

Two elegant fixes failed instructively:

- **Rewriting `/memory`'s `available` property** (`encode-int … " available"
  property`) — accepted, then silently ineffective: the memory node
  *regenerates* that property from its live allocator on every claim. The
  property is a view, not the source of truth.
- **`patch fake-limit memory-limit linux-place-ramdisk`** (Forthmacs' live
  code-patcher) — accepted, also ineffective here (this Forth compiles native
  code; the old xt isn't found in the compiled body, and `(patch)` doesn't
  complain).

The fix that worked reads `memory-limit`'s own first line —
`ramdisk-adr ?dup if exit then` — *a pre-loaded ramdisk's address IS the
memory limit*. So do the loader's job by hand, high, and let the firmware's
own escape hatch bless it:

```
ok load /pci/pci-ide@1,1/ide@1/cdrom@0:\uroot.img
ok loaded dup to /ramdisk h# 3d000000 swap move
ok h# 3d000000 to ramdisk-adr
ok boot /pci/pci-ide@1,1/ide@1/cdrom@0:\vmlinuz console=ttyS0 memmap=1023M@1M
```

(No `ramdisk` config variable this time — the loader's guarded lookup fails
harmlessly and *preserves* our hand-set values.)

```
RAMDISK: [mem 0x3d000000-0x3dafefff]      ← 976 MB, exactly where we moved it
Unpacking initramfs...
Run /init as init process
2026/07/21 03:20:37 Welcome to u-root!
```

Driver rc=0. **Forth to boot.**

## What this act structure teaches (the honest summary)

| Failure | Layer | Root cause | Fix |
|---|---|---|---|
| banner lost | harness | `wait=off` drops pre-connect output | serial client gates guest start |
| no disk node | OFW driver era | 2015 ATA probe vs QEMU 8.2 IDE | use the working ATAPI/ISO9660 path |
| triple fault | boot protocol | `virtual-mode` MMU-on vs 32-bit entry contract | physical-mode build |
| memory deadlock | zero page era | e801-only, `memory-limit` capped at OFW's 28 MB residency | `memmap=1023M@1M` |
| VFS panic | packaging | no embedded initramfs | OFW's `ramdisk` support |
| invalid magic | address collision | initrd at 17 MB inside the stub's 16 MB relocation buffer | hand-place initrd at 976 MB via `ramdisk-adr` |

Not one of these was a dead end: every failure printed evidence, and the last
three were fixed *interactively from the firmware's own prompt* — which is the
whole argument for firmware-as-REPL, made by the firmware itself.

Next: [POC-3-COREBOOT-PAYLOAD.md](POC-3-COREBOOT-PAYLOAD.md) — the same
firmware entered the coreboot way.
