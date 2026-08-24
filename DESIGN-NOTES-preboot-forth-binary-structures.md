# Preboot Forth as a Binary-Structure Toolkit — Design Notes

*Working notes from a design discussion, 2026-08-24. Context: an OpenBIOS-based
OpenFirmware port on x86/x86-64 providing a preboot Forth environment with device
and filesystem drivers, and the idea of using it to build/inspect binary structures
the way GNU poke does.*

---

## 1. Starting point: poke and ELFkickers

**GNU poke** is a structure-aware binary editor plus a Turing-complete language for
describing and manipulating binary data *in place*. You write types that map a
layout (structs, arrays, bit-fields, unit-typed offsets, endianness) onto raw bytes,
apply the type at an offset, and get a live value that **writes through** to the
underlying storage on assignment. It is format-agnostic and programmable; ELF is just
one shipped "pickle" (`elf.pk`). Its center of gravity is reading and editing what
already exists, though it can author files too.

**ELFkickers** (Brian Raiter / muppetlabs) is the narrow-and-deep counterpart:
ELF-only, fixed-purpose C tools plus the famous teensy-ELF essays — `elfls`,
`elftoc`, `ebfc`, `infect`, `rebind`, `sstrip`. Its claim to fame is authoring
minimal binaries by hand (overlapping-header tricks).

**Shared philosophy:** both treat the binary format as a data structure you edit
directly, not as untouchable compiler output. Both argue the format is knowable and
hand-editable.

**Divergence:** ELFkickers is ELF-only and static (file-at-rest). poke is
format-agnostic, programmable, and live (write-through, including `/proc/PID/mem`).

**Immediate practical application (yours):** optimizing binaries when building
images. `sstrip` is the one everyday-utility piece here — it strips section headers
entirely (more aggressive than `strip`), meaningfully shrinking static binaries for
RAM-booted images.

---

## 2. The core idea: preboot Forth as the structure engine

The proposal: use the OpenFirmware Forth environment to build and inspect binary
structures, in the spirit of poke.

### Why Forth is *natively* poke-like (a conclusion, not a stretch)

- poke's model is "type over storage, write-through on assignment."
- Forth's memory model is address-based: `@`/`!`/`C@`/`C!` read and write **through**
  addresses directly. A Forth address *is* a live, write-through view onto memory —
  poke's mapped-value semantics as the ground floor of the language, not a bolt-on.
- `CREATE ... DOES>` is the idiomatic way to define structure-defining words: lay out
  fields with `,` / `C,` / `ALLOT` at `HERE`, and `DOES>` specifies instance
  behavior. This is the same machinery Forth has always used to build **assemblers**
  in Forth syntax. Laying down binary *data* is the identical trick pointed at data
  instead of opcodes.

### The real differentiator (the reason to build this at all)

poke needs a hosted OS — its IO spaces abstract over files and `/proc/PID/mem` on a
running Linux. **Your Forth runs preboot, on bare metal, with drivers.** Your "IO
space" is physical memory, MMIO, device registers, and the flash chip itself — a
layer nothing poke-like can reach. The thesis isn't "clone poke"; it's "take poke's
model into the one environment poke is locked out of."

### Precedent already in the firmware

OpenFirmware is itself a binary-structure system:

- The **device tree** is OF's native currency and the direct ancestor of the FDT.
- **FCode** (the tokenized Forth in PCI option ROMs) is literally binary Forth
  bytecode the OF interpreter parses and executes.

So "use this Forth to build/consume binary structures" generalizes a capability OF
already has at its core rather than grafting on a foreign one.

---

## 3. Tradeoffs (honest)

- **Substrate vs batteries.** poke gives declarative types with endianness,
  bit-field slicing, unit-typed offsets, conditional/computed fields, constraint
  checking, and pretty-printers. Forth gives `CREATE DOES> , C@ !` and expects you to
  grow those abstractions yourself. Appeal or tax depending on the day.
- **Endianness.** x86 is little-endian native, but much of what you touch preboot is
  big-endian (FDT, many network and firmware structures), so byte-swap discipline is
  load-bearing, not an afterthought.
- **Cell-width drift (the sharper hazard).** Forth is cell-oriented, and the cell is
  the one width that *changes* between your builds — 4 bytes on 32-bit, 8 on 64-bit.
  `,`, `@`, `!`, and `ALLOT`-relative math all shift underneath you by build. A layout
  written in cell-native primitives that's correct on the 32-bit FCode side can
  silently mis-size on the 64-bit device-tree side. This is width drift, not a swap.

---

## 4. Port lineage and current state (as described)

- Port is based on the **OpenBIOS** tree.
- **FCode** support revived from the **OLPC** port of the **Sun (SPARC) / Apple
  (PowerPC)** Open Firmware code — the lineage where FCode was battle-tested against
  real SBus/PCI/Mac option ROMs. You inherited a mature
  `byte-load`/detokenize/`new-device`…`finish-device` path rather than rebuilding one.
- **64-bit side:** device tree verified.
- **32-bit side:** FCode confirmed on a mock device.
- 64-bit side "started working late last night" — the encode/decode words have **not
  yet** been exercised there.

---

## 5. The key insight: IEEE 1275's encode/decode wordset

The cell-width hazard is already solved, and the solution is already in your image.

The property-encoding wordset — `encode-int`, `encode-bytes`, `encode-string`,
`encode-phys`, `encode+` (concatenate), the `decode-*` inverses, all feeding
`property` — is defined to emit **fixed-width, big-endian** output *independent of the
machine's cell size*. `encode-int` is a 4-byte big-endian value whether you're on the
32- or 64-bit build.

That is exactly the width-and-endianness discipline you'd otherwise hand-roll —
except it's standardized, it's what FDT's big-endian convention descends from, and
it's the native vocabulary of the firmware you're already running.

**Conclusion:** don't build a poke analogue from scratch. Generalize the encode/decode
wordset outward from "device tree properties" to "arbitrary binary structures."

### Why this unifies your two proven pieces

They stop being separate milestones:

- The 32-bit FCode path, evaluating a mock device, is *already* constructing binary
  structures — `new-device` plus the encode/`property` calls build nodes and property
  blobs.
- The 64-bit device tree is the constructed result.

The poke-like builder isn't a new subsystem. It's the encode/decode wordset —
already load-bearing in both halves — lifted out and pointed at flash regions, MMIO,
and boot-handoff structures instead of only at `/packages` nodes.

---

## 6. Suppositions to verify

- **[Supposition — the crux]** The 1275 encode/decode words *should* round-trip
  identically across the 32-bit and 64-bit builds against the same expected byte
  image, because they're spec'd fixed-width. But your 64-bit path is hours old and
  unexercised, so whether *your implementation* honors that across the cell boundary
  is unconfirmed. If any 64-bit code path leaks cell width into encoded output, that's
  the one bug that everything higher up would inherit.
- **[Supposition]** Because FCode evaluation itself leans on the encode/`property`
  path, a width leak there would surface as subtly malformed device nodes once FCode
  runs on the 64-bit side — worth watching for when you bring that path up.

---

## 7. Next steps

1. **Round-trip test the encode/decode words across the cell boundary — first.**
   `encode-int`/`decode-int` (and `encode-bytes`, `encode-string`, `encode-phys`)
   should produce byte-identical output on the 32-bit and 64-bit builds for the same
   inputs. Diff against a known-good expected image. Do this *before* building
   higher-level structure vocabulary — a leak caught now is a one-liner; caught later
   it's an archaeology dig through everything stacked on top.
2. **Bring FCode evaluation up on the 64-bit side** and confirm node/property
   construction produces correct big-endian, fixed-width blobs there.
3. **Only then** write the convenience layer — poke-style typed accessors via
   `CREATE`/`DOES>` on top of the (now-trusted) encode/decode primitives.

---

## 8. Candidate applications (fleet-relevant)

- **Boot-handoff structures:** multiboot headers, boot params, memory maps — built in
  Forth and handed to the next stage, with direct hardware access.
- **Device-tree construction/patching** before handoff (OF's native strength).
- **Firmware image assembly:** CBFS entries, flash-layout structures (coreboot tie-in).
- **Measured-boot / attestation structures:** TPM event-log entries, PCR-extend data.
  Bidirectional — the same type description that *builds* an event-log entry also
  *parses* one back for verification.
- **Exploratory RE of undocumented blobs:** the tight hypothesis loop (guess a field →
  write a one-line type → map → look → refine), accreting a reusable format
  description as you go.

---

*End of notes.*

---

*Editorial footer, added when these notes were filed into this repo on 2026-08-24 —
not part of the original document. The body above is reproduced verbatim as received.
It is reviewed, claim by claim against the OpenBIOS source, in
[REVIEW-preboot-forth-binary-structures.md](REVIEW-preboot-forth-binary-structures.md).*
