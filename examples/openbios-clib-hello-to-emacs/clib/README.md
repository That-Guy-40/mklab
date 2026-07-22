# `clib/` — the C support library for OpenBIOS client programs

This directory is the lab's counterpart to Open Firmware's
[`clients/lib`](https://github.com/openbios/openfirmware/tree/master/clients/lib):
a small **C runtime that lets a plain C program run standalone on the
firmware**, with no operating system underneath it. A client program is *not*
Forth — it is machine code the firmware `load`s and jumps into, which then
calls *back* into the firmware through the single callback of the IEEE 1275
**client interface** (§6.3.2). `clib` is the glue that makes those callbacks
look like ordinary C functions.

## The two layers

| file | role | analogous to OFW `clients/lib` |
|---|---|---|
| `of1275.h` / `of1275.c` | C wrappers for every client-interface service (`finddevice`, `getprop`, `open`, `read`, `write`, `claim`, `exit`, …) plus `_start`, which receives the callback pointer | `1275.h`, `callofw.c`, `property.c` |
| `of1275_io.c` | POSIX-shaped `write` / `read` / `exit` over the stdout/stdin ihandles in `/chosen` | `stdio.h`, `wrappers.c` |
| `endian.h` | host-vs-firmware cell byte-order helper (a no-op on big-endian ppc, a swap on x86) | (folded into the arch subdirs) |
| `clib.h` / `clib.c` | **this lab's growth layer**: console out (`strlen`, `puts`, `put_udec`, `put_hex` on `write`), memory (`clib_claim`/`clib_release` on the `claim` service, `clib_ram_bytes` from `/memory`), and interactive console (`getch` polling the `read` service, `put_char`, `cls`, `gotoxy` via ANSI) | `string.c`, `printf.c`, `malloc.c`, `lib.c` |

The client entry convention is the same one real operating systems use to talk
to Open Firmware: `_start(residual, entry, client_interface_handler, args,
argslen)`. On PowerPC the handler arrives in `r5`; on x86 it arrives on the
stack. Everything `clib` does is one `client_interface_handler(&service)` call
away from the bare machine.

## How it grows (the ladder)

`clib` starts deliberately small — enough for `hello.c` (rung 1). It fleshes
out as the ladder climbs (see [`../PLAN.md`](../PLAN.md)):

- **memtest** (rung 3, **done**) added a `claim`-backed allocator
  (`clib_claim`/`clib_release`) and the `/memory` `reg` walk (`clib_ram_bytes`)
  — see `memtest.c`.
- **edit** (rung 4, **done**) added the interactive console — `getch`,
  `put_char`, `cls`, `gotoxy` (ANSI, no termcap) — see `edit.c`, a tiny editor.
- **MicroEMACS** (rung 4 finale) grows a buffer model + keymap on that same
  shim; a large mechanical port, still to do.

Never a syscall, never an `#include <stdlib.h>` — the "system call" *is* the
firmware callback.

## Provenance

`of1275.{c,h}`, `of1275_io.c`, and `endian.h` are vendored from
**`openbios/openbios`**'s in-tree client example
[`utils/ofclient/`](https://github.com/openbios/openbios/tree/master/utils/ofclient)
(commit `e5ac46d`, retrieved 2026-07-22), whose own `README` states it is *"an
example program using the openfirmware client interface on x86 — the same
program can be compiled on ppc."* OpenBIOS is **GPLv2** (repo `COPYING`; the
`ofclient` files carry no separate per-file notice, so the repo license
governs). `clib.{c,h}` and `hello.c` are this lab's original work and inherit
GPLv2 to match the code they link against. The *concept* — a `clients/`
directory of C programs that call back into firmware — is Open Firmware's,
which this lab reproduces on the modern codebase; the design background is
cited (not mirrored) per the repo's provenance convention. `git rm` to remove
the vendored copies.
