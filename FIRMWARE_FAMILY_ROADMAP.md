# Firmware family — a foundation-first roadmap (2026-09-15)

The OpenBIOS firmware family has grown a **roof before its walls**: ten design
docs describe capstones that all consume a shared structure toolkit
(`dsl/struct.fth`, `dsl/elf.fth`, `dsl/pe.fth`, `dsl/fdt.fth`, `dsl/cbfs.fth`,
`dsl/sha256.fth`, `dsl/eventlog.fth`), and that toolkit does **not yet exist as
built, tested, oracle-graded code**. This note fixes the build order —
**foundation, then walls, then tying it together** — pins every unbuilt plan to
it, and settles the one load-bearing architecture decision the plans have been
assuming without stating: **the readers and writers are a federation of
separable modules behind a thin shared contract, NOT one fused DSL.** Tracked in
[`TODO.md`](TODO.md) §33. This note is a **build order and an architecture
decision; it schedules nothing** and it does not touch the provisioning-toolkit
goals in [`PLAN.md`](PLAN.md).

## 1. The gap, in one picture

- **Six capstones are plan-only:** the [attested boot](ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md)
  (`openbios-measures-its-own-boot`), the [coreboot ROM workbench](COREBOOT_ROM_WORKBENCH_LAB_PLAN.md)
  and [verified boot](COREBOOT_VERIFIED_BOOT_LAB_PLAN.md), the
  [UKI](UKI_WORKBENCH_LAB_PLAN.md) and [UEFI](UEFI_WORKBENCH_LAB_PLAN.md)
  workbenches, and the [pacme inspector](DESIGN-NOTES-pacme-a-live-firmware-inspector.md).
  None is built.
- **They all import a toolkit that is itself a plan.** The
  [preboot structure toolkit](PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md) is the
  keystone that would build the missing rung (a length-prefixed TLV array +
  `alignto` on top of `struct.fth`), and it is unbuilt. What exists today is
  **scattered per-lab readers** in three shipped labs
  ([`openbios-the-rival-that-shipped`](examples/openbios-the-rival-that-shipped/README.md)
  and two siblings), not a shared, conformant set.
- **The risk is plan drift.** Each doc assumes a slightly different shape of the
  same reader. That is a *record that will outlive its subject*: when the toolkit
  is finally built, ten documents' assumptions about its API will not line up
  unless the order below pins them. This is the repo's own
  "map the full blast radius before the first edit" rule, applied to its own
  planning.

And the repo's loudest cultural rule points the same way — *"an experiment nobody
can re-run is a story"* (TODO §0). Plans nobody has built are stories one level
up. The cure is not more plans; it is to build the foundation and let the
capstones stand on something real.

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

## 3. Build order — foundation, walls, roof

### Tier 0 — the foundation (nothing else starts until this is green)
0. **`struct.fth` TLV/cursor rung + `alignto`** — the preboot toolkit's Spike 0
   decision (can the static-offset model carry a length-prefixed record, or is a
   parallel cursor needed?), green on all four arches before Tier 1.
0. **`sha256.fth`** — its **own** lab, graded against `sha256sum`. It is the
   hardest shared primitive, correctness-critical, and every attestation/signature
   capstone assumes it by name today with no plan of its own. Build it here.
0. **The conformance contract + its checker** — write the contract (§2) and a
   `check-module-conforms.sh` that proves every module implements the required
   core, that `NAME-manifest` is honest, and — the separability guarantee — that a
   **slimmed build with a module removed still passes**, naming the module absent.
   The control that must bite: a module missing `NAME-validate`, and a slimmed
   profile that silently mis-reports a dropped module as present.

### Tier 1 — the walls: readers, each a separable module against a foreign oracle
Each is one file, contract-conformant, graded against an independent host tool.
Order by which capstone it unblocks:

| module | foreign oracle | unblocks |
|---|---|---|
| `elf.fth` (exists → **conform it** to the contract) | `readelf`/`objdump` | attested boot (ELF gate) |
| `sha256.fth` consumers wire-up | `sha256sum` | attested boot, all signatures |
| `eventlog.fth` (TCG log) | `tpm2_eventlog` | attested boot |
| `cbfs.fth` (read) | `cbfstool` | coreboot workbench |
| `fdt.fth` | `dtc`/`fdtdump` | the firmware-edits-boot note, UEFI DT table |
| `pe.fth` | `objdump`/`llvm-readobj` + poke `pe.pk` | UKI, UEFI |
| `bootparams.fth` (zero page) | `/proc/…`, the kernel's own view | the firmware-edits-boot note |

### Tier 2 — the second story: writers/editors (the thin half, per the gap)
The family leans on reading; editing is the least-built and most dangerous half
(where "refuse before the irreversible step" and "assert the outcome, not the
mechanism" bugs live). Each writer is the **sibling module** to its reader,
opt-in via the contract's `NAME-emit`/`NAME-write`:

- Finish the [**two half-working stores**](DESIGN-NOTES-modern-filesystems-for-a-frozen-firmware.md)
  (TODO §24) — the write half, or record why not.
- The **edit-and-reverify loop**: read → edit → re-emit → the independent oracle
  confirms the edit and *only* the edit; a malformed edit is refused **before**
  the write.

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
treatment**, though the [chaos ladder](examples/metal-as-a-service/chaos-run.sh)
is a stated methodological goal. Add a firmware-family chaos harness that injects
a fault at **each layer** and grades on the ABSORBED / DEGRADED / HALTED /
STRANDED / LIED ladder, with a no-fault control row:

| layer | injected fault | the question |
|---|---|---|
| event log | truncated mid-write | does `eventlog.fth` HALT honestly, or LIE a short log as complete? |
| measurement | a PCR extend racing the read | ABSORBED (ordered) or a STALE read? |
| a writer (Tier 2) | killed **before** the irreversible step | ABSORBED (refused) or STRANDED (half-written)? |
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
- **Does not build anything.** The next actionable unit is **Tier 0**: the
  `struct.fth` TLV rung, `sha256.fth` with its oracle, and the contract + its
  conformance checker.
