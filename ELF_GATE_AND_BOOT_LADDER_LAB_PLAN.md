# ELF Gate & Boot Ladder — Lab Plan v1 (2026-09-05)

The **ELF reader the firmware already carries** (`dsl/elf.fth`: typed headers, program and
section tables, `vaddr>off`, `elf-hash`, and the refusals `?elf`/`?phdrs` with the gABI's
ordering rule) moves from *a thing typed at the prompt* to **a gate in the boot path**, and the
grading moves from *does the word print the right thing* to **which rung of a boot ladder did
the image reach**: refused by name, loaded but not run, ran and returned, booted. Around that
hook hang seven further spikes: measure what you are about to run, sweep every real ELF the
lab ships, one fixture per gABI clause, symbol lookup and a poke before boot, identity before
trust, the big-endian ELF32 axis — each graded against a foreign oracle or, where the
measurement says no tool checks a clause, *saying so*.

Extends [`examples/openbios-the-rival-that-shipped/`](examples/openbios-the-rival-that-shipped/)
and is the successor of
[`PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md`](PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md) (B.3, complete),
whose `elf-gate` track, fixtures and oracles are this plan's starting stock. It was outlined in
conversation on 2026-09-05, after the fourth `elf-gate` fixture measured that **no hosted tool
enforces the gABI's INTERP-order clause** — the moment the reader stopped being merely a mirror
of `readelf`.

> **The one pattern this family enforces (LOCKED): Spike 0 runs first and it is a DECISION,
> not a warm-up.** It decides *where the gate lives* — in the C loader every `load` already
> passes through, or in Forth compiled into the dictionary — and nothing in Spikes 1–6 is
> committed until a malformed payload is refused by name **before `go`** and a good one still
> boots Linux, on the arches that boot Linux. (Same discipline as
> [`PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md`](PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md) Spike 0.)

---

## 1. Why — and why now

Five things landed this week that make the plan cheap to start and pointless to defer:

- **The reader refuses, by clause.** `?phdrs` checks every `PT_LOAD` against the file, and
  since the `elf-gate` track (2026-09-03) the gABI ordering rule: `PT_PHDR`/`PT_INTERP` at
  most once, before any `PT_LOAD`. Each refusal names its clause
  (`CONSTRAINT: PT_INTERP after a PT_LOAD (gABI: it must precede every loadable segment)`).
- **The fixtures are authored, one per clause.** [`fixtures/elf-gate/build-elf-gate-fixtures.py`](examples/openbios-the-rival-that-shipped/fixtures/elf-gate/build-elf-gate-fixtures.py)
  writes four ELF64s byte-identical outside the program-header table. The fourth
  (`badint.elf`, 2026-09-05) exists because `badord.elf` violated two clauses and the firmware
  only ever refused it on the first one checked — **one fixture per clause** is now a rule.
- **The oracles are known, and so are their gaps.** `readelf` enforces PHDR order only;
  `eu-elflint` enforces INTERP multiplicity only; the kernel's `load_elf_binary`
  (`fs/binfmt_elf.c`, v6.12) takes the first `PT_INTERP` and checks nothing about order. The
  INTERP-order clause has **no foreign oracle**; the track measures that per run and words its
  verdict from the measurement ([`fixtures/elf-gate/README.md`](examples/openbios-the-rival-that-shipped/fixtures/elf-gate/README.md)).
- **The allocator the gate lives in is honest now.** `here!` refuses a dictionary overflow
  (patch 66) and `marker` exists with the refusals this dictionary needs (patch 67), so a
  gate that compiles more Forth into a live firmware cannot silently write past the end, and a
  spike can reclaim what it loaded.
- **The measured-boot half already exists.** `dsl/sha256.fth` + `dsl/eventlog.fth` author and
  replay a TCG event log; the `event-real` track grades against a real edk2/swtpm log; the
  `event-bench` track boots the same Linux through three substrates. Spike 1 here is a hook,
  not a new format.

And the boot path is already instrumented: the `amd64-linux` track boots Linux through the
64-bit firmware; the `elf-methods` track has the hosted firmware **author** an ELF and hand
it to the kernel, whose exit code is the grade; the `cbfs-payload` track reconstitutes the
four coreboot payloads and grades their segment tables against `readelf`.

## 2. Thesis & scope

**Thesis.** A firmware is the only place a structural check on an executable can stand
*before the irreversible step*. Hosted validators run on a file that something else will
later jump into; the firmware runs on the bytes it is itself about to jump into. So the
question the toolkit should answer is not "does this word print what `readelf` prints" but
**"what did the image reach"** — and that is a ladder, not a boolean:

| rung | meaning | how it is observed |
|---|---|---|
| **REFUSED** | the gate named a clause and `go` never ran | the `CONSTRAINT:` line, no jump, the prompt intact |
| **LOADED, NOT RUN** | bytes in memory, `init-program` set up, `go` not issued | `load-base`/`load-size` answer, `state-valid` says so |
| **RAN, RETURNED** | the image executed and came back with a code | the `elf-methods` shape: the authored program's exit code |
| **BOOTED** | the image took the machine | the `amd64-linux` shape: u-root's prompt |

A gate that refuses everything leaves the upper rungs empty; a gate that refuses nothing
leaves the bottom rung empty. **Every spike asserts the rungs it touches are occupied** —
the discipline the chaos harness taught
([`CLAUDE.md`](CLAUDE.md), *assert the rungs are OCCUPIED*).

**In scope:** the gate in the load path; measurement at the gate; the corpus sweep; the
per-clause conformance map; symbol lookup and one poke; identity against the provenance
record; the ELF32 big-endian axis. All on the four OpenBIOS targets where the arch allows,
and each with a foreign oracle or an explicit *"no oracle — the gABI's word alone"*.

**Out of scope:** see §6.

## 3. Verified feasibility (checked 2026-09-05, before writing this)

- **The load path has one seam.** `libopenbios/initprogram.c` `init_program()` dispatches on
  the loaded image's type to `elf_init_program()` (`libopenbios/elf_load.c`), which sets up
  the program state and calls `arch_init_program()`. On the Forth side
  `forth/debugging/client.fs` defines `load` (line 222), `init-program` (line 90) and `go`
  (line 246). A gate in either place sees the bytes at `load-base` with `load-size` before
  anything jumps. Both places are shared across the four arches.
- **The reader has what the gate needs.** `dsl/elf.fth`: `elf-at`, `?elf`, `?phdrs`
  (64-bit; `elf32.fth` supplies the 32-bit half through a hook), `elf-phnum`, `elf64-ph`,
  `vaddr>off`, `sh-name`, `elf-hash`, `.elf`/`.phdrs`/`.sections`. Its cost is measured:
  `dict-budget` puts `elf.fth` + `elf32.fth` well inside every arch's room (unix 780 KiB
  left, x86 871, amd64 750, ppc 214 with the whole toolkit loaded).
- **Authored ELFs run.** The hosted target authors an ELF with `write-file` (patch 54,
  unix only) and the kernel runs it; the exit code is the authored one (`elf-methods`).
- **A real payload corpus exists on disk.** Four coreboot ROMs with three payload kinds;
  `cbfstool extract -m` reconstitutes their ELFs; the OpenBIOS ELFs themselves
  (`openbios-builtin.elf`, `openbios-qemu.elf` — a big-endian ELF32); u-root's `vmlinux`
  in the linuxboot lab.
- **The build-id walk matches `readelf -n`** on all four arches (`tlv-primitives`), and
  `tools/openbios-rom-provenance.sh` already binds a ROM to the payload it was built from
  by digest.
- **The oracles are installed on the dev host and in CI**: binutils 2.42 `readelf`,
  elfutils 0.190 `eu-elflint` (CI's apt line gained `elfutils` on 2026-09-04), a C toolchain
  for the linker's `.hash` cross-check.

## 4. Why this lab and not a hosted tool

A hosted validator can say a file is malformed. Only the loader can **refuse to run it**,
and only a loader you can type at can show you, at the prompt, the exact clause and then
still boot the good image a moment later. The four arches remain the control they were in
B.3 — the same Forth on 32- and 64-bit cells, little- and big-endian — and Spike 6 makes
the ELF *subject* big-endian too, which a single-machine tool never has to face.

And there is the uncomfortable position the fourth fixture put the reader in: for the
INTERP-order clause it is **the only validator we have**. A plan that grades against
oracles has to say what it does when there is none. This one says: refuse on the spec's
word, print that no tool agrees or disagrees, and keep measuring so the sentence changes
the day a tool does.

## 5. The spikes

### Spike 0 — THE GATE, in the load path (DECISION)

> **DECIDED AND BUILT 2026-09-05 — (A), the gate is C, with the Forth reader as its agreement
> oracle.** Patch 68 + the `elf-ladder` track. Three things the measurement changed in the text
> below, kept as written so the correction is visible:
>
> - **The irreversible step is not `go`.** `$load` calls `init-program` itself, and
>   `elf_init_program()` copies every `PT_LOAD` to its `p_vaddr` right there. The gate therefore
>   stands in front of *that copy*, and "refused before `go`" was a weaker sentence than the one
>   needed. Before the gate, `load` of each door's own firmware ELF hung x86 and ppc.
> - **The C loader only ever sees its own class**, so the ELF64 fixtures were never on the boot
>   path of x86 or ppc, and amd64's `elf.h` still declared ELF32/EM_386 — it accepted an i386
>   client and faulted at `go`. The fixtures are now authored per door in the class it loads
>   (`fixtures/elf-gate/` ladder sets), which pulls Spike 6's big-endian axis into Spike 0 for the
>   ppc row; amd64 loads ELF64/EM_X86_64.
> - **(B) cannot gate ppc.** `dsl/elf.fth` declares byte order per field and refuses a big-endian
>   ELF by name (REVIEW E2) — so on the door whose real boot path is the C loader the Forth reader
>   is not a candidate for the gate, only for Spike 6. The track asserts that refusal as the named
>   limit it is. And the success signature's "u-root's prompt (amd64)" was wrong: Linux on amd64
>   is a bzImage through `linux_load.c`, not an ELF, so **BOOTED is not reached through this
>   gate** by anything on disk, and the verdict says so rather than passing it.
>
> Also found on the way, all fixed in patch 68: an unrecognised `load` left `state-valid` at the
> previous load's -1 (a stale record `go` would have re-entered); ppc's ldscript wraps `_end` to 0
> so `[_start,_end)` was empty; and of the seven one-clause fixtures **four are checked by neither
> `readelf` nor `eu-elflint`** (INTERP order, a segment past EOF, entry in no LOAD, the overlap) —
> Spike 3's first rows, measured per run.

**Question.** Where does the gate live, so that *every* `load` of an ELF passes through it
without the user first loading `dsl/elf.fth`?

- **(A) In C**, in `elf_init_program()` — the checks `?phdrs` makes, written once more in C,
  with the Forth reader as the *agreement oracle*: on every fixture the two must refuse or
  accept alike. Cost: duplicated logic; the C side is what the ppc row's real boot path uses,
  so a mistake strands a rung on ppc.
- **(B) In Forth**, `dsl/elf.fth`'s refusals compiled into the dictionary (a `FEATURE` patch
  under `forth/`), and `init-program` calling the gate before `arch_init_program`. Cost:
  ~20 KiB of dictionary on every arch (measured room says yes); the C loader's own parse
  still runs first and must not be the one that throws.
- **(C) Both**: (A) as the gate, (B) as the explanation — the C refusal names the clause,
  the Forth reader shows the field.

**Decision criterion:** the refusal must happen **before `go`** and name the clause, on every
arch that has the loader; the good image must still boot. Whichever of A/B/C meets that with
the smaller blast radius on the ppc boot path wins. Measure both before choosing.

**Success signature.** `load /ide@1/cdrom@0:\BADINT.BIN` then `go` → the `CONSTRAINT:`
line, the prompt intact, `state-valid` false; `load …\GOOD.BIN` → `go` → the authored
program's exit code (unix) / u-root's prompt (amd64). **Negative control:** a build with
the gate stripped runs `go` into `BADINT.BIN` — and the record says what that did.

### Spike 1 — measure what you are about to run

At the gate, `sha256` the image and author a `TCG_PCR_EVENT2` for it with
`dsl/eventlog.fth`; replay the PCR. **Control:** one byte changed in the payload moves the
digest and the replayed PCR. **Oracle:** `tpm2_eventlog` parses the log; python computes
the same extend. **Comparison:** the TPM-measured coreboot ROM's own log (`event-real`)
measures the same payload from the ROM side — the two digests of one payload, from two
measurers, must agree. The quote stays **UNKNOWN**, and the plan says so on every run.

### Spike 2 — sweep the real ELFs, not the fixtures

Every ELF the lab ships through the gate: the four coreboot payloads (reconstituted),
`openbios-builtin.elf`, `openbios-qemu.elf`, u-root's `vmlinux`, `/bin/true`. One row per
file: the firmware's answer, `readelf`'s, `eu-elflint`'s. **Any disagreement is a
finding**, the way `badint.elf` was — and a real file the firmware refuses that everything
else runs is the most interesting row the sweep can produce.

### Spike 3 — one fixture per gABI clause: the conformance map

The builder grows one malformed file per remaining rule: `e_phentsize`, `e_phoff` past EOF,
`p_memsz < p_filesz`, `p_align` not a power of two, `p_offset ≢ p_vaddr (mod p_align)`,
overlapping `PT_LOAD`s, `PT_INTERP` not NUL-terminated. Each measured against `readelf`
and `eu-elflint` and labelled: *both check it / one does / neither does*. The result is a
**coverage map of the hosted tools against the gABI**, and each *neither* row is an
upstream report ready to file (the first one is already drafted:
[`UPSTREAM-elflint-no-phdr-order-check.md`](examples/openbios-the-rival-that-shipped/fixtures/elf-gate/UPSTREAM-elflint-no-phdr-order-check.md)).

### Spike 4 — symbols: look one up, then poke it before boot

`elf-hash` exists; add the `.dynsym`/`.hash` (and `.symtab`) walk so the firmware finds a
symbol by name in a loaded image. **Oracle:** `nm`/`readelf -s`. Then the poke: change one
word at a symbol's address in a loaded payload, show the change with `region-diff`, and let
the **outcome** be the grade — the program returns a different code, or the kernel boots
with a different command line. This is GNU poke's headline trick, done on the bytes about
to run rather than on a file.

### Spike 5 — identity before trust

The build-id note walk (`tlv-primitives`) generalised: at the gate, read the image's
`.note.gnu.build-id` and compare it with the provenance record the ROM carries
(`tools/openbios-rom-provenance.sh` stamps the payload's digest). **Refuse a mismatch by
name, before `go`** — the record-outlives-its-subject guard, now inside the firmware.
**Control:** a payload rebuilt with one byte changed and the old record → refused; the
record regenerated → runs.

### Spike 6 — the big-endian axis

`openbios-qemu.elf` is itself a **big-endian ELF32**. Through `elf32.fth`'s gate on all
four arches — the LE arches reading BE fields, ppc reading its own — and the Spike 3
fixtures authored in ELF32 BE as well as ELF64 LE. Byte order is a property of the field,
not the CPU: this is where that claim gets its second subject.

## 6. What this is NOT (scope guards)

- **Not a signature scheme.** Spike 1 measures and Spike 5 checks identity; neither
  verifies a signature. A digest bound to a record is not a chain of trust, and the plan
  says what the anchor is (the ROM's provenance file on the host) and is not.
- **Not a rewrite of the C loader.** Spike 0 adds a gate; it does not replace
  `elf_load.c`'s parse. If the decision is (A), the C is the *checks* only.
- **Not a fuzzer.** Spike 3's fixtures are one-clause, authored, explained. Random
  mutation would find crashes without naming clauses; that is a different lab.
- **Not a hosted tool re-implemented.** If a spike could be done as well by `readelf` or
  `elflint` alone it is the oracle, not a spike — the B.3 rule, unchanged.

## 7. Risks & the standing bias to correct for

- **The ppc row's real boot path goes through the C loader.** A gate in C that refuses a
  well-formed BE ELF32 strands ppc at REFUSED. Spike 0's ppc leg must boot before anything
  merges.
- **A fixture that violates two clauses tests one branch.** The lesson of `badint.elf`,
  now a rule: each Spike 3 fixture differs from `good.elf` in one clause, and the guard that
  the files are identical outside the phdr table extends to each.
- **A word typed at the prompt is created into the active package.** The showcase's marker
  landed in the host bridge's wordlist because an earlier act left a node active. Every typed
  probe in these tracks begins with `device-end`, or is loaded after one.
- **Typed lines under 80 columns**, always — the hosted line editor truncates past ~82.
- **Wording from measurement, never from memory.** Every "no tool checks this" sentence is
  chosen by the run's own `readelf`/`eu-elflint` answers — and the branch that chooses it
  gets a negative control, because the first one shipped was the liar (a trailing space
  from `tr`).
- **Assert the outcome, not the mechanism.** A rung is *observed* (a prompt, an exit code,
  a `CONSTRAINT:` line), not inferred from a word having been defined.

## 8. Routing (at assembly, not before)

Each spike lands as a `smoke-openbios.sh` track with a `tests/test-smoke-<track>.sh`
wrapper, a `run-all.sh` list entry and a `DEFAULT_TRACKS` entry in
`.github/workflows/openbios-tier-b.yml`; any firmware change is a numbered patch in
`patches/` with a catalog row (`UPSTREAM-BUG` / `FEATURE`, scope by path) and a regenerated
`TESTED-TREE.patch`. Spike 0's gate joins the showcase as the act after VIII once it is
green on amd64: the good image boots, the bad one is refused, in the one boot. The lab's
`README.md` gains one row per spike; `MANUAL_TESTING.md` a ledger section per spike with
its controls watched to bite.

## 9. Success signature (per spike, observable)

| spike | the line that must print | the control that must bite |
|---|---|---|
| 0 | **met 2026-09-05 (`elf-ladder`):** `elf-gate: REFUSED -- <clause>` on `load` of each one-clause fixture, in each door's own class, before any byte moves; `go` says *No valid state*; `good.elf` LOADED (`state-valid` -1) then RUN AND RETURNED (`R` on COM1, the prompt back) on x86/amd64/ppc; the door's own firmware ELF refused as an overlap with the prompt intact. BOOTED not through this gate — said so | **held:** the pre-patch tree *is* the gate-stripped build — `load` of the firmware's own ELF hung x86 and ppc, amd64 accepted i386 code and GPF'd at `go`, an unrecognised load kept a stale `state-valid`; recorded in `MANUAL_TESTING.md` with the logs |
| 1 | the gate's digest equals `sha256sum` of the payload file; the replayed PCR equals python's | one byte changed → both move |
| 2 | one row per shipped ELF, three columns, every disagreement named | `badint.elf` in the sweep is refused by the firmware alone |
| 3 | one fixture per clause, each labelled both / one / neither | every fixture differs from `good.elf` inside the phdr table only |
| 4 | a symbol's address equals `nm`'s; the poked program returns the poked value | the unpoked run returns the original |
| 5 | the build-id read at the gate equals the provenance record's; a mismatch refused by name before `go` | a rebuilt payload with the stale record → refused |
| 6 | `openbios-qemu.elf` (BE ELF32) passes the gate on all four arches; a BE `badint32` is refused on all four | the LE fixtures' answers unchanged |

**Sequence:** 0 → 1 → 5 (they share the hook) → 2 → 3 → 6 → 4.
