# pacme: touring a live firmware inspector

_Oct 2, 2026_

GNU poke's acme-style UI, pointed not at a captured file but at a **running OpenBIOS firmware's own bytes** — and every structured view graded against the firmware's own Forth toolkit, never trusted on its own. Built and verified end to end this session: from the raw byte seam, through pickle-versus-Forth grading, to editing live RAM and driving the interactive TUI headlessly — with honest UNKNOWN-is-not-PASS boundaries throughout. GNU poke is GPLv3 and runs on the host beside QEMU; it is never linked into the GPLv2 firmware.

## At a glance

Host-side tools inspect one firmware running in QEMU across four seams — and a view counts only when an independent reader agrees with the firmware's own.

```text
           HOST  (GNU poke — GPLv3, never linked into the firmware)
  +-----------------------------------------------------------------+
  |   pacme TUI  --->  poked  <---  plet-repl / plet-out / plet-in   |
  |       ^              |          pickles:  fdt.pk  cbfs.pk  pe.pk |
  |   ttydrive           |                                          |
  |  (drives + grades)   |                                          |
  +----------------------|------------------------------------------+
                         |
     serial        NBD   |   gdbstub            QMP
   (drive the      (live |   (live RAM:         (oracle: xp / pmemsave,
    prompt)        block |    m/M packets)       the neutral check)
                   store)|
        v            v   v        v                  v
  +-----------------------------------------------------------------+
  |   QEMU  .  OpenBIOS firmware   (GPLv2)                           |
  |   dsl/ Forth toolkit + the conformance contract                 |
  |   /dt device tree  .  NVRAM store  .  live RAM                   |
  +-----------------------------------------------------------------+

   the grade:   poke pickle  ==  dsl/ Forth reader  ==  foreign oracle
```

Read it top-down: you drive pacme (or a headless smoke through `ttydrive`); `poked` runs your Poke against the firmware over one of the seams; and whatever it shows is checked against the firmware's own `dsl/` reader and a third-party tool of the same bytes.

## The pacme TUI and its pokelets

pacme is not one program — it is a handful of tiny C "pokelets" that a tmux session arranges into panes, each talking to the `poked` daemon over a Unix socket. Its prefix key is `C-g`; pressing `C-g F2` builds Layout 2: a REPL pane on top, an output pane below.

```text
#!poke!# var f = open("live.dtb")          <- plet-repl: you type Poke here
#!poke!# set_endian (ENDIAN_BIG)
#!poke!# printf ("MAGIC=%u32x\n", uint<32> @ 0#B)
#!poke!#
----------------------------------------------------
MAGIC=d00dfeed                              <- plet-out: the RESULT renders here
```

The pokelets, each one process:

| pokelet | role |
| --- | --- |
| `plet-repl` | the readline prompt (`#!poke!#`); sends a line of Poke to `poked` |
| `plet-out` | renders what `poked` emits — values, byte-dumps, errors |
| `plet-in` | feeds a highlighted region of text into `poked` for evaluation |
| `plet-poke-disas` | a disassembly view (built only when capstone is present) |

The telling detail, measured while automating it: a REPL **result** lands in the `plet-out` pane, not next to the prompt that asked for it — the prompt pane only echoes what you typed. pacme links no libpoke of its own; every pokelet is a thin client of the one `poked`. The whole thing is built from source by `build-pacme.sh` (no sudo, into a lab-local prefix) and driven + graded with no human at the keyboard by `smoke-pacme-ui.sh`, using `tools/ttydrive` to type keys and read the panes back.

## The firmware tools being graded

pacme never grades itself — it is graded against the firmware's own Forth toolkit, the `dsl/` reader family that OpenBIOS loads and runs in-place. Each reader decodes one binary format; a shared **conformance contract** makes them all answer the same questions the same way, so a second reader (a poke pickle, `objdump`, `cbfstool`) can be held against them field for field.

The contract, verb by verb:

| verb | what it answers |
| --- | --- |
| `NAME-open` | bind a reader to a buffer; refuse a wrong magic by name |
| `NAME-fields` | the field-offset table — where each field physically lives |
| `NAME-validate` | the invariants that must hold (magic, bounds, versions) |
| `NAME-manifest` | a one-line stance: `HOST-ONLY` / `LIVE` / `SNAPSHOT` |
| `NAME-write` | edit a field in place (pe, cpio, bootparams, cbfs) |
| `NAME-emit` | synthesize a structure from scratch (elf, evlog, fdt) |
| `NAME-live` | re-read the live subject each call; first consumer is `fdt-live` |

The readers themselves — `fdt` (device tree), `pe` (UKI/PE32+), `cpio` (initrd), `bootparams` (the x86 boot protocol), `cbfs` (coreboot flash), plus `elf` and an event-log emitter — are the firmware's ground truth. The lab's whole discipline is that a view is only believed when an independent reader of the *same bytes* agrees with the toolkit.

## Pickle versus fdt / pe / cbfs

The core grade: a GNU poke **pickle** decodes a firmware structure, and every field it reports must match the Forth `dsl/` reader of the same bytes **and** a neutral third-party tool. Three readers, one artifact — so the firmware's own reader is never its own oracle.

| subject | poke pickle | Forth reader | foreign oracle | byte order | liveness |
| --- | --- | --- | --- | --- | --- |
| **FDT** (device tree) | `fdt.pk` (ours) | `dsl/fdt.fth` | `fdtdump` | big-endian | **LIVE** (`fdt-live`) |
| **PE** (UKI / PE32+) | `pe.pk` (poke's own) | `dsl/pe.fth` | `objdump` | little-endian | HOST-ONLY |
| **CBFS** (coreboot ROM) | `cbfs.pk` (ours) | `dsl/cbfs.fth` | `cbfstool` | big-endian | HOST-ONLY |

Three details make it a real test, not a coincidence. The byte orders differ — FDT/CBFS are big-endian, PE little-endian — so the readers genuinely disagree about raw bytes and only agree on *decoded fields*; that is why a big-endian host (ppc) earns its keep. poke ships a `pe.pk` already, so only `fdt.pk` and `cbfs.pk` are ours. And each carries a **control that bites**: point the pickle one byte off, or flip the magic, and it is refused by name — watched to fail, not assumed to.

Only FDT is **live**: OpenBIOS builds and can modify its own `/dt`, so `fdt-live` re-flattens the running tree each call and a tree change shows up while an independent snapshot does not. PE and CBFS are static files, labelled `HOST-ONLY` — not dressed up as live.

## Editing live RAM

poke reads **and writes the running firmware's RAM** — the lab's last snapshot-only boundary, now closed. The trick: libpoke lets an embedding program register a *foreign IO device* (`pk_register_iod`), so a small C tool, `pokegdb` (`gdb-iod.c`), makes poke's every read and write into a gdb Remote-Serial-Protocol `m`/`M` packet aimed at QEMU's own gdbstub. poke's `pread` becomes `m<addr>,<len>`; its `pwrite` becomes `M<addr>,<len>:<bytes>`.

The grade, three live readers of one running guest:

1. The firmware writes a unique nonce into a buffer it allocated.
2. We find that value in **physical RAM** by scanning a QMP `pmemsave` dump — never assuming an address, because a Forth address is not a physical one on x86 OpenBIOS (the `ofmem` offset is real).
3. `pokegdb` reads that offset over the gdbstub; the QMP `xp` monitor reads it; the firmware prints it. All three agree.
4. The firmware overwrites the cell. The **same** poke reader sees the new value through the gdbstub (LIVE); a snapshot *file* taken before still shows the old one (SNAPSHOT).
5. `pokegdb` then **writes** a value, and both QMP and the firmware's own read see it — poke edited memory the firmware is using.

Why the addresses line up: OpenBIOS x86 runs with paging off (`CR0.PG=0`), so a gdb linear address *is* the guest-physical address and equals QMP `xp` — the equivalence the cross-check leans on. The honest boundary: this works on x86 (stated), the gdbstub is QEMU's `-gdb` debug transport (a lab instrument, not a firmware feature), and a vacuous "live" cannot pass — the grade asserts the live read changed *and* the snapshot did not.

## The spike ladder

Every rung of the lab's plan is built and graded — bridge to interactive UI, nothing deferred. Each is one host-verifiable smoke that ends in a single `PASS`/`FAIL`/`SKIP` line and carries a control it watched bite.

| rung | what it proves | the smoke |
| --- | --- | --- |
| Spike 0 | the bridge: QMP-NBD exposes a *live* block node; the writable-export hazard measured, not assumed | `bridge.sh` |
| Spike 1 | the seam is faithful: poke's bytes over NBD == `od` of the live store | `smoke-pacme-seam.sh` |
| Spike 2 | pickle == Forth == foreign oracle, across FDT / PE / CBFS; lands the contract's `NAME-live` | `smoke-pacme-{fdt,pe,cbfs}.sh` |
| Spike 3-lite | poke's field byte-spans match the toolkit's offset table — agreement on *where*, not just *what* | `smoke-pacme-span.sh` |
| Spike 4 | poke **edits** the live NVRAM store (share-rw NBD); a fresh boot reads the edit | `smoke-pacme-edit.sh` |
| Spike 5 | poke reads **and edits live RAM** via a bespoke gdbstub IO device | `smoke-pacme-live-ram.sh` |
| Spike 3-full | the interactive tmux UI, built from source and graded headlessly via `ttydrive` | `build-pacme.sh` + `smoke-pacme-ui.sh` |

The build order was deliberate: prove the raw seam before interpreting it, grade a pickle against the Forth before trusting either, and only then climb to editing live state and driving the UI — each rung standing on the one below.

## How it stays honest

The lab's rules are what keep "it works" from meaning "the check was easy." Each is concrete here, not a slogan:

- **A second reader, never self-grading.** Every pacme view is held against the Forth toolkit and a foreign tool of the *same bytes*. The firmware's own reader is never its own oracle.
- **Run the negative control; watch it bite.** A flipped magic must be refused by name; a read one field over must *not* find the value; a "live" read is only believed when the live handle changed and the snapshot did not. Assertions were watched failing, not reasoned about.
- **UNKNOWN is a verdict, distinct from PASS.** The UI smoke grades the data path (REPL → poked → output); it does **not** claim the UI's visual ergonomics — that stays a by-hand judgement. The live-RAM result is scoped to x86 with paging off, and says so.
- **Derive the fact; don't trust an address.** A Forth address is not a physical one, so a firmware-written value is *located by scanning physical RAM*, never assumed from the Forth pointer.
- **Fix the liar first.** A grade that once passed on garbage — scraping hex out of a command echo — was caught by distrusting an impossible number, and repaired before anything was built on it.

The tools carry the same discipline: `ttydrive` ships with a test that drives a nested tmux and reads both panes, so a tool nobody watched work does not rot.

## Try it yourself

Everything lives in `examples/pacme-inspects-the-firmware/`. Each smoke prints one `PASS`/`FAIL`/`SKIP` line and skips by name without its prerequisites (GNU poke, QEMU, a built OpenBIOS).

```sh
cd examples/pacme-inspects-the-firmware
./deps.sh                                                 # what's installed, what's missing

# the grades (pickle vs the Forth toolkit vs a foreign oracle)
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-fdt.sh      # fdt.pk == dsl/fdt.fth == fdtdump, + NAME-live
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-pe.sh       # pe.pk == dsl/pe.fth == objdump
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-cbfs.sh     # cbfs.pk == dsl/cbfs.fth == cbfstool

# editing live state
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-edit.sh     # edit the live NVRAM store; a fresh boot reads it
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-live-ram.sh # read + edit live RAM through the gdbstub IOD

# the interactive UI: build pacme from source, then grade its panes headlessly
./build-pacme.sh
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-ui.sh
```

To *watch* the UI rather than grade it, `MANUAL_TESTING.md` has the by-hand drive: start `poked`, launch pacme, press `C-g F2`, and type Poke at the `#!poke!#` prompt — the result appears in the output pane. That interactive feel is the one thing a machine here does not judge for you.
