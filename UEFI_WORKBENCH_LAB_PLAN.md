# The UEFI Workbench — a Lab Plan v1 (2026-09-14)

*Proposed **new lab**: **`uefi-workbench/`**. Where the [coreboot ROM workbench](COREBOOT_ROM_WORKBENCH_LAB_PLAN.md)
makes coreboot the subject, this makes **UEFI the subject** — the platform this repo already runs
(OVMF/edk2) but has only ever *used*, never *dissected*. The unusual thing about UEFI is that it is
**not one artifact but a set of interfaces and formats**, and nearly every one of them is a theme
the design notes already developed: PE/COFF is the [UKI workbench](UKI_WORKBENCH_LAB_PLAN.md)'s
format, the ESP is the [filesystem notes](DESIGN-NOTES-modern-filesystems-for-a-frozen-firmware.md)'
FAT, EFI variables are the [store notes](DESIGN-NOTES-the-firmware-edits-the-boot-it-makes.md)'
backing store, secure boot is the [coreboot verified-boot](COREBOOT_VERIFIED_BOOT_LAB_PLAN.md) trust
theme, and the config tables are the [FCode notes](DESIGN-NOTES-fcode-option-roms.md)' "reach Linux
through a firmware-authored tree." **UEFI is where the whole family converges.** Tracked as
[`TODO.md` §31](TODO.md#31-the-uefi-workbench--the-platform-where-the-family-converges-2026-09-14).*

---

## 1. Why — and the honest scope up front

UEFI is a **platform interface**, not a program: a firmware (OVMF/edk2) that exposes services (boot
+ runtime), consumes formats (PE/COFF apps on a FAT **ESP**), keeps state (**EFI variables** in
NVRAM), enforces a trust policy (**secure boot**: PK → KEK → db/dbx), runs a **boot manager**
(BootOrder / Boot####), and hands the OS a set of **tables** (the memory map, ACPI, SMBIOS, a
device tree). This lab builds **as much of a workbench for each of those as QEMU/OVMF honestly
allows**, each piece graded against the standard host tool. It is broad on purpose — the value is
seeing that *one platform ties every note together* — and it says at each seam how much is real on
QEMU versus real only on hardware.

## 2. Thesis & scope

**Thesis.** Make UEFI the subject and it decomposes into exactly the structures this repo already
reads and writes — a filesystem, a variable store, a signed executable, a key hierarchy, a set of
handoff tables — so the toolkit that reads ELF/CBFS/FDT/PE can read the whole platform, each part
against its own oracle (`efivar`, `sbsign`, `efibootmgr`, `dmidecode`, `dtc`, `objdump`).

**In scope, one spike per interface** (§5): the **ESP** (a FAT filesystem — the fs readers,
already planned, pointed at the real boot medium); **EFI variables** (efivarfs in the guest, the
OVMF `VARS` pflash from outside — the store table's UEFI row); **PE/COFF** apps (the UKI lab's
`dsl/pe.fth`, generalised to any `.efi`); **secure boot** (enrol dev PK/KEK/db, sign an app, boot
signed vs. unsigned — the verified-boot theme in UEFI's own mechanism); the **boot manager**
(BootOrder/Boot#### as structured variables); and the **handoff tables** (the memory map, ACPI,
SMBIOS, and the **device-tree config table** — the FCode note's "UEFI as the third firmware").

**Out of scope (hard):** writing an edk2 driver in C (this reads/exercises the platform, it does
not extend the firmware); a real secure-boot key hierarchy (dev keys, said so); hardware-anchored
variable protection (OVMF's NVRAM is a file, so "authenticated variables" prove the *logic*, not
the *unbypassable* enforcement — the verified-boot lab's HW-ANCHOR: UNKNOWN caveat, here for
variables).

### 2b. Why its own lab, and the seam vs. the UKI lab (LOCKED)
- **Artifact vs. platform.** The [UKI lab](UKI_WORKBENCH_LAB_PLAN.md) dissects one *file*; this
  exercises the *platform* that loads it. A UKI is a UEFI application, so the UKI lab is the
  flagship subject *inside* this one — but its tight, single-file story would be lost if folded
  into a platform survey, and this platform survey would never finish if it had to first fully
  dissect a UKI. Two labs, one shared `dsl/pe.fth`.
- **It is the convergence lab, and that is the point.** Every other note owns one theme; this shows
  them as facets of one platform. That framing is a deliverable, not a side effect.

## 3. Verified feasibility (to check before writing)
- OVMF runs here with a writable variable store — **✅** (`run-uefi-linuxboot.sh`: `OVMF_CODE_4M.fd`
  read-only + a per-run `OVMF_VARS_4M.fd`); the guest boots a UKI off a FAT ESP — **✅**.
- OVMF measures into a TPM — **✅** (edk2-swtpm fixture).
- oracles present or one `apt` away: `efivar`/`efibootmgr` (variables + boot manager, in the
  guest), `sbsign`/`sbverify`/`cert-to-efi-sig-list`/`sign-efi-sig-list` (secure boot),
  `dmidecode`/`acpidump` (tables), `dtc` (the DT config table), `mtools`/`mcopy` (the ESP).
- **to verify first:** whether the repo's OVMF build supports **secure boot** (some OVMF builds are
  plain; the SecureBoot variant is a different `.fd`) — Spike 4 gates on it, and names the fallback
  (read/host-verify only, as the UKI lab does) if the SecureBoot OVMF is not available.

## 4. Why this and not a hosted tool
The host tools each read *one* facet from outside a running system; none of them is **the platform
itself**, exercised live under a firmware you control, with the ability to change one variable or
one key and watch the boot decision change. And the convergence — the *same* toolkit reading the
ESP's FAT, the PE app on it, the variables behind it, and the tables it produces — is a view no
single-purpose tool offers.

## 5. The spikes

> **Spike 0 runs first and is a DECISION.**

### Spike 0 — WHICH FACETS ARE REAL ON OVMF, AND THE ANCHOR (decision)
**Question.** UEFI's security facets (secure boot, authenticated variables) have teeth only with
hardware; which does OVMF emulate faithfully, and what anchors trust? Enumerate, per facet: *real
on OVMF* (the ESP, PE apps, the boot manager, the tables, the variable *store*), *logic-only on
OVMF* (secure boot's enforcement, authenticated-variable protection — no hardware WP), *not here*
(a real vendor key hierarchy). **Criterion:** each spike states its tier on the page and prints its
own honesty line (secure boot: **KEY-ANCHOR: dev**, variables: **VAR-PROTECT: UNKNOWN**), the same
discipline the verified-boot and attested-boot labs use. The decision is *the tiering itself* — the
map of what QEMU can honestly teach.

### Spike 1 — the ESP: UEFI's filesystem, read as the boot medium
The ESP is a FAT partition holding `\EFI\BOOT\BOOTX64.EFI`. Point the filesystem readers (the
fs notes' FAT reader) at the real ESP the guest boots from, list it, extract `BOOTX64.EFI`, and
grade against `mtools`/`mcopy`. **This is the fs note's FAT reader with a job**: the medium UEFI
actually boots from. **Control:** a corrupted ESP fails the boot *observably*; the reader's listing
equals `mdir`.

### Spike 2 — EFI variables: UEFI's NVRAM store
Read the variable store two ways: from inside (`efivarfs` in the guest — `BootOrder`, `Boot0000`,
`SecureBoot`, `PK`) and from outside (the OVMF `VARS` pflash, parsed with `dsl/struct.fth` against
the variable-store format). **This is the store table's UEFI row made real** — a backing store the
firmware reads at power-on, exactly the boot-handoff note's seam-4 shape. **Control:** a variable
written in the guest survives a reboot and reads back from the `VARS` file outside (the store table's
survives-reset test); `VAR-PROTECT: UNKNOWN` printed (OVMF's NVRAM is an unprotected file).

### Spike 3 — PE/COFF apps, generalised
Take the UKI lab's `dsl/pe.fth` and point it at *any* `.efi` — the UKI, the OVMF shell, a signed
bootloader — reading headers, sections, and the data directories against `objdump`/`llvm-readobj`.
**Control:** a non-PE file is refused by name; the section map equals the oracle.

### Spike 4 — secure boot: the key hierarchy and the decision
Enrol a **dev** Platform Key, KEK, and db (`cert-to-efi-sig-list` + `sign-efi-sig-list`); sign an
`.efi` with a db key (`sbsign`); boot it (accepted), then boot an **unsigned** one (**refused by
the firmware**). Then **dbx** (revocation): revoke the signed app's hash and watch it refused. This
is the [verified-boot](COREBOOT_VERIFIED_BOOT_LAB_PLAN.md) trust theme in UEFI's own mechanism — a
firmware **deciding** whether to run a binary by signature. **KEY-ANCHOR: dev** printed (our keys,
not a vendor root); **Controls:** the signed app boots (no false negative); revoking it flips the
decision; if the OVMF build lacks secure boot, the spike degrades to read/host-verify (Spike 3 +
`sbverify`) and says so by name.

### Spike 5 — the handoff tables: what UEFI hands the OS
Read the tables UEFI produces: the **memory map** (`GetMemoryMap`, seen via the kernel's
`/sys/firmware/efi/`), **ACPI** and **SMBIOS** (config-table pointers → `acpidump`/`dmidecode` as
oracles), and — the FCode note's "third firmware" — the **device-tree config table**: hand the
guest a DT through OVMF's DTB config-table GUID and read it from `/proc/device-tree`, the UEFI seat
of "a firmware-authored tree reaches Linux". **Control:** the table the firmware published equals
the host oracle's read; the DT node authored is the node Linux receives.

### Spike 6 — the convergence view, as the deliverable
`uefi-inspect`: point it at a running (or captured) OVMF and print, in one view, the ESP contents,
the variable store, the PE app that booted, the secure-boot state, and the tables handed on — the
platform, dissected by the one toolkit, each facet against its oracle. **This is the lab's thesis
made into a tool: UEFI is not a monolith; it is five structures the toolkit already reads.**

## 6. What this is NOT (scope guards)
- **Not an edk2 fork.** Configs and enrolment, not C drivers (unless a spike needs one, numbered).
- **Not unbypassable secure boot / variable protection.** No hardware anchor on QEMU; KEY-ANCHOR:
  dev and VAR-PROTECT: UNKNOWN, every run. The logic is proven; the hardware is named.
- **Not a re-implementation of `efivar`/`sbsign`/`dmidecode`.** They are the oracles.
- **Not the UKI lab.** The single-file dissection lives there; this is the platform around it.

## 7. Routing, success signature, open questions
Tracks under `smoke-*.sh`; OVMF + the UKI/ESP reused from `~/linuxboot-lab/`; `dsl/pe.fth` imported
from the UKI lab; routed in `learning-paths.toml` beside the linuxboot and coreboot labs as the
UEFI-platform member.

| spike | the line that must print | the control that must bite |
|---|---|---|
| 0 | each facet tiered real/logic-only/not-here; honesty lines chosen | a facet claimed real that QEMU fakes is caught |
| 1 | the ESP listed by the fs reader == `mdir`; `BOOTX64.EFI` extracted | a corrupt ESP fails the boot observably |
| 2 | a variable survives a reboot, read inside and outside; VAR-PROTECT: UNKNOWN | the store table's survives-reset test, here for EFI vars |
| 3 | any `.efi` section map == `objdump` | a non-PE file refused by name |
| 4 | signed `.efi` boots, unsigned refused, dbx-revoked refused; KEY-ANCHOR: dev | signed boots (no false negative); no-SB OVMF → degrade by name |
| 5 | memory map/ACPI/SMBIOS/DT match host oracles; the DT node reaches Linux | a published table != the oracle is a finding |
| 6 | `uefi-inspect` shows all five facets in one view, oracle-graded | — |

**Open questions.** (1) Does the repo's OVMF support secure boot (Spike 4), or is the SecureBoot
`.fd` a separate fetch? Names the fallback if not. (2) Does this lab or the UKI lab own `dsl/pe.fth`
— the UKI lab builds it, this consumes it (stated). (3) Is the DT config table (Spike 5) shared
with the FCode note's "UEFI as the third firmware" track, or owned here? Likely owned here, cited
there.
