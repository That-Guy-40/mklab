# The UKI Workbench — build plan (this lab)

The canonical design, the feasibility measurements, and the full spike ladder
(Spikes 0–11) live in **[`../../UKI_WORKBENCH_LAB_PLAN.md`](../../UKI_WORKBENCH_LAB_PLAN.md)**.
This file records what *this operationalization* covers and what it defers, so the
scope is legible without re-reading the whole plan.

## What PR1 delivers (DONE)

The **capstone that consumes the contract**, on the `unix` door, self-proving:

1. **The dissector** ([`uki-dissect.fth`](uki-dissect.fth) +
   [`smoke-uki-dissect.sh`](smoke-uki-dissect.sh)). Opens a UKI with the contract's
   `pe-open`, walks its section table, and hands `.linux` and `.initrd` to `identify`
   — the registry-driven capstone — which names each with no per-format code. Graded
   against `objdump`/`objcopy`/`file`/`cpio`. This is plan **Spike 2** re-expressed as a
   *contract* consumer (the rival lab's `uki` track grades the same sections by calling
   the readers directly; here the spine is `identify` + the uniform vocabulary), plus
   the federation proof `identify`/`.modules`/`need-module` give for free.
2. **The in-RAM rescue edits** ([`smoke-uki-rescue.sh`](smoke-uki-rescue.sh)). The
   contract's `NAME-write` surface: `pe-write` grows `.cmdline` (plan **Spike 6**),
   `cpio-write` flips a config value inside the `.initrd` (plan **Spike 10**, in-RAM
   half) — each a delta with a refuse-before-write control and a foreign pre-edit
   anchor.

## What this lab defers (with the crux, so it is a spike and not a bare TODO)

- **The persisted rescue + the full break→fail→rescue showcase (Spikes 8-basic, 11) —
  BUILT (re-derived 2026-10-04, correcting a "PR2-deferred" note).** The persisted
  deliverable [`uki-edit.sh`](../openbios-the-rival-that-shipped/uki-edit.sh) (re-emits a
  patched UKI that `objcopy`/`ukify` read back — the foreign-oracle grade of an *edited*
  artifact) and the narrated [`showcase-rescue.sh`](../openbios-the-rival-that-shipped/showcase-rescue.sh)
  (boots the unedited artifact to a named failure signature first, then rescues it, across
  four acts: initrd/config/cmdline/bzImage) both exist. They are OVMF-gated **manual**
  showcases, not CI tracks. **Crux (unchanged):** the showcase needs the OVMF boot loop for
  the cmdline act; the config/initrd acts are gradeable on the host. **⚠️ 2026-10-04:** a
  `file`-version regression (`is_bzimage` greps `executable bzImage`; `file-5.46` prints
  `executable, bzImage`) makes the fixture builder SKIP, so re-verification is blocked until
  that grep is made comma-tolerant — the UKI/rescue tracks are passing-via-SKIP meanwhile.
- **The attestation strand — SELF-PREDICTION done, MEASURED BOOT now mostly done too
  (2026-10-04), one phase-level residual named.**
  - SELF-PREDICTION (`smoke-uki-pcrsig.sh`): a PCR-keyed UKI (lab keypair, `ukify --pcr-*-key
    --measure`) carries a `.pcrsig`; an independent `systemd-measure sign` over the UKI's own
    sections + key + phase-paths reproduces the carried policy digests exactly (host-side, no
    boot), `.pcrpkey` is the lab key, a tampered `.cmdline` predicts different digests.
  - MEASURED BOOT (`smoke-uki-attest-boot.sh`, NEW): the live-TPM counterpart. A bootable
    PCR-keyed UKI (real kernel + initrd) boots under **genuine OVMF + a real swtpm TPM 2.0**;
    the systemd-stub measures its sections into PCR 11; the guest reads the LIVE PCR 11 from its
    own `/sys/class/tpm/tpm0`; and `tpm2_eventlog` (the foreign oracle) replays the kernel's TCG
    event log to EXACTLY that register, its 14 PCR-11 events being the UKI's 7 sections measured
    name-then-content. A one-section change (`.cmdline`) moves PCR 11 — content-sensitive (the
    negative control bites). This closes the plan's old "the carried prediction == an actual
    OVMF+swtpm boot's PCR 11 (needs a live TPM)" for the *measurement*: the real TPM saw this UKI
    and nothing else, foreign-oracle-graded. OVMF/swtpm-gated → SKIPs where they are absent.
  - AUTHENTICODE (`smoke-uki-authenticode.sh`, NEW 2026-10-05): the signature gate that sits
    BEFORE the TPM measurement. ukify signs the UKI with a lab Secure Boot key
    (`--signtool sbsign`); `sbverify` (the foreign oracle) accepts it against the lab certificate
    and lists the embedded Authenticode signature. Both controls bite: a rogue certificate is
    rejected (the signature is bound to the lab key), and overwriting six bytes makes sbverify
    report a hash mismatch (Authenticode covers the whole image, so any post-sign edit — including
    the rescue arc's — invalidates it). Host-side, no boot. This closes the plan's
    "Authenticode extract-and-host-verify".
  - **STILL DEFERRED — a SPIKE, crux measured (2026-10-05):** PHASE-level `.pcrsig` *policy
    satisfaction* — a secret SEALED to the UKI's signed `.pcrsig` policy that UNLOCKS only on a
    boot whose PCR 11 satisfies it. Achieved so far: the self-prediction (pcrsig), the live
    measured boot (attest-boot), and the signature gate (authenticode). The gap, diagnosed from
    the attest-boot event log: that boot measures **sections-only** (14 EV_IPL events = 7 sections
    × name+content, **no phase word**), because the systemd-stub 259 does NOT extend the
    enter-initrd phase itself — `systemd-pcrextend` (the renamed `systemd-pcrphase`) does, from
    *inside a systemd initrd*. So `systemd-measure calculate`'s phase-applied prediction and the
    `.pcrsig`'s per-phase signed policy are off from the busybox boot by exactly that extension.
    **Crux:** reach the signed phase in the guest and run `systemd-creds decrypt --tpm2-signature`
    there. **Experiments, in order of cost:** (1) stage `systemd-creds` + its 9 libs +
    `systemd-pcrextend` into the measure initramfs (the packer's `--add` is single-file, so each
    `.so` is explicit) — a ~20-file bundle, fragile but bounded; the stepping-stone is a RAW-PCR
    seal to the sections-only value attest-boot already produces (no phase, no signature), proving
    the unlock mechanism against the real measured PCR 11 with a tamper negative control; (2) the
    full signed-policy version on a systemd-based initrd (`dracut` is absent here; `mkinitramfs`
    with the systemd TPM units). This is a real systemd-in-initrd integration, held as a spike
    rather than hand-waved. Plus: nothing here is a chain of trust — swtpm is software, not an
    anchor.
- **NAME-live** — DONE as `fdt-live` (#477), consumed by the pacme lab.

## Grading discipline (the repo's rules, applied here)

- Every claim is measured against a **foreign** oracle; the firmware's read-back is
  never its own oracle.
- Each track carries a **negative control that is watched to bite** (garbage →
  unrecognised; a dropped sidecar → unclaimed; an out-of-bounds edit → refused by
  name), and would fail the track if it did not fire.
- The deferred strands are named as deferred, not silently downgraded to "fine."
