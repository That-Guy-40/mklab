# REVIEW — "Preboot Forth as a poke-like binary-structure engine", second pass

*Review of the 2026-08-29 proposal — GNU poke's model (types mapped over storage,
write-through on assignment) carried into an OpenBIOS Open Firmware port on
x86/x86-64 — against this repo at `fc02a0b`. The first pass,
[`REVIEW-preboot-forth-binary-structures.md`](REVIEW-preboot-forth-binary-structures.md),
was written 2026-08-24 from source alone and its blocking finding has since been
closed; this one is written against a tree that boots.*

> **VERDICT: the thesis is no longer a claim — it has three working seams — and
> the proposal now overreaches in a different place than last time.**
>
> The differentiator the idea rests on ("take poke's model into the environment
> poke is locked out of") stopped being an argument on 2026-08-27: three smoke
> tracks write 1275-encoded structures into RAM above 4 GiB, into an MMIO
> aperture, and at a flash window. **Two of those three land. The third does
> not, and that is a measured correction to the pitch rather than a detail** —
> "the flash chip itself" is not an address you store to.
>
> What is missing is not primitives. It is **types**. The repo has
> `int!` / `string!` / `bytes!` and a cursor; poke's model is a *type applied at
> an offset yielding a named, write-through value*, and nothing here does that.
> `create ... does>` — the exact machinery — is present and has never been
> pointed at a structure.
>
> Separately: **the ELFkickers/`sstrip` half of the framing does not belong in
> this proposal.** It is a host-side, build-time file transformation with no path
> through the preboot engine. It is a good idea in its own right and it makes
> this one look bigger than it is.

---

## Method

Every finding below was **measured against the running tree or read from the
shipped source**, at `fc02a0b`, with the firmware built and booted. Where a claim
would need work that has not been done, it is labelled **UNKNOWN**.

**One thing this review did not verify at all:** the characterisation of GNU poke
(IO spaces, `/proc/PID/mem`, `elf.pk`, mapped values writing through on
assignment) and of ELFkickers is taken **from the proposal as given**. No poke
source was fetched and no poke was run. Every comparison below is therefore
"against the proposal's account of poke", not against poke. If that account is
wrong, the findings that lean on it move.

---

## What changed since the first pass

The first review's blocking finding, **F2**, was that the encode half was a
serializer into a private bump-allocated arena — *"you cannot aim `encode-int` at
a flash region, an MMIO window, a CBFS entry or a boot-handoff page"* — and that
generalizing it "is a new subsystem, which is exactly what §5 claims it is not."

It was built. `int!` / `string!` / `bytes!` take the destination as a stack
parameter, the 1275 words are redefined in terms of them, and `int!+` /
`string!+` / `bytes!+` compose successive fields at a caller-chosen address
(patches 31-32). The assertion is `here` **unchanged** — a writer that allocates
in the arena and copies would satisfy "the bytes are right" and could never be
aimed anywhere.

So the question this pass has to answer is no longer *can it write elsewhere*. It
is *what is still missing between that and poke*.

---

## G1 — The differentiator has three seams, and one of them is not what the pitch assumes

The proposal's strongest move is that the IO space is physical memory, MMIO,
device registers and flash — "a layer nothing poke-like can reach". That is now
demonstrated rather than argued, and unevenly:

| seam | track | result |
|---|---|---|
| RAM above 4 GiB | `pmem-writer` | **works** — three ints written by `int!+` at `0x100400000`, an NVDIMM reachable only in long mode, read back through the stock decoder |
| MMIO | `mmio-writer` | **works** — `int!` stores into the legacy VGA aperture at `0xb8000` put pixels on the display, at both of its addresses |
| CFI flash | `flash-writer` | **does NOT store** |

`flash-writer`'s verdict is the finding, and it is worth quoting because it is a
*negative* result that was measured rather than assumed:

> a CFI part is **NOT a store-to seam** … the writer can be AIMED at `0xffbe0000`
> … but three `int!+` stores leave the array and the host image untouched,
> because a CFI write is a command sequence (`0x20/0x40/0xff`) and not a store.

**What that costs the proposal.** "The flash chip itself" reads, in the pitch, as
another address you point the writer at. It is not. A flash target needs a
driver-mediated program operation underneath — which in poke's own vocabulary is
an **IO space with a custom backend**, not a raw offset. The split the repo
already made (*"the writer produces bytes, the flash driver programs them"*) is
the right shape; the proposal should adopt it rather than list flash beside RAM.

**And the control is the part that makes it trustworthy**: storing at the
*uncorrected* `0xffbe0000` reads back convincingly as `c0 ff ee` — into RAM,
nowhere near the chip. A seam that appears to work is the failure mode here, and
this one was caught.

---

## G2 — The gap is types, not primitives, and `does>` is sitting unused

This is the finding that should shape the next piece of work.

What exists today is a **byte-placement layer**: put an int here, a string there,
advance a cursor. What poke's model is — on the proposal's own account — is a
*type mapped over storage*, where applying the type at an offset yields a value
you can name, read, and assign through.

| poke concept (as described in the proposal) | in this tree today |
|---|---|
| write-through address | **yes, natively** — `!` / `c!` / `int!`, and now provably at chosen destinations |
| apply a type at an offset | **no** — nothing binds a layout to an address |
| named field access | **no** |
| arrays of a type | **no** |
| bit-fields | **no** (see G4) |
| unit-typed offsets | **no**, and no near analogue |
| endianness per field | **yes**, both directions (see G3) |

`create ... does>` is present (`forth/bootstrap/bootstrap.fs:1563`) and is exactly
the machinery the proposal names. **The repo has never used it for a structure.**
That is the single highest-value next artifact: a definer such that

```forth
struct elf64-ehdr
  16 field: e_ident   2 le-field: e_type   2 le-field: e_machine
   4 le-field: e_version   8 le-field: e_entry   \ ...
```

produces words that take a base address and yield a field address, with `int!` /
`le-l@` on top. Everything under it exists. Nothing above it does.

**Why this matters more than it sounds:** without a type layer, "poke-like" is
describing a pair of accessors that Forth has had since 1970. The interesting
claim in the proposal — that OF's device tree and FCode make this a
*generalisation of what the firmware already does* rather than a graft — only
lands once layouts are first-class.

---

## G3 — Endianness is already solved in both directions, and it is upstream

This removes what would otherwise be the first hard design question, and it is
non-obvious enough to be worth stating.

- The 1275 wordset is **big-endian by specification**: `l!-be` / `l@-be` write and
  read four bytes high-first, and that is the correct behaviour for device-tree
  property cells.
- x86 binary structures — ELF, multiboot, ACPI, CBFS — are **little-endian**.
- `le-w@` / `le-w!` / `le-l@` / `le-l!` exist as bound Forth words, and
  **verified against the pristine tree at the pin, they are upstream**, not
  something this lab added.

So a type layer does not have to invent endianness handling; it has to *select*
per field. A `field:` / `le-field:` pair over the existing accessors is the whole
of it.

---

## G4 — Bit-fields are a library; unit-typed offsets are a design

Two of poke's features are missing, and they are not the same size.

- **Bit-fields: cheap.** `lshift`, `rshift`, `and`, `or`, `xor` are C primitives
  in the kernel word list (`kernel/bootstrap.c:85`), so mask-and-shift accessors
  are a Forth library over what is already there.
- **Unit-typed offsets: not cheap.** poke's offsets carry a unit (bits, bytes)
  in the type system and arithmetic respects it. Forth has one numeric type and a
  cell. Emulating it means either a convention nothing enforces, or a
  representation that every accessor has to honour — a real design, and the place
  where the "poke in Forth" analogy stops being a translation and starts being an
  invention.

Recommendation: **do bit-fields, skip unit-typed offsets**, and say so, rather
than carrying an unstated debt.

---

## G5 — The ELFkickers / `sstrip` half is a different project

The proposal opens with poke *and* ELFkickers, and names `sstrip` as "the one
everyday-utility piece — meaningfully shrinking static binaries for RAM-booted
images."

That is true and it has **nothing to do with the preboot Forth engine**.
`sstrip` runs on the build host, on a file at rest, before the image is
assembled. This repo's RAM-boot labs are exactly where it would pay, and none of
that path goes through firmware. Putting the two in one proposal makes a single
good idea look like two, and invites a plan where the firmware work is justified
by a saving the firmware never delivers.

**The honest connection is intellectual, not operational**, and it is worth
keeping for that reason: ELFkickers' teensy-ELF essays are about hand-authoring
headers with deliberately overlapping fields — which *is* the authoring model the
type layer in G2 would enable, pointed at a file instead of a device. That is a
good motivating example for the engine. It is not a shared code path.

Suggested split: `sstrip` in the image-build pipeline as its own item; the Forth
engine judged on inspection and authoring at the prompt.

---

## G6 — The reader is still ahead of the writer, and it now diffs

[`examples/open-firmware-debugs-itself/dsl/ofscope.fth`](examples/open-firmware-debugs-itself/dsl/ofscope.fth)
already ships `pci-map`, `mem-map`, `region-snap` and `region-diff` — snapshot a
physical region, act, snapshot again, compare.

That is a capability the proposal undersells and that a hosted tool structurally
cannot match: **diffing physical memory across a boot transition**. poke on Linux
can diff `/proc/PID/mem` for a live process; nothing hosted can snapshot the
region a firmware handed to a kernel, because by the time you have an OS the
transition is over.

If one application is going to justify the engine, it is more likely to be this
than authoring.

---

## G7 — Reading a *file* from Forth is reachable and unproven — UNKNOWN

For "inspect an ELF" to mean inspecting one on disk, Forth has to read a byte
range out of a file into a buffer.

- `seek` exists as a package method (`forth/system/ciface.fs:240`,
  `forth/util/util.fs:100`), and `read` is a client-interface service.
- `load` off ISO9660 works and is used constantly — every multi-line probe in
  `smoke-openbios.sh` is loaded from a CD rather than typed.
- **But nothing in this repo has read a byte range of a file from Forth and
  parsed it.** `load` reads a whole file to `load-base` and evaluates it as text.

So the mechanism appears present and the outcome has never been observed. Marked
**UNKNOWN**; it is the first thing to settle if file inspection is in scope,
because it is cheap to try and it gates a whole application class.

Also measured: **no Forth-side ELF parsing exists anywhere in the repo** — zero
files match a header-field grep. The `elf.pk` analogue would be new work, not an
adaptation.

---

## Applications, graded against the tree

Re-grading the first review's table, plus what this proposal adds:

| application | grade |
|---|---|
| **Device-tree construction / patching** | **works today** — the wordset's home ground |
| **Preboot RE of blobs in memory and MMIO** | **strong, available now** — `ofscope.fth` plus the two working writer seams |
| **Boot-handoff structures** | **unblocked and demonstrated** — `pmem-writer` is exactly this shape |
| **Post-mortem / transition forensics** | **best available fit, and under-argued in the proposal** — `region-snap`/`region-diff` across a boot is something no hosted tool can do at all (G6) |
| **Firmware image assembly (CBFS, flash)** | **needs a backend, not an address** — G1 |
| **ELF / PE inspection at the prompt** | **blocked on G7 then G2** — mechanism plausible, never exercised |
| **FCode authoring** | **the most OF-native of the list, and nobody has proposed it.** The repo already *detokenizes* FCode (`detokenize`, `.calls`), and FCode is the one binary format this firmware **executes**. A type layer that emits FCode closes a loop the proposal's own "precedent already in the firmware" argument sets up |
| **Measured-boot / attestation** | **still nothing built** — the arena problem that made it a poor fit is fixed, so the objection is gone and the work has not started |

---

## What would make it real, in dependency order

1. **Settle G7 with one experiment.** Open a file on the CD, `seek`, `read` a
   byte range into a buffer, dump it. One track, no new subsystem. It either
   unlocks file inspection or tells you the read path needs work — and today
   nobody knows which.
2. **Write the type layer (G2).** `create ... does>` over `int!` / `le-l@`, with
   a `field:` / `le-field:` pair so endianness is per field (G3). The checkpoint
   is an outcome, not a mechanism: *a named field of a structure at a chosen
   address reads back what a different word wrote there.*
3. **Bit-fields as a library (G4).** Skip unit-typed offsets, deliberately and in
   writing.
4. **Pick ONE application and drive it end to end** before generalising. On the
   evidence above the strongest candidates are the forensics angle (G6, already
   half-built) and FCode authoring (most OF-native, and it would make the
   "generalises what OF already does" argument true rather than rhetorical).
5. **Split `sstrip` out (G5)** into the image-build pipeline where it belongs.

---

## What this review did NOT prove

- **No poke was run and no poke source was read.** The entire comparison rests on
  the proposal's account of poke. That is the largest single unverified input.
- **The type layer was not prototyped.** G2 says `does>` is present and unused;
  it does not say the definer will be pleasant to write. Forth definers are
  fiddly and this one has to carry endianness and width.
- **G7 was not attempted.** `seek` and `read` were found in source; no byte range
  was read from a file at a prompt.
- **Nothing was measured about performance or size.** A type layer compiled into
  the dictionary costs image space in a firmware whose builtin dictionary is
  1 MiB, and no budget was taken.
- **The FCode-authoring suggestion is untested.** The repo detokenizes FCode; it
  has never emitted any, and whether the existing `byte-load` path would accept
  hand-built tokens is unknown.

---

## Provenance

| item | value |
|---|---|
| Reviewed proposal | the 2026-08-29 message; poke/ELFkickers characterisation taken as given |
| Repo state | `fc02a0b`, firmware built and booted, 31/31 tests and 24/24 boot tracks green |
| Firmware corpus | `openbios/openbios` @ `e5ac46d`, pinned by `build-openbios.sh`, plus this repo's 48 patches |
| First pass | [`REVIEW-preboot-forth-binary-structures.md`](REVIEW-preboot-forth-binary-structures.md) — F2 closed 2026-08-29 |
| Written | 2026-08-29 |
