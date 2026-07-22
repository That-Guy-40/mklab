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
Rung 1  hello      C program -> firmware `write` -> console            [ppc: DONE]
Rung 2  clib       grow of1275 into a real support lib (puts/printf/…) [seed: DONE]
Rung 3  memtest    claim-backed allocator + /memory walk, tests RAM    [planned]
Rung 4  emacs      MicroEMACS port, tutorial-as-data, console shim     [planned]

Arc:  ppc proves the mechanism  ─►  revive the x86 client ABI (capstone)  ─►  same clients, both arches
```

**Status: Phase 0/1 complete and verified on this host** (KVM/TCG, QEMU 8.2.2);
the ppc `hello` is green end-to-end. The rest is planned and spike-de-risked —
see [PLAN.md](PLAN.md). Blow-by-blow spike write-ups:
[POC-1-BUILD-BOX-AND-CLIB.md](POC-1-BUILD-BOX-AND-CLIB.md) (a libc that is one
callback deep) and [POC-2-PPC-HELLO.md](POC-2-PPC-HELLO.md) (the firmware runs
your C program). Exact commands + signatures: [MANUAL_TESTING.md](MANUAL_TESTING.md).

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
- **x86** — the dispatcher is compiled in but **handed to no client**
  (`arch/x86/context.c` never plants the callback), and two more x86-only paths
  are bitrotted on top. This is a *deeper* museum than the Linux-boot path the
  rival lab revived — a client is more general than a kernel — and reviving it
  is this lab's capstone (Phase 3), a 3-fix patch whose first fix is already
  written ([`patches/00-x86-cif-plant.patch`](patches/00-x86-cif-plant.patch)).

That asymmetry is the lesson, and it rhymes with the rival lab's: *the same
standard, alive where it's used and fossilized where it isn't — and the fossil
takes a C patch, not a séance.*

## Quick start

```console
$ ./build-client.sh ppc hello     # cross-compile clib + hello for PowerPC (container)
$ ./smoke-client.sh ppc           # boot stock qemu-system-ppc, run it, one verdict
PASS: OpenBIOS-ppc loaded our C client and serviced its write() over the IEEE 1275 client interface (Hello world!)

$ ./run-client-qemu.sh ppc hello  # interactive: drops you at 0 > to type `boot cd:\HELLO.;1` yourself
```

Everything lands in `~/openbios-clients-lab/` (override with
`OPENBIOS_CLIENTS_WORKDIR`). No sudo anywhere. The x86 track builds today
(`build-client.sh x86`) but only *runs* after the Phase-3 revival —
`smoke-client.sh x86` SKIPs with a pointer until then.

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
