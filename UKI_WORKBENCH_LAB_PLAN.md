# The UKI Workbench — a Lab Plan v1 (2026-09-14)

*Proposed **new lab**: **`uki-workbench/`**. The linuxboot lab **builds** Unified Kernel Images
with `ukify` and **boots** them under OVMF, but never **takes one apart**. This lab makes the UKI
**the subject**: read its PE structure and named sections, extract and verify each, check the
Authenticode signature and the **pre-computed TPM measurement it carries about itself**, edit a
section and watch the measurement change. It is the artifact-focused sibling of the platform-wide
[UEFI Workbench](UEFI_WORKBENCH_LAB_PLAN.md), and it is where the toolkit gains its **PE reader**
(`dsl/pe.fth`) — the format both labs need. Tracked as
[`TODO.md` §30](TODO.md#30-the-uki-workbench--the-unified-kernel-image-as-the-subject-2026-09-14).*

---

## 1. What a UKI is, and why it is the perfect subject

A **Unified Kernel Image** is systemd's EFI **stub** — a tiny PE/COFF (`.efi`) application — with
the **kernel, initramfs, command line, os-release**, and more glued on as extra **PE sections**
(`.linux`, `.initrd`, `.cmdline`, `.osrel`, `.uname`, `.sbat`, `.pcrpkey`, `.pcrsig`, `.dtb`,
`.splash`). The firmware boots the stub as `\EFI\BOOT\BOOTX64.EFI`; the stub finds those sections
*in its own image*, publishes the initrd over an EFI protocol, and starts the kernel with the
embedded cmdline. **One file is a firmware-flashable, signable, measurable Linux** — and it is a
single self-describing binary, which is exactly the kind of structure this repo's toolkit exists
to read. Better still, a UKI **carries its own attestation policy**: the `.pcrsig` section holds
the TPM PCR values the boot *will* produce, **signed**, so a secret can be sealed to "this exact
UKI booted." A UKI is the boot-handoff, the filesystem, the store, and the measured boot — all the
notes' themes — fused into one file you can hold in your hand.

## 2. Thesis & scope

**Thesis.** A UKI is a typed binary container; read its type and every claim it makes about itself
becomes checkable — what kernel, what cmdline, what it will measure to, who signed it — against the
tools that built it. The toolkit already does this for ELF, CBFS and FDT; the UKI adds **PE** and,
with it, the two things ELF never had: a **signature** and a **self-predicted measurement**.

**In scope:** a PE reader (`dsl/pe.fth`) — headers, the section table, the data directories;
extract each UKI section and grade it (the `.linux` is a bootable EFISTUB kernel, the `.cmdline`
is the string, the `.osrel` parses); read `.pcrsig`/`.pcrpkey` and check the **predicted** PCRs
against what an actual OVMF boot **produces**; the **Authenticode** signature (extract, hash the
signed region, host-verify); and **edit-and-remeasure** (change `.cmdline`, watch the predicted
and actual measurement move together).

**Out of scope (hard):** a full PKCS#7 / X.509 chain verifier in Forth (the honest split is
**extract in the firmware, verify on the host** with `sbverify`/`pesign`, the ELF-gate provenance
pattern); minting a real signing CA (dev keys, said so); re-implementing `ukify` (it is the
oracle).

### 2b. Why its own lab (LOCKED)
- **The UKI is one artifact with a tight, teachable story**; the [UEFI workbench](UEFI_WORKBENCH_LAB_PLAN.md)
  is a whole platform. Keeping the UKI focused lets it be the flagship "thing you dissect" without
  dragging in EFI variables, the boot manager, and secure-boot key hierarchy.
- **It is where `dsl/pe.fth` is born.** Both labs need PE; building it once, here, against a
  format with a small fixed section set (the UKI's) is the cleanest first PE subject.
- **It fuses the family's themes in one file**, which is a lesson in itself: the same UKI is a
  handoff (`.cmdline`/`.initrd`), a measured boot (`.pcrsig`), and a signed artifact
  (Authenticode) — the notes made concrete.

## 3. Verified feasibility (to check before writing)
- UKIs are built and booted here — **✅** (`build-uki.sh` with `ukify`, `run-uefi-linuxboot.sh`
  under OVMF; `.uname`/`.sbat`/`.pcrsig` already named in `WALKTHROUGH.md`, signing skipped).
- the toolkit reads typed binaries against a foreign oracle — **✅** (ELF/CBFS/FDT); **PE is new**.
- oracles present or one `apt` away: `objdump -h`/`llvm-readobj` (sections), `sbverify`/`pesign`
  (signature), `ukify --measure` (predicted PCRs), `systemd-dissect`/`objcopy` (extract).
- **to verify first:** whether the lab's `ukify` emits `.pcrsig` with a dev key here (Spike 3's
  subject); and whether OVMF measures the UKI into a PCR without a full secure-boot enrolment (the
  edk2-swtpm fixture says OVMF measures — confirm the UKI leg does).

## 4. Why this and not a hosted tool
`objdump` prints sections and `sbverify` checks a signature **on the host**; neither is **the
firmware reading a UKI's structure**, and — the uniquely-afforded thing — neither closes the loop
between the UKI's **self-predicted** measurement (`.pcrsig`, computed at build) and the **actual**
measurement an OVMF boot produces. Reading the prediction, booting, and checking it came true is a
round trip across build-time and boot-time that no single hosted tool spans.

## 5. The spikes

> **Spike 0 runs first and is a DECISION.**

### Spike 0 — THE PE READER'S DEPTH (decision)
**Question.** How much PE does `dsl/pe.fth` parse? **(A) section-table only** — enough to find and
extract the UKI's named sections (the minimum that makes every other spike work); **(B) + the data
directories** — reach the Certificate Table (the Authenticode blob) and the base-relocation/import
tables (real PE, needed for Spike 4's signature and for the UEFI workbench's arbitrary `.efi`);
**(C) + the optional header fields** the measurement excludes (checksum, the security dir) — needed
to hash the *signed region* correctly. **Criterion:** the reader must reach every UKI section
(so **A** is the floor) and, for the signature spike, the signed-region hash must match
`sbverify`'s idea of it (so **C** where signatures are graded). Build **A** first; grow to **C**
only along the signature path. Measure the PE against `objdump -h` before trusting a byte.

### Spike 1 — dissect: the section table, against the oracle
`dsl/pe.fth` lists every section (name/vaddr/size/offset) matching `objdump -h`/`llvm-readobj`;
the UKI-specific sections are found by name. **Control:** a flipped `PE\0\0` signature or a section
count past the header is refused by name; the counts equal the oracle exactly.

### Spike 2 — extract, and grade each section by what it is
Pull each section and grade it against its *own* nature: `.linux` is an EFISTUB kernel (its PE/ELF
magic checks; the `elf-gate`/`?bootparams` readers already know these); `.initrd` is a cpio the
`cpio.fth` reader walks; `.cmdline` is the string (compared to what the boot's `/proc/cmdline`
shows); `.osrel` parses as `os-release`; `.uname` is the kernel version (`== .linux`'s built
version). **Control:** a section extracted with the wrong length fails its own reader, not silently.

### Spike 3 — the UKI's self-prediction: `.pcrsig` vs. the real boot
Read `.pcrpkey` (the public key) and `.pcrsig` (the **signed, pre-computed** PCR values the boot
should produce, per phase). Then **boot the UKI under OVMF+swtpm** and read the guest's actual PCR
(the edk2-swtpm capture shape). **The prediction must equal the measurement** — the UKI told the
truth about what it would measure to. **Controls:** `ukify --measure` on the host agrees with the
firmware's read of `.pcrsig` (the section decoded right); and a UKI with **one byte of `.cmdline`
changed** predicts a *different* PCR and produces that different PCR at boot — the prediction
tracks the artifact. This is the attested-boot capstone's measurement, **pre-computed and carried
inside the file**, and it is the single richest thing in the lab.

### Spike 4 — the signature: extract in firmware, verify on host
Reach the Certificate Table (Spike 0(C)); the firmware hashes the **signed region** (the PE minus
the excluded fields) and reads the PKCS#7 blob; the **host** (`sbverify`/`pesign`) verifies the
blob against a dev cert — the ELF-gate's *"measure in the firmware, anchor on the host"* split,
because a full X.509 chain in Forth is out of scope and saying so is the honesty. **Control:** an
unsigned UKI has no Certificate Table (refused by name); a re-signed UKI verifies; a tampered body
fails the host verify.

### Spike 5 — edit-and-remeasure, as the deliverable tool
`uki-inspect` prints the section map, the decoded `.cmdline`/`.osrel`/`.uname`, the `.pcrsig`
prediction, and the signature status; `uki-edit` replaces a section (`.cmdline`, say) and re-emits,
`objcopy`/`ukify` grading the result — and the changed UKI, booted, produces the new measurement
Spike 3 predicts. This is the UKI half of the coreboot workbench's `rom-edit`: the firmware-image
tool, pointed at the modern Linux boot artifact.

## 6. What this is NOT (scope guards)
- **Not a crypto library.** No PKCS#7/X.509 verification in Forth; extract-and-host-verify, named.
- **Not a UKI builder.** `ukify` builds; this reads/checks/edits and grades against `ukify`.
- **Not secure-boot enrolment** — that is the [UEFI workbench](UEFI_WORKBENCH_LAB_PLAN.md)'s
  db/KEK/PK story; here the signature is *read and host-verified*, not *enforced by firmware*.
- **Not a TPM.** `.pcrsig` is *checked against* a real (software) TPM's measurement; the quote
  stays UNKNOWN, exactly as the attested-boot lab holds.

## 7. Routing, success signature, open questions
Tracks under `smoke-*.sh`; the UKI + OVMF reused from `~/linuxboot-lab/`; routed in
`learning-paths.toml` beside the linuxboot lab; the shared `dsl/pe.fth` is this lab's export to the
UEFI workbench.

| spike | the line that must print | the control that must bite |
|---|---|---|
| 0/1 | PE section map equals `objdump -h`; UKI sections found by name | a flipped `PE\0\0` refused by name |
| 2 | each section graded by its own reader (kernel/cpio/string/os-release) | a mis-sized section fails its reader, not silently |
| 3 | `.pcrsig` prediction == the OVMF+swtpm boot's actual PCR | a changed `.cmdline` predicts *and produces* a different PCR |
| 4 | the signed-region hash matches `sbverify`; a signed UKI host-verifies | unsigned → no Certificate Table, named; tampered body fails |
| 5 | `uki-inspect`/`uki-edit` drive the loop; the edited UKI measures as predicted | a bad edit refused before re-emit |

**Open questions.** (1) PE depth — Spike 0's A/B/C, decided by the signature path. (2) Does the
lab's `ukify` emit `.pcrsig` with a dev key here, and does OVMF measure the UKI without full secure
boot? Spike 3's prerequisites. (3) Does this lab own `dsl/pe.fth` (yes) and the UEFI workbench
consume it (yes) — stated, not duplicated.
