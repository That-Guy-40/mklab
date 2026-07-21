# RUNBOOK — a guided tour of the rival that shipped

You've run [`./build-openbios.sh`](build-openbios.sh). Before touching QEMU,
meet the firmware as a plain program:

```console
$ cd ~/openbios-lab/openbios
$ printf '3 4 + .\nbye\n' | obj-amd64/openbios-unix obj-amd64/openbios-unix.dict
0 > 3 4 + . 7  ok
```

That is an IEEE 1275 Open Firmware `ok` prompt running as a **Unix process** —
no emulator, no VM. It's the tell that OpenBIOS is a C program hosting Forth,
where its rival OFW *is* Forth. Same standard, opposite architecture.

Now the real thing:

```console
$ ./run-openbios-qemu.sh          # 0 > prompt on this terminal; Ctrl-A X quits QEMU
```

The prompt is **`0 >`** — that leading number is the **stack depth** (0 items
right now). It's a full Forth interpreter on the bare machine: a language, a
debugger, and a boot loader at once.

## 1. The machine answers back (and thinks in hex)

```
0 > 3 4 + . 7  ok
0 > 5 6 * . 1e  ok
0 > decimal 5 6 * . 30  ok
```

`1e`?! The prompt's default base is **hexadecimal** (5·6 = 30 = 0x1e) — the
same trap as the OFW rival, and a reason scripted checks use base-agnostic
`3 4 + .` → `7`. `decimal`/`hex` switch it; `d# 10`/`h# 10` force one number.
Forth in a breath: values push onto a stack, words consume them; `3 4 +`
leaves 7, `.` pops and prints, `words` dumps the whole dictionary — the
"commands" *are* the language.

## 2. The device tree is alive

```
0 > dev / ls
  aliases  openprom  options  chosen  builtin  packages
  pci8086,1237@0  ide@0  ide@1  ide@2  ide@3
0 > dev /pci8086,1237@0  .properties  device-end
0 > devalias
```

`ls` walks children of the current node; `.properties` dumps a node's
key/values; `devalias` lists the short names. This live, introspectable tree
is IEEE 1275's core idea — the same concept the OFW lab toured, a second
implementation of it. The `ide@1` node is where the CD lives (section 4).

## 3. `words`, `see`, and the debugger

```
0 > words                     \ every word in the dictionary
0 > see .                     \ decompile a word (OpenBIOS 1.1 added a source debugger)
```

`see` is an OpenBIOS-1.1 feature (the release notes in
`Documentation/website/OpenBIOS.md` call out the "Forth Source Debugger") —
the kind of amenity a *maintained* firmware accretes and a frozen one never
will.

## 4. Boot Linux by hand

The lab build sets `auto-boot?` false on x86, so you always land at the
prompt. With the showcase ISO attached (`run-openbios-qemu.sh` auto-adds
`~/openbios-lab/boot.iso` if present — run the showcase once to create it):

```
0 > boot /ide@1/cdrom@0:\vmlinuz console=ttyS0 initrd=/ide@1/cdrom@0:\uroot.img
[x86] Booting file '/ide@1/cdrom@0:\vmlinuz' ...
Found Linux version 6.3.0 ... bzImage.
Loading kernel... ok
Loading initrd... ok
Jumping to entry point...
... Welcome to u-root!
```

Two things to notice, both the lab's thesis in miniature:

- **`:\vmlinuz` uses a backslash** — after the `:`, a leading `/` is read as a
  *node* path, not a filename (POC-4).
- **`initrd=` is handled by the firmware itself** (`linux_load.c` parses it),
  and there is no `memmap=`, no hand-placed initrd, no zero-page poke. In the
  OFW lab all three were live-at-the-prompt workarounds. Here the loader is
  maintained C that we *fixed* ([POC-4](POC-4-BOOT-LINUX.md)) — the difference
  between the two firmwares' survival strategies, made concrete.

Keep the line ≤ ~80 chars: the input buffer silently drops the tail.

## 5. The ppc swap-in — you compiled QEMU's firmware

```console
$ qemu-system-ppc -nographic -vga none                 # QEMU's bundled blob
Welcome to OpenBIOS v1.1 built on Apr 22 2026 09:24
0 > 3 4 + . 7  ok
$ ./run-openbios-qemu.sh ppc                            # OURS, via -bios
Welcome to OpenBIOS v1.1 built on Jul 21 2026 07:09
0 > 3 4 + . 7  ok
```

Same source, two build dates. `/usr/share/qemu/openbios-ppc` is built from
this repo; you just rebuilt it and told QEMU to boot yours. That's the
headline "the rival that shipped" made literal — the firmware in the box is
the firmware you compiled. ([POC-5](POC-5-PPC-SWAP-IN.md).)

## 6. Rival vs. rival — run both labs side by side

The point of two firmware labs is the comparison. Try the same task in each:

| Task | This lab (OpenBIOS) | [OFW lab](../open-firmware-forth-to-boot/RUNBOOK.md) |
|---|---|---|
| Prompt | `0 >` (stack depth) | `ok` |
| Boot Linux | one `boot` line; firmware parses `initrd=` | `boot` + hand-stage initrd + `fix-zp` poke |
| Fix an era-gap | patch the C, rebuild (could PR it) | re-point a `defer` live at the prompt |
| Run without QEMU | `openbios-unix` (host process) | impossible (self-hosting Forth) |
| Ships today | QEMU ppc/sparc default | OLPC/Sun history, frozen 2015 |

Boot both, run `dev / ls` in each, and note that the *same standard* produces
two different device-tree floras and two different personalities. IEEE 1275 is
a spec; these are two independent readings of it.

## Asides

- **sparc.** `build-openbios.sh` can build `sparc32`/`sparc64` too (they're in
  upstream CI), and OpenBIOS is QEMU's default firmware there as well — but
  this host has no `qemu-system-sparc*`, so the lab neither runs nor claims it.
- **A follow-on.** Booting a full OS on the ppc track (not just the prompt)
  would need a 32-bit PowerPC kernel — a separate lab, sketched in
  [POC-5](POC-5-PPC-SWAP-IN.md).
