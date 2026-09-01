# Preboot Structure Toolkit — Lab Plan v1 (2026-09-01)

A **preboot TLV/structure toolkit** in OpenBIOS Forth: generalize the type layer
(`dsl/struct.fth`, `dsl/elf.fth`) from reading ELF to **building and verifying
the firmware-native binary records** the fleet actually hands around at boot —
first the **TCG measured-boot event log** and **coreboot CBFS** — with all four
OpenBIOS targets (`unix`, `amd64`, `x86`, `ppc`) serving as an
**endianness × width correctness matrix** that a hosted tool like GNU poke
structurally cannot have.

Extends [`examples/openbios-the-rival-that-shipped/`](examples/openbios-the-rival-that-shipped/).
The direction and the primitives it needs were identified in
[`dsl/POKE-ELF-GLEANINGS.md`](examples/openbios-the-rival-that-shipped/dsl/POKE-ELF-GLEANINGS.md)
and [`DESIGN-NOTES-preboot-forth-binary-structures.md`](DESIGN-NOTES-preboot-forth-binary-structures.md)
§8; this plan turns the claim map into spikes.

> **The one pattern this family enforces (LOCKED): Spike 0 runs first and it is a
> DECISION, not a warm-up.** It decides whether `struct.fth`'s static-offset
> model can carry a length-prefixed record at all, or whether the TLV work needs
> a parallel cursor construct. Nothing in Spikes 1–3 is committed until Spike 0
> is green on all four arches. (Same discipline as
> [`OPEN_FIRMWARE_NATIVE_HABITATS_LAB_PLAN.md`](OPEN_FIRMWARE_NATIVE_HABITATS_LAB_PLAN.md).)

---

## 1. Why — and why now

Two enabling pieces just landed on `main`:

- **`write-file`** (TODO §20): the hosted firmware can now **author a structure
  in the Forth arena and persist it to a real host file**, which the host — or an
  external oracle — then reads. Author → persist → independent-decoder is the
  grading ladder the ELF work proved; it applies unchanged to any format.
- **The poke-elf prospecting note** (TODO §21): it named the exact two
  `struct.fth` primitives missing for extensible records (a **length-prefixed
  array** and **`alignto`**), and identified the `Elf_Note` TLV as the structural
  twin of a TPM event-log entry and a CBFS-ish container.

So the toolkit's *reader* half exists (`elf.fth` reads/inspects), its *writer*
primitive exists (`write-file`), and the *missing rung* is named. This lab builds
that rung and points it at two formats that matter to firmware.

**Why these two formats, and not a generic image zoo.** Both are
**firmware-native**, both are TLV-shaped (so they share Spike 0's machinery), and
between them they exercise **both endiannesses** — which is the whole reason to do
this on real multi-arch firmware rather than in poke:

- the **TCG PCClient event log** is **little-endian**;
- **coreboot CBFS metadata is big-endian** — source-confirmed, not assumed:
  `CBFS_HEADER_MAGIC 0x4F524243 /* BE: 'ORBC' */`
  (`coreboot/.../cbfs_serialized.h`). A little-endian read byte-swaps the magic;
  `ppc` reads it natively.

A generic "dissect any image" goal is diffuse and mostly re-implements host tools.
Two firmware-native TLV formats with opposite byte order are a *focused* goal that
makes the arch matrix earn its keep.

---

## 2. Thesis & scope

**Thesis (provisional, Spike 0 confirms the shape).** The IEEE-1275 encode/decode
discipline already in `struct.fth` — fixed-width, byte-order-explicit field access
that *refuses* a width it cannot represent — extends to **sequential,
length-prefixed records** with two additions, and once it does, the *same* layer
describes ELF notes, TCG event-log entries, and CBFS files. This is
`DESIGN-NOTES` §5's thesis ("generalize the encode/decode wordset outward from
device-tree properties to arbitrary binary structures") aimed at the structures
`DESIGN-NOTES` §8 said would pay.

**In scope:** build + parse + **verify** two formats, on all four arches, graded
against external oracles and a self-consistency check.

**The honest boundary (LOCKED, and it is the point of the attestation half).** A
TPM PCR is an iterated hash, `PCR = SHA256(PCR ‖ digest)`, and a measured-boot
event log is a list of extends. **Replaying the log and checking it matches a
claimed final PCR is 100% software and needs no TPM.** The one thing a real TPM
adds — a hardware-signed *quote* over the PCRs (the AK signature) — this lab
**does not fake**. It builds and verifies the log and the replay, then **stops and
names the quote UNKNOWN**, because the repo's own notes record that even swtpm
can't give a faithful AK here (it is baked into the image). *"UNKNOWN is a verdict
distinct from PASS"* — that boundary is a feature of the lab, not a gap in it.

---

## 3. Verified feasibility (checked 2026-09-01, before writing this)

Per house rule, the load-bearing claims were measured first, not assumed:

| claim | check | result |
|---|---|---|
| the two primitives are genuinely absent | `struct.fth` provides `field:`/`le-field:`/`dev-field:`/`array:` only | ✅ absent — and `struct.fth` is **static-offset** (each field's offset is fixed at compile time), which is exactly what a length-prefix breaks. Spike 0 is real. |
| CBFS metadata is big-endian | `grep CBFS_HEADER_MAGIC` in coreboot's `cbfs_serialized.h` | ✅ `0x4F524243 /* BE: 'ORBC' */` — the endianness control is **inside the subject** |
| a real subject exists to dissect | the lab's own coreboot build | ✅ `~/linuxboot-lab/coreboot/build-openbios/coreboot.rom`, 4 MiB |
| `cbfstool` oracle is obtainable | coreboot tree | ✅ source-only, buildable with `make -C util/cbfstool` (same vendored-oracle pattern as ELFkickers/`elfls`) |
| the writer side is available | TODO §20 | ✅ `write-file` on `main` |
| the event log is verifiable without hardware | the extend is a pure function | ✅ replay `H(PCR‖digest)`; `tpm2_eventlog` is the external oracle. **SHA-256 is the crux dependency — see Spike 1 risk.** |

---

## 4. Why this lab and not a hosted tool — the four arches are the control

This is the differentiator, and it is a *correctness* argument, not a taste one.
A structure toolkit's hardest property is **width × endianness**, and this session
already watched it bite twice (`min` vs `u<` answering differently on x86 and
amd64; `encode-int`/`decode-int` not round-tripping at a 64-bit cell). The four
targets are a matrix that catches exactly that class of bug:

| target | cell | endian | role in this lab |
|---|---|---|---|
| `unix` | 64-bit | LE | **the workbench** — CI-friendly, `write-file`, no QEMU; every parser is built and unit-tested here first |
| `amd64` | 64-bit | LE | the flagship bare-metal; long mode, NVDIMM/pmem — the Spike-3 device-memory target |
| `x86` | 32-bit | LE | the **narrow-cell control** — where a 64-bit-cell assumption bites (and where "the cheap check lies", the VGA false-positive) |
| `ppc` | 32-bit | **BE** | the **big-endian control** — reads CBFS's `'ORBC'` natively while LE targets byte-swap it; a hidden LE assumption in a length prefix dies here and nowhere else |

**Every track in this lab runs on all four and asserts the round-trip holds across
the matrix.** That is the negative control a single-machine tool can never run —
and it is precisely why a firmware-hosted toolkit can be *more* trustworthy about
byte order than poke, not less.

---

## 5. The spikes

### Spike 0 — the two `struct.fth` primitives, and the model decision (THE GATE)

**Deliverable:** `vfield:` (a length-prefixed byte field — an array whose count is
a *runtime* value from a prior field) and `alignto` (advance a cursor to the next
multiple of N). Both compose with the existing `t@`/`t!` so the length prefix is
read **through the width/endian-aware machinery**, not a raw fetch.

**The decision it forces (this is why it is Spike 0):** `struct.fth` today is
**static-offset** — `base field: → addr` with the offset baked at compile time. A
length-prefixed record cannot know its later offsets at compile time. So Spike 0
must decide, *by building it*, between:

- **(A)** extend `struct.fth` with a **cursor mode** — a field yields
  `(addr, next-cursor)` and records compose along a running offset; or
- **(B)** a **parallel `walk:`/`tlv:` construct** beside the static layer, leaving
  `field:` untouched.

Pick by trying (A) first; fall back to (B) if it contaminates the static path.
Record the decision in the plan the way native-habitats recorded its thesis gate.

**Exit criterion (all four arches, green):** author a synthetic length-prefixed
record — `{ len:u32, name[len], pad-to-4, body:u16 }` — with `write-file`, read it
back through the new primitives, and recover `name` and `body` **byte-identically
on `unix`, `amd64`, `x86`, and `ppc`**. The record is authored in **both** byte
orders in one run, and the **`ppc` row is the assertion**: a `le-field:` length
read on a big-endian record must be *caught*, not silently mis-sized. Negative
control: hard-code the length as LE and watch `ppc` fail by name.

**Nothing in Spikes 1–3 starts until this is green.** Both CBFS and the event log
are length-prefixed; a width/endian leak here is inherited by everything above.

---

### Spike 1 — the TCG measured-boot event log (the attestation payoff)

Split deliberately, because only half needs crypto:

- **1a — the log as a structure (no crypto).** Parse a real crypto-agile event log
  (`TCG_PCR_EVENT2`: `pcrIndex:u32, eventType:u32, digests{count,[algId:u16,
  digest]}, eventSize:u32, event[eventSize]`) with the Spike-0 primitives, and
  **author** one with `write-file`. `eventType` names come from a context-keyed
  registry (the `elf-config` shape the poke-elf note flagged, keyed by nothing
  here — the log is machine-agnostic — but reused verbatim in Spike 2). Graded
  against **`tpm2_eventlog`** reading what the firmware wrote (author → persist →
  independent oracle), plus a self-consistency pass (every `eventSize` lands on
  the next entry; `count` digests present).

- **1b — the replay (the payoff, needs SHA-256).** Compute each PCR by replaying
  its extends, `PCR = SHA256(PCR ‖ digest)`, and **verify the replayed value
  equals a claimed final PCR.** This is the attestation result you can get with no
  TPM. **Crux dependency / named risk:** OpenBIOS Forth has no SHA-256. Implement
  it once — either in Forth, or as a hosted-only bound C word beside `write-file`
  — and it is the same on all four arches (a pure function is the cleanest thing
  to validate across the matrix; NIST test vectors are the control). If SHA-256 in
  Forth proves too slow/large for the bare-metal arches, `1b` runs on `unix` and
  is documented as such — an honest partition, not a silent skip.

- **1c — the boundary, stated out loud.** The hardware-signed **quote** is
  **UNKNOWN** and printed as such: the lab measured the log and the replay; it did
  **not** and cannot verify a hardware root of trust here. Naming it is the
  deliverable's honesty, and it is what separates this from theatre.

**Exit criterion:** a firmware-authored event log that `tpm2_eventlog` parses, a
replay that matches a claimed PCR (with a negative control — flip one digest byte,
watch the replay diverge and the check fire), and the quote-is-UNKNOWN line
present on every run.

---

### Spike 2 — coreboot CBFS (the firmware-native image you already ship into)

**Deliverable:** a Forth CBFS reader over the lab's **own** `coreboot.rom` — walk
the CBFS (`'ORBC'` master header → `(magic 'LARCHIVE', len, type, checksum,
offset, name)` file entries, **all big-endian**), list the files, and **verify a
payload's declared size/hash against its bytes**. Then **author/patch** a small
CBFS entry with `write-file` and confirm `cbfstool` reads it.

**Why it converges with Spike 1:** coreboot is *where measured boot happens* — its
vboot extends PCRs and writes the very event-log format Spike 1 handles. And CBFS
reuses Spike 0's primitives directly. The big-endian metadata makes the **`ppc`
row the natural truth-teller**: it reads `'ORBC'`/`'LARCHIVE'` without a swap while
the LE arches must swap, so an accidental LE read is caught by the arch that
shouldn't need fixing.

**Oracle:** `cbfstool` (`make -C util/cbfstool`), vendored/built the way `elfls`
was. **Subject:** the real 4 MiB ROM already on disk, so this dissects a genuine
firmware image, not a fixture.

**Exit criterion:** the Forth walk of `coreboot.rom` lists the same files
`cbfstool print` does (name, type, size), a payload's bytes match its declared
metadata, an authored entry round-trips through `cbfstool`, and the walk is
correct on all four arches — the `ppc` row proving the big-endian reads are real.

---

### Spike 3 — point it at REAL device memory (the uniquely-licensed edge)

**Deliverable:** the one thing a hosted tool structurally cannot do. On the
bare-metal arches, aim the finished toolkit at **actual device memory** — parse
and verify a structure from a real **option-ROM / expansion-ROM** region or a
flash window (not a file), and **diff it across a boot transition** using
`open-firmware-debugs-itself`'s existing `region-snap`/`region-diff`
(`dsl/ofscope.fth`). This is `DESIGN-NOTES` §6/§8's *"diff physical memory across a
boot transition"* — poke on a hosted OS gets there only after the OS exists; this
is at the preboot prompt, before it does.

**Exit criterion (scoped, honest):** read a known structure (e.g. a PCI option
ROM's header / an FCode image's first bytes) from real device memory on `amd64`
and `x86`, verify a field against ground truth from an observer outside the
firmware (QEMU monitor / a host-side read of the same ROM image), and snapshot →
act → snapshot → diff a region to show a change the firmware itself caused. If a
seam isn't reachable on a given arch, it is **named as not-yet-covered**, not
quietly dropped (the chaos-matrix rule: a layer with no scenario is a layer nobody
watched fall over).

---

## 6. What this is NOT (scope guards)

- **Not a linker.** No symbol tables, no relocations, no dynamic section, no
  per-arch reloc registries. The poke-elf note already assayed those as barren for
  a firmware that never relocates.
- **Not a fake TPM.** The hardware quote is UNKNOWN and stays UNKNOWN.
- **Not a generic image dissector.** Two firmware-native TLV formats, chosen
  because they share Spike 0 and split the endianness axis. New formats are added
  only when they pay the same way.
- **Not a hosted tool re-implemented.** The justification is the four-arch control
  and the preboot device access (Spike 3); if a spike could be done as well by
  running `readelf`/`cbfstool`/`tpm2_eventlog` alone, it isn't a spike, it's the
  oracle.

---

## 7. Risks & the standing bias to correct for

- **SHA-256 in Forth (Spike 1b)** is the sharpest dependency — size/speed on the
  bare-metal arches is unproven. Mitigation: a bound C word on `unix` first
  (proves the replay logic), then decide whether the Forth version is worth it.
  Do **not** let the crypto block the structure work (1a/Spike 2 need none).
- **Cursor model contamination (Spike 0(A))** could complicate the clean
  static-offset path that ELF/CBFS *headers* rely on. The (B) fallback exists for
  exactly this; decide by measurement.
- **CBFS format drift.** CBFS has more than one era (legacy master header vs.
  FMAP-only builds). Pin to the format the lab's *own* `coreboot.rom` uses and say
  so; don't claim to read a shape the subject doesn't have.
- **The standing bias:** this family has a documented pull toward
  *"written by analogy"* — a parser that looks right and reads the wrong bytes.
  Every spike is graded against an **external oracle** and an **all-four-arch**
  round-trip precisely to break that; a green single-arch run proves nothing here.

---

## 8. Routing (at assembly, not before)

The code lands in the existing lab's `dsl/` (`struct.fth` gains `vfield:`/
`alignto`; new `cbfs.fth`, `eventlog.fth`, and a `sha256.fth`/bound word), with new
`smoke-openbios.sh` tracks (`tlv-primitives`, `event-log`, `cbfs`, and a bare-metal
`device-scan`), each **wrapped** (`tests/test-smoke-*.sh`), **listed** in
`run-all.sh`, and named in the usage strings — the track/wrapper/list guards
already enforce this. Vendored oracles (`cbfstool`, and `tpm2_eventlog` if not
packaged) follow the `oracle/elfkickers/` provenance pattern. No new `examples/`
lab unit is created, so learning-paths routing is unaffected; the plan and the
gleanings note are the inbound references. Docs, `link_check.py`, and the patch
record (this work touches only `dsl/` Forth + tracks, **not** the firmware C, so no
new firmware patch) stay green at every step.

---

## 9. Success signature (per spike, observable)

- **Spike 0:** a length-prefixed record round-trips byte-identically on `unix`,
  `amd64`, `x86`, `ppc`; the `ppc` row catches a hard-coded-LE length by name.
- **Spike 1:** `tpm2_eventlog` parses a firmware-authored log; a PCR replay matches
  a claimed value and diverges when one digest byte is flipped; the
  quote-is-UNKNOWN line prints on every run.
- **Spike 2:** the Forth walk of the real `coreboot.rom` lists the same files as
  `cbfstool print`, on all four arches, the `ppc` row proving the big-endian reads;
  an authored entry round-trips through `cbfstool`.
- **Spike 3:** a structure read from **real** device memory on `amd64`/`x86` is
  verified by an observer outside the firmware, and a region diff shows a
  firmware-caused change; uncovered seams are named, not dropped.

---

## 10. Addendum — grading CBFS surgery against the coreboot team's `cbfstool`

The oracle for the CBFS work is **`cbfstool`, coreboot's own reference
implementation**, built from the same tree that produced the ROM. This is worth
spelling out because CBFS is a format we would otherwise be grading against *our
own reading of a spec header* — the "written by analogy" trap this family already
paid for. The discipline is **bidirectional and covers surgery, not just reads**:

- **Read direction.** `cbfstool <rom> print` is ground truth for the walk: our
  Forth listing (name, type, size, offset of every file) must match it entry for
  entry, on all four arches. `cbfstool extract` gives ground-truth *bytes* for the
  payload-hash check.
- **Write / surgery direction — the one that actually matters.** When our Forth
  **authors or patches** a CBFS entry (via `write-file`), the test is **not** that
  our own reader accepts it — a parser and a writer wrong the same way agree with
  each other. The test is that **`cbfstool` accepts the whole ROM afterward**:
  `cbfstool print` still lists a coherent archive, the master-header and
  per-file fields still validate, and `cbfstool extract` returns our bytes
  unchanged. A patch our reader loves and `cbfstool` rejects is a **silent
  corruption**, and catching it is the entire reason the oracle is the coreboot
  team's tool and not ours.
- **Round-trip, both origins.** A ROM `cbfstool` *built* must survive our
  walk → author → `cbfstool` read unchanged; a structure *we* built must survive
  `cbfstool` extract → re-`add` unchanged. Either direction failing is a finding.
- **When they disagree, suspect us first — but check both.** `cbfstool` is the
  reference, so a mismatch is our bug until proven otherwise. It is *not*
  infallible (it is software, and "the control is where the bugs are"), so a
  genuine `cbfstool`-side surprise gets filed, not papered over.
- **Bind the oracle to the subject (derive, don't cache).** `cbfstool` is
  **versioned with coreboot** and its metadata handling has eras (legacy master
  header vs. FMAP-only). Grading a ROM with a `cbfstool` from a *different*
  coreboot than built it is exactly this repo's stale-record bug in oracle form.
  So the vendored/built `cbfstool` is **pinned to the same coreboot commit as the
  `coreboot.rom` under test**, and the track records both — a version string is
  not an identity; the commit is.

Same pattern as the ELF work grading against ELFkickers `elfls`, but with a
sharper edge: here we don't just *inspect* with the foreign tool, we hand it
something **we surgically altered** and require it to still call the patient
healthy.

## 11. Adjacency — the full-source bootstrap (NixOS / Guix stage0)

Worth naming, and worth naming *honestly* — it is an **adjacency and a possible
future connection, not a dependency**. Nothing in Spikes 0–3 needs it.

**What it is.** The bootstrappable-builds effort (NixOS and Guix) shrinks the
opaque **binary seed** of a system to a tiny auditable one — `hex0` and a few
hundred bytes upward to a full toolchain — so userspace is built from inspectable
source rather than trusted blobs. Its thesis is the reduction of *unauditable
trusted surface*.

**Where it genuinely connects — two hooks, one real, one aspirational:**

- **The real one: reproducible artifact + runtime attestation are complementary
  halves of one trust question, and this lab owns the seam between them.** A
  full-source bootstrap proves *the artifact is what its source says* (provenance
  / reproducibility). Measured boot (Spike 1) proves *the machine is running that
  artifact* (runtime attestation). The connective tissue is a single rule this
  repo already lives by: **derive the PCR / event-log expectation from a
  source-bootstrapped, reproducible build — do not cache a captured golden
  value.** That is `DESIGN-NOTES` §1's *derive the fact, don't cache it* and the
  metal-as-a-service `pcrs.expected`-bound-to-build-sha lesson, pointed at a
  bootstrap whose outputs are reproducible *by construction*. If the expected
  measurement is computed from a bit-reproducible source build, the event-log
  replay in Spike 1 becomes a check against a value nobody had to trust, only to
  recompute.
- **The aspirational one: firmware is the layer stage0 does not cover.** stage0
  bootstraps userspace and the toolchain from a seed; the firmware underneath is,
  on most hardware, still a blob. This lab family builds **OpenBIOS/coreboot from
  source** and boots it — the firmware-layer complement to stage0's userspace
  chain. So a source-built firmware (here) plus a source-bootstrapped userspace
  (stage0) is, in principle, an auditable chain from close to the reset vector up,
  and the CBFS + event-log toolkit is exactly what would let you **verify each
  seam**: walk the CBFS to confirm every payload is a source-built artifact,
  replay the event log to confirm the machine measured precisely those.

**The honest caveat (frame the trust chain, don't oversell it).** A reproducible
artifact does **not** supply the missing hardware root of trust — the AK-signed
quote is still **UNKNOWN** here (§2's boundary), and a bit-reproducible build makes
the *expectation* honest, not the *attestation* complete. And OpenBIOS-on-QEMU is
a software-firmware demonstration, not the SPI-flash reality of production
hardware. So the connection to draw is: **this toolkit could give the
full-source-bootstrap chain its firmware-layer verifier and its "derive the
expectation" discipline** — a direction the lab could serve, flagged so it is not
lost, not a claim that the chain is closed. (If pursued, it is its own item, and
the trust boundary gets named there the way §2 names it here.)

## 12. The payload-substitution matrix — where Spikes 2–3 go live, and the cell that's missing

The coreboot/OpenBIOS/Linux chains in this repo are not four boot demos. They are
a **payload-substitution matrix**: coreboot is a ROM that carries *a* payload,
OpenBIOS is one payload among possible others, and the target OS is reached by
one thesis or another. Seen that way, **this toolkit is the single instrument
pointed at the whole matrix** — dissect the CBFS to see *which* payload a ROM
carries, replay the event log to see *what got measured* — so the payload is the
variable and the toolkit is the constant. That is the through-line that ties the
firmware-replacement work to Spikes 1–2.

### The matrix as it stands

| delivery mechanism | payload | target | present? |
|---|---|---|---|
| QEMU multiboot (`-kernel`) | OpenBIOS | `0 >` prompt | ✅ `multiboot` track |
| **coreboot ROM** (`CONFIG_PAYLOAD_ELF`) | **OpenBIOS** (x86 + amd64) | `0 >` prompt | ✅ `coreboot`/`coreboot-amd64` — OpenBIOS *is the payload*, its LinuxBIOS birthplace |
| bare-metal amd64 (`-kernel` long-mode) | OpenBIOS | `0 >` prompt | ✅ `amd64` track |
| OpenBIOS | modern Linux + initrd | u-root | ✅ `amd64-linux` + `showcase-rival-boots-linux.sh` |
| coreboot → OpenBIOS | modern Linux | u-root | ✅ the showcase's `coreboot` flavor — the full **3-stage** chain |
| UEFI | u-root / LinuxBoot | kexec → Linux | ✅ but in a **separate lab** (`examples/linuxboot-uefi-kexec/`), hanging off **UEFI, not coreboot** |

**AND THE CELL THAT IS NOT PRESENT — call it out plainly:**

> **coreboot → modern Linux, directly ❌ — NOT PRESENT.** coreboot here only ever
> carries **OpenBIOS**. The repo *has* the Linux-as-firmware half —
> [`examples/linuxboot-uefi-kexec/`](examples/linuxboot-uefi-kexec/), a u-root
> `init` that `kexec`s — **but it hangs off UEFI, not coreboot.** So the two
> halves exist and were never joined. **That gap is the interesting part.**

### Two things the matrix affords this toolkit uniquely

- **Delivery-mechanism × arch is a correctness control for the firmware itself.**
  Same OpenBIOS, loaded three ways that relocate differently — and it has already
  caught real bugs (the `client-forth` track found the x86 stale-dictionary bug
  precisely because the coreboot-payload path relocates where multiboot does not,
  and amd64, which does not relocate, could not show it). This is the endianness
  matrix of §4 one level up: *how the firmware arrives* is as much a control as
  *how it reads bytes*.
- **coreboot → OpenBIOS is the LIVE substrate for Spikes 2–3.** OpenBIOS already
  parses coreboot's `LB_TAG` tables (`libopenbios/linuxbios_info.c`) for its
  memory map, so it runs with the ROM mapped and already reads coreboot's own
  structures. That gives the CBFS work a uniquely-licensed live form: **a Forth
  prompt that walks the CBFS of the very ROM that delivered it** — the firmware
  dissecting its own container from *inside*, on the real flash window, before any
  OS exists. No hosted `cbfstool` can be "inside the ROM it booted from." Spike 2
  (CBFS) and Spike 3 (real device memory) collapse into one demo here.

### What to build from this (in order — but NOT YET its own lab plan)

1. **The "firmware reads its own ROM" demo** — OpenBIOS-as-coreboot-payload
   walking its own CBFS at the `0 >` prompt. It is Spike 2 + Spike 3 made vivid,
   and it needs **nothing not already on disk**: a `coreboot.rom`, the Spike-2
   CBFS reader, and the `LB_TAG` parser already in-tree. This is the single most
   "uniquely afforded" thing in the whole cluster, and the natural first target of
   the CBFS reader's *live* (not file-only) form.
2. **coreboot → u-root — the missing matrix cell** (coreboot carrying a u-root
   Linux payload instead of OpenBIOS), then a small **comparison bench**: the same
   target Linux reached by **three firmware substrates** (coreboot+OpenBIOS+OFW
   boot, coreboot+u-root, UEFI+u-root). This is exactly where the **event-log half
   (Spike 1) earns its keep** — measured coreboot with *different payloads*
   produces *different measurements from the same ROM boot-block*, so "replay the
   log, see what differs" becomes a **comparison** rather than a single reading.

**Hold off on treating this as its own lab plan until B.3's Spike 0 lands** —
both items lean on the CBFS reader, which does not exist until the primitives do.
This section is the note that keeps the direction from being lost: Spikes 2–3 have
a *live* form under the coreboot-payload combination, and **coreboot → u-root is
the cell that turns the attestation half from one reading into a comparison.**

---

*Provenance: extends
[`examples/openbios-the-rival-that-shipped/`](examples/openbios-the-rival-that-shipped/);
motivated by [`dsl/POKE-ELF-GLEANINGS.md`](examples/openbios-the-rival-that-shipped/dsl/POKE-ELF-GLEANINGS.md)
(TODO §21) and [`DESIGN-NOTES-preboot-forth-binary-structures.md`](DESIGN-NOTES-preboot-forth-binary-structures.md)
§8; enabled by TODO §20's `write-file`. TCG PCClient Platform Firmware Profile and
coreboot CBFS are followed as upstream specs/source — cite, don't mirror — with a
retrieved-as-of date captured when the code is written.*

*Reviewed 2026-09-01 in
[`REVIEW-preboot-structure-toolkit-plan.md`](REVIEW-preboot-structure-toolkit-plan.md)
— completeness, feasibility, extensibility, and the components already in the
repo that this plan does not yet reuse. Its two largest corrections: §12's
"missing cell" exists (`examples/linuxboot-uefi-kexec/` Tier A), and the
four-arch matrix in §4 is a two-arch artifact until a delivery spike lands the
type layer on `ppc` and `unix`.*
