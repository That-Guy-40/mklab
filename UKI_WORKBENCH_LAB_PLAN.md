# The UKI Workbench — a Lab Plan v1 (2026-09-14; feasibility re-measured 2026-09-16)

*Proposed **new lab**: **`uki-workbench/`**. The linuxboot lab **builds** Unified Kernel Images
with `ukify` and **boots** them under OVMF, but never **takes one apart**. This lab makes the UKI
**the subject**: read its PE structure and named sections, extract and verify each, check the
Authenticode signature and the **pre-computed TPM measurement it carries about itself**, edit a
section and watch the measurement change. It is the artifact-focused sibling of the platform-wide
[UEFI Workbench](UEFI_WORKBENCH_LAB_PLAN.md), and it is where the toolkit gains its **PE reader**
(`dsl/pe.fth`) — the format both labs need. Tracked as
[`TODO.md` §30](TODO.md#30-the-uki-workbench--the-unified-kernel-image-as-the-subject-2026-09-14).*

> **Re-measured 2026-09-16, against the linuxboot lab's scripts, the host, and the edk2/swtpm
> fixture.** The thesis holds and the tooling is nearly all on the host. Three corrections:
> **(1) no UKI exists on disk today** — `~/linuxboot-lab` has neither the `vmlinuz`/`initramfs.cpio`
> inputs nor any `.efi`; the subject is rebuilt before Spike 1; **(2) `.pcrsig` is not emitted
> by the current `build-uki.sh` and cannot be** — it passes no `--pcr-private-key`/`--pcr-public-key`,
> which is what makes ukify write `.pcrsig`/`.pcrpkey` (ukify 255 and `systemd-measure` are both
> present, so it is one flag pair away; the WALKTHROUGH's "add `.pcrsig`" is a doc claim the
> artifact does not bear); **(3) the `cpio.fth` reader Spike 2 names does not exist** — it is a
> small prerequisite, not a dependency. Measured ✅: OVMF measures a directly-booted PE app into
> PCR4 with **no** secure boot (one `EV_EFI_BOOT_SERVICES_APPLICATION` event in the fixture's log),
> and every oracle is present or one `apt` away. §3 carries the rows.

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

## 3. Verified feasibility (measured 2026-09-16)
- **UKIs are built and booted here — the scripts, ✅; the artifact, absent.**
  `linuxboot-uefi-kexec/build-uki.sh` builds `uki-shell.efi` / `uki-kexec.efi` (+ their ESPs) into
  `$WORKDIR`, and `run-uefi-linuxboot.sh` boots them under `OVMF_CODE_4M.fd` (pflash unit 0,
  `readonly=on`) with a per-run copy of `OVMF_VARS_4M.fd`. But **`~/linuxboot-lab` holds no
  `.efi` today, nor the `vmlinuz`/`initramfs.cpio` it is built from** — the earlier artifacts were
  reclaimed. Spike 1's first act is the rebuild chain (`fetch-kernel.sh` → `build-uroot.sh` →
  `build-uki.sh`). The stub is on the host (`/usr/lib/systemd/boot/efi/linuxx64.efi.stub`,
  68 608 bytes), and so is `ukify 255` (`255.4-1ubuntu8.17`).
- **`.pcrsig`/`.pcrpkey` are NOT in the UKI this script builds — answered, and it is the
  script, not the tool.** `build_uki` passes exactly `--linux --initrd --cmdline --os-release
  --stub --output`; ukify writes `.pcrsig` only when given `--pcr-private-key`/`--pcr-public-key`
  (optionally `--phases`), and it needs `systemd-measure` to compute the prediction — which **is**
  installed (`/usr/lib/systemd/systemd-measure`). So Spike 3's subject is one flag pair and one
  generated keypair away, and `WALKTHROUGH.md:122`'s "add `.uname`/`.sbat`/`.pcrsig` sections" is
  a doc claim the artifact does not bear until then (fix it when the lab lands). `.uname` and
  `.sbat` ukify adds on its own (from the kernel and the stub) — believed, **verify on the rebuilt
  artifact** with `objdump -h`.
- **OVMF measures a PE application into PCR4 without secure boot — ✅ measured.** The
  [`edk2-swtpm`](examples/openbios-the-rival-that-shipped/fixtures/edk2-swtpm/README.md) capture
  (plain OVMF, no enrolment) holds exactly **one `EV_EFI_BOOT_SERVICES_APPLICATION`** event — the
  kernel's EFI stub, direct-booted. A UKI is the same event kind (it *is* an EFI application), so
  Spike 3's "actual PCR" exists without secure boot. *That fixture booted a bare kernel, not a
  UKI* — the UKI leg itself is unmeasured until the artifact is rebuilt.
- the toolkit reads typed binaries against a foreign oracle — **✅** (ELF/CBFS/FDT); **PE is new**
  and, per the roadmap's arch axis, its manifest says **`ARCH: x86-only`** (the family's PE
  subjects are x86-64 `.efi`; an aarch64 UKI under AAVMF is possible — the host has it — but is a
  door this family has not opened).
- **Oracles, measured on the host:** present — `ukify`, `systemd-measure`, `systemd-dissect`,
  `sbverify`, `sbsign`, `objdump`, `objcopy`, `mtools`, `swtpm`, `tpm2_eventlog`. One `apt` away —
  `pesign` (116), `llvm` (for `llvm-readobj`, 18), `poke` (**4.0**, for `pe.pk`; whether the
  Debian package ships the pickle is UNMEASURED — check `dpkg -L poke | grep pe.pk` before relying
  on §4a), `efitools`.
- **`cpio.fth` does not exist.** Spike 2 grades `.initrd` with "the `cpio.fth` reader" as if it
  were built; the `dsl/` has no cpio walker and the fs note's tiers cover ext/FAT/ISO, not cpio.
  A `newc` walker is the TLV shape `struct.fth`'s cursor was made for (a 110-byte ASCII header,
  then name, then data, each 4-aligned) — a small prerequisite, named here so Spike 2 does not
  discover it.

## 4. Why this and not a hosted tool
`objdump` prints sections and `sbverify` checks a signature **on the host**; neither is **the
firmware reading a UKI's structure**, and — the uniquely-afforded thing — neither closes the loop
between the UKI's **self-predicted** measurement (`.pcrsig`, computed at build) and the **actual**
measurement an OVMF boot produces. Reading the prediction, booting, and checking it came true is a
round trip across build-time and boot-time that no single hosted tool spans.

### 4a. The PE oracle: GNU poke's `pe.pk`
GNU poke ships a complete PE/COFF model, [`pickles/pe.pk`](https://git.savannah.gnu.org/cgit/poke.git/tree/pickles/pe.pk)
(José E. Marchesi, GPLv3-or-later), and it earns a place here for the same reason `objdump` does:
a **foreign, independently-authored oracle**. It is used **on the host only** — it is *not* vendored
into the firmware. That is a license fact, not a preference: OpenBIOS is GPLv2-**only** (no "or
later"), the exact incompatibility the [modern-filesystems note](DESIGN-NOTES-modern-filesystems-for-a-frozen-firmware.md)
worked through for GRUB 2, so a GPLv3 body cannot be lifted into the frozen image. On the host,
beside `objdump`, it is unencumbered — a `poke -L check.pk uki.efi` that dumps the same structure
the Forth reader claims to see.

Reading it against our sketch **confirms two things and sharpens five**, and every one of the five
is a reader requirement or a control:

- **Confirmed.** The PE entry is the 4-byte offset at `0x3C`, then the literal `['P','E','\0','\0']`
  at that offset (Spike 1's control is right); the Certificate Table is data-directory index **4**
  (Spike 0's depth-B/C target is the right entry).
- **Locate the section table by `SizeOfOptionalHeader`, never by walking to the end of the parsed
  optional header.** `pe.pk` places sections at `opt_hdr_offset + hdr.opthdr` and warns in-comment
  that the parsed optional header may not match that size. A reader that computes the section offset
  by struct-walking will drift on a real image — this is "assert the outcome, not the mechanism" in
  PE form, and it becomes a **named control**: a UKI whose `SizeOfOptionalHeader` exceeds its parsed
  optional header still yields the right section table.
- **PE32 vs PE32+ is a union discriminated on the optional-header magic** (`0x10b` vs `0x20b`).
  UKIs and x86-64 `.efi` apps are PE32+; `image_base` and the stack/heap sizes change width, so
  every later field offset depends on the magic. Spike 0's depth ladder names the magic as the
  discriminator, decided before any field past it is trusted.
- **The data-directory count is variable** (`num_of_rva_and_sizes`) — do not hardcode 16. A reader
  assuming a fixed count reads garbage on a lean image; the count is read, then indexed.
- **Attribute certificates are 8-byte aligned** (`pe.pk` pads each entry to `alignto(length, 8)`).
  Spike 4's cert walk needs that or it desynchronizes across a multi-certificate file.
- **The Authenticode signed region excludes exactly the optional-header `checksum` field and the
  Certificate Table data-directory entry** — `pe.pk` pins both locations, which is precisely what
  Spike 0 option **C** needs for the signed-region hash to agree with `sbverify`.

**The largest win is that `pe.pk` is a validity catalog.** Its constraint expressions enumerate what
a *valid* PE satisfies — `file_alignment` a power of two in `[512B, 64KB]` and `<= section_alignment`,
`size_of_image % section_alignment == 0`, `size_of_headers % file_alignment == 0`, the reserved
directories zeroed. Those map straight onto this lab's read/**validate**/edit theme: each is a
value the editor (Spike 5) must preserve or refuse, and each is a negative control that must bite
(feed the reader a PE that violates it and watch the refusal name the invariant). We lift the list;
we do not lift the code.

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
only along the signature path. Measure the PE against `objdump -h` and poke's `pe.pk` (§4a) before
trusting a byte — and **read the optional-header magic first** (PE32 vs PE32+), since every field
offset past it depends on the answer, and a UKI is PE32+.

### Spike 1 — dissect: the section table, against the oracle
`dsl/pe.fth` lists every section (name/vaddr/size/offset) matching `objdump -h`/`llvm-readobj`;
the UKI-specific sections are found by name. The section table is located by the file header's
`SizeOfOptionalHeader` (per §4a), not by walking to the end of the parsed optional header.
**Controls:** a flipped `PE\0\0` signature or a section count past the header is refused by name;
a UKI whose `SizeOfOptionalHeader` exceeds its parsed optional header still yields the right
section table (the drift `pe.pk` warns about); the counts equal the oracle exactly.

### Spike 2 — extract, and grade each section by what it is
Pull each section and grade it against its *own* nature: `.linux` is an EFISTUB kernel (its PE/ELF
magic checks; the `elf-gate`/`?bootparams` readers already know these); `.initrd` is a cpio the
`cpio.fth` reader walks (**to be written first — it does not exist**, §3; a `newc` walker on the
struct.fth cursor); `.cmdline` is the string (compared to what the boot's `/proc/cmdline`
shows); `.osrel` parses as `os-release`; `.uname` is the kernel version (`== .linux`'s built
version). **Control:** a section extracted with the wrong length fails its own reader, not silently.

### Spike 3 — the UKI's self-prediction: `.pcrsig` vs. the real boot
**Prerequisite (measured 2026-09-16):** the UKI must be built with `--pcr-private-key` /
`--pcr-public-key` (a lab-generated keypair) so ukify writes `.pcrsig`/`.pcrpkey` at all — the
current `build-uki.sh` does not, and `systemd-measure` (present) is what ukify calls to compute
the prediction. Read `.pcrpkey` (the public key) and `.pcrsig` (the **signed, pre-computed** PCR
values the boot should produce, per phase). Then **boot the UKI under OVMF+swtpm** and read the guest's actual PCR
(the edk2-swtpm capture shape). **The prediction must equal the measurement** — the UKI told the
truth about what it would measure to. **Controls:** `ukify --measure` on the host agrees with the
firmware's read of `.pcrsig` (the section decoded right); and a UKI with **one byte of `.cmdline`
changed** predicts a *different* PCR and produces that different PCR at boot — the prediction
tracks the artifact. This is the attested-boot capstone's measurement, **pre-computed and carried
inside the file**, and it is the single richest thing in the lab.

### Spike 4 — the signature: extract in firmware, verify on host
Reach the Certificate Table (Spike 0(C)); the firmware hashes the **signed region** — the PE minus
the two fields `pe.pk` pins (§4a): the optional-header `checksum` and the Certificate Table
data-directory entry — and reads the PKCS#7 blob (attribute-certificate entries walked with the
8-byte alignment `pe.pk` encodes); the **host** (`sbverify`/`pesign`) verifies the blob against a
dev cert — the ELF-gate's *"measure in the firmware, anchor on the host"* split, because a full
X.509 chain in Forth is out of scope and saying so is the honesty. **Controls:** the signed-region
hash equals `sbverify`'s idea of it (the exclusions are exactly right); an unsigned UKI has no
Certificate Table (refused by name); a re-signed UKI verifies; a tampered body fails the host verify.

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

**Open questions.** (1) PE depth — Spike 0's A/B/C, decided by the signature path. (2) ~~Does the
lab's `ukify` emit `.pcrsig` with a dev key here, and does OVMF measure the UKI without full secure
boot?~~ **Answered 2026-09-16 (§3):** ukify 255 + `systemd-measure` are on the host and *can*, but
`build-uki.sh` passes no PCR key so today's UKI has no `.pcrsig` — one flag pair away; and OVMF
measures a directly-booted PE app into PCR4 with no secure boot (one
`EV_EFI_BOOT_SERVICES_APPLICATION` in the fixture's log). Still unmeasured: the rebuilt UKI itself
(none is on disk), and whether the `poke` Debian package ships `pe.pk`. (3) Does this lab own
`dsl/pe.fth` (yes) and the UEFI workbench consume it (yes) — stated, not duplicated. (4) **New:**
`cpio.fth` is a prerequisite nobody had written down — this lab builds it (Spike 2), the fs note
cites it.
