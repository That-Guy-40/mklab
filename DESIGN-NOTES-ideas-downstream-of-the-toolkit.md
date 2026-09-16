# Ideas Downstream of the Preboot Toolkit — a Backlog (2026-09-14)

*Not lab plans — a graded backlog of ideas that fall out of the toolkit, the boot-handoff
notes, the filesystem notes and the FCode notes, kept in one place so they are not lost and so
the next one to pick up is obvious. The capstone that ties the whole arc together is its **own
lab**: [`ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md`](ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md). This note is
the four ideas beside it. Tracked as
[`TODO.md` §27](TODO.md#27-ideas-downstream-of-the-toolkit--a-backlog-2026-09-14).*

Each idea says the same three things: **what it composes** (all built or planned, none new
primitives), **the seam that makes it a measurement not a demo**, and **whether it is a track,
a lab, or undecided** — so scope is a decision on the page, not a surprise later.

> **Re-measured 2026-09-16.** The cross-references all resolve — [`RAM_INFRA_LAB_PLAN.md`](RAM_INFRA_LAB_PLAN.md),
> [`ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md`](ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md) and the ELF-gate plan
> (which does reserve the fuzzer name, §3). Two ideas gain a measured fact. **§1 (UEFI as the third
> firmware) loses its x86 leg:** the "first measurement" it names — does the cached kernel read a
> DTB config table from edk2 — is answered by the [UEFI plan](UEFI_WORKBENCH_LAB_PLAN.md#3-verified-feasibility-measured-2026-09-16),
> and the x86 EFI stub (`libstub/x86-stub.c`) has **no FDT path**, so a DTB config table reaches
> *no* x86 kernel; the three-firmware claim is real on **aarch64** (AAVMF), not x86, where it
> reaches two (OpenBIOS `SETUP_DTB`, OFW native on ppc). **§3 and §4's cpio dependency now has a
> home:** `cpio.fth` is still unbuilt and is a *shared* prerequisite three plans want (the
> firmware-edits note, the UKI plan's Spike 2, this note's fuzzer), so it is built once by whichever
> lands first. The ranking (§5) is unchanged.

---

## 1. The third firmware in the portability story — UEFI hands Linux the same tree

The FCode note proves one option ROM under two IEEE-1275 firmwares; the filesystem and handoff
notes reach Linux through OpenBIOS's `SETUP_DTB`. **UEFI is the third seat**: edk2 hands Linux a
device tree through a configuration table (the DTB GUID), and the repo already builds OVMF
(`fixtures/edk2-swtpm/`). So "a firmware-authored device tree reaches Linux" can be shown three
ways — OpenBIOS via `SETUP_DTB`, OFW natively on ppc through the client interface, and UEFI via
the config table — which lifts the portability claim from the *bytecode* level (one FCode blob,
two interpreters) to the *firmware-interface* level (three firmwares, one kernel-visible tree).

- **Composes:** `dsl/fdt.fth` (flatten), the handoff notes' `SETUP_DTB`, the edk2/OVMF fixture,
  `/proc/device-tree` as the oracle.
- **The measurement:** the *same* authored node (a `compatible` a lab module binds to) appears
  in `/proc/device-tree` under all three firmwares, and the module binds under each — a claim
  about the OF *binding*, not any one firmware.
- **Track or lab?** A **track** in the attested-boot lab's Spike 5 orbit (that lab already
  spans the three firmwares), or a small sibling if the UEFI DTB path proves fiddly. Undecided;
  the first measurement is whether edk2 on the lab's OVMF actually exposes the DTB config table
  to the cached kernel. **Measured 2026-09-16 (UEFI plan §3): on x86, no** — the x86 EFI stub has
  no FDT code, so a DTB config table reaches no x86 kernel; the config-table seat of this idea is
  **aarch64-only** (AAVMF, `-M virt`, where ArmVirtQemu publishes the DTB as `EFI_DTB_TABLE`). So
  on x86 "a firmware-authored tree reaches Linux" is a *two*-firmware claim (OpenBIOS `SETUP_DTB`,
  OFW native on ppc); making it *three* needs the aarch64 door the family has not opened. That
  reshapes this idea from "a track under the capstone" to "a track that carries an aarch64 leg or
  states its x86 absence by name" — no longer undecided on the mechanism, only on whether to open
  that door.

## 2. The A/B updater — the boot counter made a product

The most product-shaped thing in the arc, and the one that makes the store table earn its keep.
Seam 4 of the handoff notes (the NVRAM/pmem boot counter), the filesystem readers, and the ELF
**and** bzImage gates compose into a real rollback loop: **two kernels on two backing stores, a
counter picks one, a boot that never reaches userspace (so never clears the counter) falls back
to the other at the next power-on.** It is the RAM-infra rule — *newest build, unless the newest
build did not come up* ([`RAM_INFRA_LAB_PLAN.md`](RAM_INFRA_LAB_PLAN.md)) — implemented in
OpenBIOS Forth, and it is where the whole family stops being demonstrations and becomes a boot
loader that does a job.

- **Composes:** the boot counter (store table §2.5, per-door store), the fs readers (two kernels
  on a real filesystem), the gates (each kernel passes its format's gate before it is picked),
  `nvramrc` as the picker (§1b of the handoff notes).
- **The measurement:** three power cycles — a good kernel boots and clears the counter (primary
  stays selected); a kernel with `init=/nonexistent` never clears it and the **next** boot takes
  the fallback, the console naming why; a panicking kernel (`panic=5`) also rolls back. Controls:
  the fallback is *not* taken when the counter was cleared; the fallback is refused by name when
  the alternate slot is empty rather than looping.
- **Track or lab?** **Its own small lab**, likely — it needs two kernels, two stores, a picker
  and a rollback policy, which is more than a track and has its own finish line ("a bad update
  rolls back, unattended, and says so"). A strong candidate to write up as a plan next.

## 3. The reader fuzzer — the lab the ELF-gate plan deferred

The ELF-gate plan says in as many words: *"Not a fuzzer. Random mutation would find crashes
without naming clauses; that is a different lab."* **This is that lab.** The toolkit now reads
ELF, CBFS, FDT, cpio and (planned) filesystems; a mutation fuzzer over the existing fixtures
asks of each reader the chaos-ladder question: does a malformed blob get **REFUSED by name**
(ABSORBED), or does it crash the firmware (HALTED/STRANDED), hang it (STRANDED), or — the worst
— read the wrong bytes and report success (LIED)?

- **Composes:** the fixtures (each format's good blob as the seed), the dictionary refusals
  (patches 66/67, the firmware's own guardrails), `dict-used`/`region-diff` to see damage,
  QEMU's monitor as the outside observer, the four-arch matrix.
- **The measurement — and why it is not just "run afl":** the grade is not "did it crash" but
  **which rung**, and the interesting finding is the LIED row — a mutation the reader accepts and
  misreads — because that is the class the whole toolkit's "graded against a foreign oracle"
  discipline exists to prevent. Every mutation the reader accepts is re-checked against the host
  oracle (`readelf`, `cbfstool`, `dtc`), and a disagreement is the finding.
- **Track or lab?** **Its own lab.** It is a different *activity* (generate, run at scale, triage
  by rung) from the toolkit's per-clause fixtures, needs a corpus and a triage harness, and pairs
  with the FCode note's security posture. The ELF-gate plan already reserved the name.

## 4. Two hardening ideas — smaller, and worth naming so they are not forgotten

- **The one-cursor consistency meta-test.** The same length-prefixed cursor vocabulary
  (`>rec`/`t@+`/`vbytes`/`alignto`/`vfield:`) now backs **five** readers — ELF notes, CBFS, FDT,
  cpio (planned) and the TCG event log. Nothing asserts it behaves *identically* across them: a
  fix to the cursor for one format could quietly change another. A meta-test drives the cursor
  through a synthetic record and every real format's fixture and asserts the same primitive
  produces the same offsets/lengths in all — the drift guard the repo applies to checkers,
  applied to the shared reader. **A track**, in the rival lab, cheap.
- **The forensics-firmware artifact.** Combine the FCode note's "toolkit as a driver" (a card's
  ROM carries the readers) or the NVRAM door with a prebuilt image, so a bare `qemu-system-*`
  boot comes up with `struct.fth`/`elf.fth`/`cbfs.fth`/`fdt.fth` already present — a **forensics
  firmware** you point at a blob with no setup. **Its own small deliverable**, license
  permitting (the FCode-on-a-card door is GPLv2-clean; a distributable image is a licensing
  decision like the filesystem note's). Undecided; depends on the toolkit-as-a-driver track
  landing first.

## 5. The ranking, so the next pick is obvious
1. **The attested boot** — its own lab, already planned
   ([`ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md`](ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md)); the capstone
   that gives every note a shared destination.
2. **The A/B updater** (§2) — the most product-shaped; the next lab plan to write.
3. **The reader fuzzer** (§3) — the deferred lab; highest security value, needs a triage harness.
4. **UEFI as the third firmware** (§1) — a track under the capstone; the DTB-table measurement is
   **done (2026-09-16)** and moved it: real on aarch64 (AAVMF), absent on x86 by the kernel's own
   stub, so the track carries an aarch64 leg or names the x86 absence.
5. **The cursor meta-test** (§4) — cheap hardening, a track, do it alongside any cursor change.
6. **The forensics-firmware image** (§4) — a nice-to-have, gated on the toolkit-as-a-driver track
   and a licensing call.
