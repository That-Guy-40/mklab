# The Attested Boot — a Capstone Lab Plan v1 (2026-09-14; feasibility re-measured 2026-09-16)

*Proposed as **its own lab**, deliberately downstream of and separate from the toolkit work,
so it builds on the readers/writers/gates without getting in their way. Working lab name:
**`openbios-measures-its-own-boot/`** (naming decided in §2b; "attested" is the ambition,
"measured, and accounted for" is the honest word — the hardware quote stays UNKNOWN, §1).
This plan threads five things already built or planned:
[the preboot toolkit](PREBOOT_STRUCTURE_TOOLKIT_LAB_PLAN.md) (readers, `sha256`, the event
log), [the ELF gate & boot ladder](ELF_GATE_AND_BOOT_LADDER_LAB_PLAN.md) (B.4),
[the boot-handoff notes](DESIGN-NOTES-the-firmware-edits-the-boot-it-makes.md) (the zero
page, `SETUP_DTB`, the `?bootparams` bzImage gate), the
[filesystem readers](DESIGN-NOTES-modern-filesystems-for-a-frozen-firmware.md), and the
[FCode option-ROM notes](DESIGN-NOTES-fcode-option-roms.md) (measured `byte-load`). Tracked as
[`TODO.md` §26](TODO.md#26-the-attested-boot--a-capstone-lab-openbios-measures-its-own-boot-2026-09-14).*

> **Re-measured 2026-09-16, against the tree and the kernel's source.** §3's feasibility rows
> hold. Its "to verify first" question (= §9.2) is now **answered, and the answer is no**: the
> kernel creates `/sys/kernel/security/tpm0/` only when a TPM chip registers *and* the firmware
> left a log where the kernel already knows to look — an ACPI `TPM2`/`TCPA` table, an EFI config
> table, or the Open Firmware `linux,sml-base` property — and no OpenBIOS door can reach any of
> the three today. So §9.3's "the log has no standard type" is wrong in a productive way (it has
> two, both firmware-authored, neither open here), **Spike 3's oracle is the mailbox by
> decision**, and **Spike 4's third witness exists only on the edk2 leg**. §3 also gains an
> UNKNOWN row for the lab kernel's config, and the Linux door is named correctly (amd64).

---

## 1. Why — and the honest frame first

Every note in this family measures **one link** of the boot and hands it on; nothing yet
**joins them and hands the account across to the OS**. The capstone is one sentence: *the
firmware measures everything it touched on the way up — the payload it ran, the kernel and
initrd it loaded, the command line and device tree it authored, the option ROMs that ran —
authors one TCG event log of that chain, and hands the OS **both the boot and the log**, so
userspace can replay the firmware's own account against the kernel's record.*

**The honest word is "measured", not "attested", and the lab says so on every run.** A
hardware-signed **quote** — the thing that makes a measurement *trustworthy* to a remote
party — needs a real TPM with a real attestation key, which nothing in QEMU's software TPMs
can produce (the `event-real`/`event-bench` tracks already state this). So the lab proves the
**chain is internally consistent and independently replayable** — the firmware's log, the
kernel's `binary_bios_measurements`, and a host replay all agree — and prints **QUOTE:
UNKNOWN** with the reason, every run. That gap, named precisely, is the teaching moment: it is
exactly where "measured boot" stops and "attestation" begins, and most treatments blur it.

**Why now:** the pieces exist. `dsl/sha256.fth` is a pure function proven on four arches;
`dsl/eventlog.fth` authors and replays a crypto-agile log graded against `tpm2_eventlog`;
the ELF gate (patch 68) refuses before the copy; the handoff notes author the zero page and
`SETUP_DTB`; `SETUP_PCI`/`byte-load` measurement is in the FCode notes. The capstone is
**composition and one new gate** (the bzImage gate, §5 Spike 1), not new primitives.

## 2. Thesis & scope

**Thesis.** A firmware that reads structures can also **measure** them, and one that edits the
handoff can also **carry its measurements across it**. The result is a boot whose every input
is accounted for by the firmware and checkable by the OS with no firmware driver in the path —
the "record bound to its subject" law (CLAUDE.md) applied to the whole boot, with the trust
anchor named as absent.

**In scope:** measure the payload, kernel, initrd, command line, DTB, and each `byte-load`ed
option ROM; author one event log spanning them; hand the OS the log (through a reserved e820
range — the mailbox, §5 Spike 3) *and* the boot; replay and require agreement — **three ways
where a third witness exists** (firmware, host, and the kernel's own `binary_bios_measurements`
on the edk2 leg), **two ways on the OpenBIOS doors** with the third seat named UNKNOWN (§5
Spike 4); **both** an ELF gate and a bzImage gate feed the chain (§5).

**Out of scope (hard):** a hardware quote (UNKNOWN, always); sealing/unsealing to PCRs
(that needs the quote); modifying secure-boot policy; any real machine or vendor firmware.

### 2b. Why its own lab (LOCKED)

- **It is a *consumer*, not a primitive.** Every dependency is built or planned elsewhere;
  folding the capstone into the rival lab would bloat that lab's already-large showcase and
  couple the toolkit's cadence to a capstone that only makes sense once the gates are green.
  A separate lab lets the toolkit work land independently and this lab pick up the pieces at
  its own pace — the same reason `open-firmware-native-habitats/` is its own lab and not a
  track in the rival.
- **It spans two firmwares and, at Spike 5, three.** The measured-boot bench already reaches
  UEFI (edk2/swtpm) and coreboot; the capstone's "same boot, N firmwares, one report" is a
  cross-lab harness that does not belong inside any single firmware's lab.
- **Its risk profile is different.** The chaos/security posture of the FCode note lives here
  too (a measured boot's job is to *notice* a bad payload), so this lab carries the
  attack/prevention framing that the toolkit lab deliberately does not.
- **It has a stated end, unlike a toolkit.** "The chain agrees three ways and the quote is
  UNKNOWN by name" is a finish line; the toolkit is open-ended. Separate lifecycles.

## 3. Verified feasibility (to check before writing, per the family rule)

- `dsl/sha256.fth` matches NIST on unix/x86/amd64/ppc — **✅ measured** (toolkit Spike 1b).
- `dsl/eventlog.fth` authors + replays a log `tpm2_eventlog` parses — **✅** (`event-log`,
  `event-replay`, `event-real`).
- the kernel exposes `/sys/kernel/security/tpm0/binary_bios_measurements` under the phase-2
  swtpm+OVMF guest — **✅** (the toolkit plan's Spike 1 subject).
- `tools/openbios-rom-provenance.sh` binds a ROM to the payload inside it by **deriving**
  (extracts the payload and compares it to the ELF) — **✅ exists**, and its own header
  retracts a stale "cannot extract" claim, which is the shape Spike 0 wants.
- the host has `swtpm`, `tpm2_eventlog`, QEMU `tpm-tis`/`tpm-crb` (x86 only — **ppc `mac99`
  has no TPM device at all**), and phase 2 already passes TPM args (`test-tpm-args.sh`) — **✅**.
- **the Linux door is `amd64-linux`**, the only track that boots a kernel under OpenBIOS
  (`arch/x86/linux_load.c` exists but no track exercises the 32-bit door). The plan's first
  draft said "OpenBIOS-x86"; corrected.
- **Answered 2026-09-16 (was "to verify first"): does that door's kernel expose
  `/sys/kernel/security/tpm0/…` without a TPM? No — and not *with* one either, under
  OpenBIOS.** From `drivers/char/tpm/eventlog/common.c`: `tpm_bios_log_setup()` runs when a
  chip registers, calls `tpm_read_log()` (ACPI → EFI → OF, in that order), and **`if (rc < 0)
  return;` before `securityfs_create_dir`** — no log found, no directory at all. The three
  places it looks are all *firmware-authored*: an ACPI `TPM2` table's `log_area_start_address`
  (or a `TCPA` table), an EFI configuration table, or the Open Firmware `linux,sml-base` /
  `linux,sml-size` properties on the TPM's device-tree node (`eventlog/of.c`, which also
  wants `compatible = "IBM,vtpm"`). Under OpenBIOS: **no ACPI** (`arch/amd64/openbios.c`:
  *"this tree has no ACPI parser at all"* — QEMU's tables, TPM2 included, sit in fw_cfg
  behind a table-loader OpenBIOS does not run, so the kernel boots with no RSDP); **no EFI**;
  and the **OF route — exactly the device tree the `fdt` track already flattens — needs a
  DT-probed TPM, and the ppc machine has none**. Consequence: on the OpenBIOS doors the
  kernel's own log interface is unreachable by mechanism, not by configuration; the mailbox
  (Spike 3) is the route, and the kernel is a witness only on the edk2 leg (Spike 4).
- **UNKNOWN — the lab kernel's config.** `~/linuxboot-lab/payload-bzImage` is 6.3.0
  (`coreboot@reproducible`), carries no `IKCFG` marker, and no `.config` for it is on disk.
  `CONFIG_TCG_TPM`, `CONFIG_OF` (which `SETUP_DTB` needs), and `CONFIG_SECURITYFS` are
  **unverified**. Spike 1's first act is to build or locate a kernel whose config is known and
  say which; until then this row stays UNKNOWN rather than assumed.

## 4. Why this and not a hosted tool

`tpm2_eventlog` parses a log; `systemd-analyze pcrs` replays one; neither can be **inside the
firmware authoring the log as the boot happens**, before any OS, on four arches, with the
payload it is measuring being the firmware doing the measuring. The uniquely-afforded thing is
the **same log, authored in the firmware and replayed in three independent places that must
agree** — the firmware is one witness, the kernel a second, the host a third, and no single
hosted tool occupies more than one of those seats.

## 5. The spikes

> **Spike 0 runs first and is a DECISION** (the family rule): where the measurement hook lives
> and what anchors "expected".

### Spike 0 — THE ANCHOR (decision)
**Question.** A measured log is only as meaningful as what "expected" is bound to. Where does
the reference come from, so a replay means something?
- **(A) The ROM's provenance file** (`tools/openbios-rom-provenance.sh` already stamps the
  payload digest) — the log's PCR for the payload is checked against it. Cost: the anchor is a
  host file, not a hardware root; say so.
- **(B) A golden log captured once** and vendored (the `event-real` shape) — the replay must
  reproduce it. Cost: a golden that can go stale (bind it to the build, the MAAS lesson).
- **(C) Both**: (A) for the live payload, (B) for the cross-firmware bench.
**Criterion:** the anchor must be **derivable and bound to its subject's identity**, and a
mismatch refused by name before `go`. Decide by which gives the un-fakeable comparison with
the smallest stale-record surface.

### Spike 1 — the bzImage gate (`?bootparams`), brought to green
The user wants **both** gates. The ELF gate exists (patch 68, `elf-ladder`); the **bzImage
gate is the handoff notes' §2.6 `?bootparams`** — build it here as this lab's first code, since
the capstone must measure a bzImage's gate verdict. It validates the setup header (magic,
`HdrS`, the compression magic, the image CRC32), the zero page against the file, e820 coherence
against `/memory`, the `setup_data` chain, and the initrd archive — refusing by name before the
jump, or UNKNOWN by name (the kernel-only questions). **Success:** `load …\vmlinuz` → the gate
runs, a one-field-bad fixture is refused by name, the good image boots; the verdict is a value
the log can measure. **Control:** the gate stripped → the bad image is accepted (the negative
control the ELF ladder also holds).

### Spike 2 — measure the chain
At each gate (ELF and bzImage) and each `byte-load`, `sha256` the bytes and author a
`TCG_PCR_EVENT2` into one log: PCR for the payload, the kernel, the initrd, the command line
string, the DTB `dt>fdt` wrote, and each option ROM. **Control:** one byte changed in any input
moves exactly its entry's digest and the replayed PCR, and nothing else's.

### Spike 3 — hand the log across (the mailbox, by decision)
Carry the finished log to the OS in a **reserved e820 range named on the command line** (the
handoff notes' mailbox). This is a decision, not a fallback: the two *standard* firmware→kernel
channels for a TCG log — an ACPI `TPM2` table's log area and the Open Firmware
`linux,sml-base` property — are both firmware-authored and **neither is open through an
OpenBIOS door** (§3: no ACPI, no EFI, no TPM on ppc), so the kernel's own ingestion
(`/sys/kernel/security/tpm0/binary_bios_measurements`) is **unreachable here by mechanism**.
A `setup_data` record has no type for it. **Oracle:** userspace reads the log back from
`/dev/mem` at the named address (an initrd that has it), and its sha256 equals the firmware's.
**The tree goes too** (`SETUP_DTB`, if `CONFIG_OF` — §3's UNKNOWN row), so the DTB the log
measured is the DTB the kernel received — the two accounts are of one boot. **Named and not
taken:** authoring an ACPI `TPM2` table would mean authoring ACPI from nothing (RSDP → RSDT →
TPM2) on a firmware that has none; that is a lab of its own, not a spike here.

### Spike 4 — replay, require agreement; three ways where a third witness exists
The firmware replays its own log (`evlog-replay`); the host replays the same bytes
(`tpm2_eventlog` + python `hashlib`). **On the OpenBIOS doors that is the whole jury** — two
witnesses — and the run prints the third seat as **`KERNEL WITNESS: UNKNOWN — no
firmware-authored log channel reaches this kernel (§3)`**, by name, not as a blank. **The
third witness exists on the edk2 leg only** — the kernel's `binary_bios_measurements`, which
`event-real` already replays to the machine's own PCRs 8/8 — so on that leg **all three PCR
sets must agree**, or the divergence is named per entry. **QUOTE: UNKNOWN** printed with its
reason, every run, on every leg. §2b's finish line reads accordingly: *three ways where a
third witness exists, two where it cannot, and the missing seat named.*

### Spike 5 — the same boot, N firmwares, one report
Generalise the `event-bench`: the same kernel+initrd reached by **OpenBIOS**, **coreboot**, and
**UEFI (edk2)**, each producing its own measured log, collated into one report of *what differs
in the handoff each firmware built* — the zero page/DTB it authored and the PCRs it extended.
This is the payload-substitution matrix (toolkit §12) with measurement on top: the payload is
the constant, the firmware the variable, and the log says what each did differently.

### Spike 6 — the malicious payload, noticed (the security row)
The FCode note's chaos rows, seen from the measurer's seat: a payload/option-ROM that persisted
or was swapped changes the replayed PCR, and the bench shows the compromised boot's log
differing from the clean one in exactly the entry the tamper touched — "replay the log, see
what differs", pointed at malware. **Defensive, emulated**, per that note's frame; the
deliverable is that the measured boot **detects** the change the FCode note's preventions block.

## 6. What this is NOT (scope guards)
- **Not attestation.** No quote, ever; UNKNOWN by name every run. Measured ≠ attested, and the
  lab's whole honesty is holding that line.
- **Not a TPM implementation.** It authors and replays the log; the swtpm (where used) is the
  hardware model, and it is software — said so.
- **Not sealing/unsealing.** That needs the quote.
- **Not a new firmware.** One gate (Spike 1) and composition; the measurement hook rides the
  gates and `byte-load` that already exist or are planned.

## 7. Routing (at assembly, not before)
Each spike a `smoke-*.sh` track in the new lab with a `tests/` wrapper and a `run-all.sh` entry;
the bench a `showcase-*.sh`; any firmware change a numbered patch with a catalog row. Routed in
`learning-paths.toml` **after** the ELF-gate and handoff work in `boot-and-crash`, as the
cluster's capstone; a 00-INDEX row; the cross-lab dependencies (rival lab's `fcode-utils`,
build doors; the edk2/coreboot fixtures) stated, not hidden.

## 8. Success signature (per spike, observable)
| spike | the line that must print | the control that must bite |
|---|---|---|
| 0 | the anchor named, a mismatch refused before `go` | a stale anchor refused by name |
| 1 | the bzImage gate refuses a one-field-bad image by name; the good one boots | gate stripped → bad image accepted |
| 2 | one log spanning payload/kernel/initrd/cmdline/DTB/ROMs; each entry's digest matches the host's | one byte per input moves only its entry |
| 3 | userspace reads the log back from the mailbox via `/dev/mem`, sha256 == the firmware's; `/proc/device-tree` carries the measured DTB (or `CONFIG_OF` named absent) | the mailbox address wrong → not found, by name |
| 4 | OpenBIOS doors: firmware and host PCRs agree, `KERNEL WITNESS: UNKNOWN` named; edk2 leg: firmware, host **and** kernel agree; QUOTE: UNKNOWN printed on every leg | a flipped entry diverges in every witness identically |
| 5 | one report, three firmwares, the per-firmware handoff differences named | the no-fault row: identical payload, identical payload-PCR |
| 6 | the tampered boot's log differs from clean in exactly the touched entry | the clean boot is byte-identical run to run |

## 9. Open questions
1. **Spike 0's anchor** — (A), (B), or (C)? Decide by the stale-record surface.
2. ~~**Does the OpenBIOS-x86 kernel expose the log interface without a TPM?**~~ **Answered
   2026-09-16: no, and not with one either** — `tpm_bios_log_setup()` returns before creating
   `securityfs` entries unless `tpm_read_log()` finds a firmware-authored log through ACPI,
   EFI, or the OF `linux,sml-base` property, and no OpenBIOS door (amd64, the only Linux
   door) provides any of the three (§3). Adding `tpm-tis`+swtpm to that door registers a chip
   and changes nothing about the log. Spike 4's third witness lives on the edk2 leg.
3. ~~**`setup_data` record vs the e820 mailbox**~~ **Decided: the mailbox** (Spike 3). The
   first draft's reason — "the log has no standard type" — was wrong: it has **two**, the ACPI
   `TPM2` log area and the OF `linux,sml-base` property, both firmware-authored. The real
   reason is that neither is reachable from OpenBIOS without first authoring ACPI (no) or
   having a DT-probed TPM on ppc (none). `setup_data` genuinely has no type for it.
4. **Does Spike 5's UEFI leg belong here or stay in the rival lab's `event-bench`?** It exists
   there; the capstone may *consume* it rather than re-home it — a cross-lab call, §2b.
