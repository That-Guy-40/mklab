# RUNBOOK — a guided tour of the firmware that answers back

You've run [`./build-ofw.sh`](build-ofw.sh) and have `emuofw.rom`. Start here:

```console
$ ./run-ofw-qemu.sh          # ok prompt on this terminal; Ctrl-A X quits QEMU
```

Watch the boot: `debug-startup` narrates every stand-init step on COM1
(`Probing memory` → `probe-pci` → `Install console`), then the banner, a
countdown you can interrupt with any key, a failed netboot (no bootable
device), and finally:

```
ok
```

That prompt is a **full Forth interpreter running on the bare machine** — no
OS, no libc, interrupts off, and yet: an interactive programming language,
a debugger, and a boot loader in 512 KiB. Everything below is typed at it.

## 1. The machine answers back

```
ok 3 4 + .
7
ok 5 6 * .
1e
```

`1e`?! **The prompt thinks in hexadecimal** (5·6 = 30 = 0x1e). This bites
every check you'll ever script against it. `decimal` and `hex` switch the
base; `d# 10` / `h# 10` force one number's base regardless.

Forth in one breath: values go on a stack, words consume them. `3 4 +` leaves
7; `.` pops and prints. `words` dumps the entire dictionary — every command
the firmware has, because the "commands" *are* the language.

## 2. The device tree is alive

```
ok dev /  ls
... cpus  dropin-fs  flash@fff80000  pci  mmu  memory@0  aliases
    options  openprom  chosen  packages
ok dev /memory@0  .properties  device-end
reg        ...
available  00100000 01900000 ...
ok devalias
```

This is IEEE 1275's central idea: the hardware inventory is a **live,
introspectable namespace** — nodes with properties and *methods* — not a table
handed to the OS and forgotten. Linux's `/proc/device-tree` on ARM boards is
this structure, fossilized. Here you can walk it, query it, and (as the POCs
show) *rewrite* it while the machine runs. `devalias` will stop mid-listing
and wait for a key: the firmware ships its own pager. (Readers of
[`UNIX-less-without-less`](../UNIX-less-without-less/README.md): yes, even
firmware has a `more`.)

`/packages` is the software half — `deblocker`, `fat-file-system`,
`iso9660-file-system`, `disk-label` — support code any driver can open by
name. And `dropin-fs` holds the **FCode** driver modules: drivers as
ISA-independent bytecode, the mechanism that let a 1990s option card carry
its own driver for any CPU architecture. That is OFW's answer to firmware
modularity — the question UEFI later answered with PE binaries and protocol
GUIDs, and [LinuxBoot](../linuxboot-uefi-kexec/README.md) answered by using
Linux itself.

## 3. Files, disks, and reading things by hand

Attach media (rebuild a FAT16 image any time — no root needed):

```console
$ truncate -s 64M ~/ofw-lab/disk.img && mkfs.vfat -F16 ~/ofw-lab/disk.img
$ mcopy -i ~/ofw-lab/disk.img some-kernel ::/VMLINUZ
$ ./run-ofw-qemu.sh coreboot        # picks up disk.img automatically
```

```
ok dir /isa/ide@i1f0/disk@0:\
fat-file-system
--A-rwxrwxrwx  10226368  ...  VMLINUZ
ok load /isa/ide@i1f0/disk@0:\vmlinuz
ok load-base d# 64 dump
```

`load` + `dump` — read a file, then hex-dump the bytes it landed in memory.
POC-2 used exactly this to prove a "corrupt" initrd was actually perfect and
the corruption happened later. The firmware is its own forensic toolkit.

Era honesty: which disk works differs by flavor (2015 drivers vs QEMU 8.2) —
the emu flavor reads **ISO9660 on the CD path** (its ATA disk probe fails);
the coreboot flavor reads **FAT16 on the legacy ISA-IDE path** (after two live
fixes — next section). Details: [POC-2](POC-2-OK-PROMPT.md) Act 1,
[POC-3](POC-3-COREBOOT-PAYLOAD.md) steps 4–5.

## 4. Fixing the firmware from inside the firmware

The lab's proudest trick. Every era-gap was repaired at the prompt:

```
ok : my-dma  h# 1000 mem-claim ;         \ a working DMA allocator...
ok ' my-dma to allocate-dma              \ ...re-pointed into a dead defer
ok loaded dup to /ramdisk  h# 3d000000 swap move    \ hand-place an initrd high
ok h# 3d000000 to ramdisk-adr            \ bless it via memory-limit's early exit
ok : fix-zp  h# ff h# 90210 c!  h# 3d000000 h# 90218 l!  h# afedfc h# 9021c l! ;
ok ' fix-zp to linux-hook                \ poke the kernel handoff page pre-jump
```

`defer` words are firmware-sanctioned patch points; `move`/`c!`/`l!` are raw
memory; `linux-hook` runs after the zero page is written and before the jump.
On UEFI each of these fixes is a recompile-and-reflash. Here they're four
lines of typing — *that asymmetry is the whole lesson.*

## 5. Forth to boot

```console
$ ./showcase-forth-to-boot.sh
PASS: Forth to boot: OFW hand-staged the initrd and booted Linux to u-root
```

Unattended: interrupt autoboot, `load` the cpio, `move` it to 976 MB, set
`ramdisk-adr`, `boot …\vmlinuz console=ttyS0 memmap=1023M@1M`, and a 2015
firmware walks a 6.3.0 x86_64 kernel to `Welcome to u-root!`. The coreboot
track's variant (smaller kernel, direct `read` to the final address, the
`linux-hook` zero-page poke) is scripted step-by-step in
[POC-3](POC-3-COREBOOT-PAYLOAD.md) and [MANUAL_TESTING.md](MANUAL_TESTING.md).

## 6. The ten-second cousin: OpenBIOS (and which repo is which)

```console
$ qemu-system-ppc -nographic -vga none      # stock QEMU, zero lab artifacts
...
No valid state has been set by load or init-program
0 > 3 4 + . 7  ok
```

(Ctrl-A X quits. The prompt is `0 >` — the number is the stack depth.)

That is **OpenBIOS** — a *different*, independently-written implementation of
the same IEEE 1275 standard, and QEMU's default firmware on ppc/sparc. Same
standard, same Forth feel, different codebase. The GitHub org hosts both,
which fuels the eternal confusion:

- **`github.com/openbios/openfirmware`** — Mitch Bradley's OFW (Firmworks),
  what this lab builds; frozen December 2015.
- **`github.com/openbios/openbios`** — OpenBIOS proper; still actively
  maintained (the QEMU-bundled ppc build above says Apr 2026), with x86
  support of its own. **That follow-on now exists as its own lab:**
  [`../openbios-the-rival-that-shipped/`](../openbios-the-rival-that-shipped/README.md)
  builds this firmware, swaps our own build in for QEMU's, and boots Linux
  from its x86 prompt — where the era-gaps this lab fixed *at the prompt* are
  fixed *in C* instead.

One QEMU quirk found while verifying this: OpenBIOS's console input works on
the muxed stdio chardev (`-nographic`, as above) but a bare
`-serial unix:…` socket delivers no input to it — drive it through a pty
(the pager lab's `drive-pager.py` does) or just type at it like a human.

## Exercises

1. **Base trap:** predict what `d# 100 d# 25 + .` prints, then check. Fix it
   two ways (`decimal` first; `u.` vs `.` is *not* one of them — why?).
2. **Tree spelunking:** find the UART the console is using (`dev /isa ls`,
   `.properties`) and read its `reg` property. Which I/O port is it?
3. **Patch practice:** define `: memory-limit-report memory-limit u. ;` and
   compare against `/memory@0`'s `available` — you're watching the POC-2
   memory bug from the inside.
4. **Boot archaeology:** `boot` with no arguments and read the failure chain
   (`boot-device` config variable → `devalias` → driver open). Where does the
   default `/pci/ethernet` come from? (`printenv boot-device`.)
5. **Cross-implementation:** repeat exercise 1 at OpenBIOS's `0 >` prompt.
   Which defaults differ?
