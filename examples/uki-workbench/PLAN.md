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
  - SEALED-SECRET UNLOCK (`smoke-uki-pcr-unlock.sh`, NEW 2026-10-05): the end-to-end — not "the
    boot measures X" but "a key that exists only when the boot measures X". A self-contained
    initrd carries `systemd-creds` + `systemd-pcrextend` and their full runtime closure
    (`libsystemd-shared`, the dlopen'd `libtss2` set, the dynamic linker) beside busybox, run in a
    ramdisk under genuine OVMF + swtpm. Boot A (good UKI): the stub measures sections into PCR 11,
    `systemd-pcrextend` adds the enter-initrd phase, `systemd-creds` SEALS a secret to PCR 11
    as-measured (`--tpm2-pcrs=11`) and DECRYPTS it back — UNLOCK-OK. Boot B (one section, `.cmdline`,
    changed — same TPM, same sealed cred): PCR 11 measures differently, the TPM REFUSES the policy
    ("policy does not match current system state … tampered") — UNLOCK-FAIL, the **negative control
    biting**. Two boots share one swtpm state dir (SRK persists) and one ext2 scratch (the cred
    persists A→B). The credential is bound to the boot, not merely stored on it.
    **This resolves the in-initrd systemd-userspace integration the earlier spike flagged.**
  - **RESOLVED (2026-10-06) — why the signed-policy variant did not gate, chased to ground.** The
    direct `--tpm2-pcrs=11` policy above is a hard gate but breaks on any legitimate UKI update; the
    update-survivable form is the UKI's SIGNED `.pcrsig` (`systemd-creds --tpm2-public-key`, a
    PolicyAuthorize over the signature), and its tampered boot kept unlocking. The chase (a controlled
    in-guest experiment matrix): a `--tpm2-public-key` cred decrypts **with no signature at all**, and
    **even on a tampered boot** (different PCR 11) — so the signed-PCR policy is **SOFT**:
    `systemd-creds` degrades to the SRK-only key when no matching signature is present, by design for
    boot-time credential loading, and there is **no strict/require flag** (`systemd-creds --help`
    confirms only `--tpm2-signature`/`--refuse-null`). It is NOT the TPM (event-log replay: the two
    UKIs measure PCR 11 to genuinely different values `0x096a…`/`0xa506…`) and NOT the test. The HARD,
    update-survivable signed gate lives in **`systemd-cryptenroll` on a LUKS volume** — disk encryption
    has no soft fallback, so there a wrong/unsigned PCR state truly blocks unlock (a separate mechanism;
    a future demo if wanted). `smoke-uki-pcr-unlock.sh` now pins this as a **watched contrast**: on the
    tampered boot the `--tpm2-pcrs` cred is refused (hard) while the `--tpm2-public-key` cred unlocks
    (soft), so a future systemd making the signed policy strict would bite the test. (Also found while
    chasing: `/sys/class/tpm` is unregistered in the mklab-kernel — PCR reads go via the securityfs
    event log, not sysfs.) The hardware AK quote stays UNKNOWN — swtpm is software, not an anchor.
- **NAME-live** — DONE as `fdt-live` (#477), consumed by the pacme lab.

## Grading discipline (the repo's rules, applied here)

- Every claim is measured against a **foreign** oracle; the firmware's read-back is
  never its own oracle.
- Each track carries a **negative control that is watched to bite** (garbage →
  unrecognised; a dropped sidecar → unclaimed; an out-of-bounds edit → refused by
  name), and would fail the track if it did not fire.
- The deferred strands are named as deferred, not silently downgraded to "fine."
