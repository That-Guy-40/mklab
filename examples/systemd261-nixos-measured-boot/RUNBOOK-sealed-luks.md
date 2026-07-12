# RUNBOOK — Spike G: TPM2-sealed LUKS + attestation

**Bind encrypted storage to the *measured OS* — the disk unlocks only if the
machine booted the expected software — and prove that state to a remote party
with a signed PCR quote.** This is the trust-chain payoff of the whole lab:
Spike D measured the OS into PCR 11; here that measurement becomes the *key* to
the data.

> **Load-bearing honesty.** Under QEMU/KVM the TPM is **swtpm**, a *software*
> emulator (it reports manufacturer `"IBM"`). Every step below runs faithfully,
> but swtpm **is not a trust anchor** — anything that can read its userspace can
> forge PCR values or the attestation key. What this proves is that the
> *plumbing* is correct, not that this VM is trustworthy. In production the anchor
> is a **hardware TPM**, a **hypervisor-backed vTPM rooted in host silicon**, or
> **confidential computing**. Read every green check here as *"the wiring is
> right,"* never *"this node can be trusted."*

## The chain, in one picture

```
   firmware/boot            systemd-stub            systemd-cryptenroll
   measures PCR 7   ─┐      measures the      ┌─►   seals a LUKS keyslot to a
   (secure-boot)     ├─►    UKI into PCR 11 ──┤     TPM policy over PCR 7 + 11
   measures PCR 11  ─┘      (measured-os)     └─►   tpm2_quote signs {PCRs‖nonce}
                                                    with an Attestation Key (AK)

   later boot →  PCRs match  → TPM releases the key → LUKS opens, no passphrase
                 PCRs differ → TPM refuses          → data stays sealed
```

## Fast path — prove it in a running measured VM

The mechanism needs a booted, measured, `tpm=true` VM (PCR 11 must be populated).
Either the Spike-D verity VM (`nixos261v`) or the Spike-G sealed image
(`nixos261s`) works.

```bash
# build + boot the sealed golden image (skip if you already have nixos261v up):
examples/systemd261-nixos-measured-boot/build-nixos-image.sh --sealed
phase2-qemu-vm/lab-vm.sh create --config examples/systemd261-nixos-measured-boot/vm-nixos261-sealed.toml
phase2-qemu-vm/lab-vm.sh start  nixos261s

# drive the demo from the host (no login needed — pushes the guest script over serial):
examples/systemd261-nixos-measured-boot/sealed-luks-demo.sh nixos261s
```

…or on the guest console directly: `bash /etc/lab/sealed-luks-demo`.

Expected verdict (captured in [`MANUAL_TESTING.md`](MANUAL_TESTING.md) §Spike G):

```
- TPM2 keyslot enrolled, sealed to PCR 7+11
- UNSEALED by the TPM against live PCRs — /dev/mapper/sealeddemo opened, zero passphrase
- attestation: AK-signed PCR 7+11 quote over nonce … VERIFIED (fresh + TPM-signed)
- after PCR 11 changed, the TPM REFUSED to unseal — the seal is bound to the measured OS ✅
PASS: TPM2-sealed LUKS: seal→unseal-on-good-PCRs→refuse-on-changed-PCRs, plus a verified AK PCR-quote
```

## What each step proves

1. **Seal** — `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+11 <dev>` adds
   a second LUKS keyslot whose key is a *TPM-sealed* secret. The TPM will only
   release it when PCR 7 (secure-boot state) **and** PCR 11 (the measured UKI)
   equal their values at enroll time.
2. **Unseal** — `systemd-cryptsetup attach … tpm2-device=auto,headless=true` opens
   the volume with the TPM alone, **no passphrase**, because the live PCRs still
   match. `headless=true` means "never fall back to a prompt" — so the negative
   test can't be masked by an interactive password.
3. **Attest** — an **Attestation Key** signs a `tpm2_quote` over the selected PCRs
   plus a verifier-chosen **nonce**; `tpm2_checkquote` validates the signature and
   the nonce. This is the Keylime-style remote-attestation primitive: proof that
   *a* TPM in *this* PCR state signed a *fresh* challenge.
   - **Caveat:** swtpm's AK chains to a self-generated EK with **no manufacturer
     certificate**, so this proves *"a TPM signed it,"* not *"genuine hardware."*
     Real attestation pins the EK certificate to a vendor CA — impossible with a
     software TPM by construction.
4. **Refuse** — extend PCR 11 with a bogus measurement (simulating a *different*
   OS booting) and the TPM **refuses to unseal**. This is the whole point: the
   seal is bound to *what booted*, not merely to *possession of a chip*.

## Declarative shape — the sealed golden image (Tier B)

`image/sealed.nix` is the Spike-D measured/dm-verity base plus:

- `dm_crypt` loaded, the verified demo baked at **`/etc/lab/sealed-luks-demo`**;
- a `seal-data.service` **reference** (opt-in, `wantedBy = [ ]`) that reproduces
  the enroll flow on a real `/dev/disk/by-partlabel/data` device and unlocks it on
  every subsequent boot — the systemd-261 image-based idiom of *shipping the
  intent* and realizing it on first boot against the *target's* TPM.

It deploys over the **same Tier-B iPXE/UEFI path** as the verity image — the only
difference is the artifact names:

```bash
examples/systemd261-nixos-measured-boot/build-nixos-image.sh --sealed
examples/systemd261-nixos-measured-boot/stage-netboot.sh      --sealed   # reuses deployer.nix + a Nix-built ipxe.efi
phase4-podman/lab-podman.sh up --config examples/systemd261-nixos-measured-boot/nixos-pxe-sealed.toml
phase2-qemu-vm/lab-vm.sh create --config examples/systemd261-nixos-measured-boot/nixos-pxe-sealed.toml
phase2-qemu-vm/lab-vm.sh start  nixos261-sealed
# after the deployer dd's the image and reboots, on the measured host:
#   /etc/lab/sealed-luks-demo    → PASS
```

**Verified vs author-run.** The seal→unseal→attest→refuse **mechanism** and the
**sealed image build + boot + baked demo** are agent-verified (captured in
`MANUAL_TESTING.md`). The full iPXE `--sealed` deploy uses the **identical**
mechanism already verified for the verity image in Spike E Tier B (only the raw
filename differs), and realizing the opt-in `seal-data` `/data` on first boot
needs a spare data device + a reboot — both are **author-run**; nothing measured
is claimed as machine-verified without a captured transcript.

## Why PCR 7 *and* PCR 11

Sealing to **PCR 11 alone** would bind to the measured OS but ignore the boot
path; **PCR 7 alone** binds to the secure-boot key state but not the actual
kernel/initrd. Together they say *"the expected OS, launched through the expected
boot chain."* In production you would additionally use a **signed PCR policy**
(`--tpm2-public-key`) so the seal survives legitimate kernel updates (you re-sign
the new PCR set) without re-enrolling — noted here, not exercised.
