# REVIEW — "Preboot Forth as a Binary-Structure Toolkit"

*Review of [DESIGN-NOTES-preboot-forth-binary-structures.md](DESIGN-NOTES-preboot-forth-binary-structures.md),
written 2026-08-24. The notes propose using an OpenBIOS-based Open Firmware port as a
GNU-poke-like engine for building and inspecting binary structures, and conclude that
the IEEE 1275 property encode/decode wordset should be generalized outward rather than
a poke analogue written from scratch.*

> **VERDICT: the thesis is sound; the conclusion does not survive reading
> `forth/device/property.fs`.**
>
> "Take poke's model into the environment poke is locked out of" is a good framing, and
> the notes' central factual claim — that `encode-int` is cell-width-independent — is
> **confirmed by source**, closing §6's crux without a boot.
>
> But §5's operative move ("lift the wordset out and point it at flash regions, MMIO,
> and boot-handoff structures") hits an architectural wall: **the encode half is a
> serializer into a private bump-allocated arena, not a mapping layer**, and mapping is
> the one property poke's model is built on. The read half generalizes; the write half
> does not exist yet.
>
> Separately, §7's step 1 — the test the notes call "the crux, do this first" — is
> aimed at the half of the wordset that is correct by construction, and is
> **structurally incapable** of catching the width bug it is worried about.

---

## STATUS 2026-08-29 — the verdict above is largely INOPERATIVE

**A second pass, written against a tree that boots, is
[`REVIEW-preboot-forth-as-a-poke-engine.md`](REVIEW-preboot-forth-as-a-poke-engine.md).**
It grades the same idea after F2 was closed, and finds the remaining gap is a
*type* layer rather than more primitives.

**This review became the work plan for patches 25-34, and then for TODO 16.** Both
structural findings are closed, and so are F4, F5 and F6. The findings are left
as written — struck through and annotated in place rather than edited away,
because what was true on 2026-08-24 is the record of why the work was done.

| finding | 2026-08-24 | 2026-08-29 |
|---|---|---|
| **F1** two proven pieces are two firmwares | two codebases | **still two codebases — consequence void.** FCode now evaluates inside the 64-bit OpenBIOS build itself, so the cross-implementation confound is gone without the merge F1 asked for |
| **F2** `encode+` is `nip +`; the write half does not generalize | the finding that breaks §5 | **CLOSED** — patch 27 concatenates; patches 31/32 give the writers a destination and a cursor |
| **F3** the crux test tests the correct half | structurally blind | **CLOSED BY REPLACEMENT** — no cross-build byte diff exists; `property-abi` asserts the four 64-bit-only invariants this review proposed instead. One half is carried on purpose: see the note there |
| **F4** `encode-phys` is not fixed-width | ungraded hazard | **CLOSED, and asserted** in three contexts per arch |
| **F5** `decode-bytes` is broken, and dead | static reading | **CLOSED** — patch 25; and it is no longer dead, the probe exercises it and pins its depth |
| **F6** step ordering is backwards | three config flips blocking everything | **CLOSED** — all three flipped, each with its own checkpoint |
| **Revised next steps 1-4** | the replacement plan | **all four done**, including step 3's design fork |

**What is still open**, and it is the honest remainder:

- **§8's measured-boot / attestation row.** Nothing has been built. Its grade
  should improve now that the arena problem is fixed, but that is a prediction.
- **F3's decode-side asymmetry is unfixed BY CHOICE.** `l@-be` still
  zero-extends. It is carried as TODO §13.2(a), characterized rather than fixed,
  and the premise it is tolerated on is now **derived on every boot** — every
  four-byte decode counted, none with bit 31 set — instead of assumed.

---

## Method, and what this review did not do

Every finding below was reached by **reading the shipped source**, not by booting
anything. Two corpora:

| corpus | how it was obtained |
|---|---|
| `openbios/openbios` @ `e5ac46dd24e6216c36aa80462af25457e7029440` (2026-06-29) | fresh shallow clone of `master`, 2026-08-24 |
| this repo's Open Firmware labs | in tree |

~~**That commit is not pinned by anything.**~~ — **PINNED 2026-08-27.**
[`build-openbios.sh`](examples/openbios-the-rival-that-shipped/build-openbios.sh) now
checks `openbios` out at `e5ac46d` detached, so the line references below no longer
drift under a later clone. When this was written the script did a bare `git clone` of
`master` and patched whatever it landed on; `e5ac46d` is simply what `master` resolved
to on the review date, and it happens to be the same commit
[`X86-64-FEASIBILITY.md`](examples/openbios-the-rival-that-shipped/X86-64-FEASIBILITY.md)
recorded.

It also applied **one** patch. As of 2026-08-27 it applies
[`patches/TESTED-TREE.patch`](examples/openbios-the-rival-that-shipped/patches/TESTED-TREE.patch),
the whole divergence — the numbered patches are the record and are *not* a linear
series. That mattered here: before the change, a clean checkout built no `arch/amd64`
at all, so a reader following this review's amd64 line references would have been
reading about firmware their own tree could not produce.

~~**No firmware was built and no prompt was driven for this review.**~~ — true when
written; **every finding below has since been booted** (2026-08-25 onward). Where a
claim would need a boot to settle, it was labelled **UNKNOWN** rather than asserted —
the notes' own §6 discipline, kept — and each of those UNKNOWNs has now been
measured. See *What this review did NOT prove* at the end, which is annotated. Line references are `file:line` at the commit above.

---

## What holds up

**§5's load-bearing claim is true, and can be closed by reading.** `encode-int` really
does emit four big-endian bytes irrespective of cell width:

```forth
: encode-int ( n -- prop-addr prop-len )
  /l alloc-tree tuck l!-be /l ;                    \ forth/device/property.fs:216
```

`/l` is not a cell. It is `buildconstant("/l", sizeof(u32))` — `kernel/bootstrap.c:849`
— so it is 4 on every arch OpenBIOS builds, and `l!-be` (property.fs:16) is a
hand-rolled byte loop that writes `addr+3` down to `addr+0`. Nothing in that path can
observe the cell size.

So **§6's crux supposition is resolved: for `encode-int`, the implementation honors the
spec across the cell boundary, by construction.** It did not need the 64-bit build to
come up first.

Also confirmed, and needed by §7 step 3: `does>` exists in this Forth
(`forth/bootstrap/bootstrap.fs:1563`), so `CREATE`/`DOES>` structure-defining words are
available.

---

## F1 — The "two proven pieces" are two different firmwares

> **2026-08-29 — the premise still holds, the consequence does not.** No OFW
> `fcode` path was merged; they remain two codebases. But patches 17-18 brought
> PCI enumeration and FCode evaluation up on OpenBIOS `arch/amd64`, so
> FCode-at-a-64-bit-cell now exists **inside one firmware**. The
> cross-implementation confound this finding warns about is gone without the
> merge it asks for.

§5's *"Why this unifies your two proven pieces"* argues the 32-bit FCode path and the
64-bit device tree stop being separate milestones because encode/decode is load-bearing
in both. **In this repo they are not two halves of one system:**

| piece | firmware | evidence |
|---|---|---|
| the 64-bit device tree | **OpenBIOS** `arch/amd64` | Spike 1's `dev / ls` at the `0 >` prompt — [`examples/openbios-the-rival-that-shipped/X86-64-FEASIBILITY.md`](examples/openbios-the-rival-that-shipped/X86-64-FEASIBILITY.md) |
| FCode on a mock card | **OFW** (Bradley's Firmworks tree) | [`examples/open-firmware-debugs-itself/run-ofw-debug.sh`](examples/open-firmware-debugs-itself/run-ofw-debug.sh) boots `emuofw.rom`; `dsl/fcode-card.fth` is toke'd into a PCI option ROM |

Those are different codebases with different `property.fs` files. The same feasibility
document records that OFW's cell is nailed to four bytes at the root of its
metacompiler (`cpu/x86/kerncode.fth:723` — `/l constant /n`) and that **no 64-bit port
of any OFW target exists**. So a "round-trip across the cell boundary" spanning those
two pieces is a **cross-implementation** test wearing a cross-cell-width costume: if the
two sides disagree, you have learned nothing about width.

This is [CLAUDE.md](CLAUDE.md)'s *test that asserts the mechanism instead of the
outcome*, one level up — the test names two artifacts that happen to be the two things
that work, rather than the invariant it means to check.

**§4 is the place to fix this.** If the port described in the notes has actually merged
OFW's `ofw/fcode/` path into OpenBIOS, that is a large and interesting claim and the
whole of §5 rests on it — it should be stated outright, with what was taken and from
where. Nothing in this repo records that having happened, so from here it reads as two
labs being described as one port.

---

## F2 — `encode+` is `nip +`: the write half does not generalize

> **CLOSED 2026-08-29.** `encode+` now concatenates rather than assuming
> adjacency (patch 27) — and the control disproved this section's own account of
> the defect: `nip +` returned the *right* length over the *wrong* bytes, not a
> wrong length. The storage abstraction this finding said was missing was then
> built: `int!` / `string!` / `bytes!` take the destination as a parameter and
> the 1275 words are redefined on top of them (patch 31), with `int!+` /
> `string!+` / `bytes!+` composing successive fields at a caller-chosen address
> (patch 32). The assertion is `here` **unchanged**. Three of §8's rows that this
> finding blocked now have working tracks: `pmem-writer`, `flash-writer`,
> `mmio-writer`.

This is the finding that breaks §5's conclusion and most of §8.

```forth
: encode+ ( prop-addr1 prop-len1 prop-addr2 prop-len2 -- prop-addr3 prop-len3 )
  nip + ;                                          \ forth/device/property.fs:233

: alloc-tree ( n -- addr )
  dup >r  here swap allot  dup r> 0 fill ;         \ forth/device/property.fs:34
```

`encode+` **discards the second buffer's address and sums the two lengths.** It is
correct only because every `encode-*` bump-allocates at `HERE` via `alloc-tree`, so
consecutive fragments are necessarily adjacent. `reg` (property.fs:326-328) is built on
exactly that assumption:

```forth
  >r  ( phys.lo ... phys.hi ) encode-phys
  r>  ( addr1 len1 size )     encode-int
  encode+
```

Two consequences, and they are structural rather than incidental:

- **There is no "encode *into* this address" primitive anywhere in the wordset.** Every
  `encode-*` word chooses its own destination. You cannot aim `encode-int` at a flash
  region, an MMIO window, a CBFS entry or a boot-handoff page — it will write into the
  dictionary arena and hand you back a pointer, every time.
- **`encode+` is not composable with anything that touches `HERE`.** One `create`, one
  `,`, one helper that allocates between the two fragments, and the concatenation
  silently spans someone else's bytes. Nothing errors; the length is simply a lie.

So the poke analogy inverts precisely where it matters. poke's core operation is
*mapping a type over storage that already exists*; `encode-*` is *constructing fresh
bytes in an arena you do not choose*. The **decode** half is genuinely general —
`decode-int` and `decode-string` take an arbitrary `( prop-addr prop-len )` and read
through it, which is why [`examples/open-firmware-debugs-itself/dsl/ofscope.fth`](examples/open-firmware-debugs-itself/dsl/ofscope.fth)
can already walk `/memory` with it.

**The honest restatement of §5:** the read half is already a general structure parser
and can be pointed anywhere today. The write half is a device-tree property constructor,
and generalizing it means writing the storage abstraction it never had — an
`encode-at` / mapped-buffer primitive underneath the existing words. That is still a
good plan. It is just not "lift it out and point it elsewhere"; it is a new subsystem,
which is exactly what §5 claims it is not.

---

## F3 — The crux test tests the correct half, and cannot express the real bug

> **CLOSED BY REPLACEMENT 2026-08-29.** The cross-build byte diff was never
> written. `smoke-openbios.sh property-abi` asserts the four 64-bit-only
> invariants listed under *Revised next steps* instead — and every one of them
> has bitten at least once.
>
> **One half is carried on purpose.** The encode-side truncation was resolved
> toward *refuse*: `encode-int` of a value ≥ 2³² now throws by name (patch 26),
> LIED down to HALTED. The decode-side zero-extension is **deliberately not
> fixed** — sign-extending `l@-be` would corrupt every decoded address with bit
> 31 set — so it is asserted *as itself*, and the premise it is tolerated on is
> derived per boot rather than assumed.

§7 step 1 proposes byte-identical encode output on both builds, diffed against a golden
image, *before* anything else. Three problems, in increasing severity.

### It cannot fail in the direction §6 fears

§6 worries that a 64-bit path might "leak cell width into encoded output." `encode-int`
is `/l`-sized by construction (above), so the byte image is identical on both builds —
**and would stay identical even if everything above it were broken.** A green result
here means "the bytes are four bytes", which was never in doubt. This is
[CLAUDE.md](CLAUDE.md)'s own rule verbatim: *a scan that matches nothing and a scan that
is broken print the same green ✓.*

### The width asymmetry that does exist is on the decode side, where a byte diff is blind

```forth
: l@-be ( addr )
  0 swap 4 bounds do  i c@ swap 8 << or  loop ;    \ forth/device/property.fs:24
```

That accumulates four bytes into a **cell**, zero-extending. `decode-int`
(property.fs:135-140) is its only caller. So:

| build | `-1 encode-int decode-int` yields |
|---|---|
| 32-bit | `ffffffff` — i.e. `-1` |
| 64-bit | `00000000ffffffff` — i.e. `4294967295` |

**Identical bytes, different value.** A byte-image diff reports success. Any consumer
that compares a decoded int against a signed value or a pointer diverges — and
`forth/admin/devices.fs:434` does exactly that:
`decode-int nip nip ihandle>phandle active-package = if`.

### The encode-side bug is one the proposed test cannot even express

`l!-be` masks to four bytes with no overflow check, and OpenBIOS encodes **pointers** as
ints in the shared Forth:

| site | what is encoded |
|---|---|
| `forth/admin/iocontrol.fs:42` | `stdin @ encode-int " stdin" (property)` — an ihandle |
| `forth/admin/iocontrol.fs:76` | `stdout @ encode-int " stdout" (property)` — an ihandle |
| `forth/device/display.fs:362` | `display-ih encode-int " display" property` — an ihandle |
| `forth/system/ciface.fs:45,49` | the decode side: `decode-int nip nip to mmu-ih` / `to memory-ih` |

On a 64-bit firmware, an instance above 4 GiB is **silently truncated** into
`/chosen`'s `stdin`, and read back as a bogus ihandle. Today this is masked because the
firmware runs identity-mapped at 1 MiB — but the feasibility study sells *memory above
4 GB* as the port's headline gain, and P3 already placed `/nvram` at `0x100000000`.

A cross-build byte-identity test **structurally cannot find this**, because the input
that triggers it is unrepresentable on the 32-bit build. You cannot push a value ≥ 2³²
onto a 4-byte-cell stack to compare the two sides.

**What the test should be instead** is a set of assertions that only make sense on the
64-bit build, listed under *Revised next steps* below.

---

## F4 — `encode-phys` is not fixed-width

> **CLOSED 2026-08-29, and now asserted rather than merely known.**
> `property-abi` measures `encode-phys` in **three** contexts per arch: 8 bytes
> under `/` (no parent, the 1275 default of 2 cells), the root's own declaration
> under `/ide@1`, and `c` under a PCI child whose bus declares 3. A fixed-width
> `encode-phys` makes all three equal.

§5 and §7 step 1 both group `encode-phys` with `encode-int` as fixed-width. It is not:

```forth
: encode-phys ( phys.lo ... phys.hi -- prop-addr prop-len )
  encode-int my-#acells 1- 0 ?do  rot encode-int encode+  loop ;  \ property.fs:237
```

Its width is `my-#acells × 4`, and `my-#acells` (property.fs:148) reads the **parent
node's `#address-cells`** at call time, defaulting to **2** when there is no parent or
no property. The root sets it to 1 (`forth/device/tree.fs:15`).

So the same `encode-phys` call produces different byte counts at different points in the
device tree, **on the same build**. Its width is a function of tree context, not of cell
size. A byte-identity diff on `encode-phys` either false-alarms (different nodes) or
passes while proving nothing about width (same node) — and there is no way to tell which
happened from the diff alone.

---

## F5 — `decode-bytes` is broken, and dead

```forth
: decode-bytes  ( addr1 len1 #bytes -- addr len2 addr1 #bytes )
  tuck -  ( addr1 #bytes len2 )
  r> 2dup +  ( addr1 #bytes addr2 ) ( R: len2 )
  r> 2swap
  ;                                                \ forth/device/property.fs:195
```

> **CLOSED 2026-08-29, and the UNKNOWN below was watched.** The first `r>` is a
> transposed `>r` — one character (patch 25). The static reading was *nearly*
> right and wrong about the outcome: it did not pop the caller's return address
> and crash, it **returned cleanly with six items where four are documented**,
> which is worse. It is also no longer dead: `property-abi` round-trips
> `encode-bytes`/`decode-bytes` on both arches and asserts the **depth**, from an
> empty stack back to an empty one.

Two bare `r>` with no matching `>r`. The stack comment even annotates a return-stack
item that nothing put there. As written this pops the caller's return address.

It is also **dead**: `grep -rn 'decode-bytes'` over the whole tree returns that
definition and nothing else, and it is absent from the FCode table — which carries
`decode-phys` (`forth/device/table.fs:282`), `decode-int` (`:368`) and `decode-string`
(`:369`), and no `decode-bytes` at all.

Consequence for §7 step 1: **the `encode-bytes` round-trip it asks for does not exist
today.** You would be authoring the inverse, not testing it. (Marked
**UNKNOWN-by-execution**: this is a reading of the source, not a crash observed at a
prompt. It should be trivially confirmable at the `ok` prompt once one is reachable.)

---

## F6 — The step ordering is backwards, for a delivery reason

> **CLOSED 2026-08-29.** All three flips landed, each with its own observable
> checkpoint: `CONFIG_FSYS_ISO9660` and `CONFIG_LOADER_FORTH` (patches 12-13, with
> patch 14 making `(init-program)` reachable at all), `CONFIG_DRIVER_VGA`
> (patches 17-18). Verified in the tree: all three read `true` on amd64. The
> serial-console workaround this section dreads was never needed — the probes are
> multi-line Forth **loaded off media**.

§7 puts the round-trip test *first* and FCode *second*. But on the amd64 build there is
currently no way to get test Forth into the firmware. Diffing the two upstream configs
(whitespace-normalized):

```console
$ diff config/examples/x86_config.xml config/examples/amd64_config.xml
CONFIG_LOADER_FORTH   x86 true   →  amd64 false
CONFIG_FSYS_ISO9660   x86 true   →  amd64 false
CONFIG_FSYS_UFS       x86 true   →  amd64 false
CONFIG_DRIVER_VGA     x86 true   →  amd64 false
CONFIG_HFSP           x86 false  →  amd64 true
CONFIG_DEBUG_FS       x86 false  →  amd64 true
```

- **No Forth loader and no ISO9660** means step 1's test has to be typed at the serial
  prompt — into a console this repo has documented as lossy and, per
  [TODO.md](TODO.md) §12, silently truncating past ~80 characters. The ISO9660 row is
  already TODO §12's blocker 1.
- **`CONFIG_DRIVER_VGA=false` is the sharper one for step 2.** `drivers/pci.c:1045` —
  `feval("['] vga-driver-fcode 2 cells + 1 byte-load")` — is the only in-tree FCode
  execution on the x86 side, and it is compiled out of amd64. So *"bring FCode
  evaluation up on the 64-bit side"* starts as a **config flip**, the same shape as
  blocker 1, not as a port.

The caveat that makes step 2 worth doing anyway: once that flag is on, it will be the
first FCode ever evaluated at a 64-bit cell in this tree, which is where §6's *second*
supposition genuinely earns its keep.

---

## Revised next steps

> **ALL FOUR DONE, 2026-08-29.** Marked per step below.

Replacing §7, in dependency order:

1. ~~**Flip `CONFIG_DRIVER_VGA`, `CONFIG_FSYS_ISO9660` and `CONFIG_LOADER_FORTH` on
   amd64.**~~ — **DONE** (patches 12-14, 17-18); all three read `true` on amd64. Cheap, independently testable, and it gives every step below a delivery
   path. Each flip needs its own observable checkpoint — for ISO9660 that is TODO §12's
   `dir /ide@1/cdrom@0:\` listing `vmlinuz`; for `LOADER_FORTH` it is a `.fth` file
   loaded off media instead of typed; for VGA it is `byte-load` reached at all.
2. ~~**Write the 64-bit-only assertions, not the cross-build byte diff.**~~ —
   **DONE**, and each of the four bullets below is now a live assertion in
   `smoke-openbios.sh property-abi`: `encode-int` **refuses** (patch 26);
   `decode-int`'s zero-extension is pinned as deliberate with its premise derived
   per boot; `encode-phys`'s length is measured in three contexts; and `/chosen`'s
   `stdin` round-trips, with a *different* ihandle checked to be distinguishable so
   that "they matched" means something. The invariants
   worth money, none of which a golden-image diff can state:
   - `encode-int` of a value ≥ 2³² — must refuse, or be documented lossy and every call
     site audited.
   - `decode-int` of an encoded `-1` — pin the zero-extension as deliberate, or fix it.
   - `encode-phys` under `#address-cells` of 1 *and* 2 — assert the length changes, so
     nobody re-reads it as fixed-width later.
   - the pointer sites in F3's table — assert `/chosen`'s `stdin` survives a round trip
     at whatever address instances actually land on in long mode.

   This is the same bug class the feasibility study's census already caught four times
   (`multiboot.h`'s `unsigned long` wire structs, `dict_end - dict_start` pointer
   subtraction) — one layer up, in Forth.
3. ~~**Decide the storage question before writing any convenience layer**~~ —
   **DECIDED AND BUILT** (TODO 16, patches 31-32): the fork went to an
   `encode-at`-style primitive **underneath** the 1275 words, not a parallel
   vocabulary. `encode-int` and `encode-string` are now defined in terms of `int!`
   and `string!`. Original reasoning kept: because it is a
   design fork rather than sugar: does the poke analogue get an `encode-at ( n addr -- )`
   / mapped-buffer primitive *underneath* the 1275 words, or a parallel vocabulary
   beside them? §8's entire application list depends on the answer, and §7 step 3
   currently assumes it away.
4. ~~**Fix or delete `decode-bytes`**~~ — **FIXED** (patch 25), not deleted, and
   the round-trip claim now exists and asserts the stack depth.

Each of these is stated as an outcome rather than a mechanism, per
[CLAUDE.md](CLAUDE.md) — "the length changes when `#address-cells` changes", not "the
loop ran twice".

---

## Grading §8's candidate applications

| application | grade |
|---|---|
| **Device-tree construction/patching** | **works today as described** — it is the wordset's home ground, and the only entry that needs nothing from F2 |
| **Exploratory RE of undocumented blobs** | **strong, and available now** — it needs only the decode half, which is already general. `ofscope.fth` is a working precedent |
| **Boot-handoff structures** | ~~**blocked on F2**~~ → **UNBLOCKED, demonstrated** — `smoke-openbios.sh pmem-writer` writes three 1275-encoded ints with `int!+` at `0x100400000`, above 4 GiB, and reads them back |
| **Firmware image assembly (CBFS, flash layout)** | ~~**blocked on F2**, harder — the destination is not even RAM~~ → **PARTLY, and the scope was corrected by measurement**: `flash-writer` shows the writer can be *aimed* at a CFI part at `0xffbe0000`, and that a CFI part is **not** a store-to seam — a write is unlock/erase/program/poll, not a store. `mmio-writer` does store, at both of its addresses |
| **Measured-boot / attestation** | ~~**worst fit for the arena problem**~~ — **the arena problem is fixed, and nothing has been built.** Still the open row: no TPM or event-log work exists in this lab. The grade should improve; that is a prediction, not a result |

One thing the notes undersell: the poke-like **reader** is much closer to done than §4
implies. [`examples/open-firmware-debugs-itself/`](examples/open-firmware-debugs-itself/README.md)
already ships `see`, `detokenize`, `.calls` and a `decode-int`-driven memory walker. It
is the **writer** that is the new subsystem.

---

## What this review did NOT prove

Stated explicitly, because the notes' §6 sets that standard and it would be poor form to
drop it here. **Annotated 2026-08-29: every one of these has since been settled, which
is the part of this document that had the shortest shelf life.**

- ~~**Nothing was booted.**~~ — **all of it has been, from 2026-08-25 on.** F5 in
  particular has been watched, and the static reading was *wrong about the outcome*:
  `decode-bytes` did not pop the caller's return address and crash, it returned
  **cleanly** with six items where four are documented. A clean return is worse than
  the crash this section predicted, and only a boot could say so.
- ~~**The port described in §4 was not inspected.**~~ — **moot.** `property.fs` in
  this repo's tree now carries **five** local patches (25, 26, 27, 31, 32 — counted,
  not recalled), so F2-F5 *were* re-checked against that file — by changing it. F2's
  `nip +` adjacency contract was indeed deliberately rewritten, which is what closed it.
- ~~**Whether an amd64 instance can land above 4 GiB was not measured.**~~ —
  **MEASURED, on every boot.** `property-abi` prints the top 32 bits of `/chosen`'s
  live `stdin` and asserts they are zero: instances land **below** 4 GiB today, and
  the day that changes the track fails by name and says what it means. And the
  truncation is no longer unchecked — `encode-int` refuses (patch 26), so the hazard
  is now an honest abort rather than a silent wrong answer.
- ~~**The config flips in F6 were not applied or built.**~~ — **applied, built and
  booted**; all three read `true` on amd64 in the tree today.
- ~~**No claim is made about `encode-string`.**~~ — it inherited F2 and it inherited
  the fix: `string!` takes a destination and `encode-string` is defined in terms of it,
  with `property-abi` asserting `here` unchanged, the terminator written, and the bytes
  copied. Still no width dimension.

---

## Provenance

| item | value |
|---|---|
| Reviewed document | [DESIGN-NOTES-preboot-forth-binary-structures.md](DESIGN-NOTES-preboot-forth-binary-structures.md) |
| Its `sha256` (as received, body without this repo's editorial footer) | `754b4ee682d581664d4c3b025179408803e81838e0d34ae125a55e52a09b3b6c` |
| Source corpus | `github.com/openbios/openbios` @ `e5ac46dd24e6216c36aa80462af25457e7029440` (2026-06-29) — ~~`master` as of the retrieval date, **not a pinned commit**~~ **pinned by `build-openbios.sh` since 2026-08-27** |
| Status | **findings F2-F6 closed 2026-08-29**; see *STATUS* at the top |
| Retrieved | 2026-08-24 |
| Sibling measurements relied on | [X86-64-FEASIBILITY.md](examples/openbios-the-rival-that-shipped/X86-64-FEASIBILITY.md), [TODO.md](TODO.md) §12 |
