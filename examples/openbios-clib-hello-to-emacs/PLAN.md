# PLAN — openbios-clib-hello-to-emacs

**Status: IN PROGRESS — Phases 0/1/2 COMPLETE and green (ppc); Phase 3
ROOT-CAUSED, 2 of 4 fixes landed — the x86 firmware now loads our client and
enters it, blocked on the CIF trampoline (POC-4); Phase 4 foundation COMPLETE
and green (an interactive editor client — POC-5), full MicroEMACS port
remaining.**
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
- **Phase 3 — the x86 revival capstone. ⏳ ROOT-CAUSED; client loads and runs
  (POC-4).** **One root cause, four repairs** — x86 relocates itself by
  *rebasing the GDT* (`arch/x86/segment.c`), so every firmware address is
  segment-relative and `virt_offset` scales with RAM size. `linux_load.c`
  translates everything with `phys_to_virt()`; the generic client path never
  did, and that is the whole rot.
  1. **CIF-plant — ✅ written.** `arch/x86/context.c arch_init_program` never
     hands a launched client the callback (ppc does, in `r5`). 5 client param
     slots + `param[2]` ([`patches/00-x86-cif-plant.patch`](patches/00-x86-cif-plant.patch)).
     Incomplete — see #4.
  2. **`load-base` — ✅ FIXED, verified.** The `0x4000000` constant resolved to
     physical ~597 MB, past the end of RAM; reads returned zeros while the
     device reported full success. Now computed at runtime as
     `phys_to_virt(4 MiB)`. `load-base l@` = `464c457f` (`\x7fELF`),
     `load-size` = 7748. **The file load works.**
  3. **Client ELF copy — ✅ FIXED, verified.** `elf_load.c` copied segments to a
     raw `p_vaddr`, landing *inside the relocated firmware* and GP-faulting.
     Now `phys_to_virt()`, matching the elf-boot path in the same file. **`go`
     now enters the client and it executes its own code.**
     (2+3: [`patches/01-x86-load-base-and-elf-copy.patch`](patches/01-x86-load-base-and-elf-copy.patch).)
  4. **CIF trampoline — ⏳ OPEN, scoped.** The client runs with **flat** base-0
     segments while firmware runs rebased, so `param[2]` needs `virt_to_phys` +
     a segment-switching trampoline, *and* every pointer crossing the boundary
     (the params array and the strings inside it) needs translating in
     `libopenbios/client.c`. Alternative worth weighing: enter the client with
     the `RELOC` segments so nothing needs translating. That design call is the
     next step.
  Until #4 lands, `smoke-client.sh x86` `SKIP`s with a pointer to POC-4.
  **POC-4 also retracts its own earlier diagnosis** ("reaches none of the
  loaders" / "the disk-label wiring is broken") — both were instrument
  artifacts; the wiring was always fine.
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
