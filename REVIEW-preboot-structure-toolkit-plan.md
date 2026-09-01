# REVIEW — "Preboot Structure Toolkit — Lab Plan v1"

*Review of [`PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md`](PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md)
(v1, 2026-09-01; TODO B.3) against this repo at `cd3609e`, written 2026-09-01.
Graded on the four axes asked for — completeness, feasibility, extensibility,
top-of-mind — plus the two the repo cares about most: what is already built that
the plan does not reuse, and which of its claims were reasoned rather than
measured. Method and limits are in [§0](#0-method-and-what-this-review-did-not-do).*

> **VERDICT: the spine is right and the gate is in the right place; the plan is
> wrong about what already exists, in both directions.**
>
> **Right:** Spike 0 as a *decision* rather than a warm-up (the static-offset
> model in `dsl/struct.fth` genuinely cannot carry a length prefix — confirmed
> by reading `(tfield)`, which bakes the offset at `create` time); two
> firmware-native TLV formats chosen so the byte-order axis is split *inside the
> subject*; the hardware quote named UNKNOWN and left there; and §10's
> insistence that CBFS surgery is graded by coreboot's own tool, not ours.
> Nothing below argues with any of that.
>
> **Wrong, direction one — it under-counts the repo.** §12's headline gap,
> *"coreboot → modern Linux, directly ❌ — NOT PRESENT"*, is present. It is
> **Tier A of [`examples/linuxboot-uefi-kexec/`](examples/linuxboot-uefi-kexec/README.md)**:
> `build-coreboot.sh` builds a coreboot ROM whose CBFS payload is a Linux
> kernel plus u-root, verified end-to-end twice (disk finale and network
> `pxeboot`). The cell the plan proposes to build as item (2) is the lab it
> cites as the counter-example ([F1](#f1--the-cell-that-is-not-present-is-present-and-it-is-the-lab-the-plan-cites-as-the-counter-example)).
> The same host holds **four** coreboot ROMs with three different payload
> kinds — the "which payload does this ROM carry" bench the plan wants exists
> as a set of files today, unread.
>
> **Wrong, direction two — it over-counts the lab.** The four-arch matrix that
> §4 calls *"the control a hosted tool can never run"* does not exist yet. Every
> type-layer track runs on **x86 and amd64 only**; no `dsl/*.fth` has ever been
> loaded on `ppc` or on `unix`, and there is a measured reason for each: the
> hosted target reads stdin through an **80-column** line editor and every dsl
> file except `elf-write.fth` has lines of **177–181** columns; the sibling
> habitats lab measured that OpenBIOS-ppc **cannot load from media** and that
> its only delivery door is a **3 KiB** NVRAM string — `struct.fth` alone
> minifies to **3,159 bytes** ([F3](#f3--the-four-arch-matrix-does-not-exist-yet-and-two-of-its-rows-have-no-door)).
> `write-file` is bound on `unix` only, so Spike 0's exit criterion — author
> with `write-file`, read back on all four — cannot be executed on three of
> the four arches as written, and on the fourth there is no `read-file`
> (TODO §20 parks it as *"not done"*).
>
> **And one feasibility claim was reasoned where the repo had already
> measured the opposite.** §10 rests on `cbfstool extract`; this repo's own
> [`tools/openbios-rom-provenance.sh`](tools/openbios-rom-provenance.sh)
> records that *"this tree's cbfstool cannot `extract` a payload at all"*
> ([F2](#f2--10-rests-on-cbfstool-extract-which-this-repo-has-already-measured-failing)).
>
> None of this is fatal. It moves the first increment: **before Spike 0 there
> is a delivery spike** (get the type layer *onto* all four arches, and give
> the round-trip a read-back path), and the *order* of Spikes 1–3 should flip
> so the one with a subject already on disk (CBFS, four ROMs) runs before the
> one whose subject the plan never names (an event log — no ROM in this repo
> is built with vboot or a TPM, and nothing here has ever parsed one).

---

## 0. Method, and what this review did NOT do

- **Read, not run.** This container has no `~/openbios-lab`, no
  `~/linuxboot-lab`, and no coreboot tree, so **nothing was built or booted**.
  Every finding is a reading of the repo at `cd3609e` — the plan, its three
  source documents, `dsl/*.fth`, `smoke-openbios.sh`, the CI workflows, and the
  sibling labs. Where a claim below rests on someone else's measurement it says
  whose and where.
- **Measured here, cheaply:** the maximum line length of each dsl file; which
  tracks invoke `qemu-system-ppc` or `openbios-unix`; the minified size of
  `struct.fth` through the habitats lab's own `minify-fth.py`; that no `.fth`
  or `.fs` file in the repo contains a hash function; that no file in the repo
  parses a TCG event log or names `binary_bios_measurements`; that no coreboot
  config fragment in the repo sets `CONFIG_VBOOT` or `CONFIG_TPM*`; and that
  `tools/link_check.py` reports 0 broken links with the plan in place (its
  anchors resolve, including the one TODO B.3 links).
- **Not verified:** anything inside the OpenBIOS source itself (`load-base` on
  ppc, whether `alloc-mem` behaves identically there, the `LB_TAG` parser §12
  cites) — the clone is not here. Those are marked as such.

---

## 1. Findings

Ordered by how much they move the plan, not by section.

### F1 — The "cell that is not present" is present, and it is the lab the plan cites as the counter-example

§12 draws the matrix and then says, in bold, that coreboot here *only ever
carries OpenBIOS*, that the Linux-as-firmware half *hangs off UEFI, not
coreboot*, and that joining them is *"the interesting part."* TODO B.3 repeats
it verbatim.

[`examples/linuxboot-uefi-kexec/build-coreboot.sh`](examples/linuxboot-uefi-kexec/build-coreboot.sh)
opens with: *"TIER A: build a real coreboot ROM with a LinuxBoot payload. This
is the canonical LinuxBoot: coreboot (the firmware itself) carries a Linux
kernel + u-root as its CBFS payload, and `qemu -bios coreboot.rom` boots it."*
It builds coreboot's crossgcc from source, compiles linux-6.3, builds u-root,
and assembles the ROM. The lab's README tier table marks it **✅ verified**;
[`POC-PXEBOOT.md`](examples/linuxboot-uefi-kexec/POC-PXEBOOT.md) is *"VERIFIED
FROM THE REAL COREBOOT ROM"* through to an unattended AlmaLinux install. There
are two config fragments (`coreboot-qemu-q35-linuxboot.config`,
`coreboot-qemu-q35-pxeboot.config`), a `run-coreboot-linuxboot.sh`, a
`run-coreboot-boot-disk.sh` finale that `kexec`s a real disk's OS, and
`run-coreboot-pxe*.sh`. The plan's §12 row *"UEFI | u-root / LinuxBoot"* is
that lab's **Tier B**; Tier A was never looked at.

**Consequences, all of them favourable:**

- **Item (2) in §12 is already built.** What is *not* built is the thing item
  (2) was for — the **comparison bench** (one target Linux via three firmware
  substrates) and the event-log comparison. Those stay; the prerequisite
  vanishes.
- **The host has four coreboot ROMs with three payload kinds**, and
  [`build-coreboot-openbios.sh`](examples/openbios-the-rival-that-shipped/build-coreboot-openbios.sh)
  already enumerates them because it sha-guards the siblings' artifacts:
  `build/coreboot.rom` (16 MiB q35, LinuxBoot kernel + u-root),
  `build-ofw/coreboot.rom` (the OFW lab's Firmworks payload),
  `build-openbios/coreboot.rom` (4 MiB i440FX, OpenBIOS x86 as a SELF
  payload) and `build-openbios-amd64/coreboot.rom`. §12's own thesis — *"the
  payload is the variable and the toolkit is the constant"* — has its subject
  set on disk today. The Spike 2 walk should list **all four** and prove it
  can tell them apart by what it finds under `fallback/payload`, not one.
- **The three-substrate comparison already has three substrates**
  (coreboot+OpenBIOS+`amd64-linux`, coreboot+LinuxBoot Tier A,
  UEFI+LinuxBoot Tier B). The showcase scripts exist in both labs.

**Fix:** rewrite §12's matrix with the Tier A row present, drop item (2)'s
build step, and re-point it at the bench. Correct TODO B.3 in the same commit
— it is the plan's one inbound summary and it is wrong the same way.

### F2 — §10 rests on `cbfstool extract`, which this repo has already measured failing

§10's whole discipline — *"`cbfstool extract` gives ground-truth bytes"*,
*"`cbfstool extract` returns our bytes unchanged"*, *"a structure we built must
survive `cbfstool` extract → re-`add`"* — is built on one verb. The §3
feasibility table checked that `cbfstool` is *obtainable*; it did not check
that verb.

[`tools/openbios-rom-provenance.sh`](tools/openbios-rom-provenance.sh), written
2026-08-27 for the same ROM, says: *"coreboot TRANSFORMS an ELF into its own
segment format on the way in (1,162,128 bytes of ELF became a 75,851-byte
`simple elf` CBFS file here), so a byte-compare is meaningless, and **this
tree's cbfstool cannot `extract` a payload at all** — it fails with 'Failed
while operating on COREBOOT region'."* That is why the pairing is cached
rather than derived. The plan's §3 table lists the same ROM as ✅ and the
same oracle as ✅ and never meets this sentence.

Two more things the same script settles:

- **`cbfstool` is already built, per objdir, by the coreboot build itself.**
  `build-coreboot.sh` calls `./build/cbfstool build/coreboot.rom print` as its
  own checkpoint. So §10's *"pin the vendored cbfstool to the same coreboot
  commit as the ROM"* is satisfied **by construction** if the track uses
  `$OBJDIR/cbfstool` from the tree that built `$OBJDIR/coreboot.rom` — and a
  separately vendored copy, as §8 proposes *"the way `elfls` was"*, is exactly
  the drift §10 warns against. Don't vendor it; derive it.
- **The payload is SELF, not the ELF.** *"Verify a payload's declared size /
  hash against its bytes"* is a hash over coreboot's segment format. That is
  fine, and it should say so — the naive reader will try to match it against
  `openbios-builtin.elf` and conclude the reader is broken.

**Fix:** re-measure `cbfstool extract` against the current tree *first*, on a
`raw`-type file (which every CBFS era extracts) and on the payload separately.
Scope §10's surgery round-trip to **raw entries** unless the payload extract
turns out to work; grade the payload by `print` metadata plus a hash of the
bytes at the offset `print` reports. Record the result in §3's table as the
row that was missing.

### F3 — The four-arch matrix does not exist yet, and two of its rows have no door

§4 makes the four arches the differentiator: *"every track in this lab runs on
all four and asserts the round-trip holds across the matrix."* Today:

| track | x86 | amd64 | ppc | unix |
|---|---|---|---|---|
| `struct-layer`, `struct-array`, `struct-device`, `elf-methods`, `rmw-fields` | ✅ | ✅ | — | — |
| `file-writer` (the only `write-file` user) | — | — | — | ✅ |
| any dsl file at all | ✅ | ✅ | **never** | **never** |

Measured here: `qemu-system-ppc` is invoked by exactly two tracks (`ppc`,
`diagnostics`), both of which type bare built-in words over a pty; `ppc` and
`unix` appear **zero** times in `dsl/*.fth` and in `MANUAL-TYPE-LAYER.md`. The
type layer is a two-arch artifact with a four-arch ambition, and each missing
row has a *specific, already-measured* reason:

- **`unix`: the 80-column door.** TODO §20 and the `file-writer` track both
  record that `openbios-unix` reads stdin through an 80-column line editor
  (*81 survive, 83 cut*), which is why `elf-write.fth` is hand-kept ≤ 82 and
  why *"the 133-col `dsl/elf.fth` cannot be piped to the unix target."*
  Measured now: `struct.fth` 177, `elf.fth` 177, `elf32.fth` 181. **The
  workbench cannot load the engine.** And once loaded, there is no way to
  read a file *back* — §20's own *"Natural sequel (not done)"* is `read-file`.
- **`ppc`: the 3 KiB door.** The habitats lab measured its delivery matrix
  cell by cell ([README](examples/open-firmware-native-habitats/README.md),
  [`DELIVERY.md`](examples/open-firmware-native-habitats/DELIVERY.md)):
  on OpenBIOS-ppc *"Media ❌ no filesystem compiled"*, *"Just type it ❌ dies
  at 80 columns"*, and the one door that works is `-prom-env nvramrc=…`, a
  single line inside a 3,072-byte NVRAM shared with every other variable.
  `minify-fth.py` on `struct.fth` yields **3,159 bytes** — over the budget by
  itself, before `cbfs.fth` or `eventlog.fth` exist. (Whether the rival lab's
  own `qemu-ppc` build has a filesystem compiled in is not checked here; the
  sibling's ❌ is the only measurement on file.)
- **`write-file` is `arch/unix` only, by design** (patch 54: *"hosted-only on
  purpose"*). On the three QEMU arches "author with `write-file`" is not a
  thing. The persisting seams there are `pmem` (amd64 only — NVDIMM above
  4 GiB), CFI flash (x86, and stores are *commands*), and the VGA aperture.
- **`struct.fth` carries an x86-shaped constant.** `load-base-phys` selects
  `4000000` or `400000` **by cell width** (`/n 8 =`). On ppc `/n` is 4, so it
  would silently pick x86's value; `>virt`/`>phys` are then wrong-by-
  construction there. Not a bug today (it has never run on ppc), but it is the
  first `T-ERR` the ppc row would need — and a nice example of §4's own point,
  which is that the narrow-cell control and the big-endian control are
  different controls.

**What follows.** Spike 0's exit criterion cannot be executed as written on
any arch. The honest first increment is a **Spike −1, delivery**: get the
existing type layer onto all four arches and prove `struct-layer`'s controls
there *before* adding primitives to it. Three options, in order of preference:

1. **Bake the dsl into the dictionary at build time.** OpenBIOS compiles its
   Forth sources into `openbios-<arch>.dict`; adding `dsl/*.fth` to that list
   (behind a build flag) gives all four arches the layer with no staging, no
   80-column limit and no NVRAM budget — CLAUDE.md's own advice for a lossy
   console: *"compile the probe in… a word baked into the dictionary."* Cost:
   a build patch (see F8) and a dictionary budget nobody has taken
   (the poke-engine review's last *did-not-prove* item).
2. **Reflow to ≤ 80 columns.** Mechanical, but it fixes only `unix`, and the
   comment-heavy style that makes these files worth reading is what gets
   squeezed.
3. **Give `unix` a `-f` disk image the dsl can `load` from** — the read-only
   disk emulation §20 lists — plus `read-file` for the round-trip.

Whichever, the claim in §4 should be rewritten from present to future tense
until the row exists, and the plan should say what "author" means per arch: on
`unix`, `write-file` then a host oracle; on `amd64`, `pmem` then `od`; on `x86`
and `ppc`, in-arena, with the bytes printed for the host to compare.

### F4 — Spike 1 has no subject, and no ROM in this repo can produce one

Spike 1a says *"parse a real crypto-agile event log"* and never says where one
comes from. Checked:

- The lab's own coreboot config is five lines
  (`build-coreboot-openbios.sh`): board, ROM size, `PAYLOAD_ELF`, payload
  path. No `CONFIG_VBOOT`, no `CONFIG_TPM2`. Neither linuxboot config
  fragment sets them either; the only `vboot` in the repo is a submodule
  fetch. So §5's *"coreboot is where measured boot happens — its vboot extends
  PCRs and writes the very event-log format Spike 1 handles"* is true of
  coreboot and **false of every ROM this repo builds.** OpenBIOS has no TPM
  driver at all.
- Nothing in the repo parses an event log. `binary_bios_measurements`,
  `tpm2_eventlog`: zero hits outside the plan. The measured-boot lab that does
  exist — [`examples/metal-as-a-service/`](examples/metal-as-a-service/README.md)
  `image+measured` — reads PCR values from sysfs and signs quotes; it never
  opens the log.
- The repo *has* measured the thing §12's comparison bench would trip over:
  MAAS `DEFERRED.md` — *"The BIOS fleet cannot measure a payload at all…
  SeaBIOS measures the boot-sector code and the partition table and nothing
  in the filesystem, so a PCR policy over a BIOS boot blesses any payload."*
  A coreboot+OpenBIOS ROM without vboot measures **nothing**, so "same ROM
  boot-block, different payloads, different measurements" needs
  coreboot **built with vboot and a TPM** behind it — a fourth ROM
  configuration the plan should name as a prerequisite of §12(2), not assume.

**Where a real subject already is, cheaply.** Phase 2's `lab-vm.sh` has a
per-VM swtpm sidecar behind `tpm = true` (used by MAAS and by
[`examples/systemd261-nixos-measured-boot/`](examples/systemd261-nixos-measured-boot/README.md)).
Any OVMF guest booted that way exposes
`/sys/kernel/security/tpm0/binary_bios_measurements` — a genuine
`TCG_PCR_EVENT2` log written by edk2, with `tpm2_eventlog` (tpm2-tools,
packaged) and `systemd-analyze pcrs` (the NixOS lab already prints it) as two
independent oracles. That is Spike 1a's subject and its control, from labs
that exist, with no crypto and no coreboot rebuild. Spike 1b's replay then has
a claimed PCR to match: the guest's own `pcr-sha256/` files, the same ones
`measure-init.sh` reads.

The **AK caveat** the plan cites (*"the repo's own notes record that even
swtpm can't give a faithful AK here"*) is real and is in three places by
design (`DEFERRED.md`, `drivers/image-measured.sh`, `measure-init.sh`); the
plan should link one of them rather than paraphrase.

### F5 — Spike 3's subject is the one feasibility claim §3 did not check, and the reachable one is §12(1)

§3 verifies six load-bearing claims and Spike 3 is not among them. Its exit
criterion names *"a PCI option ROM's header / an FCode image's first bytes"*
from real device memory on `amd64` and `x86`. Three things on file:

- **No config space, no port I/O.** The poke-engine review's *did-not-prove*
  list (2026-08-30): *"This firmware binds no port-I/O words on x86 or amd64
  and no config-space accessors, so MMIO is the only device seam Forth can
  reach."* Finding an expansion-ROM BAR is a config-space read.
- **The firmware's PCI allocator leaves BAR0 of the VGA device unassigned**
  (`mmio-writer` track, measured 2026-08-27), which is why that track uses the
  legacy aperture. An option-ROM BAR programmed by this allocator is not a
  safe assumption.
- **The only FCode option ROM in the repo is built for the other firmware.**
  [`examples/open-firmware-debugs-itself/build-fcode-rom.sh`](examples/open-firmware-debugs-itself/build-fcode-rom.sh)
  tokenises `dsl/fcode-card.fth`, wraps a PCI ROM header, validates with
  `romheaders`, and attaches it with `-device e1000,romfile=` — to **OFW**.
  Whether OpenBIOS-x86 would find, map, or `byte-load` it is unmeasured
  (the review's own open item: *"whether it accepts a buffer that did not come
  from a PCI option ROM is unmeasured"* — and the converse, one that did, is
  equally so).

Meanwhile the seam that **is** reachable is the one §12 describes and then
postpones. Booted with `-bios coreboot.rom`, the 4 MiB ROM is memory-mapped
at the top of the 4 GiB space; the `flash-writer` track already reads a CFI
window at `0xffbe0000` through `>virt` and proves (with an erased-part
control) that it is looking at the chip. So *"a Forth prompt that walks the
CBFS of the very ROM that delivered it"* needs the Spike 2 reader, an address,
and an observer outside the firmware — and the observer is trivial: the ROM
**file** on the host, `cmp`'d byte-for-byte, plus QEMU's monitor `xp` as a
second witness. §12(1) says this *"needs nothing not already on disk."* It is
the honest Spike 3.

**Fix:** make §12(1) Spike 3's exit criterion on `x86`/`amd64`; keep the
option-ROM read as a **named UNCOVERED row** with the two blockers above
(config space; an OpenBIOS-side FCode ROM subject), per the chaos-matrix rule
the plan itself invokes. The `region-snap`/`region-diff` half of Spike 3 then
has a natural transition to diff: the firmware's own `LB_TAG` table walk (the
`linuxbios_info.c` parser §12 cites, patched in this lab's patch 01 and 39)
runs at init; snapshot the CBMEM-forwarded table region, re-run the walk,
diff — a change the firmware itself caused, from a code path already in-tree.

### F6 — `region-snap`/`region-diff` are not "existing" in this lab; they are OFW words that have not been ported

Spike 3 says *"using `open-firmware-debugs-itself`'s existing
`region-snap`/`region-diff` (`dsl/ofscope.fth`)."* That lab runs Bradley's
**Firmworks OFW** (`run-ofw-debug.sh`), not OpenBIOS — the first review's F1
(*"the two proven pieces are two different firmwares"*) applies here. The
words themselves are fifteen lines of `alloc-mem` / `move` / `c@` and should
port cleanly (`alloc-mem` is already used by this lab's tracks), but:

- the self-containment rule means a **copy** into
  `openbios-the-rival-that-shipped/dsl/`, not a cross-lab `load`;
- the habitats lab already did this exercise for `ofdiag` and recorded what
  survives an OpenBIOS port and what does not (*"the tracers do not — OpenBIOS
  declares no `defer`"*); its
  [`PORTING.md`](examples/open-firmware-native-habitats/PORTING.md) is the
  checklist, and its plan graded `ofscope` as *"likely"*, not done;
- on `x86` the snapshot address must go through `>virt` or it snapshots RAM
  that reads back convincingly — the `flash-writer` trap, again.

Small, but "existing" is the word that hides a step.

### F7 — Spike 0's synthetic record is weaker than the real subject already on disk

Spike 0 authors `{ len:u32, name[len], pad-to-4, body:u16 }`. The gleanings
note the plan is built from named a *real* record of exactly that shape as
*"the single richest vein"*: **`Elf_Note`** — `namesz, descsz, type,
name[namesz], pad-to-4, desc[descsz], pad-to-4`. It is present in the ELF the
`struct-*` tracks already load (`.note.gnu.build-id`, `.note.ABI-tag` in any
host-built image); its oracle is `readelf -n`, already used by `file-writer`;
its `desc` on a build-id note is a **content hash of the image**, which is the
repo's *bind the fact to its subject's identity* rule handed over for free;
and `dsl/elf.fth` already names `NOTE` as a `p_type` and parses none. Using
the note as Spike 0's subject costs nothing extra and gives the gate a real
subject, a foreign oracle, and a first consumer in the same move. Keep the
synthetic record as the *authored* half (it is the negative-control fixture —
the note is the positive one).

Two extensibility notes in the same vein:

- **FDT is missing from the plan.** The gleanings say the two primitives are
  *"also what it would take to describe the device tree's own structure block
  (length-prefixed, NUL-padded, 4-byte-aligned)."* OpenBIOS's device tree is
  the one subject every arch has natively, and a `dt>fdt` flatten is the
  boot-handoff structure DESIGN-NOTES §8 lists first. §6 should name it as
  *deferred, and why* so it is not lost the way §12 says it is trying not to
  lose things.
- **§E3's `file:` definer** (poke's *members mapped at offsets read from
  earlier members*) is the declarative form of `vfield:`; the review called it
  *"maybe twenty lines… worth having the moment a second table is added."* CBFS
  is that second table. Decide in Spike 0 whether `vfield:` **is** the
  cursor-mode `file:` or sits beside it — that is option (A) vs (B) restated
  in the review's vocabulary, and naming it avoids building it twice.

### F8 — "No new firmware patch" is contradicted by the plan's own mitigations

§8: *"this work touches only `dsl/` Forth + tracks, **not** the firmware C,
so no new firmware patch."* But Spike 1b's named mitigation is *"a hosted-only
bound C word beside `write-file`"* (that is patch 54's shape — a patch to
`arch/unix/unix.c`); F3's `read-file` is another; F3's option 1 (bake the dsl
into the dictionary) is a build patch. Any of those is outside
`arch/{x86,amd64}/`, so [`tools/check-patch-scope.sh`](tools/check-patch-scope.sh)
requires an `Arch-tested: x86 amd64 ppc` header — meaning **the ppc build must
be run for a unix-only change**, which is the rule working as intended and
worth planning for.

On SHA-256 specifically: the plan's *"bound C word on `unix` first"* gives 1b
on one arch of four. A Forth SHA-256 is ~150 lines of 32-bit arithmetic —
the one place a **32-bit cell is not a hazard**, and on the 64-bit cells the
rotates need masking, which makes it a clean matrix control in its own right
(NIST vectors as the oracle, `sha256sum` as the second). If the point of the
lab is the matrix, the hash should live in it.

### F9 — The `ppc` control catches a different bug than §5 says it does

§5: *"a `le-field:` length read on a big-endian record must be caught… hard-code
the length as LE and watch `ppc` fail by name."* It would not fail on `ppc`
alone. `struct.fth` builds every accessor from `c@`/`rb@` **by byte**, so
byte order is a property of the field declaration, not of the CPU — a
mislabelled `le-field:` reads the same wrong number on all four arches, which
is the design working. What the `ppc` row uniquely catches is a **host-native
access that slipped in** — a bare `@`, `w@`, `l@`, `,` — and, with `x86`, a
cell-width-selected constant (F3's `load-base-phys`). Write the negative
control as *"replace the length read with a bare `l@` and watch `ppc` alone
diverge"*; that is the assertion the matrix can actually make, and it is the
mechanism-vs-outcome distinction CLAUDE.md keeps.

### F10 — CI will not run any of it unless the plan says where

Tier B runs a hand-listed `DEFAULT_TRACKS` in
[`.github/workflows/openbios-tier-b.yml`](.github/workflows/openbios-tier-b.yml)
(`multiboot dict-identity amd64 property-abi diagnostics vga ppc struct-layer
struct-array struct-device elf-methods rmw-fields`). `unix` and `file-writer`
— the only tracks that exercise the hosted target and `write-file` — are
**not in it**, so the plan's "workbench" is a target CI does not boot. §8's
routing should add: new tracks join `DEFAULT_TRACKS` (and
`tools/openbios-tier-b-relevant.sh`'s filter) or they are tests nobody runs.
The wrapper/list guards the plan relies on check that a track *has a
wrapper*, not that CI *runs* it.

### F11 — §11's adjacency is not adjacent; it is in the repo

§11 discusses NixOS/Guix full-source bootstrap as a possible future
connection. [`examples/systemd261-nixos-measured-boot/`](examples/systemd261-nixos-measured-boot/README.md)
already builds a NixOS image in the repo's nix-build-box, boots it under OVMF
+ swtpm, ships a dm-verity + UKI golden image with `measured-os` MET, and
seals LUKS to PCR 7+11 with a quote-attestation stub. And the OpenBIOS builds
here are byte-reproducible since patches 47–48 (`SOURCE_DATE_EPOCH`). §11's
*"derive the PCR expectation from a reproducible build"* therefore has both
halves on disk: a reproducible UKI whose PCR 11 systemd computes, and a
reproducible firmware. It is one lab away, not aspirational — and it belongs
in the same paragraph as §12's comparison bench, because it is the same
sentence.

---

## 2. What holds up

- **Spike 0 as a decision.** Confirmed by reading: `(tfield)` stores
  `offset, width, order, space` at `create` time and `does>` adds the stored
  offset; there is no cursor anywhere. A length prefix cannot be expressed.
  The (A)/(B) fork is real and building it is the only way to pick.
- **The two formats.** TLV-shaped, firmware-native, opposite byte order — and
  the CBFS one has **four subjects on disk** (F1), which is better than the
  plan knew.
- **The quote stays UNKNOWN.** Stated three times, matches the MAAS lab's own
  framing, and is the line that separates the attestation half from theatre.
- **§10's grading direction.** *"A parser and a writer wrong the same way agree
  with each other"* is the right fear, and the fix (coreboot's own tool judges
  the patient) is right — once the tool's verbs are re-measured (F2).
- **The scope guards.** Not a linker, not a fake TPM, not a generic
  dissector. The plan would be smaller and better if it added *not a dictionary
  budget nobody measured* to the list and then measured one.

---

## 3. Reusable components the plan does not name

| component | where | what it gives the plan |
|---|---|---|
| **coreboot + Linux/u-root ROM, two configs, run scripts** | `examples/linuxboot-uefi-kexec/` Tier A | §12(2) built; the third substrate of the bench; a 16 MiB CBFS with a `bzImage`-type payload to read next to the SELF one |
| **four `coreboot.rom`s on one host** | enumerated by `build-coreboot-openbios.sh`'s sha guard | the Spike 2 subject set — same reader, three payload kinds |
| **`$OBJDIR/cbfstool`, built by the tree that built the ROM** | every coreboot objdir | §10's "pin to the same commit" for free; no vendoring |
| **`tools/openbios-rom-provenance.sh`** | `tools/` | the *bind the ROM to its payload* discipline §10 wants, already shipped — and the measured `extract` failure (F2) |
| **swtpm sidecar (`tpm = true`)** | `phase2-qemu-vm/lab-vm.sh` | a real `TCG_PCR_EVENT2` log from any OVMF guest, plus the PCRs it must replay to (F4) |
| **`measure-init.sh`, `verify-lib.sh gen-ak`, `drivers/image-measured.sh`** | `examples/metal-as-a-service/` | the AK/quote boundary written down three times; PCR read-out; the SeaBIOS-measures-nothing finding |
| **`systemd-analyze pcrs`, UKI + dm-verity image, sealed LUKS** | `examples/systemd261-nixos-measured-boot/` | a second event-log/PCR oracle and §11's reproducible-expectation half |
| **`stage-dsl.sh`, `minify-fth.py`, the delivery matrix, `PORTING.md`** | `examples/open-firmware-native-habitats/` | every door OpenBIOS-ppc has, measured; the porting checklist; the 3 KiB budget (F3) |
| **`region-snap`/`region-diff`** | `examples/open-firmware-debugs-itself/dsl/ofscope.fth` | fifteen portable lines — but on OFW, not yet on OpenBIOS (F6) |
| **`build-fcode-rom.sh` + `romheaders`** | `examples/open-firmware-debugs-itself/` | the only PCI option-ROM subject in the repo, and a host-side validator for one (F5) |
| **`flash-writer`'s corrected window + `>virt`/`>phys`** | `smoke-openbios.sh`, `dsl/struct.fth` | the address discipline for reading the ROM window from inside on x86 (F5) |
| **`drive-pty-repl.py --echo-gate`** | `tools/` | already verified against real OpenBIOS-ppc; the only safe way to type at that console |
| **`Elf_Note` in the ELF the tracks already load; `readelf -n`** | `dsl/elf.fth`, `file-writer` | Spike 0's real subject and oracle (F7) |
| **`oracle/elfkickers/README.md` provenance shape** | the rival lab | the template for any oracle that *does* need vendoring (`tpm2-tools` does not; it is packaged) |

## 4. Missing connections, in one list

1. §12 ↔ `linuxboot-uefi-kexec` Tier A (F1) — the largest, and it inverts a
   headline.
2. §10 ↔ `openbios-rom-provenance.sh` (F2) — the plan re-derives a discipline
   the tool already enforces, and misses the measurement it recorded.
3. §4 ↔ the habitats lab's delivery matrix (F3) — the `ppc` row's door was
   measured a month ago.
4. Spike 1 ↔ `lab-vm.sh tpm = true` / MAAS / NixOS (F4) — three labs hold the
   subject and two oracles.
5. Spike 3 ↔ §12(1) (F5) — the plan postpones the reachable seam and schedules
   the unreachable one.
6. Spike 0 ↔ the gleanings' own `Elf_Note` (F7).
7. §11 ↔ the NixOS measured-boot lab and patches 47–48 (F11).
8. §8 ↔ `DEFAULT_TRACKS` (F10).

## 5. Recommended order, in dependency order

1. **Correct the record**: §12's matrix and TODO B.3 (F1); §3's table gains
   the `cbfstool extract` row and the Spike 3 row (F2, F5); §4 to future
   tense (F3); §8 loses *"no new firmware patch"* (F8).
2. **Spike −1, delivery**: the existing `struct-layer` controls green on
   `ppc` and `unix`, via the dictionary or a reflow (F3); `read-file` or an
   in-arena read-back defined per arch. This is the gate before the gate.
3. **Spike 0** on the `Elf_Note` (F7), with the negative control rewritten
   per F9.
4. **Spike 2 first, over all four ROMs**, live window as the `x86`/`amd64`
   Spike 3 (F1, F5); `ppc` and `unix` read the ROM as a file.
5. **Spike 1a** on a `binary_bios_measurements` log from a `tpm = true` guest
   (F4); **1b** in Forth on all four (F8); **1c** unchanged.
6. **§12's bench** — now a comparison of three existing substrates plus one
   new ROM configuration (coreboot with vboot + swtpm) named as its
   prerequisite (F4).

## 6. What this review did NOT prove

- **Nothing was booted.** In particular: whether the rival lab's own
  `qemu-ppc` build can `load` from an ISO (the sibling's ❌ is a measurement of
  the sibling's build); whether `alloc-mem` and `move` behave on ppc as the
  `region-snap` port assumes; whether OpenBIOS-x86 exposes a `romfile=`
  option ROM anywhere Forth can reach; what `cbfstool extract` does on the
  *current* coreboot checkout (the recorded failure is from 2026-08-27).
- **The dictionary budget was not measured.** F3's option 1 depends on it.
- **The SELF payload's on-disk layout was not read.** F2's "hash the bytes at
  the offset `print` reports" assumes `print`'s offsets are file offsets in
  every CBFS era; verify against the master header before trusting it.
- **No poke, no coreboot source, no OpenBIOS source** was opened. The `LB_TAG`
  parser claim in §12 is taken from this lab's own patches 01 and 39, which
  touch it, not from reading `linuxbios_info.c`.

## Provenance

Written 2026-09-01 against `cd3609e`. Sources read in full: the plan;
[`DESIGN-NOTES-preboot-forth-binary-structures.md`](DESIGN-NOTES-preboot-forth-binary-structures.md);
[`dsl/POKE-ELF-GLEANINGS.md`](examples/openbios-the-rival-that-shipped/dsl/POKE-ELF-GLEANINGS.md);
[`dsl/struct.fth`](examples/openbios-the-rival-that-shipped/dsl/struct.fth);
TODO §0.6, §20, §21 and B.3; the relevant sections of
[`REVIEW-preboot-forth-binary-structures.md`](REVIEW-preboot-forth-binary-structures.md)
and [`REVIEW-preboot-forth-as-a-poke-engine.md`](REVIEW-preboot-forth-as-a-poke-engine.md);
[`OPEN_FIRMWARE_NATIVE_HABITATS_LAB_PLAN.md`](OPEN_FIRMWARE_NATIVE_HABITATS_LAB_PLAN.md)'s
gate; the `unix`, `file-writer`, `flash-writer`, `mmio-writer`, `ppc`,
`diagnostics` and `struct-layer` tracks of `smoke-openbios.sh`; both coreboot
build scripts; the linuxboot, habitats, debugs-itself, MAAS and NixOS lab
READMEs and the files named above; both CI workflows. Sibling reviews in this
family: the two `REVIEW-preboot-*` documents above, whose findings this one
does not restate.
