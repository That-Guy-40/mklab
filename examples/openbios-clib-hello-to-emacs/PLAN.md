# PLAN — openbios-clib-hello-to-emacs

**Status: Phases 0–3 COMPLETE and green on BOTH arches — the capstone is done.**
`hello`, `memtest`, and `edit` all run as IEEE 1275 client programs on stock
`qemu-system-ppc` *and* on a revived OpenBIOS-x86 (six firmware repairs, POC-4);
six green smoke verdicts. Phase 4's foundation is complete (POC-5); the full
MicroEMACS port is the remaining finale.
Follow-on to [`../openbios-the-rival-that-shipped/`](../openbios-the-rival-that-shipped/README.md).
Same house style, same spike→POC→assemble lifecycle. Where the rival lab taught
**Forth/FCode** extension (words loaded *into* the interpreter), this lab teaches
the *other* IEEE 1275 extension path: **client programs** — machine-code C
binaries the firmware `load`s and enters, which call *back* into firmware
through the client interface (§6.3.2). It reproduces Open Firmware's
[`clients/`](https://github.com/openbios/openfirmware/tree/master/clients)
directory (`hello`, `lib`, `memtest`, `emacs`) on the modern `openbios/openbios`
codebase.

## Thesis

`clients/lib` is a **C runtime library**, not a bag of Forth words: it lets a
plain C program run standalone on the bare machine, with the firmware callback
standing in for the operating system. OpenBIOS already ships the mechanism
(`utils/ofclient/`, and `of_client_interface()` — all 25 services — compiled
into every arch), so the question was never "can it?" but "where has it rotted?"
Answer, from the spikes: **the client interface is alive on ppc and a museum on
x86** — a deeper museum than even the *Linux*-boot path the rival lab revived,
because a client is a more general thing than a kernel.

## The two de-risking spikes (out-of-tree, agent-verified — see POC-1/POC-2)

| # | de-risks | outcome | POC |
|---|---|---|---|
| A | does the shipped client interface actually enter a C client? | **PASS (ppc)** — `hello` loaded from CD, `boot`, "Hello world!" over the CIF | [2](POC-2-PPC-HELLO.md) |
| B | what does x86 need? | **gap confirmed + root-caused** — a 3-fix revival; fix #1 (CIF-plant) written & builds | [PLAN §Phase 3] |

## Decisions (user-confirmed)

- **Name** `openbios-clib-hello-to-emacs` (names the ladder + the C library).
- **Both arches; x86 revival is the capstone.** ppc proves the mechanism early
  (its client entry-glue is already wired); the lab then *builds toward*
  completing the x86 client ABI as its climax.
- **Ladder:** `hello → clib → memtest → emacs` (a RAM-tester client, then a
  MicroEMACS port with its tutorial as data).
- Routing: joins `close-to-the-metal`; a `boot-and-crash` step is added once the
  x86 capstone lands (so the journey never advertises an unfinished lab).

## Phases

- **Phase 0 — build box + clib. ✅ DONE.** Lean cross-toolchain container
  (`Containerfile`); vendored `utils/ofclient` as the clib seed
  (`clib/of1275*`), grown with `clib.{c,h}` (`puts`/`put_udec`/`put_hex` on the
  firmware `write` service). `build-client.sh [ppc|x86] [program]`.
- **Phase 1 — ppc proves it. ✅ DONE (green).** `smoke-client.sh ppc`: stock
  `qemu-system-ppc` loads `hello-ppc` from a CD and answers `Hello world!` +
  the clib number formatting, all over the client interface. POC-2.
- **Phase 2 — memtest as a client. ✅ DONE (green).** `clib` grew a
  `claim`-backed allocator (`clib_claim`/`clib_release`) and a `/memory` `reg`
  walk (`clib_ram_bytes`); `clib/memtest.c` claims 4 MiB and runs
  address-uniqueness + four data fills + a walking-bit pass, reporting
  `memtest: PASS`. `smoke-client.sh ppc memtest`.
  [POC-3](POC-3-MEMTEST.md).
- **Phase 3 — the x86 revival capstone. ✅ DONE (green). POC-4.** All three
  clients — `hello`, `memtest`, `edit` — run on a revived OpenBIOS-x86, verified
  by `smoke-client.sh x86 {hello,memtest,edit}` on KVM. **Six** repairs, not the
  three scoped, all descending from one design decision: x86 relocates the
  firmware by *rebasing the GDT*, so firmware pointers are segment-relative and
  `virt_offset` scales with RAM size — and nobody ever taught the client path.
  1. `load-base` resolved past the end of RAM (reads returned zeros while the
     device reported full success) → computed at runtime.
  2. The launched client was never handed the callback (ppc plants it in `r5`).
  3. The ELF loader never declared `>ls.file-type`, so *both* arms of
     `arch_init_program`'s type test had been unreachable for years.
  4. The client was entered with **flat** segments. Fork: a trampoline + rewriting
     the dispatcher (every `pb->args[i]` may or may not be a pointer, per
     service), versus entering the client in the firmware's **`RELOC`** segments
     so nothing needs translating. Chose the latter; the client links at
     `0x20000`, inside a window that sizes itself with `virt_offset`.
  5. x86 had **no console device node** — `/chosen` stdin/stdout were both `0`,
     so every client `write()` went to ihandle 0 and vanished. Wrapped the
     console the arch already has in an `open`/`read`/`write` node.
  6. x86 bound no **`cif-claim`** → a bump allocator over the free window.
  All six: [`patches/01-x86-client-revival.patch`](patches/01-x86-client-revival.patch),
  applied by [`build-firmware-x86.sh`](build-firmware-x86.sh) on top of the rival
  lab's eight. POC-4 also **retracts an earlier misdiagnosis of this same
  phase** — "reaches none of the loaders" was an instrument artifact.
- **Phase 4 — the editor rung. ✅ FOUNDATION DONE (green); full port remaining.**
  `clib` grew its console half — `getch` (polls the non-blocking firmware
  `read`), `put_char`, `cls`, `gotoxy` (ANSI). `clib/edit.c` is a tiny
  interactive line editor (input loop + echo + Backspace + Ctrl-X) that runs as
  a client and is driven headlessly: `smoke-client.sh ppc edit` types `hellX`,
  Backspaces the `X`, adds `o`, Ctrl-X → `edit: wrote 5 chars: hello`. POC-5.
  This proves the interactive foundation; the literal `emacs` finale is a
  **MicroEMACS port** (multi-line buffer + keymap + tutorial-as-data) on top of
  the same shim + `clib_claim` — a large mechanical port, the honest next step.

## Justified deviations

- **No firmware build for the ppc track.** The ppc client is entered by the
  *stock* `qemu-system-ppc` (its OpenBIOS already wires the CIF), so Phase 0/1
  need no OpenBIOS compile at all — only a cross-gcc. The `Containerfile` stays
  lean until Phase 3 needs toke/xsltproc.
- **Provenance = cite-don't-mirror**, plus a small **vendored** clib seed
  (`utils/ofclient`, GPLv2, pinned to commit `e5ac46d`) that we *extend* — see
  [`clib/README.md`](clib/README.md). Joins `close-to-the-metal`, NOT
  `provenance-vendored`.
- **New state dir** `~/openbios-clients-lab/` (client binaries, ISOs, logs).

## Verification

Phase 1: `smoke-client.sh ppc` PASSes on this host (KVM/TCG); MANUAL_TESTING
carries the real transcript. Both catalogs green (`paths.py --check`,
`link_check.py`). Committed only when asked.
