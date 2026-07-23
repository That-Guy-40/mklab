# openbios-clib-hello-to-emacs — the C programs that call the firmware back

Open Firmware and OpenBIOS have **two** ways to add code. The rival lab,
[`../openbios-the-rival-that-shipped/`](../openbios-the-rival-that-shipped/README.md),
taught the first: **Forth/FCode words**, loaded *into* the interpreter and run
*by* it (everything at the `0 >` prompt). This lab teaches the other:
**client programs** — freestanding **machine-code C binaries** the firmware
`load`s and jumps into, which then call *back* into the firmware through the
IEEE 1275 **client interface** (§6.3.2: `finddevice`, `getprop`, `open`, `read`,
`write`, `claim`, `exit`, …). It reproduces Open Firmware's
[`clients/`](https://github.com/openbios/openfirmware/tree/master/clients)
directory — `hello`, a C support library (`lib`), `memtest`, and `emacs` — on
the modern `openbios/openbios` codebase, climbing a ladder from a one-line
`hello` to a RAM tester to a text editor, all running on the bare machine with
**no operating system underneath.**

```text
Rung 1  hello      C program -> firmware `write` -> console            [ppc + x86: DONE]
Rung 2  clib       grow of1275 into a real support lib                 [DONE: console + claim-backed alloc + getch/ANSI]
Rung 3  memtest    claim-backed allocator + /memory walk, tests RAM    [ppc + x86: DONE — memtest: PASS]
Rung 4a edit       interactive client (getch + ANSI), one-line editor  [ppc + x86: DONE]
Rung 4b emacs      MicroEMACS-style: multi-line buffer + keymap +      [ppc + x86: DONE — splits lines, mode line,
                   mode line + tutorial-as-data (the finale)                        tutorial preloaded]

Arc:  ppc proves the mechanism  ─►  revive the x86 client ABI (capstone)  ─►  same clients, both arches  ─►  editor finale  ✅
```

**Status: the ladder is COMPLETE and green on BOTH arches** (verified on this
host, KVM, QEMU 8.2.2). `hello`, a `memtest` client, a tiny **interactive
editor**, and a **MicroEMACS-style multi-line editor** all run as client programs
on stock `qemu-system-ppc` *and* — the capstone — on a **revived OpenBIOS-x86**,
which took six firmware repairs ([POC-4](POC-4-X86-REVIVAL.md), which also
*retracts the lab's own earlier misdiagnosis of that same phase*). **Eight green
smoke verdicts** (four rungs × two arches). Blow-by-blow write-ups:
[POC-1-BUILD-BOX-AND-CLIB.md](POC-1-BUILD-BOX-AND-CLIB.md) (a libc that is one
callback deep), [POC-2-PPC-HELLO.md](POC-2-PPC-HELLO.md) (the firmware runs your
C program), [POC-3-MEMTEST.md](POC-3-MEMTEST.md) (a RAM tester with no OS),
[POC-4-X86-REVIVAL.md](POC-4-X86-REVIVAL.md) (the x86 revival — six repairs, root
cause found), [POC-5-EDITOR.md](POC-5-EDITOR.md) (an interactive editor with no
OS), [POC-6-MICROEMACS.md](POC-6-MICROEMACS.md) (the finale — a MicroEMACS-style
multi-line screen editor, both arches), and [POC-7-DISK-BOOT.md](POC-7-DISK-BOOT.md)
(the same clients loaded off an ext2 **hard disk**, not a CD — on **both** arches:
x86 `disk` (as shipped) / `disk-fat` (after a rebuild enables FAT), and ppc `disk`
on the **stock** blob's native ext2 reader with no build at all).
Roadmap: [PLAN.md](PLAN.md); exact commands + signatures:
[MANUAL_TESTING.md](MANUAL_TESTING.md).

## "A client library" is C, not Forth

The most common confusion (and the one this lab exists to clear up):
OFW's [`clients/lib`](https://github.com/openbios/openfirmware/tree/master/clients/lib)
is a **C runtime library** — `printf.c`, `string.c`, `malloc.c`, and the
callback wrappers in `1275.h` — *not* a collection of Forth words. It is the
libc-substitute that lets a C program stand on its own two feet on a machine
with no libc and no kernel. This lab's `clib/` is the same idea on the modern
codebase:

| extension path | what it is | how it's loaded | example |
|---|---|---|---|
| **Forth / FCode** | words in the dictionary | interpreted by the firmware | device drivers, everything at `0 >` (rival lab) |
| **client program** | machine code (ELF) | `load`ed + entered; calls back via the client interface | `hello`, `memtest`, `emacs` (**this lab**) |

The client entry convention is the one real operating systems use to talk to
Open Firmware: `_start(residual, entry, client_interface_handler, args,
argslen)`. On PowerPC the handler arrives in `r5`; on x86 it arrives on the
stack. See [`clib/README.md`](clib/README.md).

## Why ppc is done and x86 is the capstone

OpenBIOS ships the whole client mechanism — `of_client_interface()` (all 25
services) is compiled into every arch, and `utils/ofclient/` is upstream's own
example client. But it has only stayed *wired up* where it's exercised:

- **ppc** — the client interface **is** the OS boot ABI there (yaboot, Linux,
  the BSDs all enter through it), so it never rotted. Our `hello-ppc` runs on
  the **stock** `qemu-system-ppc` with no firmware build at all (POC-2).
- **x86** — a museum, and reviving it was this lab's capstone (Phase 3, now
  **done**). Every exhibit traced to **one design decision**: x86 relocates
  itself by *rebasing the GDT*, so firmware pointers are segment-relative and
  `virt_offset` scales with RAM size — and nobody ever taught the client path.
  `linux_load.c` wraps every access in `phys_to_virt()`, which is exactly why
  the rival lab's Linux capstone worked and the client path did not. **Six
  repairs** ([`patches/01-x86-client-revival.patch`](patches/01-x86-client-revival.patch),
  applied by [`build-firmware-x86.sh`](build-firmware-x86.sh) on top of the
  rival lab's eight): a `load-base` past the end of RAM, an unplanted callback,
  a file type the loader never declared (leaving *both* arms of a dispatch
  unreachable for years), the flat-vs-rebased segment split, **no console device
  node at all** (`/chosen` stdin/stdout were `0`, so client output vanished),
  and no `cif-claim`. Blow-by-blow — including the design fork and a
  **retraction of this lab's own earlier misdiagnosis** —
  [POC-4](POC-4-X86-REVIVAL.md).

That asymmetry is the lesson, and it rhymes with the rival lab's: *the same
standard, alive where it's used and fossilized where it isn't — and the fossil
takes a C patch, not a séance.*

## Quick start

```console
$ ./build-client.sh ppc hello       # cross-compile clib + hello for PowerPC (container)
$ ./smoke-client.sh ppc hello       # boot stock qemu-system-ppc, run it, one verdict
PASS: OpenBIOS-ppc loaded our C client 'hello' and it answered Hello world! over the IEEE 1275 client interface

$ ./smoke-client.sh ppc memtest     # rung 3: a RAM tester as a client
PASS: OpenBIOS-ppc loaded our C client 'memtest' and it ran the RAM tester to a clean PASS over the IEEE 1275 client interface

$ ./smoke-client.sh ppc edit        # rung 4a: a tiny one-line interactive editor (driven headlessly)
PASS: OpenBIOS-ppc loaded our C client 'edit' and it ran a tiny interactive editor (typed, backspaced, Ctrl-X saved) over the IEEE 1275 client interface

$ ./smoke-client.sh ppc emacs       # rung 4b: a MicroEMACS-style MULTI-line editor (splits lines, mode line)
PASS: OpenBIOS-ppc loaded our C client 'emacs' and it ran a MicroEMACS-style multi-line editor (typed, split a line with Enter, C-x C-c saved-and-exited) over the IEEE 1275 client interface

$ ./run-client-qemu.sh ppc emacs    # interactive: type at it yourself (C-x C-s saves, C-x C-c exits)

$ ./build-firmware-x86.sh           # the capstone: rival lab's 8 x86 fixes + this lab's 6
$ ./smoke-client.sh x86 hello       # same C source, same clib, other arch
PASS: revived OpenBIOS-x86 loaded our C client 'hello' from an ISO9660 CD and it answered Hello world! over the IEEE 1275 client interface

$ ./smoke-client.sh x86 hello disk  # POC-7: load the SAME client off an ext2 hard disk, not a CD
PASS: revived OpenBIOS-x86 loaded our C client 'hello' from an ext2 hard disk and it answered Hello world! over the IEEE 1275 client interface
```

Everything lands in `~/openbios-clients-lab/` (override with
`OPENBIOS_CLIENTS_WORKDIR`); the revived x86 firmware is built in the rival
lab's tree under `~/openbios-lab/`. No sudo anywhere.

## Where this sits

A sibling of the rival lab, one step deeper into the same firmware. The rival
built OpenBIOS and drove its Forth prompt; this one writes C that the firmware
serves. Both live in the **close-to-the-metal** collection (see the
[learning-paths hub](../learning-paths/README.md)); once the x86 capstone lands,
this lab takes its place in the
[`boot-and-crash`](../learning-paths/path-boot-and-crash.md) journey right after
the rival.

## Provenance

Cite-don't-mirror (the design of OFW's `clients/` is cited, not archived), plus
a small **vendored** clib seed — `openbios/utils/ofclient` (GPLv2, pinned to
commit `e5ac46d`) — that this lab *extends*. Details and attribution:
[`clib/README.md`](clib/README.md).
