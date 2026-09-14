# The coreboot ROM Workbench — a Lab Plan v1 (2026-09-14)

*Proposed **new lab**: **`coreboot-rom-workbench/`**. The repo builds coreboot ROMs in four
places and boots them, but always uses coreboot as a **substrate** — a ROM that carries a
payload so something else is the subject. This lab makes **coreboot itself the subject**: build
a ROM, take it apart, put it back together differently, boot each variant, and grade every step
against coreboot's own `cbfstool`/`ifdtool` and the boot outcome. It is the **construction**
half of a two-lab split; the **trust** half is
[`COREBOOT_VERIFIED_BOOT_LAB_PLAN.md`](COREBOOT_VERIFIED_BOOT_LAB_PLAN.md). Tracked as
[`TODO.md` §28](TODO.md#28-the-coreboot-rom-workbench--coreboot-as-the-subject-2026-09-14).*

---

## 1. Why — and why now

Everything the repo does with coreboot treats the ROM as opaque: `build-coreboot.sh` produces
`coreboot.rom`, `qemu -bios coreboot.rom` boots it, and the payload inside is what gets studied
([`linuxboot-uefi-kexec/`](examples/linuxboot-uefi-kexec/README.md) studies LinuxBoot; the
[rival lab](examples/openbios-the-rival-that-shipped/README.md) studies OpenBIOS-as-payload).
The **toolkit already reads a coreboot ROM's insides** — `dsl/cbfs.fth` walks CBFS, `cbfs-live`
walks the ROM the firmware booted from, `cbfs-write` does surgery on a CBFS image on the unix
workbench — but nothing yet **builds, modifies, and re-boots a coreboot ROM as the deliverable**,
with the boot outcome as the grade. The pieces are all on disk (a built coreboot tree with
`cbfstool`, the toolkit's readers/writers, the measured-boot fixtures). The lab is composition
plus a small amount of new plumbing, and it turns the toolkit's "firmware image assembly"
application — which the poke-elf reviews graded *"needs a backend, not an address"* — into a
real thing, because **coreboot is that backend**.

## 2. Thesis & scope

**Thesis.** A ROM is a filesystem (CBFS) inside a region map (FMAP) inside a flash-descriptor
layout, and each layer is a structure the toolkit can read, the firmware can be made to modify,
and a foreign tool (`cbfstool`, `ifdtool`, `fmaptool`) can grade. Make coreboot the subject and
the ROM becomes **editable, measurable, and re-bootable** — the "firmware you assemble" rather
than "the firmware you were handed."

**In scope:** build a minimal q35 ROM from a checked-in config; dissect FMAP + CBFS + the flash
descriptor with the toolkit against `cbfstool`/`ifdtool`; **CBFS surgery on a live bootable ROM**
(add a file the payload reads, replace the payload, resize/relocate, then boot it); the **payload
matrix** (one board, every payload coreboot ships); and **coreboot's own handoff record** (the
coreboot table / CBMEM / timestamps) read by the toolkit — the firmware's account of its own
work, the coreboot counterpart to "OpenBIOS describes its work to Linux."

**Out of scope (hard):** real-hardware board bring-up / raminit (QEMU is not a board — say so);
signing/verification (that is the sibling trust lab); anything that needs a real flash chip's
write-protect (also the trust lab's honesty caveat).

### 2b. Why its own lab (LOCKED)
- **Different subject, same instrument.** The toolkit is the *reader*; this lab is coreboot the
  *thing read and rebuilt*. Folding it into the rival lab would make that lab's showcase carry a
  second firmware's build story; folding it into linuxboot would bury it under that lab's
  boot-a-payload thesis. It is a consumer of both, and of the toolkit, and belongs beside them.
- **Its grade is the boot, not a track's assertion.** A modified ROM that boots (or refuses to)
  is the outcome; `cbfstool` is the second witness. That "edit → re-boot → grade" loop is a
  lab's worth of harness, not a track.
- **It is the shared backend two other things want.** The attested-boot capstone measures CBFS
  edits; the verified-boot lab signs regions this lab lays out. Building the workbench once, here,
  keeps that plumbing in one place.

## 3. Verified feasibility (to check before writing, per the family rule)
- a real coreboot tree with `cbfstool`/`ifdtool`/`fmaptool` and a bootable q35 ROM — **✅**
  (`build-coreboot.sh`, `~/linuxboot-lab/coreboot`, pinned ~`e95bdb7e`).
- the toolkit reads CBFS live in the ROM it booted from — **✅** (`cbfs-live`) — and rewrites a
  CBFS image graded by `cbfstool` — **✅** (`cbfs-write`, unix).
- coreboot emits a coreboot table + CBMEM the payload reads — **✅** (OpenBIOS already parses
  `LB_TAG` tables; `cbmem` is built by the tree, the measured-boot fixtures use a static `cbmem`).
- **to verify first:** whether `cbfstool add`/`remove`/`extract` on a *built* ROM produces a ROM
  QEMU still boots (it should — this is cbfstool's job — but measure before claiming); and which
  payloads coreboot's q35 target actually builds today (§5 Spike 3's matrix is only what builds).

## 4. Why this and not a hosted tool
`cbfstool` builds and edits a ROM on the host; it **cannot be the firmware reading the ROM it
booted from**, and it is exactly the oracle this lab grades against. The uniquely-afforded thing
is the **loop**: the firmware reads its own live CBFS (`cbfs-live`), the host edits the ROM
(`cbfstool`), the edited ROM boots, and the firmware reads the change back from inside — a
round trip no single hosted tool closes. And the payload matrix (§5 Spike 3) is a *comparison*
across firmwares' handoffs that no one payload's own tooling can make.

## 5. The spikes

> **Spike 0 runs first and is a DECISION** (the family rule).

### Spike 0 — THE EDIT SURFACE (decision)
**Question.** Where does a ROM edit happen, so the grade is honest? **(A) host-side** with
`cbfstool` (the ROM is a file; edit, re-boot, and the firmware reads the change) — cheap, but the
firmware is only a *reader* of someone else's edit; **(B) firmware-side** with `cbfs-write` on the
live mapped ROM window (the firmware edits its own flash) — the uniquely-licensed thing, but the
`flash-writer` track already measured that a bare store to the CFI window is a *command* not data,
so a live self-edit needs the flash driver's program sequence, which may be more than QEMU's
pflash gives; **(C) both**, host-side as the workhorse and firmware-side as the one vivid demo.
**Criterion:** the edit the lab is *built on* must round-trip (edit → re-boot → firmware reads it
back), graded by `cbfstool`; the vivid live self-edit is a bonus, not the spine. Measure (B)'s
reach before betting on it.

### Spike 1 — dissect: FMAP + CBFS + the descriptor, against the oracle
Point the toolkit at a built ROM: `dsl/cbfs.fth` lists every CBFS file (offset/type/size/name)
matching `cbfstool print`; a new small `dsl/fmap.fth` reads the FMAP region map matching
`cbfstool layout`/`fmaptool`; and the flash descriptor's regions against `ifdtool -d`. **Control:**
a byte flipped in the FMAP signature is refused by name; the counts match the oracle exactly.

### Spike 2 — surgery on a live bootable ROM
Three edits, boot-graded: **add** a CBFS file (`raw`) the payload reads at boot and prove it read
it; **replace** the payload and boot the new one; **resize/relocate** a region and boot (or fail
by name if it no longer fits). Each graded twice: `cbfstool` accepts the image (host oracle), and
the ROM **boots to the expected outcome** (the real grade). **Control:** an edit that corrupts a
required region must make the boot fail *observably* (a named coreboot log line), not silently
hang — the CLAUDE.md "assert the outcome" rule.

### Spike 3 — the payload matrix (one board, every payload)
Coreboot's design is *hardware init, then hand off to a payload*. Build the **same q35 board**
with each payload the target supports — SeaBIOS, edk2/TianoCore, GRUB2, FILO, LinuxBoot (have it),
OpenBIOS (have it), a bare Linux — and reach the **same target** (a shell, or `cat /proc/version`)
through each. One report of **what each payload does differently in the handoff**: the CBFS entry,
the console it brings up, the boot time, and (feeding the attested-boot bench) the measurement it
produces. **Control:** the payload is the only variable — identical board, identical target;
a payload that fails to build is UNCOVERED **by name**, not dropped.

### Spike 4 — coreboot's own handoff record, read by the toolkit
Turn the toolkit around from "read the payload's structures" to "read the *firmware's* account":
the **coreboot table** (`LB_TAG_*`: the memory map, the framebuffer, the serial console, the CBMEM
location), **CBMEM** (the coreboot-managed memory the payload inherits, incl. the timestamps and
the console log), read with `dsl/struct.fth` and graded against the `cbmem` tool. This is the
coreboot counterpart to the handoff notes' "the firmware describes its work to Linux" — here the
firmware describes its work to its *payload*, and the toolkit reads the description.

### Spike 5 — the dissector/editor, as the deliverable tool
Assemble Spikes 1–2 into one instrument: `rom-inspect` opens a ROM and prints its FMAP regions,
CBFS files, descriptor layout and coreboot-table summary; `rom-edit` adds/replaces/removes and
re-emits, `cbfstool` grading every result. Runs on the unix workbench (no QEMU) for inspection,
and drives the boot-graded loop for edits. **This is the "firmware image assembly" backend the
poke-elf reviews said the toolkit needed** — coreboot supplies the format, the toolkit supplies
the reader/writer, this Spike supplies the tool.

## 6. What this is NOT (scope guards)
- **Not board bring-up.** QEMU is not a board; raminit is real only on hardware. The lab studies
  the ROM's *structure and payload interface*, which QEMU exercises fully, and says the raminit
  gap out loud.
- **Not verification or signing.** Laying out regions is here; signing them is the trust lab.
- **Not a cbfstool clone.** `cbfstool` is the oracle, never re-implemented; the toolkit reads from
  *inside the firmware*, which is the thing cbfstool cannot do.
- **Not a new coreboot fork.** Configs and CBFS edits, not source patches to coreboot (unless a
  spike needs one, numbered and cataloged like the rival lab's).

## 7. Routing (at assembly, not before)
Each spike a `smoke-*.sh` track + `tests/` wrapper + `run-all.sh` entry; the payload matrix a
`showcase-*.sh`; the coreboot tree reused from `~/linuxboot-lab/` (sha-guarded, the way the rival
lab guards sibling ROMs). Routed in `learning-paths.toml` in `boot-and-crash` beside the linuxboot
and rival labs; a 00-INDEX row; the cross-lab coreboot-tree dependency stated.

## 8. Success signature (per spike, observable)
| spike | the line that must print | the control that must bite |
|---|---|---|
| 0 | an edit round-trips: edit → re-boot → the firmware reads it back; `cbfstool` agrees | (B)'s reach measured — a bare live store is a command, named |
| 1 | FMAP/CBFS/descriptor counts equal `cbfstool`/`ifdtool` | a flipped FMAP signature refused by name |
| 2 | a modified ROM boots to the expected outcome; `cbfstool` accepts it | a corrupt required region fails the boot *observably* |
| 3 | the same target reached through every buildable payload, one comparison report | payload the only variable; a non-building payload UNCOVERED by name |
| 4 | the coreboot table + CBMEM read from inside, matching `cbmem` | a wrong `LB_TAG` length refused, not misread |
| 5 | `rom-inspect`/`rom-edit` drive the whole loop, cbfstool-graded | a bad edit refused before the ROM is emitted |

## 9. Open questions
1. **Spike 0's edit surface** — (A)/(B)/(C)? Decide by whether the firmware-side live self-edit
   reaches through QEMU's pflash (the `flash-writer` result says probably not for a bare store).
2. **Which payloads build on today's q35 target** (Spike 3)? The matrix is only what builds; the
   first measurement is `make` per payload.
3. **Does this lab own the `rom-edit` tool, or does the attested-boot lab consume it** for its
   CBFS-tamper measurement? Likely owned here, consumed there — stated, not duplicated.
