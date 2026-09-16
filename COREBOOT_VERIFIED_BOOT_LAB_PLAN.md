# coreboot Verified Boot — a Lab Plan v1 (2026-09-14; feasibility re-measured 2026-09-16)

*Proposed **new lab**: **`coreboot-verified-boot/`**. Coreboot's real answer to the question the
[attested-boot capstone](ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md) has to leave open — *"can I trust
the firmware I just ran?"* — is **vboot** (verified boot): a small read-only half of the ROM
checks a cryptographic **signature** on the read-write half before running it, and falls back to
recovery if it fails. This lab builds that, with **A/B firmware slots** and **rollback
protection**, so the family draws the whole line from *no record* → *measured* → **verified**.
It is the **trust** half of a two-lab split; the **construction** half is
[`COREBOOT_ROM_WORKBENCH_LAB_PLAN.md`](COREBOOT_ROM_WORKBENCH_LAB_PLAN.md). Tracked as
[`TODO.md` §29](TODO.md#29-coreboot-verified-boot--the-trust-half-vboot-ab-rollback-2026-09-14).*

> **Re-measured 2026-09-16, against the coreboot tree** (`src/mainboard/emulation/qemu-q35/`,
> `src/security/vboot/`, `3rdparty/vboot/`). Four of §3's "to verify" rows are answered from
> upstream's own source, and one of them changes a spike: **(1) vboot on q35 is an upstream
> feature, not a hope** — the board's Kconfig carries a `config VBOOT` block and ships two FMAP
> layouts, `vboot-rwa-8M.fmd` (RO + RW_A) and `vboot-rwab-8M.fmd` (RO + RW_A + RW_B), so A/B
> slots are a config choice (`VBOOT_SLOTS_RW_AB`), not a port; **(2) both layouts are 8 MiB**,
> where every ROM this repo builds is 16 MiB; **(3) without a TPM, rollback protection is not
> "unanchored" — it is *disabled***: `select VBOOT_MOCK_SECDATA if !TPM`, and the Kconfig says
> *"Anti-Rollback Protection disabled because mocking secdata is enabled"* — so Spike 3 has a
> subject only with the swtpm the measured-coreboot fixtures already stand up, where the counter
> lives in TPM NV (`secdata_tpm.c`); **(4) the RO region has no write-protect on this board at
> all** — `get_write_protect_state()` is the `__weak` default returning 0 — but QEMU can enforce
> one *outside the guest* by splitting the image across two pflash units with the RO unit
> `readonly=on`, the OVMF_CODE/OVMF_VARS shape, which is a stronger anchor than the first draft's
> UNKNOWN and is Spike 0's option (C). Also measured: the dev keys coreboot signs with by
> default are on disk, and `futility`'s source is present, unbuilt. §3 carries the rows.

---

## 1. Why — and the honest frame first

The measured-boot work (`event-log`, `event-real`, `event-bench`) and the attested-boot capstone
**record** what booted; neither **decides whether to run it**. Coreboot's vboot does: the ROM is
split into a tiny **RO** (read-only) recovery region and a larger **RW** (read-write) region, the
RO region holds public keys and verifies the RW region's signature before jumping into it, and a
failed verification boots **recovery** instead. That is the mechanism the attested-boot lab names
as absent — it is *verification*, one step past measurement — and coreboot ships it.

**The honesty caveat, up front and on every run.** Real vboot's teeth come from **hardware
write-protect** on the RO region (a physical pin / flash WP) and a **hardware rollback counter**
— neither of which QEMU's pflash provides. So this lab proves the **verification and recovery
logic** (a bad signature is caught, recovery takes over, a good update is adopted, a rolled-back
version is refused), and prints **HW-ANCHOR: UNKNOWN** with the reason, exactly as the
attested-boot lab prints **QUOTE: UNKNOWN**. Measured → verified is a real step forward; verified
→ *unforgeably* verified still needs the hardware, and the lab says precisely where that line is.
That honesty is the whole teaching value: most people conflate "the firmware checked a signature"
with "the check can't be bypassed," and they are different claims.

## 2. Thesis & scope

**Thesis.** A firmware that can *measure* a payload can also *refuse* one: give the ROM a
read-only root of trust and a signed read-write body, and boot becomes a **decision**, not just a
record. Add two slots and a version counter and it becomes a **safe update**: a bad firmware
image is caught before it runs and rolled back to a known-good one, unattended.

**In scope:** a vboot-enabled q35 ROM (RO + RW_A + RW_B + recovery, a real signing keypair the lab
generates); verification pass/fail demonstrated (tamper RW_A → caught → recovery); **A/B firmware
slots** with a selector; **rollback protection** (a lower version refused); and the tie-in — the
verified boot's decision **measured into** the attested-boot log, so "it was verified" is itself
recorded.

**Out of scope (hard):** a hardware write-protect or rollback anchor (UNKNOWN, always); a real
vendor key hierarchy (the lab generates its own dev keys and says so); TPM-sealed secrets (that
needs the quote the attested-boot lab also lacks); SMM/runtime isolation (a different threat
model — §7 names it as an adjacent lab, not built here).

### 2b. Why its own lab, and why NOT folded into attested-boot (LOCKED)
- **Measurement and verification are different claims and deserve separate labs.** Attested-boot
  *records*; this lab *decides and refuses*. One is a logbook, the other a gate. Keeping them
  apart is the same discipline that keeps "measured" and "attested" distinct on the page.
- **It composes with the A/B updater at the firmware layer.** The
  [A/B updater idea](DESIGN-NOTES-ideas-downstream-of-the-toolkit.md) rolls back a bad *kernel*;
  this rolls back a bad *firmware* — the same shape one layer down, and the two together are the
  full "safe update at every layer" story.
- **Its threat model is tamper, not corruption.** The chaos ladder here grades an *adversary*
  (a signed-wrong image, a rolled-back image), which is the FCode-note/security posture, not the
  toolkit's "read it correctly" posture.

## 3. Verified feasibility (measured 2026-09-16)
- coreboot builds a q35 ROM today — **✅** (three build scripts, six ROMs; the tree is a depth-1
  shallow clone at `c583b0c4` whose identity no script records — the
  [workbench plan](COREBOOT_ROM_WORKBENCH_LAB_PLAN.md) §3 carries that row and its fix).
- **vboot on q35 is upstream — ✅, read from the board.** `src/mainboard/emulation/qemu-q35/Kconfig`
  has a `config VBOOT` block selecting `VBOOT_STARTS_IN_BOOTBLOCK`, `VBOOT_VBNV_CMOS` and the GBB
  flags that switch off the EC/PD/lid machinery a real Chromebook has, plus `VBOOT_SLOTS_RW_A`
  by default. **Not measured: that it boots here** — Spike 0's question stands, but it is now
  "does upstream's own layout boot on this QEMU", not "can vboot be made to fit q35".
- **A/B slots ship as an FMAP layout — ✅.** Two `.fmd` files beside the board:
  `vboot-rwa-8M.fmd` = `RW_SECTION_A` (0x3c0000: `VBLOCK_A`, `FW_MAIN_A`, `RW_FWID_A`) +
  `RW_VPD` + `WP_RO` (`FMAP`, `RO_FRID`, `GBB`, `COREBOOT` CBFS); `vboot-rwab-8M.fmd` = two
  `RW_SECTION_{A,B}` of 0x1c0000 each + `RW_SHARED` (`VBLOCK_DEV`) + `RW_LEGACY` + `WP_RO`.
  `VBOOT_SLOTS_RW_AB` selects the second. **Both are 8 MiB** (`FLASH 0x800000`); every ROM this
  repo builds is **16 MiB** (`CONFIG_ROM_SIZE=0x01000000`), so the vboot ROM is a different size
  from the workbench's, and "the RO/RW FMAP shared with the workbench lab" means *upstream's*
  8 MiB layout shared, not the workbench's 16 MiB one. **Slot capacity matters:** `FW_MAIN_A` is
  ≈3.69 MiB in `rwa` and ≈1.69 MiB in `rwab`; the LinuxBoot payload `Image` is **3.08 MiB**
  (fits A-only, **not** A/B), `openbios-builtin.elf` is **1.14 MiB** (fits both). So Spike 2's
  A/B subject is OpenBIOS (or SeaBIOS), not LinuxBoot, unless the layout is re-cut.
- **Rollback protection without a TPM is disabled, not merely unanchored.**
  `src/security/vboot/Kconfig`: `select VBOOT_MOCK_SECDATA if !TPM`, and under `if VBOOT` the
  comment *"Anti-Rollback Protection disabled because mocking secdata is enabled."* With a TPM
  the counter lives in **TPM NV space** (`secdata_tpm.c`, the firmware-versions index). The
  board `select`s `MEMORY_MAPPED_TPM` (TIS/CRB at `0xfed40000`), and the measured-coreboot
  fixtures ([`fixtures/coreboot-swtpm/`](examples/openbios-the-rival-that-shipped/fixtures/coreboot-swtpm/README.md))
  already build q35 with `CONFIG_TPM2=y` + `TPM_MEASURED_BOOT=y` against a **swtpm**. So
  **Spike 3 exists only on a TPM build**, and its answer to "where does the counter live, does it
  survive a reboot" is: *in the swtpm's NV state on the host, which persists across QEMU
  restarts as long as that state directory does* — HW-ANCHOR is then **a software TPM**, said
  by name, the same caveat the bench already prints.
- **The RO region has no write-protect on this board.** `chromeos.c` declares no WP GPIO (only
  a virtual recovery GPIO), so vboot's `get_write_protect_state()` is the `__weak` default in
  `src/security/vboot/bootmode.c` and **returns 0**: the firmware believes RO is unprotected.
  But the layout puts `WP_RO` **last** — the top of flash, where x86's reset vector is — and
  QEMU maps pflash **unit 0 at the top of 4 GiB and unit 1 below it** (the OVMF_CODE/OVMF_VARS
  convention). Splitting the ROM at the `WP_RO` boundary (4 KiB-aligned in both layouts:
  `0x3c1000` for `rwa`, `0x395000` for `rwab`) into unit 0 `readonly=on` + unit 1 writable gives
  the RO region a write-protect **enforced by the host, outside the guest** — a real anchor for
  the *logic*, if not a hardware one. That is Spike 0's option (C); its boot is the measurement.
- **The slot selector and the recovery request live in CMOS** (`VBOOT_VBNV_CMOS`, offset
  `0x2c`). QEMU's RTC CMOS is **volatile across a process restart**, so `fw_try_next` /
  `fw_try_count` / the recovery flag survive a *warm reboot inside one QEMU* and not a power
  cycle (a new process). Spike 2's "select B, boot B" is therefore a reboot, not a relaunch —
  or the CMOS bytes are pre-seeded. Said here so the first failed A/B run is not a mystery.
- **Keys: coreboot signs with `3rdparty/vboot/tests/devkeys/` by default** (`VBOOT_ROOT_KEY`,
  `VBOOT_RECOVERY_KEY`, `VBOOT_FIRMWARE_PRIVKEY`, `VBOOT_KEYBLOCK`), and the submodule is
  populated. So a vboot ROM signs *out of the box* — with keys the whole world has. **The lab
  still generates its own** (§2's "a real signing keypair"), because with public dev keys
  "tampered → refused" proves the mechanism but "signed with the wrong key → refused" proves
  nothing. `futility` sources are present (`3rdparty/vboot/futility`, `util/futility`), unbuilt;
  coreboot builds it when `VBOOT=y`.
- **SMM (§7) is real on this build already**: `HAVE_SMI_HANDLER=y`, `SMM_ASEG=y`,
  `smihandler.c` in the board directory. The runtime sibling has a subject on day one.

## 4. Why this and not a hosted tool
`futility`/`vboot_reference` sign and verify images **on the host**; they cannot be the RO region
**refusing to jump into a bad RW region at power-on**, before any OS, and then **booting recovery
instead** — that decision is the firmware's, live, and it is exactly what this lab demonstrates.
The host tools are the oracle for the signatures; the boot is the thing they cannot be.

## 5. The spikes

> **Spike 0 runs first and is a DECISION.**

### Spike 0 — DOES VBOOT BUILD AND BOOT HERE, AND WHAT ANCHORS "TRUST" (decision)
**Question.** Before anything, does a `CONFIG_VBOOT` q35 ROM with an RO/RW split **boot** on this
repo's QEMU target, and where does the root of trust physically live? **(A)** vboot's own key in
the RO region, RO assumed immutable (the honest QEMU story: RO is not really write-protected, so
the anchor is UNKNOWN — named); **(B)** anchor the RO region's integrity in the **TPM** the
measured-boot fixtures already stand up (measure RO into a PCR, so a changed RO is at least
*detectable* even if not *preventable*) — a real, if partial, anchor; **(C) host-enforced RO**
(measured 2026-09-16, §3): split the image at the `WP_RO` boundary across two pflash units,
unit 0 `readonly=on` — the guest cannot write RO, enforced from outside it, the OVMF shape.
**Criterion:** the vboot ROM must boot and verify the RW region on this target; the anchor is
whichever gives an honest, stated trust story with the smallest pretense. **What is already
known, so the decision starts further along:** vboot on q35 is upstream (a `config VBOOT`
block and two shipped FMAPs), so the fallback verifier is very unlikely to be needed; the build
is **8 MiB, not 16**; the board's own `get_write_protect_state()` returns 0, so (A) is not
"RO assumed immutable" but "RO known unprotected, said so"; and **(B) is not optional for
Spike 3** — without a TPM vboot mocks secdata and anti-rollback is *disabled*, so the ROM is a
`CONFIG_TPM2` build against swtpm from the start. **Recommended shape: (B) + (C)** — the TPM for
the counter and for measuring RO, the pflash split for a write-protect the guest cannot lift —
with (A)'s unprotected single-unit boot as the *control* that shows the split doing something.
**Measure the plain boot first**, then the split. If vboot will not boot on q35 here, the lab
says so and pivots to a from-scratch RO/RW verifier in the ROM-workbench's FMAP (the fallback,
still named).

### Spike 1 — verification: a bad RW is caught, recovery takes over
Generate a dev keypair; sign RW_A; boot (verified, normal). Then **tamper one byte of RW_A** and
boot: the RO region's verification **fails, by name**, and **recovery boots instead**. **Controls:**
the untampered RW_A boots normally (no false positive); recovery is reached *because* verification
failed, not by a stuck config (flip it back → normal boot returns). The grade is the **boot
path taken**, observed from the console, not a log line asserting intent.

### Spike 2 — A/B firmware slots
Two RW slots (RW_A good, RW_B a different good build), a selector; boot A, then select B and boot
B, proving both are independently verified and bootable. Then **B signed wrong**: the selector
tries B, verification fails, **falls back to A** — the firmware-layer A/B the kernel-layer updater
mirrors. **Two facts from §3 shape the run:** the `rwab` layout's slots hold ≈1.69 MiB each, so
the A/B payload is **OpenBIOS (1.14 MiB) or SeaBIOS, not LinuxBoot (3.08 MiB)**; and the selector
(`fw_try_next`/`fw_try_count`) lives in **CMOS**, which QEMU forgets on a process restart, so
"select B, boot B" is a **warm reboot inside one QEMU** (or a pre-seeded CMOS), never a relaunch.
**Control:** with both good, the selector's choice is honoured; with the chosen one bad, the
*other* is taken, by name.

### Spike 3 — rollback protection
A version number in each RW slot and a stored "minimum acceptable version". Sign an **older**
version and try to boot it: **refused**, because rolling back to a known-vulnerable firmware is
an attack. **Control:** the current version boots; the older one is refused *by version*, and the
minimum advances when a newer version is adopted. **This spike exists only on a TPM build** (§3):
without one, vboot `select`s `VBOOT_MOCK_SECDATA` and anti-rollback is *disabled by Kconfig*,
so a no-TPM ROM would "accept" the older version and prove nothing — that no-TPM boot is the
spike's **negative control**, expected to accept, and named as the disabled case. With
`CONFIG_TPM2` + swtpm the counter is in **TPM NV** (`secdata_tpm.c`) and persists across QEMU
restarts with the swtpm state directory. The line printed is therefore not the first draft's
generic **HW-ANCHOR: UNKNOWN** but the specific one: **HW-ANCHOR: swtpm NV (software TPM; a
host with the state file can rewrite the minimum)** — the *policy* proved, the enforcement
anchored to a thing the lab can name and the host can forge.

### Spike 4 — the verified decision, measured
Tie into the attested-boot capstone: the vboot verdict (which slot, verified or recovery, version)
is **measured into the event log**, so the attestation record says not just *what* booted but
*that it was verified and which slot*. A recovery boot and a normal boot differ in the log by the
entry vboot wrote — "the firmware recorded its own trust decision". **Control:** a tampered RW that
triggers recovery shows the recovery path in the log, differing from the clean boot in exactly the
vboot entry.

## 6. What this is NOT (scope guards)
- **Not unforgeable verification.** No hardware write-protect or rollback anchor on QEMU;
  HW-ANCHOR: UNKNOWN every run. The lab proves the *logic*, names the missing *hardware*.
- **Not attestation.** Verification decides locally whether to boot; attestation proves to a
  *remote* party. This lab is the local decision; the quote is still UNKNOWN (attested-boot's job).
- **Not a key-management product.** Dev keys the lab generates, said so; no vendor PKI.
- **Not SMM / runtime isolation** — a different threat model (§7).

## 7. Adjacency — the runtime sibling (SMM), named, not built here
Boot-time verification (this lab) answers *"was the firmware I loaded the right one?"*. It does
**not** answer *"can code that is already running escalate?"* — that is **System Management Mode
(SMM)**, x86's ring -2, the most privileged mode and the classic home of firmware rootkits (the
runtime counterpart to the FCode note's malicious option ROM). coreboot sets up SMM and **locks**
it (SMRAM `D_LCK`), and QEMU's q35 emulates SMM, so a lab that **demonstrates an unlocked SMM is a
compromise and the lock prevents it**, graded on the chaos ladder, is a real thing — but a
**different threat model and its own lab**, a sibling of
[`SECURITY_RANGE_LAB_PLAN.md`](SECURITY_RANGE_LAB_PLAN.md) and the FCode note's Thunderstrike
rows. Named here so the seam is explicit: **verified boot is integrity at load; SMM is isolation
at runtime**, and mixing them would blur the very distinction the family exists to teach.

## 8. Routing (at assembly, not before)
Each spike a `smoke-*.sh` track; the coreboot tree + vboot tooling reused from `~/linuxboot-lab/`
(its identity recorded first — the workbench plan's row; today nothing pins the tree); the FMAP
is **upstream's 8 MiB `vboot-rwab-8M.fmd`**, shared with the ROM-workbench lab as the layer its
region edits land in (cross-lab, stated — and a different ROM size from the workbench's 16 MiB
default, so the two labs' ROMs are siblings, not the same file). Routed in
`learning-paths.toml` after the attested-boot capstone in `boot-and-crash` as its verification
sibling; a 00-INDEX row.

## 9. Success signature (per spike, observable)
| spike | the line that must print | the control that must bite |
|---|---|---|
| 0 | upstream's 8 MiB vboot q35 ROM boots and verifies RW on a `CONFIG_TPM2`+swtpm build; the anchor named per row — `RO-WP: host pflash readonly` (C) or `RO-WP: none (get_write_protect_state=0)` (A), `SECDATA: swtpm NV` | the single-unit (A) boot: the same RO store that the split refuses goes through; vboot won't boot here → the fallback verifier, named |
| 1 | tampered RW_A → verification fails by name → recovery (the RO CBFS's payload) boots | untampered RW_A boots normally (no false positive) |
| 2 | boot A, then B (a warm reboot, the selector in CMOS); B-signed-wrong falls back to A by name; payload is OpenBIOS or SeaBIOS (the slot is 1.69 MiB) | both good → selector's choice honoured |
| 3 | on the TPM build: an older version refused by version; current boots; `HW-ANCHOR: swtpm NV (software TPM)` printed | the no-TPM build *accepts* the older version and prints `ANTI-ROLLBACK: disabled (VBOOT_MOCK_SECDATA)` — the disabled case named, not hidden; the minimum advances when a newer version is adopted |
| 4 | the vboot verdict is in the event log; recovery differs from clean by that entry | a tampered RW shows the recovery path in the log |

## 10. Open questions
1. **Does `CONFIG_VBOOT` build and boot on this repo's q35 target** (Spike 0)? **Narrowed
   2026-09-16:** it *builds* by upstream's own design — the board carries a `config VBOOT` block
   and two shipped FMAPs — so the open half is only the *boot*, on an 8 MiB image; the fallback
   verifier stays named and is now unlikely to be needed.
2. ~~**(A) RO-assumed-immutable or (B) TPM-anchored RO**~~ **Narrowed:** (A) is "RO known
   unprotected" (`get_write_protect_state()` returns 0 on this board), (B) is *required* for
   Spike 3 (no TPM → anti-rollback disabled), and a third option **(C)** — the RO region on a
   pflash unit QEMU holds `readonly=on` — gives a write-protect enforced outside the guest.
   Recommended (B)+(C) with (A) as the control; Spike 0's boot decides.
3. ~~**Where does the rollback counter live on the QEMU target**~~ **Answered:** in TPM NV
   (`secdata_tpm.c`) on a `CONFIG_TPM2` build, i.e. the swtpm's state file on the host, which
   persists across QEMU restarts; without a TPM there is **no counter** (`VBOOT_MOCK_SECDATA`,
   anti-rollback disabled by Kconfig). HW-ANCHOR is now specific: *a software TPM whose NV the
   host can rewrite.* The selector and recovery request are a separate store — CMOS, volatile
   across a process restart.
4. **Is SMM (§7) the next security lab after this**, given it is the runtime half of the same
   trust story and pairs with the FCode Thunderstrike work? A scheduling call, not a scope one.
