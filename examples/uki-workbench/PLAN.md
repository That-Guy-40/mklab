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
- **The attestation strand — the SELF-PREDICTION half is DONE** (`smoke-uki-pcrsig.sh`), the
  BOOT half is deferred. A PCR-keyed UKI (lab keypair, `ukify --pcr-*-key --measure`) carries a
  `.pcrsig`; an independent `systemd-measure sign` over the UKI's own sections + key + phase-paths
  reproduces the carried policy digests exactly (host-side, no boot), `.pcrpkey` is the lab key,
  and a tampered `.cmdline` predicts different digests. **Still deferred, UNKNOWN not PASS:** the
  carried prediction == an **actual OVMF+swtpm boot's** PCR 11 (needs a live TPM), and the
  Authenticode extract-and-host-verify. The plan §3 has the feasibility rows.
- **NAME-live** — DONE as `fdt-live` (#477), consumed by the pacme lab.

## Grading discipline (the repo's rules, applied here)

- Every claim is measured against a **foreign** oracle; the firmware's read-back is
  never its own oracle.
- Each track carries a **negative control that is watched to bite** (garbage →
  unrecognised; a dropped sidecar → unclaimed; an out-of-bounds edit → refused by
  name), and would fail the track if it did not fire.
- The deferred strands are named as deferred, not silently downgraded to "fine."
