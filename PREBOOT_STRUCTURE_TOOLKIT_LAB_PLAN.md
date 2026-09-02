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
| the writer side is available | TODO §20 | ✅ `write-file` on `main` — **hosted `unix` only** (patch 54); "author" means something different per arch — see Spike 0 |
| the event log is verifiable without hardware | the extend is a pure function | ✅ replay `H(PCR‖digest)`; `tpm2_eventlog` is the external oracle. **SHA-256 is the crux dependency — see Spike 1 risk.** |
| the oracle's verbs actually work ([review F2](REVIEW-preboot-structure-toolkit-plan.md#f2--10-rests-on-cbfstool-extract-which-this-repo-has-already-measured-failing)) | run `cbfstool print`/`extract` on the lab's own ROM | ✅ re-measured 2026-09-01: `print` works; `extract` works on `raw` entries (LZMA decompressed too) **and on the payload with `-m x86`** — the 2026-08-27 "cannot extract a payload at all" in `tools/openbios-rom-provenance.sh` was a run missing the `-m ARCH` flag the error itself names (now corrected there). The extracted payload is a **reconstituted** ELF (segments only — different size and sha256 than the input), so §10's surgery round-trip byte-compares are scoped to `raw` entries; the payload is graded by `print` metadata + reconstituted-extract parseability. |
| the four-arch matrix has a door on every arch ([review F3](REVIEW-preboot-structure-toolkit-plan.md#f3--the-four-arch-matrix-does-not-exist-yet-and-two-of-its-rows-have-no-door)) | boot each arch, deliver `struct.fth`, run the G2 controls | ✅ **measured 2026-09-01 — Spike −1 below.** Both "missing" doors existed in the shipped builds; no reflow, no dictionary bake, no new C. |
| Spike 3 has a reachable subject ([review F5](REVIEW-preboot-structure-toolkit-plan.md#f5--spike-3s-subject-is-the-one-feasibility-claim-3-did-not-check-and-the-reachable-one-is-121)) | the poke-engine review's did-not-prove list + the `flash-writer` track | ⚠️ the PCI option-ROM read is **blocked** (no config-space/port-I/O words bound) and stays a named UNCOVERED row; the reachable subject is §12(1)'s live ROM window (`flash-writer` already reads CFI at `0xffbe0000` through `>virt`) — Spike 3 is re-aimed there. |

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

**Every track in this lab MUST run on all four and assert the round-trip holds
across the matrix.** That is the negative control a single-machine tool can never
run — and it is precisely why a firmware-hosted toolkit can be *more* trustworthy
about byte order than poke, not less.

**Status ([review F3](REVIEW-preboot-structure-toolkit-plan.md#f3--the-four-arch-matrix-does-not-exist-yet-and-two-of-its-rows-have-no-door)
→ Spike −1):** when this plan was written the matrix was a two-arch artifact —
no `dsl/*.fth` had ever been loaded on `ppc` or `unix`. **Spike −1 (below) closed
that on 2026-09-01**: the existing `struct-layer` controls ran green on all four
arches, so the matrix exists as a measured fact; what remains is enforcing it
per-track as the toolkit's tracks are built (§8).

One measured caveat the `ppc` row earned, **now fixed (2026-09-02)**:
`struct.fth`'s `load-base-phys` selected its constant **by cell width**
(`/n 8 =`), so on ppc (`/n`=4) it silently picked x86's `400000` — `>virt`/`>phys`
were wrong-by-construction there. The fix distinguishes the one *relocating* arch
(x86, 32-bit LE, `virt_offset` reassigned in `arch/x86/segment.c`) from ppc
(32-bit BE, `virt_offset = 0`, source-confirmed) by native CPU byte order, so ppc
now gets its identity `4000000`; x86/amd64/unix are unchanged. The `tlv-primitives`
track asserts `load-base-phys` per arch on every run. It is a clean example of the
narrow-cell and big-endian rows being **different controls**
(review F3's closing point).

---

## 5. The spikes

> **EXECUTION ORDER (re-sequenced by the
> [review](REVIEW-preboot-structure-toolkit-plan.md#5-recommended-order-in-dependency-order),
> numbering kept):** Spike −1 (✅ done) → Spike 0 → **Spike 2 before Spike 1** —
> CBFS has four subjects already on disk (review F1) while the event log's
> subject comes from a swtpm guest, not from anything this lab boots (review F4)
> — with Spike 3 re-aimed at §12(1)'s live ROM window and running as Spike 2's
> `x86`/`amd64` live form (review F5).

### Spike −1 — delivery (added by [review F3](REVIEW-preboot-structure-toolkit-plan.md#f3--the-four-arch-matrix-does-not-exist-yet-and-two-of-its-rows-have-no-door)) — RESULT: **GREEN**, 2026-09-01

*The gate before the gate: get the existing type layer onto `ppc` and `unix` and
prove the `struct-layer` controls there, before adding primitives to it.*

**Result: both "missing" doors already existed in the shipped builds — no line
reflow, no dictionary bake, no new firmware C.** The review's three options were
all unnecessary; what was needed was the right invocation, found by measuring on
the host the review's container did not have:

- **`ppc` — the ISO door works.** The habitats lab's *"Media ❌ no filesystem
  compiled"* was a measurement of a **different build**: this lab's `obj-ppc` has
  `ISO9660`/`EXT2`/`HFS(+)`/`GRUBFS` compiled **and registered** (`/packages`
  lists `iso9660-files` et al.), and the raw ATAPI read chain works (`seek`+`read`
  through the `cd` ihandle returns the `CD001` descriptor). The lock was two
  path-syntax defects in the **native** iso9660 driver, both read out of
  `fs/iso9660/`: `iso9660_get_node` skips leading `\` but **not** the classic
  partition-separator comma (so the documented `cd:,\path` form fails), and
  `iso9660_name` never strips the ISO9660 `;1` version suffix (so a plain name
  fails; `strcasecmp` makes case free). The working form, on a **plain** ISO
  (no Rock Ridge/Joliet needed):
  `load cd:\STRUCT.FTH;1` → `load-base load-size evaluate`.
  **Always gate on `load-size`**: a failed `load` prints ` ok` with
  `load-size`=0 — a false success, the LIED rung, watched here.
- **`unix` — the `-f` door works.** `openbios-unix -f door.iso <dict>` creates
  `/unix/block/disk` (alias `hd`); its **grubfs** (built here with
  ext2fs/reiserfs/iso9660 backends) mounts the same ISO. Two divergences from
  ppc, both measured: grubfs **strips** the `;1` itself (`load hd:\STRUCT.FTH`,
  no suffix — the exact inverse of the native driver), and the hosted process has
  **no memory mapped at `load-base`** (0x4000000), so `load` segfaults until it
  is re-pointed into the arena:
  `20000 alloc-mem value mybuf  mybuf (u.) s" load-base" $setenv`
  (`load-base` is an nvram int-config; `$setenv` is the lever). A positional
  *source file* argument is **not** a door — `main()`'s else-branch prints
  `not supported.`; the 80-column limit constrains the **line editor only**, and
  the 177-byte comment lines of `struct.fth` evaluate fine once delivered by
  `load` on both new arches.

**Exit criterion, met:** the `struct-layer` track's own `G2CHK.FTH` (extracted
verbatim from `smoke-openbios.sh`, plus `struct.fth`+`elf.fth` and the same
`SUBJ.ELF`) ran on all four arches; markers diffed mechanically against the
existing track's fresh reference logs:

| comparison | markers | result |
|---|---|---|
| `ppc` vs `x86` (32-bit rows) | 34/34 | **identical** (buffer address excluded) — incl. `T-ERR-narrow-cell` firing on the 8-byte read, `T-ERR-width=3`, `T-ERR-be64` |
| `unix` vs `amd64` (64-bit rows) | 34/34 | **identical** — incl. the 8-byte LE read *answering* (`g2x-entry=101d70`) |

Byte order proved to be a property of the **declaration, not the CPU** exactly as
designed (`field:`/`le-field:` build every access from `rb@`/`c@` bytewise), so
the BE machine and the LE machines print the same 34 values — which is the
matrix's baseline. What `ppc` uniquely catches from here is a **host-native
access that slips in** (a bare `l@`/`@`), which is Spike 0's negative control
([review F9](REVIEW-preboot-structure-toolkit-plan.md#f9--the-ppc-control-catches-a-different-bug-than-5-says-it-does)).

**Two hosted-target gotchas recorded for the tracks:** (1) on `unix`,
`evaluate` after a failed load (or any `load` before the `$setenv` remap)
segfaults the process at the unmapped default `load-base` — the track must remap
first and gate on `load-size`; (2) the ppc console needs `drive-pty-repl.py
--echo-gate` and prompt-expects (`0 > `), never end-marker expects after a
refusal — the `T-ERR` abort cuts the word short of its end marker by design.

**Routing of this result:** the four-arch run is formalized as `struct-layer`
track arms + CI wiring (§8), so the measurement cannot rot as a one-off.

---

### Spike 0 — the two `struct.fth` primitives, and the model decision (THE GATE) — DECISION: **(B)**; PRIMITIVES **GREEN on 4/4**, 2026-09-01

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

**DECISION — (B), decided by building it (2026-09-01).** The measured reason (A) is
rejected: `t@ ( adr tid -- u )` is **already offset-agnostic** — it reads
width/order/space from the tid and takes the address from the caller (the offset
is added by the *field word's* `does>`, never by `t@`). So a length-prefixed walk
needs **no change to `field:` at all**, only (i) a running cursor to feed `t@`,
and (ii) a **bare** tid to describe each element. Baking a cursor into the field
word would contaminate the static-offset path that ELF/CBFS *headers* rely on, for
zero gain. So (B) is a parallel cursor vocabulary — `>rec`/`rec@`/`+rec`/`alignto`
+ `t@+`/`vfield:` + a bare-tid `type:` definer — that **reuses `t@`/`t!`
unchanged** and leaves `field:`/`array:`/`(tfield)` untouched. This also answers
review E3: `vfield:` **is** the cursor-mode `file:` (a member whose extent is read
from an earlier member), built, not beside a second thing.

**Landed (2026-09-02).** The primitives ship as a new **cursor section of
`dsl/struct.fth`** (`type:`/`>rec`/`rec@`/`+rec`/`rec-off`/`alignto`/`t@+`/`t!+`/
`vfield:`) — `field:`/`array:`/`(tfield)` untouched, still option (B) — behind a
`tlv-primitives` smoke track that runs the walk on all four arches, wrapped
(`tests/test-smoke-tlv-primitives.sh`), listed in `run-all.sh`, and in the
tier-b CI `DEFAULT_TRACKS` (which now also builds the `unix` target so the
workbench arm runs in CI, per review F10). The track asserts the four-arch
agreement and both controls below on every run.

**Measured result — the synthetic record `{ len:u32le, name[len], pad-to-4,
body:u16le }` authored in-arena and walked back through `vfield:`/`alignto`, all
four arches:**

| marker | unix | amd64 | x86 | ppc |
|---|---|---|---|---|
| namelen / name | 3 / ELF | 3 / ELF | 3 / ELF | 3 / ELF |
| after-name off → align-4 off | 7 → 8 | 7 → 8 | 7 → 8 | 7 → 8 |
| body (u16le) | beef | beef | beef | beef |
| end off / poison-past-end | a / ff | a / ff | a / ff | a / ff |
| **neg: correct read** (`u32le t@`) | 3 | 3 | 3 | 3 |
| **neg: host-native `l@`** | 3 | 3 | 3 | **3000000** |

Eight positive markers identical across all four; the length recovered correctly
on the big-endian machine; and the negative control **diverged on `ppc` alone**,
exactly as [review F9](REVIEW-preboot-structure-toolkit-plan.md#f9--the-ppc-control-catches-a-different-bug-than-5-says-it-does)
predicted — a bare `l@` that slipped a host-native access into a byte-order-
explicit parser is invisible on the three LE arches and caught only by the BE row.

**Still open before this spike is *complete* (vs. its primitives landed and under
CI):** the real `Elf_Note` positive case + `readelf -n` oracle (subject below);
and the per-arch `write-file`/`pmem`/in-arena author paths (the track authors the
synthetic record in-arena on every arch today). The `load-base-phys` cell-width
bug §4 flagged is **fixed** and asserted per-arch by the track.

**The subject ([review F7](REVIEW-preboot-structure-toolkit-plan.md#f7--spike-0s-synthetic-record-is-weaker-than-the-real-subject-already-on-disk)):
the positive case is a REAL record, `Elf_Note`** — `namesz, descsz, type,
name[namesz], pad-to-4, desc[descsz], pad-to-4` — present in any host-built ELF
the `struct-*` tracks already load (`.note.gnu.build-id`), with `readelf -n` as
the foreign oracle and a build-id `desc` that is a **content hash of the image**
(the *bind-the-fact-to-its-identity* rule handed over for free). The synthetic
record `{ len:u32, name[len], pad-to-4, body:u16 }` stays as the **authored**
half and the negative-control fixture. Decide in the same spike whether
`vfield:` *is* the cursor-mode `file:` definer the poke-engine review's E3
sketched, or sits beside it — that is option (A) vs (B) restated, and naming it
avoids building it twice.

**Exit criterion (all four arches, green):** parse the real `Elf_Note` and match
`readelf -n`; author the synthetic record in **both** byte orders and read it
back through the new primitives, recovering `name` and `body` byte-identically
on `unix`, `amd64`, `x86`, and `ppc`. Per arch, "author" means
([review F3](REVIEW-preboot-structure-toolkit-plan.md#f3--the-four-arch-matrix-does-not-exist-yet-and-two-of-its-rows-have-no-door)):
on `unix`, `write-file` then a host oracle reads it; on `amd64`, the `pmem`
seam then `od`; on `x86` and `ppc`, in-arena with the raw bytes printed for the
host to compare.

**Negative control — corrected by
[review F9](REVIEW-preboot-structure-toolkit-plan.md#f9--the-ppc-control-catches-a-different-bug-than-5-says-it-does),
and Spike −1 measured why:** a mislabelled `le-field:` reads the same wrong
number on **all four** arches (byte order lives in the declaration; every
accessor is built bytewise from `rb@`/`c@`) — that mislabel is caught by the
**oracle** row, not the ppc row. What `ppc` alone catches is a **host-native
access that slips in**: replace the length read with a bare `l@` and watch
`ppc` alone diverge, by name. Both controls run; each is labelled with what it
proves.

**Nothing in Spikes 1–3 starts until this is green.** Both CBFS and the event log
are length-prefixed; a width/endian leak here is inherited by everything above.

---

### Spike 1 — the TCG measured-boot event log (the attestation payoff)

**The subject
([review F4](REVIEW-preboot-structure-toolkit-plan.md#f4--spike-1-has-no-subject-and-no-rom-in-this-repo-can-produce-one)):
no ROM this repo builds can produce an event log** — no coreboot config here
sets `CONFIG_VBOOT`/`CONFIG_TPM*`, and OpenBIOS has no TPM driver, so *"coreboot
is where measured boot happens"* is true of coreboot and false of every ROM on
this host. The real subject comes from what the repo already has: **phase 2's
swtpm sidecar (`tpm = true`)** under an OVMF guest exposes
`/sys/kernel/security/tpm0/binary_bios_measurements` — a genuine
`TCG_PCR_EVENT2` log written by edk2 — with `tpm2_eventlog` (packaged) and the
NixOS measured-boot lab's `systemd-analyze pcrs` as **two** independent oracles,
and the guest's own `pcr-sha256/` files as the claimed PCRs for 1b's replay. The
AK caveat below is already written down three times in
[`examples/metal-as-a-service/DEFERRED.md`](examples/metal-as-a-service/DEFERRED.md)
and its drivers — linked, not paraphrased.

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

**Oracle — derive it, don't vendor it
([review F2](REVIEW-preboot-structure-toolkit-plan.md#f2--10-rests-on-cbfstool-extract-which-this-repo-has-already-measured-failing)):**
every coreboot objdir **already builds its own `cbfstool`**
(`build-coreboot.sh` uses `./build/cbfstool … print` as its own checkpoint), so
the track uses **`$OBJDIR/cbfstool` from the tree that built `$OBJDIR/coreboot.rom`**
— §10's "pin to the same commit" satisfied by construction. A separately
vendored copy, the way `elfls` was, is exactly the drift §10 warns against.

**Subjects — all FOUR ROMs on the host, not one
([review F1](REVIEW-preboot-structure-toolkit-plan.md#f1--the-cell-that-is-not-present-is-present-and-it-is-the-lab-the-plan-cites-as-the-counter-example)):**
`build/coreboot.rom` (16 MiB q35, **LinuxBoot kernel+u-root** payload),
`build-ofw/coreboot.rom` (the OFW lab's Firmworks payload),
`build-openbios/coreboot.rom` and `build-openbios-amd64/coreboot.rom` (OpenBIOS
as a SELF payload) — three payload kinds,
already enumerated by `build-coreboot-openbios.sh`'s sha guard. §12's thesis —
*the payload is the variable, the toolkit is the constant* — has its subject set
on disk today, so the walk must list all four **and tell them apart by what it
finds under `fallback/payload`**.

**Exit criterion:** the Forth walk of each ROM lists the same files
`cbfstool print` does (name, type, size), a payload's bytes match its declared
metadata, an authored entry round-trips through `cbfstool`, and the walk is
correct on all four arches — the `ppc` row proving the big-endian reads are real.
(`ppc` and `unix` read a ROM as a file — the ISO/`-f` doors from Spike −1;
`x86`/`amd64` additionally get the **live** flash-window form, which is Spike 3.)

---

### Spike 3 — point it at REAL device memory (the uniquely-licensed edge)

**Deliverable — re-aimed by
[review F5](REVIEW-preboot-structure-toolkit-plan.md#f5--spike-3s-subject-is-the-one-feasibility-claim-3-did-not-check-and-the-reachable-one-is-121):
§12(1), the firmware walking the CBFS of the very ROM that delivered it.**
Booted with `-bios coreboot.rom`, the ROM is memory-mapped at the top of 4 GiB
and the `flash-writer` track already reads a CFI window at `0xffbe0000` through
`>virt` (with an erased-part control proving it is the chip, not RAM). Spike 3 =
the Spike 2 reader pointed at that live window on `x86`/`amd64`, verified by an
observer outside the firmware — the ROM **file** on the host, `cmp`'d
byte-for-byte, plus QEMU's monitor `xp` as a second witness. This is the one
thing a hosted tool structurally cannot do: no `cbfstool` can be *inside the ROM
it booted from*, before any OS exists.

The original subject — a **PCI option-ROM / expansion-ROM header** — is a
**named UNCOVERED row**, with its two measured blockers stated: this firmware
binds no config-space or port-I/O words (the poke-engine review's did-not-prove
list), and the only FCode option-ROM subject in the repo
(`open-firmware-debugs-itself/build-fcode-rom.sh`) is attached to **OFW**, not
OpenBIOS. Uncovered, not dropped (the chaos-matrix rule).

**The diff half:** `region-snap`/`region-diff` are **fifteen OFW lines that have
not been ported** —
[review F6](REVIEW-preboot-structure-toolkit-plan.md#f6--region-snapregion-diff-are-not-existing-in-this-lab-they-are-ofw-words-that-have-not-been-ported):
they get **copied** into this lab's `dsl/` (self-containment rule), through the
habitats lab's `PORTING.md` checklist, with `>virt` on the snapshot address on
`x86` (the `flash-writer` trap). The natural transition to diff is the
firmware's own `LB_TAG` table walk (`linuxbios_info.c`, patched by this lab's
patches 01 and 39): snapshot the table region, re-run the walk, diff — a change
the firmware itself caused, from a code path already in-tree.

**Exit criterion (scoped, honest):** the live CBFS walk on `x86`/`amd64` from
the mapped ROM window matches both the host-side file walk and `cbfstool print`;
a `region-snap`/`region-diff` shows a firmware-caused change; the option-ROM row
prints as UNCOVERED with its blockers named.

---

## 6. What this is NOT (scope guards)

- **Not a linker.** No symbol tables, no relocations, no dynamic section, no
  per-arch reloc registries. The poke-elf note already assayed those as barren for
  a firmware that never relocates.
- **Not a fake TPM.** The hardware quote is UNKNOWN and stays UNKNOWN.
- **Not a generic image dissector.** Two firmware-native TLV formats, chosen
  because they share Spike 0 and split the endianness axis. New formats are added
  only when they pay the same way.
- **FDT is deferred, and here is why it is not lost
  ([review F7](REVIEW-preboot-structure-toolkit-plan.md#f7--spike-0s-synthetic-record-is-weaker-than-the-real-subject-already-on-disk)):**
  the gleanings note says Spike 0's two primitives are also exactly what the
  device tree's structure block needs (length-prefixed, NUL-padded,
  4-byte-aligned), and a `dt>fdt` flatten is the boot-handoff structure
  `DESIGN-NOTES` §8 lists first — OpenBIOS's device tree being the one subject
  every arch has natively. Deferred because it adds a third format before the
  first two have paid; it is the named first candidate once they have.
- **Not a dictionary budget nobody measured.** Spike −1's doors made the
  bake-into-the-dictionary option unnecessary, so the budget stays unmeasured —
  and no claim is made about it. If a future spike wants the dsl compiled in,
  measuring that budget is its first task.
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
already enforce this. `cbfstool` is **derived from the ROM's own objdir**, not
vendored (§10); `tpm2_eventlog` is packaged (`tpm2-tools`); anything that *does*
need vendoring follows the `oracle/elfkickers/` provenance pattern. No new
`examples/` lab unit is created, so learning-paths routing is unaffected; the
plan and the gleanings note are the inbound references.

**Firmware patches: expected, not excluded
([review F8](REVIEW-preboot-structure-toolkit-plan.md#f8--no-new-firmware-patch-is-contradicted-by-the-plans-own-mitigations)).**
The first draft claimed *"no new firmware patch"* while naming a hosted-only
bound C word (Spike 1b) and `read-file` as mitigations — both are patches to
`arch/unix/unix.c`, which is **outside** `arch/{x86,amd64}/`, so
`check-patch-scope.sh` requires an `Arch-tested: x86 amd64 ppc unix` header —
i.e. the ppc build gets run even for a unix-only change. That is the rule
working as intended; plan for it. (Spike −1 itself needed no patch.) On SHA-256:
a Forth implementation is ~150 lines of 32-bit arithmetic — the one place a
32-bit cell is *not* a hazard, and the 64-bit cells must mask their rotates —
which makes it a clean matrix control in its own right (NIST vectors as the
oracle, `sha256sum` as the second). If the point of the lab is the matrix, the
hash should live in it; the hosted C word is the bring-up aid, not the
deliverable.

**CI wiring
([review F10](REVIEW-preboot-structure-toolkit-plan.md#f10--ci-will-not-run-any-of-it-unless-the-plan-says-where)):**
a new track that is not in `openbios-tier-b.yml`'s `DEFAULT_TRACKS` (and
`tools/openbios-tier-b-relevant.sh`'s filter) is a test CI never runs — the
wrapper/list guards check that a track *has* a wrapper, not that CI *boots* it.
Every new track joins both. The tier-b build loop gains the `unix` target (and
the artifact gate gains `openbios-unix` + its dict), so the workbench and
`file-writer`/`unix` tracks stop being CI-invisible.

Docs, `link_check.py`, and the patch record stay green at every step.

---

## 9. Success signature (per spike, observable)

- **Spike −1 (✅ met 2026-09-01):** the shipped `struct-layer` controls run green
  on all four arches — `ppc≡x86` and `unix≡amd64`, 34/34 markers, every `T-ERR`
  refusal by name; the delivery door for each arch is recorded.
- **Spike 0:** the real `Elf_Note` parses and matches `readelf -n`; the synthetic
  length-prefixed record round-trips byte-identically on `unix`, `amd64`, `x86`,
  `ppc`; the `ppc` row catches a **host-native access** (a bare `l@`) by name, and
  the oracle row catches a mislabelled byte order.
- **Spike 1:** `tpm2_eventlog` parses a swtpm guest's `binary_bios_measurements`
  the firmware re-authored; a PCR replay matches the guest's own claimed value and
  diverges when one digest byte is flipped; the quote-is-UNKNOWN line prints on
  every run.
- **Spike 2:** the Forth walk of each of the four `coreboot.rom`s lists the same
  files as `$OBJDIR/cbfstool print`, on all four arches, the `ppc` row proving the
  big-endian reads and telling the payload kinds apart; an authored `raw` entry
  round-trips through `cbfstool`.
- **Spike 3:** the **live** CBFS walk from the mapped ROM window on `amd64`/`x86`
  matches both the host-side file walk and `cbfstool print`; a region diff shows a
  firmware-caused change; the option-ROM read prints as UNCOVERED with its blockers
  named.

---

## 10. Addendum — grading CBFS surgery against the coreboot team's `cbfstool`

The oracle for the CBFS work is **`cbfstool`, coreboot's own reference
implementation**, built from the same tree that produced the ROM. This is worth
spelling out because CBFS is a format we would otherwise be grading against *our
own reading of a spec header* — the "written by analogy" trap this family already
paid for. The discipline is **bidirectional and covers surgery, not just reads**:

- **Read direction — with `extract`'s verbs re-measured 2026-09-01
  ([review F2](REVIEW-preboot-structure-toolkit-plan.md#f2--10-rests-on-cbfstool-extract-which-this-repo-has-already-measured-failing)
  asked; §3's table has the row).** `cbfstool <rom> print` is ground truth for
  the walk: our Forth listing (name, type, size, offset of every file) must
  match it entry for entry, on all four arches. `cbfstool extract` gives
  ground-truth *bytes* for **`raw` entries** (it decompresses LZMA ones, so the
  compare is against the decompressed payload); for the **`simple elf` payload**
  it needs `-m ARCH` and returns a **reconstituted** ELF (segments only —
  different size/sha256 than the input ELF), so the payload is graded by `print`
  metadata + a hash of the bytes at the offset `print` reports **after verifying
  that offset against the master header** — `print`'s offsets being file offsets
  in this ROM's CBFS era is checked, not assumed.
- **Write / surgery direction — the one that actually matters.** When our Forth
  **authors or patches** a CBFS entry (via `write-file`), the test is **not** that
  our own reader accepts it — a parser and a writer wrong the same way agree with
  each other. The test is that **`cbfstool` accepts the whole ROM afterward**:
  `cbfstool print` still lists a coherent archive, the master-header and
  per-file fields still validate, and `cbfstool extract` returns our bytes
  unchanged. A patch our reader loves and `cbfstool` rejects is a **silent
  corruption**, and catching it is the entire reason the oracle is the coreboot
  team's tool and not ours. (Authored entries are **`raw` type**, where
  `extract` is a byte-faithful oracle — the re-measured scope above.)
- **Round-trip, both origins.** A ROM `cbfstool` *built* must survive our
  walk → author → `cbfstool` read unchanged; a **`raw` entry** *we* built must
  survive `cbfstool` extract → re-`add` unchanged. Either direction failing is a
  finding.
- **When they disagree, suspect us first — but check both.** `cbfstool` is the
  reference, so a mismatch is our bug until proven otherwise. It is *not*
  infallible (it is software, and "the control is where the bugs are"), so a
  genuine `cbfstool`-side surprise gets filed, not papered over.
- **Bind the oracle to the subject (derive, don't cache).** `cbfstool` is
  **versioned with coreboot** and its metadata handling has eras (legacy master
  header vs. FMAP-only). Grading a ROM with a `cbfstool` from a *different*
  coreboot than built it is exactly this repo's stale-record bug in oracle form.
  So the track uses **`$OBJDIR/cbfstool` from the objdir that built
  `$OBJDIR/coreboot.rom`** — every coreboot build produces one, so the pin to
  the same commit holds **by construction**, with no vendored copy to drift
  (review F2). The track records the commit both came from — a version string is
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

**Closer than "aspirational"
([review F11](REVIEW-preboot-structure-toolkit-plan.md#f11--11s-adjacency-is-not-adjacent-it-is-in-the-repo)):
both halves of the "derive the expectation" sentence are already on disk.**
[`examples/systemd261-nixos-measured-boot/`](examples/systemd261-nixos-measured-boot/README.md)
ships a reproducible dm-verity + UKI image whose PCR 11 systemd computes, booted
under OVMF + swtpm; and the OpenBIOS builds here are byte-reproducible since
patches 47–48 (`SOURCE_DATE_EPOCH`). A reproducible firmware plus a reproducible
UKI with a computed expectation is one lab away, not a research direction — and
it belongs in the same sentence as §12's comparison bench.

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
| **coreboot ROM** (`CONFIG_PAYLOAD_ELF`) | **Linux kernel + u-root** | kexec → Linux | ✅ **`examples/linuxboot-uefi-kexec/` Tier A** — `build-coreboot.sh`, the canonical LinuxBoot, verified twice (disk finale + network `pxeboot`) |
| UEFI | u-root / LinuxBoot | kexec → Linux | ✅ the same lab's **Tier B** |

**CORRECTION
([review F1](REVIEW-preboot-structure-toolkit-plan.md#f1--the-cell-that-is-not-present-is-present-and-it-is-the-lab-the-plan-cites-as-the-counter-example)):
the cell this section originally declared missing — in bold — is present.**

> The first draft said *"coreboot → modern Linux, directly ❌ — NOT PRESENT…
> the Linux-as-firmware half hangs off UEFI, not coreboot… that gap is the
> interesting part."* That was wrong in the best direction: it is **Tier A of
> [`examples/linuxboot-uefi-kexec/`](examples/linuxboot-uefi-kexec/README.md)**
> — a real coreboot ROM carrying linux-6.3 + u-root as its CBFS payload,
> ✅-verified through to an unattended AlmaLinux install
> ([`POC-PXEBOOT.md`](examples/linuxboot-uefi-kexec/POC-PXEBOOT.md)); the row
> this draft *did* list was only that lab's Tier B. The host holds **four
> coreboot ROMs with three payload kinds** (`build/`, `build-ofw/`,
> `build-openbios/`, `build-openbios-amd64/`), so "which payload does this ROM
> carry" has its subject set on disk today — unread, which is Spike 2's job.
> What is genuinely not built is the **comparison bench** below — and its
> measured-boot leg needs a ROM configuration that measures at all (review F4:
> nothing here sets `CONFIG_VBOOT`/`CONFIG_TPM*`, so today's ROMs measure
> nothing — a coreboot-with-vboot build is that leg's named prerequisite).

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
2. **The comparison bench** — the build step the first draft put here is
   **already built** (review F1: coreboot → u-root is the linuxboot lab's
   Tier A), so this item is now *only* the bench: the same target Linux reached
   by **three existing firmware substrates** (coreboot+OpenBIOS boot,
   coreboot+u-root Tier A, UEFI+u-root Tier B — the run scripts exist in both
   labs). This is exactly where the **event-log half (Spike 1) earns its keep**
   — measured coreboot with *different payloads* produces *different
   measurements from the same ROM boot-block*, so "replay the log, see what
   differs" becomes a **comparison** rather than a single reading. **Named
   prerequisite** (review F4): a fourth ROM configuration built with
   `CONFIG_VBOOT` + a TPM behind it — today's ROMs measure nothing, and MAAS
   `DEFERRED.md` already measured where that road leads (*"a PCR policy over a
   BIOS boot blesses any payload"*).

**Hold off on treating this as its own lab plan until B.3's Spike 0 lands** —
both items lean on the CBFS reader, which does not exist until the primitives do.
This section is the note that keeps the direction from being lost: Spikes 2–3 have
a *live* form under the coreboot-payload combination, and **the bench is what
turns the attestation half from one reading into a comparison.**

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
