# coreboot bring-up — a host-side porting workbench, and a payload inspector (2026-09-16)

Two labs that aim the firmware toolkit at **coreboot board bring-up** — the term
of art for getting coreboot running on a **new mainboard**. Neither expects the
Forth firmware to boot bare metal; both live where the roadmap put this family:
the toolkit is a **coreboot payload** and a **Linux host-side workbench**, per
[`FIRMWARE_FAMILY_ROADMAP.md`](FIRMWARE_FAMILY_ROADMAP.md) (a Tier-3 pair). Tracked
in [`TODO.md`](TODO.md) §34.

Two labs, called out as separate things:

- **`coreboot-bringup-workbench`** — host-side. Harvest a running board's hardware
  facts, **grade and honesty-label** a coreboot board port against them. Aids
  bring-up *before* coreboot boots the board.
- **`coreboot-payload-inspector`** — in-firmware. OpenBIOS built as a **coreboot
  payload**, reading the coreboot tables and CBMEM from inside a booted (emulated)
  coreboot, graded against the host's own tools. Inspects *after* bring-up.

## 1. Why — and the term of art

Porting coreboot to a board nobody has done yet is **board bring-up**. coreboot's
own [`util/autoport`](https://github.com/coreboot/coreboot/blob/master/util/autoport/readme.md)
already automates the first move: boot the board on its **vendor firmware**, run
`inteltool`/`superiotool`/`ectool` + `lspci`/`dmidecode`/`acpidump` into a `logs/`
directory, and generate a `src/mainboard/<vendor>/<board>/` skeleton
(`devicetree.cb`, GPIO tables, romstage, `board_info.txt`). So the harvest step
has a reference implementation. **This lab does not reimplement autoport** — it
does the thing autoport does not: **verify** a port against the live hardware and
**label** every fact by how much it can be trusted.

## 2. Thesis & scope

**Thesis.** A coreboot port is a pile of **structured artifacts** (`devicetree.cb`,
FMAP, CBFS, the coreboot table the payload receives, ACPI/SMBIOS the board
produces) — exactly the shapes this toolkit reads. Turn the toolkit on them and it
can *grade* a port against the machine it targets, and dissect what a booted
coreboot hands its payload, each against a foreign oracle.

**In scope (Lab A, workbench):** ingest a board's harvested facts; read the
generated `devicetree.cb` and the ROM's FMAP/CBFS; grade them against the live
system; label each derived fact `DISCOVERED` / `VENDOR-STATE` / `UNDERIVABLE`
(§5). **In scope (Lab B, payload):** OpenBIOS as a coreboot payload on the
emulated `qemu-q35` target; read the **coreboot table** (`lb_*` records) and the
**CBMEM console** from inside; grade against the host's `cbmem`.

**Out of scope (hard):** deriving the **underivable** half of a port from a running
system — raminit/memory training, early SoC init from reset, and the closed blobs
(Intel **FSP**, AMD **AGESA**, `mrc.bin`, microcode). A booted OS cannot know these
and the lab says so by name rather than guessing. **Flashing a real board** — the
lab reads and verifies, it never writes firmware to metal.

### 2b. Why two labs, and the seam between them (LOCKED)

They sit on **opposite sides of the boot**: Lab A works **before** coreboot runs
on the board (host-side, on the vendor-firmware-booted machine, to *build* the
port); Lab B works **after** (in-firmware, on a board coreboot already boots, to
*inspect* the handoff). A workbench that aids bring-up and a payload that presumes
bring-up are different subjects with different honesty tiers, so they are separate
labs. They **share** the toolkit's CBFS/FMAP readers and the roadmap's host-process
stance; neither owns the other. §2b LOCKED.

## 3. Verified feasibility (to check before writing)

- **autoport exists and its output is a documented, static artifact** — a `logs/`
  dir of raw tool dumps and a generated board directory. Parsing those is durable;
  driving the tools live is not (§5, Spike 0).
- **coreboot builds for QEMU** (`qemu-i440fx`/`qemu-q35` and non-x86 `qemu-*`
  targets), so Lab B's payload boot is **verifiable on emulation**, no metal.
- **The payload path has repo precedent** —
  [`open-firmware-forth-to-boot` POC-3](examples/open-firmware-forth-to-boot/POC-3-COREBOOT-PAYLOAD.md)
  already ran Forth/OpenBIOS as a coreboot payload.
- **coreboot's own tools are already oracles here.** The CBFS work in
  [`openbios-the-rival-that-shipped`](examples/openbios-the-rival-that-shipped/dsl/cbfs.fth)
  grades against `cbfstool`; this lab extends the pattern to `cbmem`, `inteltool`,
  `superiotool`, `dmidecode`, `acpidump` as oracles.
- **to verify first:** which coreboot `qemu-*` target boots an OpenBIOS ELF payload
  cleanly today (Lab B, Spike 0), and whether a real captured autoport `logs/` set
  can be committed as a fixture without licensing snags.

## 4. Why this and not `autoport` alone

autoport **generates**; it does not **verify**, and it cannot tell a porter which
of its guesses to trust. This lab is the grader and the honesty layer on top:
read the port, check it against the live machine with coreboot's own tools as
oracles, and label every fact by its reliability. autoport hands you a skeleton;
this tells you which bones are real.

## 5. The spikes

> **Spike 0 runs first and is a DECISION.**

### Lab A — `coreboot-bringup-workbench`

**Spike 0 — THE INPUT SEAM (decision).** How does the workbench get a board's
facts? **(A) parse static artifacts** — autoport's `logs/` dumps and/or the
generated board directory: **robust**, because they are *files*, not tool
invocations, and they survive coreboot renaming or deprecating a util. **(B) drive
the tools live** — invoke `inteltool`/`superiotool`/`lspci`/… to produce fresh
logs: **fragile**, because the coreboot team may replace or retire any of them.
**Decision:** the workbench's input contract is **"a directory of logs/dumps"**
(option A is the floor and always works); live tool-driving is an **optional
producer** of that directory, isolated behind a thin adapter so that removing it
does not touch the parser. **Rudimentary autoport-log parsing is the required
core; direct tool-driving is the removable edge.** **Control:** the parser runs to
completion on a committed fixture `logs/` set with **no tools installed at all**.

**Spike 1 — parse the harvest into structured facts.** Read the `logs/` dumps
(and/or the board dir) into a typed table: PCI topology, Super I/O, EC, SPD/DIMM,
ACPI/SMBIOS, GPIO where present, the flash/IFD layout. **Control:** a truncated or
tool-version-shifted log is flagged **by name**, never silently half-parsed.

**Spike 2 — read the port's own artifacts, graded by a foreign oracle.** Parse the
generated `devicetree.cb`, and the ROM's FMAP/CBFS, and check them against
`cbfstool`/`ifdtool`. **Control:** a `devicetree.cb` node with no matching live
device, and a CBFS region whose map disagrees with `cbfstool`, are both findings.

**Spike 3 — grade the port against the live machine, and LABEL every fact.** For
each port fact, compare to the live oracle and stamp one of:
`DISCOVERED` (read from live hardware, trustworthy), `VENDOR-STATE` (a
post-vendor-init snapshot — *not* reset truth, hand-verify), `UNDERIVABLE`
(raminit/FSP/blob — host-side cannot know; must come from a datasheet or the blob).
**This labelling is the deliverable** — it tells a porter which parts of an
autoport skeleton to trust. **Control:** a fact the running system cannot possibly
know (a raminit parameter) is refused a `DISCOVERED` label.

**Spike 4 — the mismatch bites.** Feed the grader a board directory with a
deliberately wrong GPIO or Super I/O; it flags the divergence against the live
oracle. **Control:** the wrong port is caught; a correct port grades clean.

### Lab B — `coreboot-payload-inspector`

**Spike 0 — build OpenBIOS as a coreboot payload (decision + floor).** Which
emulated coreboot target boots the OpenBIOS ELF payload? Settle on one `qemu-*`
target; that boot, verified on emulation, is the floor for the rest. **Control:**
the payload reaches its prompt under a booted coreboot in QEMU.

**Spike 1 — read the coreboot handoff from inside.** From the payload, read the
**coreboot table** (`lb_*` records: memory map, framebuffer, serial, CBMEM console,
board ID) — a TLV-shaped structure the toolkit's `struct`/TLV reader is built for —
and the **CBMEM console**. **Control:** a record type the reader doesn't know is
named unknown, not skipped.

**Spike 2 — grade against the host's own tools.** The payload's read of the
coreboot table and CBMEM equals the host `cbmem -l`/`cbmem -c` and `cbfstool`
view. **Control:** a mismatch between the in-firmware read and `cbmem` is a finding.

**Spike 3 — real-board capture as fixture, labelled.** A coreboot table / CBMEM
dump captured from a **real** board is read and graded, and marked
`HW-ANCHOR: capture` — verified against the capture, **not** claimed as a live
metal run here. **Control:** an emulated result is never printed as a metal result.

## 6. What this is NOT (scope guards)

- **Not a re-implementation of autoport / the coreboot utils.** They harvest and
  generate; they are the oracles. This grades and labels.
- **Not a raminit / FSP deriver.** The `UNDERIVABLE` label exists precisely to say
  what a running system cannot tell you. No guessing memory training from a booted
  machine.
- **Does not flash real hardware.** Reads and verifies a port; the destructive
  write to a real SPI flash is out of scope. Fixtures come from captures, not from
  the lab touching metal.
- **Lab B is not a bring-up aid.** It presumes coreboot already boots the target;
  it inspects the handoff, it does not help produce the port (that is Lab A).

## 7. Routing, success signature, honesty labels, open questions

Two host/emulated labs (Lab A host-side, Lab B on the emulated coreboot target),
routed in `learning-paths.toml` beside the [coreboot ROM workbench](COREBOOT_ROM_WORKBENCH_LAB_PLAN.md)
and [verified boot](COREBOOT_VERIFIED_BOOT_LAB_PLAN.md) labs; checkpoints are
host-side `parse`/`grade`/`cbmem`-diff commands under `smoke-*.sh`. Per the
roadmap these are **Tier-3 capstones** consuming Tier-1 readers (`cbfs`, `fmap`,
plus new `lbtable`, `devicetree.cb`, `smbios`/`acpi` readers this pair adds), each
pinned to the contract when built.

| lab / spike | the line that must print | the control that must bite |
|---|---|---|
| A0 | input seam chosen; parser runs on a fixture `logs/` with no tools installed | live-tool path removed → parser still passes |
| A1 | the harvest as a typed fact table | a truncated/version-shifted log flagged by name |
| A2 | `devicetree.cb` + FMAP/CBFS == `cbfstool`/`ifdtool` | a node with no live device, a CBFS map mismatch, are findings |
| A3 | every fact stamped DISCOVERED / VENDOR-STATE / UNDERIVABLE | a raminit param refused a DISCOVERED label |
| A4 | a correct port grades clean | a wrong GPIO/SuperIO port is caught |
| B0 | OpenBIOS payload reaches its prompt under coreboot in QEMU | — |
| B1 | the coreboot table + CBMEM read from inside | an unknown `lb_*` record named, not skipped |
| B2 | in-firmware read == host `cbmem`/`cbfstool` | a mismatch is a finding |
| B3 | a real-board capture graded, `HW-ANCHOR: capture` | an emulated result never printed as metal |

**Honesty axes (per the roadmap's manifest).** `ARCH: x86-only` on the
autoport/`inteltool`/FSP-facing parts (Intel-centric by nature), while the
CBFS/FMAP/SMBIOS/coreboot-table readers stay multi-arch. `HOST-ONLY` on Lab A's
grading; `HW-ANCHOR: capture` vs an emulated run on Lab B.

**Chaos rows (the family chaos ladder).** A truncated `logs/` set mid-harvest
(HALT honestly, or LIE a partial port complete?); a CBMEM console that rotated
between capture and read (scoped read, or STALE?); a live-tool adapter whose tool
is missing or renamed (DEGRADE to the parsed fixture + name it, never a silent
wrong fact).

**Open questions.** (1) Which coreboot `qemu-*` target boots the OpenBIOS payload
cleanest today (B0)? (2) Can a real autoport `logs/` capture be vendored as a
fixture cleanly, or must it be synthesised? (3) Does the `devicetree.cb` reader
live here or graduate into the shared Tier-1 set (likely graduates, since the ROM
workbench wants it too)?
