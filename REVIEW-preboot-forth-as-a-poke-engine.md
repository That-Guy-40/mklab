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
> ~~What is missing is not primitives. It is **types**. … `create ... does>` —
> the exact machinery — is present and has never been pointed at a structure.~~
>
> **BUILT 2026-08-29 — and the review was wrong about where it starts.** The
> diagnosis holds: what was missing is types. The *prescription* did not — the
> definer was never the work, because **OpenBIOS already ships one**.
> `forth/bootstrap/bootstrap.fs:1570` has `0 constant struct` and
> `: field create over , + does> @ + ;`, and it works at the untouched prompt
> (measured: `size`=7, offsets 0/4/6). What `field` lacks is **width and byte
> order**; [`dsl/struct.fth`](examples/openbios-the-rival-that-shipped/dsl/struct.fth)
> adds only that, in ~60 lines over accessors that were already bound. Both of
> G2's checkpoints are met on both arches and the layer parses a real ELF64
> header — see §G2.
>
> **UPDATED 2026-08-29, after reading GNU poke 5.0's source and manual.** The
> analogy's foundation moved: poke is **not** write-through on assignment — its
> manual specifies an explicit three-step map/modify/**poke-back** for scalars,
> and write-through is a property of mapped *composite* values. So Forth's `!` is
> *more* immediate than poke's scalar path and *less* capable than its composite
> one, and the type layer's requirement sharpens from "compute a field address"
> to **"make field update be the write"** (§P1). Two other corrections: flash is
> a **backend** in poke's own seven-function IO interface rather than a limit of
> the model (§P2), and `elf.pk` no longer ships at all (§P4).
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

~~**One thing this review did not verify at all:** the characterisation of GNU
poke … is taken **from the proposal as given**. No poke source was fetched and no
poke was run.~~

**DISCHARGED 2026-08-29 — see §P below.** GNU poke **5.0** was fetched from
`ftp.gnu.org` (`sha256` 6873d59a…, 8.9 MB) and read: the IO-device interface, the
shipped backends, the shipped pickles, and the manual's own statement of
assignment semantics. **One of the proposal's central claims did not survive, and
it is the one the whole Forth analogy rests on.** poke itself was *not built or
run* — the findings below are from its source and manual, which is the same
standard the first pass held itself to.

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

## P — What reading GNU poke 5.0 changed

Four corrections and one confirmation, all from the shipped source and manual.

### P1 — "write-through on assignment" is FALSE for scalars, and that inverts the Forth analogy

This is the finding that matters most, because the proposal's whole bridge to
Forth is *"a Forth address is a live, write-through view onto memory — poke's
mapped-value semantics as the ground floor of the language."*

poke's manual, on changing an integer in an IO space:

> First, we would map it into a variable, change the value, and **then poke it
> back** to the IO space.
> ```
> (poke) var n = int @ offset
> (poke) n = n + 1
> (poke) int @ offset = n
> ```
> **This three-steps process is necessary** because in `n = n + 1` above we are
> modifying the value of the variable `n`, not the integer actually stored at
> offset.

**Write-through is not poke's assignment semantics. It is a property of mapped
COMPOSITE values** — arrays and structs — and it works because poke copies
composites by *value sharing*, so "updating their elements has a side effect: the
area corresponding to the updated element … is updated as well."

Both halves of the analogy move, in opposite directions:

- **Forth is *more* write-through than poke, at the scalar level.** `!` is the
  store. There is no variable to poke back from. The proposal undersells this.
- **Forth is *less* write-through than poke, at the level that matters.** poke's
  composite write-through knows *which bytes an element occupies*, because the
  value carries its type. That is precisely what this tree does not have — and it
  turns G2 from "add a type layer" into a sharper requirement: **the type layer
  must make field UPDATE be the write, not merely compute a field address.**

### P2 — flash is a BACKEND, not a limitation, and poke's own interface is tiny

`libpoke/ios-dev.h` defines the whole contract an IO space must satisfy:

```c
open · close · pread · pwrite · get_flags · size · flush
```

Seven function pointers, `pread`/`pwrite` at an offset. Eight backends ship:
`file`, `mem`, `mmap`, `nbd`, `proc`, `stream`, `sub`, `zero`.

**This confirms G1's conclusion and softens its tone.** A CFI part is not a
store-to seam — that stays measured and true — but "needs a driver-mediated
backend" is not poke telling us the model does not fit. It is the model's own
extension point, and a flash IO space is `pread` = read the array, `pwrite` = the
unlock/erase/program/poll sequence. The architecture anticipates exactly this.

### P3 — "poke is locked out" is true, and NOT for the reason given

The proposal says poke needs a hosted OS because *its IO spaces* abstract over
files and `/proc/PID/mem`. The IO layer is not the obstacle — it is seven
functions, and `ios-dev-mem.c` is a malloc'd buffer.

The obstacles measured:

| | |
|---|---|
| `libpoke` is **183,315 lines across 36 `.c` files** | porting poke preboot is not on the table, and was never the proposal — worth having the number |
| it runs on **Jitter**, a JIT/VM generator vendored in the tree | this, not the IO layer, is what makes poke hosted |
| `ios-dev-mmap.c` exists | on a booted Linux with `/dev/mem`, **poke can already reach physical memory and MMIO** |

That last row narrows the differentiator and makes it sharper. "MMIO" is not by
itself out of poke's reach. What is genuinely unreachable is **preboot** — before
an OS exists — and **firmware-owned state**: the boot transition itself, device
registers before any driver has claimed them, flash through the firmware's own
programming path. §G6's forensics angle is therefore not one application among
several; it is the *only* one the differentiator uniquely licenses.

### P4 — `elf.pk` no longer ships, and that strengthens the format-agnostic claim

The proposal offers `elf.pk` as the shipped example. In poke 5.0 `pickles/`
contains a `README.elf` saying the ELF pickles *"are now distributed
separately"*. What does ship is **60+ pickles**: `pe.pk` and eleven PE
architectures, `coff.pk`, `mbr.pk`, `gpt.pk`, `jffs2.pk`, `ustar.pk`, `pcap.pk`,
`jpeg.pk`, `bmp.pk`, `id3v1/v2`, `openpgp.pk`, `ctf/btf/sframe`, `srec.pk`,
`leb128.pk`, `ieee754.pk`, `crc16.pk`.

Minor as a correction; useful as evidence. ELF is not merely "one of" the
formats — it is not special enough to be bundled at all.

### P5 — unit-typed offsets confirmed, so G4 stands unchanged

The manual indexes them as *united values* and gives offsets their own chapter.
G4's recommendation — do bit-fields, skip unit-typed offsets, in writing — is
unaffected.

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

## G2 — ~~The gap is types, not primitives, and `does>` is sitting unused~~ — BUILT 2026-08-29, and `does>` was never the missing piece

~~This is the finding that should shape the next piece of work.~~ — **it did, and
the first thing building it found was a defect in this section.**

> **RESOLVED.** [`dsl/struct.fth`](examples/openbios-the-rival-that-shipped/dsl/struct.fth)
> plus `smoke-openbios.sh struct-layer`, green on **both** arches. The rest of
> this section is kept because its *diagnosis* was right; its *prescription*
> was not, and the correction is below.

### The correction: the definer already existed

This section says `create ... does>` is "present and has never been pointed at a
structure" and treats writing the definer as the deliverable. Half of that is
true — nothing in **this repo** had used it — and the half that matters is not:
**the firmware ships the definer itself.**

```forth
0 constant struct                             \ forth/bootstrap/bootstrap.fs:1568
: field  create over , + does> @ + ;          \ …:1570
```

`struct  4 field a  2 field b  1 field c  constant size` runs at the untouched
`0 >` prompt and gives `size`=7 with offsets 0/4/6, measured on amd64 before a
line of the layer was written. So the **address** half of poke's mapped value —
apply a layout at a base, get the address of a named member — has been in
OpenBIOS the whole time, and this review spent a section recommending it be
built.

**Why the mistake was possible, and it is this repo's own recurring shape.** The
section was written from a `git grep` of *this repo* for a definer. That question
is not the question it was taken to answer: *does the firmware already do this?*
A grep over the lab is a cheap check standing in for one about the corpus
underneath it — the same substitution `check-harness-net.sh` made twice. The fix
was not cleverness; it was **booting the thing and asking it**.

### What was actually missing, and what it cost

`field` carries an **offset and nothing else**. Every read then restates the
width and the byte order by hand at the call site, which is precisely where a
binary-structure parser goes wrong. The layer adds those two facts and nothing
else:

```forth
: field:    ( off width -- off' )  0 (tfield) ;   \ big-endian  (1275 native)
: le-field: ( off width -- off' )  1 (tfield) ;   \ little-endian
```

A typed field leaves `( base -- adr tid )` — **the address first**, which is the
whole design and is §P1 reached from the other side. poke needs
map / modify / **poke-back** for a scalar because the variable is a copy; there
is no copy here to write back from, so `t!` *and* a bare `le-l!` through `t-adr`
are equally the write. Both were measured.

Two accessors had to be written because the firmware ships neither: 2-byte
big-endian (1275 never needed it — a property cell is four bytes) and 8-byte
either way. The 8-byte path **refuses by name on a 32-bit cell** rather than
truncating, which makes x86 an arch-level control: every other row is identical
across the two arches, and only that one diverges.

### What it proves, and the controls that make that mean something

| checkpoint | measured |
|---|---|
| a named field reads back what a **different word** wrote | `int!` (the 1275 encoder) → BE field = `deadbeef`; `le-l!` (a C binding) → LE field = `cafebabe` |
| storing **through** a field is the write, with no write-back step | `t!` of `11223344` leaves memory holding `44 33 22 11`; a bare `le-l!` at `t-adr` reads back `55667788` |
| the layer parses a real ELF64 | the amd64 firmware's own boot image off ISO9660: magic `464c457f`, class 2, type 2, machine `3e`, entry `101d70`, size `21af8` — all equal to ground truth `struct.unpack`ed from the same bytes on the host |
| **order control** — the same bytes through the other order | `bebafeca` / `efbeadde`, exact reversals. Without this row, "it round-tripped" is satisfied by one accessor being its own inverse |
| **two views** of one region agree | `e_entry` as two 4-byte halves and as one 8-byte LE field at `0x18` both give `101d70`, so the offsets are not arithmetic nobody checked |
| **three refusals** fire by name | an unimplemented width, big-endian 64, and an 8-byte field on x86's 32-bit cell |

**Seven injections were run against it and all seven bit** — and the fourth
exposed a defect in the assertions themselves, which is where this repo keeps
finding them. Three rows asserted that a refusal *printed its name*. That is the
mechanism. The **outcome** of a refusal is that the operation did not complete,
so each refusing word now ends on its own marker and the assertion is that
marker's **absence** — after which an injected `t-width-err` that names the
width, balances the stack and returns a number anyway fails by name, where the
printed-name assertion had passed it.


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

**SHARPENED 2026-08-29 by §P1.** Reading poke changed what this layer has to do.
It is not enough for `e_entry` to *resolve to an address* — poke's convenience is
that updating a field of a mapped value **is** the write to storage. In Forth
that means a field word must yield something you can store *through*, and a
structure mapped at an address must not be a copy. Forth is well placed for this
precisely because it never had a copy in the first place: there is no value
semantics to undo, only an address to hand back.

So the deliverable is a definer whose fields are **addresses into the mapped
region**, with width and endianness attached — at which point `!`/`le-l!` on a
field *is* poke's composite write-through, reached from the other side and
without the shared-value machinery poke needed to get there.

~~`create ... does>` is present (`forth/bootstrap/bootstrap.fs:1563`) and is exactly
the machinery the proposal names. **The repo has never used it for a structure.**
That is the single highest-value next artifact: a definer such that~~ — **the
firmware had already used it for a structure, seven lines further down the same
file (`:1570`). See the correction above.** The sketch below is close to what
shipped, with `field:`/`le-field:` taking the width *before* the name so the
declaration reads as the upstream `struct`/`field` idiom does:

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

## G8 — Arrays, a second backend, and the defect that asking for one turned up

*Added 2026-08-30, closing the two items §"What this review did NOT prove" still
listed after G2 was built.*

### Arrays: the other half of poke's composite model

A single mapped struct is not poke's model; poke writes
`Elf64_Phdr[ehdr.e_phnum] @ ehdr.e_phoff`. The Forth equivalent is a stride and
an index, and `array:` is six lines over the same `create ... does>`.

What makes `smoke-openbios.sh struct-array` worth more than a table of constants
is that **the subject states its own layout**. An ELF64 header carries
`e_ehsize`, `e_phentsize` and `e_phnum`, so three assertions compare the
*declaration* against the *file* rather than against a number written twice:
`/elf64-ehdr` must equal `e_ehsize`, `/elf64-phdr` must equal `e_phentsize`. An
offset that drifts anywhere in the header layout moves the very field that
catches it — demonstrated by injection: shrinking one field by two bytes made
`e_ehsize` read `0x0`.

The traversal is graded by a number the **firmware derives** — its own sum of
`p_filesz` across the `PT_LOAD` segments — because a walk that gets one element
wrong changes it. And the control is the stride: the same element type walked at
a stride wrong by 8 must read exactly the bytes the host says live at that wrong
place, and a *different* type from the correct walk. Without that row, "the walk
worked" is satisfied by an array whose index does nothing.

### A second backend — which is what poke's IO spaces are

§P2 found that poke's whole IO contract is seven function pointers and eight
backends, and concluded a flash target "is the model's own extension point."
**IEEE 1275 had already made that split**, in §5.3.7.2: `rb@ rw@ rl@ rb! rw! rl!`
are device-register access, distinct from `c@ w@ l@` precisely because a platform
may need a barrier or a bus byte-swap there. So the type layer's second backend
is not an invention; it is picking up a seam the standard already defines.
`dev-field:` / `le-dev-field:` are built from `rb@`/`rb!` alone, a byte at a
time, so byte order is explicit rather than inherited from the host CPU.

### …except the seam was not implemented

**The six words had bodies containing no words at all.** Not stubs that abort —
empty. Measured at the prompt before anything was written:

```
b8000 c@   -> 41       (the byte just written there)
b8000 rb@  -> b8000    at depth 1
42 b8002 rb!           left depth 2 having stored nothing
```

`forth/device/table.fs:390-395` binds **FCode tokens `0x230`-`0x235`** to exactly
these, so an FCode driver reading a device register receives an address, and one
writing a register stores nothing *and leaks two cells*. The presenting symptom
is therefore not a wrong value — it is a **stack shift**, surfacing somewhere
else entirely. That is the same shape as this lab's patches 25 and 34, and it is
the third time the real defect has been a stack shift wearing someone else's
symptoms. `forth/device/feval.fs:72` carries a FIXME saying `byte-load` "uses
`c@` rather than `rb@` for now" — the gap was known and worked around at one call
site rather than closed.

[Patch 49](examples/openbios-the-rival-that-shipped/patches/49-device-register-words-were-empty.patch)
gives them their memory-mapped bodies. Reverting only `rb@` was watched to fire
the track's headline row by name; reverting **all six** does not reach that row
at all — it overflows the Forth stack, 4000 stores leaking two cells each, which
is the write half's real failure mode and is worth knowing.

### And the two arches disagree, which was not the plan

On amd64 a typed array of VGA text cells mapped over `0xb8000` paints 2000 cells
through the layer; physical `0xb8000` then reads `41 1f 41 1f …` under QEMU's
monitor and the screen shows 158,445 blue pixels against **0** for an identical
no-paint boot.

On x86 the identical code **reads back `1f41` through Forth and never reaches the
device.** Physical `0xb8000` still holds `30 07 20 07 3e 07 20 07` — the
console's own `0 > ` prompt in grey-on-black — and the screen shows zero blue.
`arch/x86` relocates by rebasing the GDT, so a Forth address is not a physical
one; the store lands in ordinary RAM and reads back perfectly through the same
accessor that wrote it.

**That row is asserted positively rather than skipped**, because it is the cheap
check lying in the same run as the arch where it tells the truth. It is the trap
the `flash-writer` track met at `0xffbe0000`, met again from a different
direction, and it is the sharpest argument in this document for the thing the
proposal is least specific about: **a write to a device is graded by an observer
that is not the writer.** poke on a hosted OS gets that for free from the kernel;
here it has to be built, and the layer that makes field access convenient does
nothing whatsoever to make the address correct.

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

## G7 — ~~Reading a *file* from Forth is reachable and unproven — UNKNOWN~~ — RESOLVED 2026-08-29: it works

**Measured, and it settles the whole ELF-inspection class.** The amd64 firmware
loaded a real ELF64 off ISO9660 and parsed its header at the `0 >` prompt with
the upstream little-endian accessors:

| field | firmware | host ground truth |
|---|---|---|
| `e_ident[0:4]` via `le-l@` | `464c457f` | `0x464c457f` |
| `EI_CLASS` via `c@` | `2` | `2` (ELF64) |
| `e_type` via `le-w@` | `2` | `0x0002` |
| `e_machine` via `le-w@` | `3e` | `0x003e` (x86-64) |
| `e_entry` via `le-l@` | `101d70` | `0x00101d70` |
| `load-size` | `21af8` | 137976 bytes |

**No `seek`/`read` was needed.** `load` reads a whole file to `load-base`, and
indexing into that buffer with `le-l@` / `le-w@` / `c@` is the parse. The
application class is unlocked with words that already exist.

**Two things the experiment taught that reading could not.** First, `load`
*always* lands at `load-base`, so loading the parser and then the subject
overwrites the parser — the working order is **define the parser, then load the
subject under it**. Second, the first run reported a missing field that was
present: a `grep '^g7-'` missed a line that continued the prompt's echo, which is
this repo's own line-anchored-regex trap, met for the fourth time.

What remains genuinely unproven is reading a byte *range* of a large file
without loading all of it — irrelevant for headers, relevant for a 4 GB image.

### Original finding, kept

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
| **Preboot RE of blobs in memory and MMIO** | **strong, and now TYPED** — `ofscope.fth` and the two writer seams, plus a layout that can be mapped over a device's registers through 1275's own accessors (§G8). The x86 half also demonstrates the trap: a typed device write there reads back perfectly and never reaches the device |
| **Boot-handoff structures** | **unblocked and demonstrated** — `pmem-writer` is exactly this shape |
| **Post-mortem / transition forensics** | **the strongest fit, and now the ONLY one the differentiator uniquely licenses** (P3: a booted Linux poke reaches MMIO via `mmap`+`/dev/mem`; it cannot reach the boot transition). Caveat measured: `region-snap`/`region-diff` live in the **OFW** lab, not this OpenBIOS one — ~100 lines of plain Forth to port, but a port, not a reuse |
| **Firmware image assembly (CBFS, flash)** | **needs a backend, not an address** — G1 |
| **ELF / PE inspection at the prompt** | ~~blocked on G7 then G2~~ — **closed, tables included.** `struct-layer` parses the header; `struct-array` walks the **program-header table** of a real image and is graded by a sum the firmware derives, so a single mis-stepped element fails it. PE is a `pe.pk`-shaped declaration away and untried |
| **FCode authoring** | **the most OF-native of the list, nobody proposed it, and the execution half already exists.** `byte-load ( addr xt -- )` is a plain Forth word (`forth/device/feval.fs:63`), so *tokens built in a buffer at a chosen address can be executed by the firmware today* — `bytes!+` in, `byte-load` out. No FCode **assembler** exists anywhere (only the host-side `toke` and this repo's detokenizer), so the emitting half is new work; the loop it closes is not hypothetical |
| **Measured-boot / attestation** | **still nothing built** — the arena problem that made it a poor fit is fixed, so the objection is gone and the work has not started |

---

## What would make it real, in dependency order

1. ~~**Settle G7 with one experiment.**~~ — **DONE 2026-08-29, and it works.** A
   real ELF64 was loaded off ISO9660 and its header parsed at the prompt, five
   fields matching host ground truth, with no `seek`/`read` needed. File
   inspection is unlocked with existing words. What is left there is reading a
   byte *range* of a file too large to load whole — irrelevant for headers.
2. ~~**Write the type layer (G2) — now the top item, and with a sharper spec.**~~
   — **DONE 2026-08-29.** Both checkpoints met on both arches, and the G7 subject
   was used exactly as suggested: the definer pointed at `load-base` after
   loading an ELF re-derives the same fields, against host ground truth. The
   step cost less than this list assumed for a reason the list had wrong — the
   definer already shipped (§G2). What it cost instead was the *typing*: two
   accessors the firmware lacks, and seven injections to establish that the
   assertions bite.
3. **Bit-fields as a library (G4).** Skip unit-typed offsets, deliberately and in
   writing.
4. **Pick ONE application and drive it end to end** before generalising. On the
   evidence above the strongest candidates are the forensics angle (G6, already
   half-built) and FCode authoring (most OF-native, and it would make the
   "generalises what OF already does" argument true rather than rhetorical).
5. **Split `sstrip` out (G5)** into the image-build pipeline where it belongs.

---

## What this review did NOT prove

- ~~**No poke was run and no poke source was read.**~~ — **poke 5.0's source and
  manual were read** (§P), and one central claim did not survive. But **poke was
  still not built or run**: every §P finding is a reading of its source and
  documentation, not an observation of its behaviour. In particular the
  three-step scalar poke-back is quoted from the manual, not watched.
- ~~**The type layer was not prototyped.**~~ — **it was, and it works**; see
  §G2. ~~What is *still* unproven there: … a **live device's registers** … no
  **arrays** of a type …~~ — **both closed 2026-08-30**, and the device half
  produced a firmware patch (§G8). What remains, narrowed:
  - **A read with side effects is still unmeasured, and now measurably
    unreachable.** This firmware binds no port-I/O words on x86 or amd64 and no
    config-space accessors, so MMIO is the only device seam Forth can reach and
    its reads are idempotent. An UNKNOWN with a reason, not a gap.
  - **Nothing writes a structure the firmware then acts on** — the difference
    between parsing and authoring, and still the honest edge of this work.
- ~~**G7 was not attempted.**~~ — **attempted and settled**; see G7. What was
  *not* attempted is reading a byte range without loading the whole file, and
  `seek`/`read` remain unexercised because `load` made them unnecessary.
- **Nothing was measured about performance or size.** A type layer compiled into
  the dictionary costs image space in a firmware whose builtin dictionary is
  1 MiB, and no budget was taken.
- **The FCode-authoring suggestion is untested.** `byte-load ( addr xt -- )` was
  confirmed to be a plain Forth word at `forth/device/feval.fs:63`, so the
  execution half exists — but **no hand-built token was ever fed to it**, and
  whether it accepts a buffer that did not come from a PCI option ROM is
  unmeasured.

---

## Provenance

| item | value |
|---|---|
| Reviewed proposal | the 2026-08-29 message; poke/ELFkickers characterisation taken as given |
| Repo state | `fc02a0b`, firmware built and booted, 31/31 tests and 24/24 boot tracks green |
| Firmware corpus | `openbios/openbios` @ `e5ac46d`, pinned by `build-openbios.sh`, plus this repo's 48 patches |
| First pass | [`REVIEW-preboot-forth-binary-structures.md`](REVIEW-preboot-forth-binary-structures.md) — F2 closed 2026-08-29 |
| poke corpus | GNU poke **5.0** tarball from `ftp.gnu.org/gnu/poke/`, `sha256` `6873d59abe821c8111b88623…`, retrieved 2026-08-29 — read, **not built or run** |
| Type layer | [`examples/openbios-the-rival-that-shipped/dsl/struct.fth`](examples/openbios-the-rival-that-shipped/dsl/struct.fth), measured by `smoke-openbios.sh struct-layer`, `struct-array` and `struct-device` on amd64 **and** x86 |
| Written | 2026-08-29; §P and the G7 resolution added the same day; §G2 **built and corrected** the same day; §G2's arrays and §G8's device backend added 2026-08-30 |
