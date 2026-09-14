# coreboot Verified Boot — a Lab Plan v1 (2026-09-14)

*Proposed **new lab**: **`coreboot-verified-boot/`**. Coreboot's real answer to the question the
[attested-boot capstone](ATTESTED_BOOT_CAPSTONE_LAB_PLAN.md) has to leave open — *"can I trust
the firmware I just ran?"* — is **vboot** (verified boot): a small read-only half of the ROM
checks a cryptographic **signature** on the read-write half before running it, and falls back to
recovery if it fails. This lab builds that, with **A/B firmware slots** and **rollback
protection**, so the family draws the whole line from *no record* → *measured* → **verified**.
It is the **trust** half of a two-lab split; the **construction** half is
[`COREBOOT_ROM_WORKBENCH_LAB_PLAN.md`](COREBOOT_ROM_WORKBENCH_LAB_PLAN.md). Tracked as
[`TODO.md` §29](TODO.md#29-coreboot-verified-boot--the-trust-half-vboot-ab-rollback-2026-09-14).*

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

## 3. Verified feasibility (to check before writing)
- coreboot builds a q35 ROM today — **✅** (`build-coreboot.sh`).
- coreboot supports `CONFIG_VBOOT` with a QEMU target and generates keys with its own
  `futility`/`vboot_reference` tooling — **to verify first**: that `CONFIG_VBOOT` + the RO/RW FMAP
  split builds and boots on the q35 target this repo uses (some vboot knobs assume real-board
  FMAP; the first spike is *does a vboot ROM boot at all here*).
- A/B slots are an FMAP layout (RW_A/RW_B) coreboot's vboot selects between — **to verify**: the
  QEMU target's default FMAP has them or they can be added (the ROM-workbench lab's FMAP work,
  §1's cross-lab tie).
- rollback protection reads/writes a counter — on hardware it is the TPM or a protected flash
  region; **to verify** where the QEMU target keeps it and whether it survives a reboot (this is
  where HW-ANCHOR: UNKNOWN gets specific).

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
*detectable* even if not *preventable*) — a real, if partial, anchor. **Criterion:** the vboot ROM
must boot and verify the RW region on this target; the anchor is whichever gives an honest,
stated trust story with the smallest pretense. **Measure (A) works at all before reaching for
(B).** If vboot will not build on q35 here, the lab says so and pivots to a from-scratch RO/RW
verifier in the ROM-workbench's FMAP (the fallback, named now).

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
mirrors. **Control:** with both good, the selector's choice is honoured; with the chosen one bad,
the *other* is taken, by name.

### Spike 3 — rollback protection
A version number in each RW slot and a stored "minimum acceptable version". Sign an **older**
version and try to boot it: **refused**, because rolling back to a known-vulnerable firmware is
an attack. **Control:** the current version boots; the older one is refused *by version*, and the
minimum advances when a newer version is adopted. **HW-ANCHOR: UNKNOWN** printed — the counter is
in unprotected flash on QEMU, so this proves the *policy*, not the *unbypassable* enforcement.

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
(sha-guarded); the RO/RW FMAP shared with the ROM-workbench lab (cross-lab, stated). Routed in
`learning-paths.toml` after the attested-boot capstone in `boot-and-crash` as its verification
sibling; a 00-INDEX row.

## 9. Success signature (per spike, observable)
| spike | the line that must print | the control that must bite |
|---|---|---|
| 0 | a vboot q35 ROM boots and verifies RW; the anchor named; HW-ANCHOR: UNKNOWN | vboot won't build here → the fallback verifier, named |
| 1 | tampered RW_A → verification fails by name → recovery boots | untampered RW_A boots normally (no false positive) |
| 2 | boot A, then B; B-signed-wrong falls back to A by name | both good → selector's choice honoured |
| 3 | an older version refused by version; current boots; HW-ANCHOR: UNKNOWN | the minimum advances when a newer version is adopted |
| 4 | the vboot verdict is in the event log; recovery differs from clean by that entry | a tampered RW shows the recovery path in the log |

## 10. Open questions
1. **Does `CONFIG_VBOOT` build and boot on this repo's q35 target** (Spike 0)? Everything hinges on
   it; the fallback (a from-scratch RO/RW verifier in the workbench's FMAP) is named if not.
2. **(A) RO-assumed-immutable or (B) TPM-anchored RO** for the trust story? (B) is more honest on
   QEMU (detectable if not preventable); decide after Spike 0 shows what the target supports.
3. **Where does the rollback counter live on the QEMU target**, and does it survive a reboot? This
   is where HW-ANCHOR: UNKNOWN gets specific rather than generic.
4. **Is SMM (§7) the next security lab after this**, given it is the runtime half of the same
   trust story and pairs with the FCode Thunderstrike work? A scheduling call, not a scope one.
