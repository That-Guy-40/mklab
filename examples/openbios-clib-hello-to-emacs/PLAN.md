# PLAN — openbios-clib-hello-to-emacs

**Status: IN PROGRESS — Phases 0/1/2 COMPLETE and green (ppc); Phases 3–4 planned.**
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
- **Phase 3 — the x86 revival capstone.** Land the 3 fixes so x86 runs the same
  clients:
  1. **CIF-plant** — `arch/x86/context.c arch_init_program` never hands a
     launched client the callback (ppc does, in `r5`). Fix: 5 client param
     slots + `param[2]=&of_client_interface`. **Written & builds**
     ([`patches/00-x86-cif-plant.patch`](patches/00-x86-cif-plant.patch)).
  2. **iso9660 `load`** — the native `fs/iso9660/iso9660_fs.c` "load" method
     leaves garbage at load-base (the rival lab only fixed grubfs; linux_load
     has its own reader, so this path was never run). Visible defect:
     `iso9660_files_{read,seek,load}` do `if (type != FILE) PUSH(...)` with no
     `return` → stack corruption.
  3. **boot detour** — the rival patch's unconditional `linux_load` in
     `arch/x86/boot.c` shadows the generic `$load`; guard it to a real bzImage.
  Then `smoke-client.sh x86` turns green and the ladder runs on both arches.
- **Phase 4 — MicroEMACS.** Editor core + tutorial-as-data; a console/termcap
  shim on clib `read`/`write`. Documented author-run if it outgrows the sandbox.

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
