# The UKI Workbench — a Lab Plan v1 (2026-09-14; feasibility re-measured 2026-09-16)

*Proposed **new lab**: **`uki-workbench/`**. The linuxboot lab **builds** Unified Kernel Images
with `ukify` and **boots** them under OVMF, but never **takes one apart**. This lab makes the UKI
**the subject**: read its PE structure and named sections, extract and verify each, check the
Authenticode signature and the **pre-computed TPM measurement it carries about itself**, edit a
section and watch the measurement change. It is the artifact-focused sibling of the platform-wide
[UEFI Workbench](UEFI_WORKBENCH_LAB_PLAN.md), and it is where the toolkit gains its **PE reader**
(`dsl/pe.fth`) — the format both labs need. Tracked as
[`TODO.md` §30](TODO.md#30-the-uki-workbench--the-unified-kernel-image-as-the-subject-2026-09-14).*

> **Contract pin (roadmap §2):** this workbench **consumes `{pe, cpio, bootparams}` at
> `contract v1`** — the convention in
> [`dsl/CONTRACT.md`](examples/openbios-the-rival-that-shipped/dsl/CONTRACT.md). All three
> **now conform** (`dsl/{pe,cpio,bootparams}-conform.fth`): each has `NAME-open`/`-fields`/
> `-validate`/`-manifest` with a biting negative control, graded by
> `tests/test-contract-conformance.sh`. So this workbench builds on conformant readers — a
> `.linux` section validated by `bootparams-validate`, `.initrd` walked after `cpio-open`, the
> UKI itself opened by `pe-open` — consuming any of them the same way. The remaining half is the
> **writer** surface: the in-place editor `pe-edit` now exposes `NAME-write` (Tier 2a, graded
> on a delta with a refuse-before-write control), and the **author** half `NAME-emit` now exists
> too (Tier 2b: `elf-emit`/`evlog-emit`/`fdt-emit`, graded on an emit→own-reader round trip). The
> contract's writer surface is complete; this workbench consumes readers and writers alike at `contract v1`.

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
  `pesign` (116), `llvm` (for `llvm-readobj`, 18), `poke` (**4.0**, for `pe.pk` — **measured
  2026-09-16 from the package's file list: it ships `/usr/share/poke/pickles/pe.pk`**, plus
  `poked`, and its `libpoke1` pulls `libnbd0`; so §4a's oracle is one `apt install poke` away),
  `efitools`.
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

### Dependency map — two strands, and where they meet (added 2026-09-18)

The spikes are **not one linear chain**; they are two strands that cross at exactly one point.

- **Spikes 0–2 ran in order and are BUILT.** Spike 0 (the PE-reader depth *decision*) and Spike 1
  (dissect the section table) were satisfied by [`dsl/pe.fth`](examples/openbios-the-rival-that-shipped/dsl/pe.fth)
  (#439, depth A) and its `pe` track — they never got their own tracks because the reader work *was*
  the spike. Spike 2 (grade each section by what it is) is the [`uki` track](examples/openbios-the-rival-that-shipped/README.md)
  (#443).
- **Spikes 3–4–5 are the ATTESTATION / SIGNATURE strand** — the UKI's self-predicted TPM measurement
  (`.pcrsig`), Authenticode extract-and-host-verify, and the edit-and-remeasure deliverable. **None is
  built.** They need `pe.fth` depth **B/C** (the data directories / Certificate Table), a UKI built
  with a PCR key, and an OVMF+swtpm boot — a *different theme* from rescue.
- **Spikes 6–11 are the RESCUE / MUTATION strand**, and **they build on the READERS, not on 3/4/5.**
  Built so far: **Spike 6** (`.cmdline` edit, `cmdline-edit` track, #444), **Spike 9** (initrd
  swap/append, `initrd-swap` track, #445), **Spike 10** (config-in-initrd, `config-edit` track, #446).
  Still open, each depending only on already-merged readers: **7** (bzImage `cmd_line_ptr`) →
  `bootparams.fth` (**oracle now measured 2026-09-18 — no longer deferred; see Spike 7**);
  **8-basic** (host re-emit) → `pe.fth` + `objcopy`/`ukify` (fully tooled, independent);
  **11** (capstone) ties 6/7/9/10 together. So the jump from Spike 2 to Spike 6 is intentional, not a gap.
- **The two strands meet at exactly one place: Spike 8's FULL form.** The host `uki-edit` tool's
  *basic* form (host `objcopy` rewrite of a section) is independent, but re-signing and "measures as the
  edited `.pcrsig` predicts" reach into Spike 4 (signature) and Spike 3 (the PCR key/measurement) — and
  Spike 8 **subsumes Spike 5**. So Spike 8 is where 3/4/5 would be pulled in (or a basic Spike 8 ships
  and defers the attestation loop). Everything else in the rescue arc needs nothing from 3/4/5.

### The rescue arc — editing a boot artifact: command line, initrd, config (Spikes 6–11, added 2026-09-17)

*Motivation.* The everyday reason to open a boot artifact in anger is a **rescue boot**: add
`init=/bin/bash`, `single`, `rd.break` or `systemd.unit=rescue.target` to a kernel command line
without a USB stick, a chroot, or blind line-editing in GRUB over a serial port. The readers
[`pe.fth`](examples/openbios-the-rival-that-shipped/dsl/pe.fth) (#439),
[`bootparams.fth`](examples/openbios-the-rival-that-shipped/dsl/bootparams.fth) (#440) and
[`cpio.fth`](examples/openbios-the-rival-that-shipped/dsl/cpio.fth) (#438) already *find* the
command line; this arc is about **mutating** it. The write side is not new — `struct.fth` ships
`t!`/`c!`/`t-set`, and `cbfs-write.fth`/the `rmw-fields` track already do graded in-place surgery —
so these spikes are assembly, not new primitives.

The arc grows past the command line: **swapping or appending to the initrd** (Spike 9), **editing
any section or an embedded config blob** — e.g. a broken `/etc/fstab` *inside* the initramfs
(Spike 10), and a **full rescue-scenario demo** that fails first and is rescued by these edits
(Spike 11). The ambition is deliberate: this is *"never-before-fully-explored capability, to empower
creativity and be a safety net greater than what exists today"* — held to the repo's rules, so each
capability is graded against a foreign oracle and each claim that can't be measured is marked
UNKNOWN rather than asserted.

**Both persistence modes are in scope, on purpose** — every capability below has two forms and the
demo shows each:
- **In-RAM, one-shot** — patch the loaded image (or the pointers a loader reads) at the prompt and
  jump to it; nothing on disk changes. This is the OpenFirmware/OpenBoot form (Spikes 6/7/9/10 in
  their in-firmware variant).
- **Persisted** — a modified artifact written back to disk/ESP that survives reboots. This is the
  host-tool form (Spike 8, and the persisted variants of 9/10), and it is what a UEFI x86 box uses.

**Two boundaries stated up front, so the arc is not oversold:**
- **In-firmware editing lives in the OpenFirmware/OpenBoot world** (the `ok` prompt on SPARC, old
  PowerMacs, POWER — this lab, in QEMU). It is *not* a rescue shell for a UEFI x86 laptop: OpenBIOS
  is not that machine's firmware, so the in-firmware spikes prove the *technique* and grade it in
  the OF world; the portable deliverable for a UEFI box is the **host tool** (Spike 8 and friends).
- **Growing a fixed-size region needs a re-emit.** A UKI section (`.cmdline`, `.initrd`) and a
  loaded initrd occupy a fixed extent; an in-place edit must fit the slack, and *growing* past it is
  the host tool's re-emit. The arc keeps in-place (in-RAM) and re-emit (persisted) distinct.

Build order is **6 → 7 → 8 → 9 → 10 → 11** (simplest proof first; the capstone demo last, once every
capability it stitches together exists).

### Spike 6 (#1) — in-firmware in-place `.cmdline` edit, the smallest real proof — BUILD FIRST
At the OpenBIOS prompt: `pe-find .cmdline` → overwrite the bytes in the loaded UKI **in place**
(`c!`/`t!`), e.g. append `init=/bin/bash`. **Grade:** re-read the section and confirm the new string
is there, and that a host `objcopy --only-section=.cmdline`/`objdump` sees the same bytes the firmware
wrote — the edit is real on disk-image, not just in the firmware's claim. **Control:** a write that
overruns `SizeOfRawData` is refused by name, not silently scribbled past the section. This is an
in-RAM, one-shot edit — booting the result end to end is Spike 3's OVMF loop, reused.

**MEASURED 2026-09-18 (the read contract — was an open UNKNOWN).** The systemd EFI stub reads
`.cmdline` up to **the first NUL, bounded by the section's `VirtualSize`** — *both* bounds. Foreign
oracle (systemd v255): `efi-string.c:189` `xstrn8_to_16` loops `while (n > 0 && *str8 != '\0')`, and
`pe.c:164` sets that `n` to the section's `VirtualSize` (not `SizeOfRawData`). Measured end to end
under OVMF with an AlmaLinux EFISTUB kernel, the kernel's own `Kernel command line:` line as the
oracle and the negative control biting:

| `.cmdline` shape | kernel command line |
|---|---|
| embedded NUL at byte 21, `VirtualSize`=37 | truncated at the NUL (`console=ttyS0 Q5AAA=1`) |
| grown past `VirtualSize`, header **not** bumped | grown text **absent** (bounded by `VirtualSize`) |
| grown, `VirtualSize` bumped to cover it | grown text **present** |

**Consequence for this spike (a correction to the earlier draft):** `ukify` emits `.cmdline` with
`VirtualSize` == the exact string length, **no NUL and no slack** — the `SizeOfRawData`=512 padding is
**invisible to the stub**, so "append within the section's slack" is wrong. A same-length or shorter
replacement works in place with a NUL terminator (the NUL truncates the tail). **Growing the command
line requires bumping the section header's `VirtualSize`** (`pe.fth`'s section fields `t!` it), and the
overrun to refuse is against `VirtualSize`/`SizeOfRawData`, not a mythical slack.

### Spike 7 (#3) — the bzImage `cmd_line_ptr` seam, the classic-kernel rescue path — ORACLE MEASURED 2026-09-18
Not every rescue target is a UKI. A plain `kernel + initrd` boot reads its command line from the
boot_params field `cmd_line_ptr` (u32 @ `0x228`), which `bootparams.fth` already reads. This spike
**writes the buffer that pointer names**.

**The obstacle, named precisely — and why it stalled the spike.** `cmd_line_ptr` is a *runtime* field:
it is **zero in the on-disk bzImage** (the live `bootparams` fixture reads `cmdline_ptr=0`). Only a
*bootloader* ever sets it, and it sets it in RAM. So there is no foreign on-disk decoder to grade the
edit against, and minting the zero-page ourselves and reading it back would be a **round trip that hides
a symmetric offset error** (the repo's rule). That, precisely, was the deferral.

**Resolved — a foreign, non-round-trip oracle, measured 2026-09-18.** QEMU's own `-kernel` loader *is* a
real, independent bootloader that sets `cmd_line_ptr`. Boot the real bzImage under
`qemu-system-x86_64 -kernel … -append "<sentinel>"`, let the guest's `linuxboot` option ROM run ~0.15 s
(**measured stable through 1.0 s** — a wide window, not a race), QMP `stop`, and `pmemsave` guest
**physical memory from 0**. Measured: a genuine `boot_params` lands at phys `0x10000` — found by
*scanning* for the reader's own anchors (`boot_flag`=0xAA55 @ +0x1fe **and** `HdrS` @ +0x202), never a
hard-coded address — with `cmd_line_ptr=0x20000` pointing at the exact `-append` string and
`cmdline_size=0x7ff`. Because the dump is **physical-0-indexed, `cmd_line_ptr` is a direct offset into
it**: `bootparams.fth`'s `bp-cmdline-ptr t@` followed as an absolute offset lands on the string with **no
pointer rebasing**, so the one fidelity compromise is gone. QEMU authored the pointer *and* the buffer;
the reader and the oracle are different programs.

**7a — read · edit · read-back (BUILDABLE, faithful).**
- *Fixture* (`fixtures/cmdline-ptr/`, derived at run time, self-SKIP without a QEMU + a bzImage): the
  freeze-and-dump above, sliced to phys `0..0x21000` (~132 KiB — carries boot_params @ 0x10000 through
  the cmdline buffer @ 0x20000, and fits the firmware load window) plus the sentinel string it must hold.
- *New words* (`dsl/bootparams-edit.fth`, on `struct.fth`, matching the `pe-edit`/`cpio-edit` shape):
  `bp-cmdline ( -- adr len | 0 0 )` follows `cmd_line_ptr` into the image and returns the NUL-terminated
  string; `bp-cmdline-set ( new-adr u -- ok? )` overwrites it in place, NUL-terminating and refusing **by
  name** (`bp| CMDLINE-TOO-BIG`) a line longer than `cmdline_size` (u32 @ 0x238). In-place, same slot —
  the rescue edit (`init=/bin/bash`, `single`, `rd.break`) is *shorter* than the original, so it fits.
- *Grade:* `bp-cmdline` returns the sentinel (oracle = the string handed to `-append`, foreign, not a
  round trip); after `bp-cmdline-set`, `bp-cmdline` returns the new line **and** the host re-reads it by
  an independent python `struct` decode of the written-back dump's `cmd_line_ptr`. Four-arch — the field
  is LE, so ppc earns its keep exactly as in `bootparams.fth`.
- *Control:* a line longer than `cmdline_size` (0x7ff) refused by name, the buffer **unchanged** after.

**7b — the runtime contract (MEASURED 2026-09-18; the boundary is now precise, not a blanket UNKNOWN).**
That a kernel *booted* with the edited line shows it splits into two questions, and the split is the
finding:

- **The boot-*line* reaches the kernel — MEASURED.** Booting Linux through this lab's OpenBIOS with a
  marker on the boot line (`boot …:\v console=ttyS0 S7B=rescue initrd=…`), the **kernel itself** prints
  `Kernel command line: console=ttyS0 S7B=rescue` and `Unknown kernel command line parameters
  "S7B=rescue", will be passed to user space` — i.e. the marker reached the kernel's command line
  (`Kernel command line:` is exactly what `/proc/cmdline` exposes). The path is `linux_load()` →
  `parse_command_line(cmdline, COMMAND_LINE_LOC=0x91000)` → `set_command_line_loc` sets
  `cmd_line_ptr = 0x91000` (`arch/x86/linux_load.c:685-686`, protocol ≥ 0x202). `initrd=` is stripped by
  the loader as the initrd filename, standard.
- **A firmware-*prompt* edit of the LIVE `cmd_line_ptr` does NOT reach the kernel — structural, from the
  loader source.** `linux_load()` builds the 0x91000 buffer and sets `cmd_line_ptr` from the boot-line
  string at `boot` time, then jumps to the kernel with **no return to the `0 >` prompt**. There is no
  prompt window in which the live buffer exists and control is at the prompt, so `bootparams-edit.fth`
  (Spike 7a) necessarily edits a **foreign captured `boot_params` dump**, not the live boot — which is
  exactly what it does. Lifting this would require a **loader hook** (patch `linux_load` to consult a
  Forth-editable buffer, or to drop to the prompt after `parse_command_line` and before the jump) — a
  firmware change, not available today. That, not "unknown whether it reaches," is the honest boundary.

The runtime loop our *edit* closes is the UKI `.cmdline` path — Spike 6 under OVMF, where the edit is a
section the stub re-reads (Q5 above) — not the classic-bzImage prompt path. Spike 7 proves the
classic-BIOS *technique* on a foreign dump, grades it against a foreign oracle, and now names precisely
what it cannot boot and why.

### Spike 8 (#2) — the host-side `uki-edit` rescue tool, the deliverable — TWO FORMS (toolchain measured 2026-09-18)
The portable *"produce a rescue image without a chroot"* tool, and the rescue framing of Spike 5. This is
the **one place the rescue strand touches the attestation strand** (dependency map), so it splits cleanly
along that seam — and the split is what lets the rescue deliverable ship without waiting on 3/4/5.

**8-basic — the rescue deliverable, buildable now (no attestation dependency).** `objcopy`/`ukify`
rewrite `.cmdline` — **growing it past the in-place slack** the in-RAM Spike 6 cannot — re-lay the
sections, and emit a patched UKI to drop on the ESP: a change that *persists* across reboots, which the
in-RAM edits (6/7) deliberately do not. This is what a UEFI x86 box actually uses, since it cannot run
the firmware-side edit. Toolchain **measured present 2026-09-18**: `objcopy`, `objdump`, `ukify`,
`sbsign`, `sbverify`, `cpio`, `genisoimage`. **Grade:** the re-emitted UKI's `.cmdline` reads back correct
under **both** `pe.fth` (the lab's reader) **and** `objdump -h` / `objcopy --dump-section` (foreign) — two
decoders, one section. **Control:** an edit that would break the PE (a section overlap, a size past the
file, a bad section count) is refused **before** re-emit, not written out broken. For a non-secure-boot
rescue box this ships **unsigned** and is complete; re-signing is the bridge to 8-full. Needs nothing
from Spikes 3/4/5.

**8-full — re-sign + measures-as-predicted (gated behind the attestation strand 3→4→5).** Additionally
`sbsign` re-signs the re-emitted UKI (verified by `sbverify`), and `systemd-measure` (**present** at
`/usr/lib/systemd/systemd-measure`, off-PATH) predicts the post-edit PCR, proved against an OVMF+swtpm
boot (both present). This reaches into **Spike 3** (a UKI built *with* a PCR key + `.pcrsig` — today's
`build-uki.sh` passes none, §7 open-Q2, so this is a *fixture change, not a tool gap*) and **Spike 4**
(Authenticode extract-and-host-verify). So 8-full is where 3/4/5 are pulled in, and **Spike 8 subsumes
Spike 5**. **Grade:** the re-signed UKI host-verifies (`sbverify`), boots under OVMF (Spike 3's loop), and
produces the *new* measurement the edited `.pcrsig` predicts. **Control:** a re-emit whose `.pcrsig` no
longer matches the measured PCR is refused / flagged, not shipped as "attested".

Build order: **8-basic is buildable immediately** (fully tooled, independent); **8-full waits on the
attestation strand** — a different theme and a larger build (a PCR-keyed UKI, an OVMF+swtpm PCR read). The
rescue arc needs only 8-basic; 8-full is the attestation payoff.

### Spike 9 — swap or append to the initrd, in RAM and persisted
This realizes the [firmware-edits note](DESIGN-NOTES-the-firmware-edits-the-boot-it-makes.md)'s
**§2.2 `initrd-append`** seam — a `cpio.fth` consumer named there and now buildable. Two operations,
each in both persistence modes:
- **Append a file** (drop a rescue tool / a fixed config into the initramfs). The clean mechanism is
  the kernel's own: it unpacks **concatenated** cpio archives (this is exactly how CPU-microcode
  early-initrd works), so appending needs no rewrite of the existing archive — build a *small* newc
  cpio holding the one new member and concatenate it. `cpio.fth` walks the result to prove both the
  old members and the new one are present, in order, and refuses a malformed join by name.
  - *In-RAM:* concatenate in the loaded image and boot it (bzImage world: extend the `ramdisk_size`
    the kernel unpacks; UKI world: within the `.initrd` section's slack).
  - *Persisted:* the host builds the one-member cpio (`printf … | cpio -o -H newc`) and appends it,
    or re-emits the UKI's `.initrd` (Spike 8's `objcopy`/`ukify`). The *ambitious* in-firmware
    variant is a minimal `cpio-emit` word (a newc writer — 13 ASCII-hex fields, a name, 4-aligned);
    named here as a stretch, not assumed.
- **Swap the whole initrd** (boot a known-good rescue initramfs). bzImage world: load a different
  initrd into memory and point `ramdisk_image`/`ramdisk_size` (u32 @ `0x218`/`0x21c`, via
  `bootparams.fth`) at it — in-RAM, one-shot, and a genuinely strong rescue move. UKI world: replace
  the `.initrd` section (in-place if it fits, else the host re-emit).
**Grade:** `cpio.fth` walks the swapped/appended initrd and finds the new member; on a boot-capable
arch, the booted system shows the appended file present (e.g. `/rescue.sh` exists) or the swapped
rescue initramfs reaches its shell — `/proc` / the running system is the ground truth, not the
firmware's read-back. **Control:** an append that overruns the ramdisk window (or the section slack)
is refused by name, not concatenated past the end.

### Spike 10 — edit any section, or a config blob *inside* the initrd (the "deeper" edit)
The same read → mutate → (in-place | re-emit) discipline, aimed past `.cmdline` at **any** named
section or embedded blob. The headline rescue use is the one that today needs a full USB-and-chroot:
**fix a broken config that is blocking boot — a bad `/etc/fstab`, `/etc/crypttab`, a wrong
`root=UUID`, a misfired systemd unit — while it sits *inside the initramfs*.** `cpio.fth`'s
`cpio-find` already returns that file's bytes; a **same-length** in-place edit (comment a line out
with `#`, flip `ro`→`rw`, blank a UUID) is a `c!` loop and needs no rebuild; a length change is the
host re-emit. Other targets fall out for free: a UKI's `.osrel`/`.uname`, and — through the existing
[`cbfs-write.fth`](examples/openbios-the-rival-that-shipped/dsl/cbfs-write.fth) — a **coreboot CBFS
config**, the same idea one firmware layer down. **Grade:** the host re-parses the edited blob
(`cpio -i` extracts the file and it holds the new bytes; `objdump` for a section) — the edit is real
outside the firmware's own claim. **Control:** an edit whose new length ≠ old is refused in the
in-place path (it must go through the re-emit), and an edit that would corrupt the container's own
structure (a cpio header, a section table) is refused by name before it is written.

### Spike 11 — the capstone: a full rescue scenario, failing first, then rescued
The demo that ties the arc together and shows the safety net working end to end. A boot artifact is
**deliberately broken** so the machine does **not** come up — a kernel `root=` pointing nowhere, or
an `/etc/fstab` in the initramfs with a bad mount that hangs the boot. The operator then, *without a
USB stick or a chroot*, uses the toolkit to rescue it, three ways the demo walks in turn:
1. **cmdline** — add `rd.break` / `init=/bin/bash` (Spikes 6/7) to reach a shell;
2. **config** — fix the offending line in the initramfs config in place (Spike 10);
3. **initrd** — append a rescue script, or swap in a known-good rescue initramfs (Spike 9),
each shown **in-RAM** (patch the loaded image at the OF prompt and boot) *and* **persisted** (the
host tool writes a fixed artifact to the ESP/disk that survives a reboot). **The negative control is
the point, not an afterthought** (the repo's rule): the demo first shows the *un-edited* artifact
genuinely failing to boot — a recorded failure signature — so that reaching the rescue shell after
the edit proves the edit is what rescued it, and not that it would have booted anyway. **Success
signature:** the broken boot fails with its named signature; each edited boot reaches a rescue shell
whose `/proc/cmdline` (or a marker file / the fixed mount) shows exactly the change made; the
persisted artifact reproduces the rescue across a power-cycle.

**STARTED 2026-09-18 — measured anchors and one design constraint discovered (all on this lab's
OpenBIOS bzImage path, `payload-bzImage` + `uroot.cpio`):**
- **The negative control is real and named — MEASURED.** Booting with **no initrd** panics with
  `Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)` (preceded by
  `VFS: Cannot open root device "(null)" … error -6`). Supplying the good initrd
  (`initrd=/ide@1/cdrom@0:\u`) rescues it to `Welcome to u-root!`. That is the **initrd** rescue's
  break/rescue pair, ready to build.
- **Design constraint — an `init=` break does NOT fail with an initramfs.** `init=/nonesuch` was
  measured to fall through to `Run /init as init process` (the kernel's initramfs default) and u-root
  booted anyway — so a bad-`init=` cmdline break is silently rescued by the kernel and is **not** a
  valid negative control here. The genuine **cmdline** rescue therefore belongs to the **UKI
  `.cmdline`** path under OVMF (Spike 6, where the stub re-reads the section per Q5's read contract),
  not the classic bzImage prompt. The classic-kernel rescue narrative is the boot-**line** (7b: it
  reaches the kernel) plus the **config** (Spike 10) and **initrd** (above) paths.
- **The cmdline-grow mechanics are settled by Q5:** growing a UKI `.cmdline` needs the section's
  `VirtualSize` bumped (no slack); a same-or-shorter rescue param works in place with a NUL.
- **Next to build:** a narrated `showcase-rescue.sh` (sibling of `showcase-preboot-toolkit.sh`) + a
  one-verdict `smoke-openbios.sh` track, walking the three break→fail→rescue pairs (cmdline via the
  UKI/OVMF loop; config via `cpio-edit.fth`; initrd via the VFS-panic pair above), each in-RAM and
  persisted, each with its unedited artifact failing first.

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
| 6 (#1) | `pe-find .cmdline` edited in place; `objcopy`/`objdump` see the firmware's new bytes | a write past `SizeOfRawData` refused by name, not scribbled past the section |
| 7 (#3) | the buffer `cmd_line_ptr` names holds the new line; the booted kernel's `/proc/cmdline` shows it | a line longer than `cmdline_size` refused by name |
| 8 (#2) | `uki-edit` re-emits + re-signs a persistent patched UKI; it boots and measures as predicted | a PE-breaking edit refused before re-emit |
| 9 | `cpio.fth` walks the swapped/appended initrd; the booted system shows the new member | an append past the ramdisk window / section slack refused by name |
| 10 | the edited config/section reads back correct under a host re-parse (`cpio -i`/`objdump`) | a length-changing in-place edit, or one that corrupts the container, refused by name |
| 11 | the broken boot fails with its named signature; each edited boot reaches a rescue shell showing the change; the persisted artifact survives a power-cycle | the *un-edited* artifact must fail first — no negative control, no proof the edit rescued anything |

**Open questions.** (1) PE depth — Spike 0's A/B/C, decided by the signature path. (2) ~~Does the
lab's `ukify` emit `.pcrsig` with a dev key here, and does OVMF measure the UKI without full secure
boot?~~ **Answered 2026-09-16 (§3):** ukify 255 + `systemd-measure` are on the host and *can*, but
`build-uki.sh` passes no PCR key so today's UKI has no `.pcrsig` — one flag pair away; and OVMF
measures a directly-booted PE app into PCR4 with no secure boot (one
`EV_EFI_BOOT_SERVICES_APPLICATION` in the fixture's log). Still unmeasured: the rebuilt UKI itself
(none is on disk). The `poke` package question is closed — it ships `pe.pk` (measured from the
package's file list, see §3). (3) Does this lab own
`dsl/pe.fth` (yes) and the UEFI workbench consume it (yes) — stated, not duplicated. (4) **New:**
`cpio.fth` is a prerequisite nobody had written down — this lab builds it (Spike 2), the fs note
cites it. (5) **Resolved 2026-09-18 (was: does the stub read `.cmdline` to `VirtualSize` or the first
NUL?).** **Both bounds: up to the first NUL, bounded by `VirtualSize`.** Foreign oracle systemd v255
(`efi-string.c:189` `while (n>0 && *str8!='\0')`, `n`=`VirtualSize` from `pe.c:164`) and measured end to
end under OVMF with the negative control biting (see Spike 6). `ukify` emits `VirtualSize` == exact
string length with **no NUL and no slack**, so **growing the command line requires bumping the section's
`VirtualSize`** — the `SizeOfRawData` padding is invisible to the stub; a same-or-shorter replacement
works in place with a NUL terminator. (6) The rescue arc's honest boundary is stated in §5: in-firmware editing is
the OpenFirmware/OpenBoot world (Spikes 6–7, in-RAM, one-shot); the UEFI-x86 deliverable is the
host tool (Spike 8, persisted to the ESP). (7) **Resolved 2026-09-18 (Spike 7):** the "no clean on-disk
oracle for `cmd_line_ptr`" deferral is lifted — QEMU's `-kernel` loader, frozen just after its
`linuxboot` ROM runs and dumped from physical 0 (QMP `pmemsave`), is a *foreign* producer of a real
`boot_params` (measured: `boot_params`@0x10000, `cmd_line_ptr=0x20000`→the `-append` string,
`cmdline_size=0x7ff`, stable 0.15–1.0 s). **7b resolved 2026-09-18 — the boundary is now precise, not a
blanket UNKNOWN:** the boot-*line* cmdline **does** reach the booted kernel (measured — with a marker on
this lab's OpenBIOS `boot` line the kernel prints `Kernel command line: … S7B=rescue` and `Unknown kernel
command line parameters "S7B=rescue", will be passed to user space`); what is structurally *not*
available is a firmware-*prompt* edit of the live `cmd_line_ptr` reaching the kernel — `linux_load()`
(`arch/x86/linux_load.c:685`) builds the 0x91000 buffer from the boot line at `boot` and jumps with no
prompt re-entry, so Spike 7a edits a foreign dump by necessity and closing the loop would need a loader
hook (see Spike 7b block). (8)
Spike 8 splits at the strand seam: **8-basic** (host re-emit, fully tooled 2026-09-18) ships the rescue
deliverable now; **8-full** (re-sign + measures-as-predicted) waits on the attestation strand 3→4→5.
