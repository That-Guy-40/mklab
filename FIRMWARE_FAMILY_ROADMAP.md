# Firmware family — a foundation-first roadmap (2026-09-15; gap analysis re-measured 2026-09-16)

> **Corrected 2026-09-16.** The first draft of this note was written away from the tree
> and said the shared structure toolkit "does not yet exist as built, tested,
> oracle-graded code." **That was a cached fact served after its subject changed** — the
> repo's own stale-record bug class, applied to its own planning. Measured against the
> checkout: the [preboot structure toolkit](PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md) records
> Spikes −1 through 5 **done, 2026-09-01→03**, and six of the seven named modules are on
> disk in one lab, each graded against a foreign oracle. §1 and §3 below are the *measured*
> gap; **§2 (the architecture decision) is unchanged, word for word** — the evidence for
> it turned out to be stronger in the built code than in the plans.

The OpenBIOS firmware family has ten design docs describing capstones that all
consume a shared structure toolkit (`dsl/struct.fth`, `dsl/elf.fth`,
`dsl/pe.fth`, `dsl/fdt.fth`, `dsl/cbfs.fth`, `dsl/sha256.fth`,
`dsl/eventlog.fth`). This note fixes the build order — **conform the foundation,
then walls, then tying it together** — pins every unbuilt plan to it, and settles
the one load-bearing architecture decision the plans have been assuming without
stating: **the readers and writers are a federation of separable modules behind a
thin shared contract, NOT one fused DSL.** Tracked in [`TODO.md`](TODO.md) §33.
This note is a **build order and an architecture decision; it schedules nothing**
and it does not touch the provisioning-toolkit goals in [`PLAN.md`](PLAN.md).

## 1. The gap, measured (2026-09-16)

Everything in this section was derived from the checkout at `eae9281`, not from
the plan documents. The lab is
[`examples/openbios-the-rival-that-shipped/`](examples/openbios-the-rival-that-shipped/README.md);
its `dsl/` holds 14 files, 2,403 lines.

- **Six capstones are plan-only:** the [attested boot](ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md)
  (`openbios-measures-its-own-boot`), the [coreboot ROM workbench](COREBOOT_ROM_WORKBENCH_LAB_PLAN.md)
  and [verified boot](COREBOOT_VERIFIED_BOOT_LAB_PLAN.md), the
  [UKI](UKI_WORKBENCH_LAB_PLAN.md) and [UEFI](UEFI_WORKBENCH_LAB_PLAN.md)
  workbenches, and the [pacme inspector](DESIGN-NOTES-pacme-a-live-firmware-inspector.md).
  None is built. *(This row was right.)*
- **The toolkit they import IS built — in one lab, not scattered across three.**
  Every module lives in `openbios-the-rival-that-shipped/dsl/`; the sibling
  Open Firmware labs carry debugging DSLs (`ofscope`, `detok`, `patch`, `tracers`)
  and **no format reader at all** — the only thing that ever crossed between labs
  was `region-snap`/`region-diff`, ported *into* this one. Per module:

  | module | state | foreign oracle | arches |
  |---|---|---|---|
  | `struct.fth` — static layer **and** the TLV cursor (`type:` `>rec` `alignto` `t@+` `t!+` `vbytes` `vfield:`) | **built; Spike 0 decided (B), 2026-09-02** | — (the substrate) | 4/4 (`tlv-primitives`, in CI) |
  | `sha256.fth` | built, 2026-09-03 | NIST vectors; PCR replay equals `tpm2_eventlog` and python `hashlib` | 4/4 (`event-replay`) |
  | `elf.fth` + optional `elf32.fth` | built | `readelf`, `eu-elflint`; ELFkickers for the writer | 4/4 (`elf-gate`, `elf-ladder`, in CI) |
  | `cbfs.fth` (+ `cbfs-write`, `cbfs-payload`) | built, read **and** write | coreboot's own `cbfstool`; `readelf` for payload segments | 4/4 read; write unix-only (`write-file` is hosted) |
  | `eventlog.fth` (reader, author, replay) | built | `tpm2_eventlog`; a real edk2/swtpm log replays to the machine's own PCRs 8/8 | unix (`event-*`) |
  | `fdt.fth` (writer) + `fdt-read.fth` (reader) | built, both halves | `dtc`, `fdtdump`, `fdtget` | 4/4 (`fdt`, `fdt-import`, in CI) |
  | `pe.fth` | **absent** | — | — |
  | `bootparams.fth` | **absent** | — | — |

- **The writers are not "the least-built half" either.** `elf-write.fth`,
  `cbfs-write.fth` (two negative controls that `cbfstool` rejects), `fdt.fth`'s
  `dt>fdt` and `eventlog.fth`'s `evlog-author` all exist and are oracle-graded.
  The first draft's Tier 2 pointed at [TODO §24](TODO.md), which is the x86
  **floppy** FDC write and the sun4m store — device *backing stores*, a different
  axis from a format's writer half.
- **What the plans could not see, and the code shows: drift already happened, in
  the refusal convention.** Four modules refuse a bad input four different ways —
  `elf.fth` **aborts** through `struct.fth`'s `chk` with a message; `fdt-read.fth`'s
  `fdt-open ( adr -- ok? )` **returns a flag** and prints `BAD-MAGIC`;
  `eventlog.fth` **sets a variable** (`ev-err`) and prints `!BADALG`; and
  `cbfs.fth`'s `cbfs-list` **stops silently** at the first non-`LARCHIVE` and
  prints `CBFS-END` — so a corrupt first entry is indistinguishable from an empty
  CBFS. The last is a defect, not a style: the tracks never feed it a corrupt ROM
  because `cbfstool`'s listing is the oracle. *This* is the evidence for §2's
  contract — not ten documents disagreeing about an API, but four modules that
  already do.
- **Where the contract's vocabulary already exists, by hand.** `elf.fth`'s
  `hook` aborts with `this is an ELF32 and dsl/elf32.fth is not loaded` — the
  registry's "name what is absent," done once for one module pair. `?elf64`
  refuses a big-endian ELF *by name* rather than misread it (the honest halt).
  `struct.fth` already keeps `t-off`/`t-width`/`t-order` per field — the
  `NAME-fields` enumerator's data is there; only the word is missing. Each
  module's header carries its manifest as **prose** (what it is NOT, what is
  optional) with no word to ask.
- **Measured HERE is not measured THERE.** Tier-b CI's `DEFAULT_TRACKS` runs the
  struct/elf/tlv/fdt/optrom/dict-budget/marker set on all four arches. **`cbfs*`,
  `event-*`, `file-writer` and `region-diff` are in no workflow** — `ci.yml` runs
  the lab's `tests/run-all.sh` headless, where those wrappers SKIP for want of the
  coreboot ROM and `tpm2-tools`. So the attestation half (SHA-256 vectors, the
  event log against `tpm2_eventlog`) and the CBFS half are green only on the
  development host. `dict-budget` compiles `sha256.fth` on four arches in CI but
  measures *fit*, not digests.
- **The risk is still plan drift**, but its shape is different from the first
  draft's: the capstones assume a reader API that exists and is *inconsistent*,
  so the moment of pinning (§2's `contract vN`) is when each capstone is built.

And the repo's loudest cultural rule points the same way — *"an experiment nobody
can re-run is a story"* (TODO §0). A plan that misdescribes what is built is a
story about a story. The cure is the conformance pass in §3, on code that runs.

## 2. Architecture decision (LOCKED): a federation, not a fusion

**The readers and writers stay separate.** One format, one module, each
**removable, addable, and composable** on its own. This is deliberate and it is
the owner's stated intent, for three reasons that outrank the mild convenience of
one big file:

1. **Prunability for real hardware.** If any of this firmware is ever written to
   a real chip, the image must slim to only the formats that machine needs. A
   fused DSL cannot be slimmed; a federation drops the modules you don't load.
2. **Repo-split-ability.** The firmware family may one day live in its own repo,
   apart from metal-as-a-service and the provisioning labs. Separable modules
   with a small shared substrate lift cleanly; a monolith does not.
3. **Composition is the point.** The family's pedagogy is "the same toolkit reads
   ELF *and* CBFS *and* the event log." That reads best as parts you can name and
   combine, not one opaque whole.

**What is genuinely shared (the substrate) versus what stays separate (the
formats).** Standardize the *interface*, not the *implementations* — the "in part,
from each layer" the owner asked for:

- **Shared substrate (small, and the only true dependency):** the `struct.fth`
  cursor/TLV primitives and `alignto` (the preboot toolkit's Spike 0 rung), plus
  `sha256.fth`. These are the bytes-and-math floor every format needs and none
  should re-implement.
- **The conformance contract (a convention, not a framework):** each module
  *opts in* to a tiny, uniform vocabulary so a capstone can consume any module
  the same way, without the modules being fused. Required core, per module `NAME`:
  - `NAME-open ( addr len -- handle )` — bind to a buffer, refuse a bad magic **by name**.
  - `NAME-fields ( handle -- )` — enumerate fields (name, offset, size) for the
    grader and the UI.
  - `NAME-validate ( handle -- reason|0 )` — the format's invariants; `0` = valid,
    else a named reason (the `pe.pk` validity-catalog idea, per format).
  - `NAME-manifest` — self-description: what it reads, what it deliberately does
    **not**, its **honesty label** and **arch scope** (§5).
  - Optional extensions, taken "in part": `NAME-emit`/`NAME-write` (the writer
    half, §4), `NAME-live` (a seam-backed handle, for pacme).
- **A loader/registry that composes what is present and NAMES what is absent.**
  Loading module `X` registers it; a build without `X` is not an error, it prints
  `MODULE X: not loaded` — a slimmed profile, legible as one. This is what makes
  prunability checkable rather than claimed.

The contract is versioned (`contract vN`). Each capstone plan gains a one-line pin
— *"consumes {elf, pe, sha256} at contract v1"* — as it is built, so drift closes
at the moment of building, not after.

## 3. Build order — conform the foundation, then walls, then roof

### Tier 0 — conform what is built (nothing else starts until this is green)

The foundation exists; Tier 0 is a **conformance pass over running code**, not a
build. Each item is small because the pieces are already there:

0. **One refusal convention.** `NAME-validate ( handle -- reason|0 )` for every
   module, implemented once at the seam all of them already pass through —
   `struct.fth`'s `chk`/`chk<`/`chk?` — so a refusal is a *returned, named reason*
   and the `abort"`/flag/variable/silent-stop quartet in §1 collapses to one shape.
   **Fix `cbfs-list`'s silent stop while there**: a bad first magic is refused by
   name, and a corrupt ROM becomes the track's negative control.
0. **`NAME-fields` in the substrate.** Derive the enumerator from the metadata
   `struct.fth` already keeps per field (`t-off`/`t-width`/`t-order`); every module
   gets it for free and none hand-lists a layout twice.
0. **`NAME-manifest` as a word.** Lift the honesty prose each header already
   carries (what it is NOT, what is optional, `HOST-ONLY`, arch scope — §5) into a
   word a checker can call.
0. **The registry.** Generalise `elf.fth`'s `hook` (`… dsl/elf32.fth is not
   loaded`) into the loader that names every absent module the same way.
0. **The conformance checker**, `check-module-conforms.sh`: proves every module
   implements the required core, that `NAME-manifest` is honest, and — the
   separability guarantee — that a **slimmed build with a module removed still
   passes**, naming the module absent. The control that must bite: a module
   missing `NAME-validate`, and a slimmed profile that silently mis-reports a
   dropped module as present.
0. **A CI witness for the attestation and CBFS halves.** `event-real` replays a
   *vendored* log and needs only `tpm2-tools` on the runner; `cbfs`/`cbfs-payload`
   need the coreboot ROM (cache it, or a fixture-only leg). Until this lands,
   "green on all four arches" for `sha256.fth` and `eventlog.fth` is a claim about
   one machine — §1's *measured here* row.

### Tier 1 — the walls: the two missing readers, and the pins
Each is one file, contract-conformant, graded against an independent host tool.
Order by which capstone it unblocks:

| module | state | foreign oracle | unblocks |
|---|---|---|---|
| `elf.fth` | built → **conform** (Tier 0) | `readelf`/`eu-elflint` | attested boot (ELF gate — the C-loader gate is B.4 Spike 0, done) |
| `sha256.fth` consumers wire-up | built → **conform** | NIST vectors, `tpm2_eventlog`, `hashlib` | attested boot, all signatures |
| `eventlog.fth` (TCG log) | built → **conform** | `tpm2_eventlog` | attested boot |
| `cbfs.fth` (read) | built → **conform**, fix the silent stop | `cbfstool` | coreboot workbench |
| `fdt.fth` / `fdt-read.fth` | built → **conform** | `dtc`/`fdtdump` | the firmware-edits-boot note, UEFI DT table |
| `pe.fth` | **to build** | `objdump`/`llvm-readobj` + poke `pe.pk` | UKI, UEFI |
| `bootparams.fth` (zero page) | **to build** | `/proc/…`, the kernel's own view | the firmware-edits-boot note |

### Tier 2 — the second story: the edit-and-reverify loop
The writers exist (`elf-write`, `cbfs-write`, `dt>fdt`, `evlog-author`), graded
against oracles. What is **not** built is the loop that makes editing safe — the
half where "refuse before the irreversible step" and "assert the outcome, not the
mechanism" bugs live:

- **Read → edit → re-emit → the independent oracle confirms the edit and *only*
  the edit; a malformed edit is refused before the write.** Today each writer is
  graded on a whole authored artifact; none is graded on a *delta*.
- Each writer opts in through the contract's `NAME-emit`/`NAME-write`.
- The two half-working **stores** ([TODO §24](TODO.md): the floppy write, sun4m)
  are a separate axis — backing stores, not format writers — and stay tracked
  there; they are not on this tier's critical path.

### Tier 3 — the roof: capstones, each pinned to the contract
Built only on green Tier 0–2 modules, in rough dependency order:
[attested boot](ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md) →
[coreboot workbench](COREBOOT_ROM_WORKBENCH_LAB_PLAN.md) +
[verified boot](COREBOOT_VERIFIED_BOOT_LAB_PLAN.md) →
[UKI](UKI_WORKBENCH_LAB_PLAN.md) → [UEFI](UEFI_WORKBENCH_LAB_PLAN.md) →
[pacme inspector](DESIGN-NOTES-pacme-a-live-firmware-inspector.md). Each gets its
one-line contract pin when built.

## 4. The chaos ladder — a cross-cutting tier, not an afterthought

The family grades against foreign oracles (good) but has **no fault-injection
treatment** — measured: the LIED/HALTED vocabulary appears in the smoke driver
only as *grading language* in comments and messages, never as an injected fault —
though the [chaos ladder](examples/metal-as-a-service/chaos-run.sh) is a stated
methodological goal. Add a firmware-family chaos harness that injects a fault at
**each layer** and grades on the ABSORBED / DEGRADED / HALTED / STRANDED / LIED
ladder, with a no-fault control row:

| layer | injected fault | the question |
|---|---|---|
| event log | truncated mid-write | does `eventlog.fth` HALT honestly, or LIE a short log as complete? |
| measurement | a PCR extend racing the read | ABSORBED (ordered) or a STALE read? |
| a writer (Tier 2) | killed **before** the irreversible step | ABSORBED (refused) or STRANDED (half-written)? |
| a reader | a corrupt first record (the `cbfs-list` case) | refused by name, or an empty listing that LIES? |
| the pacme seam | NBD drop / a stale `SNAPSHOT` served as `LIVE` | caught, or LIED? |
| the loader | a module absent | DEGRADED + named, never a silent wrong read |

The ladder must assert the rungs are **occupied**, not just that criticals are
zero (the metal-as-a-service lesson). This fills the gap directly.

## 5. Two honesty axes the contract must carry

- **Arch scope — protect the family's sharpest edge.** The distinctive correctness
  claim is the four-arch (`unix`/`amd64`/`x86`/`ppc`) endianness×width matrix, the
  thing a hosted tool like GNU poke *structurally cannot have*. Modules that can be
  four-arch **must** be (`elf`, `struct`, `sha256`, `eventlog`, `cbfs`, `fdt`).
  The inherently single-arch formats (`pe`, and the UEFI/UKI work) declare
  `ARCH: x86-only` in their manifest — honestly, not by pretending — so the family
  never quietly steps off its own differentiator.
- **Liveness — the `pe.pk` and pacme stance.** Every module states `HOST-ONLY`
  where a host oracle grades it, and every live view states `LIVE` vs `SNAPSHOT`
  (pacme), so a corpse is never mistaken for a running subject.

## 6. The separability & split test (the guarantee, made checkable)

Prunability and repo-split-ability are only real if a checker proves them:

- **Slim profile builds and passes** with the substrate + *any subset* of readers;
  a removed module is named absent, never silently missing (Tier 0's checker).
- **Lift test:** the firmware family builds and passes with only the substrate
  (`struct.fth`, `sha256.fth`), the contract, and `tools/` checkers as shared
  dependencies — nothing from the provisioning phases or MAAS. If that holds, the
  family can move to its own repo by copying that closure. A `check-*.sh` that
  builds the minimal closure is the proof.

## 7. What this does NOT do

- **Does not fuse the DSLs.** The contract is a convention modules opt into, one
  file per format, each removable. Explicitly the opposite of one DSL.
- **Does not schedule.** It is a dependency order and an architecture decision;
  readiness, not dates.
- **Does not touch the provisioning goals.** `PLAN.md`'s multi-backend, multi-arch,
  self-contained toolkit is a different axis; this roadmap is the firmware family's
  own build order and says so.
- **Does not build anything.** The next actionable unit is **Tier 0**: one
  refusal convention through `chk` (and `cbfs-list`'s silent stop closed), a
  substrate-derived `NAME-fields`, manifests as words, the registry, the
  conformance checker — and a CI witness for the tracks only this host runs.
