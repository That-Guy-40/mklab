# SHOWCASE — what this lab lets you *prove*

> A reproducible NixOS image, built by no-one-in-particular on a laptop with no
> Nix installed on the host, is netbooted onto a bare disk over iPXE — and from
> that point on the machine can **prove what it is**: it booted the exact
> software you shipped, it will only run code from a verified filesystem, it
> unlocks its own disk *only* because the right OS measured itself into a chip,
> and it can hand a remote party a signed, replay-proof receipt of that state.
> Then you roll a change out to a deterministic 1/3 of the fleet with no
> orchestrator. **Every claim below has a captured terminal signature** in
> [`MANUAL_TESTING.md`](MANUAL_TESTING.md).

The one-sentence thesis: **Nix owns *reproducibility + image composition*; systemd
261 owns *measured boot, execution restriction, and staged rollout*.** This lab is
that sentence, made bootable. (New to Nix? Start with
[`../nixos-ipxe-deploy/WHY-NIX.md`](../nixos-ipxe-deploy/WHY-NIX.md).)

---

## The capability matrix

| You want to… | The knob | What you get to *prove* | Status |
|---|---|---|---|
| Build the same OS bit-for-bit, anywhere | Nix flake (pinned `nixos-unstable`) | the image carries **systemd 261**; rebuild → identical store paths | ✅ verified |
| Boot it on real firmware, on disk not RAM | iPXE → `dd`/`nixos-install` | OVMF/SeaBIOS → **on-disk** NixOS login | ✅ both tiers |
| Know the machine booted *your* software | dm-verity + UKI + `ConditionSecurity=measured-os` | PCR 11 measured; the condition is **MET** | ✅ verified |
| Refuse to run anything off a verified FS | `RestrictFileSystemAccess=` | *(exec-only-from-signed-verity)* | ⚠️ **not in nixpkgs' 261 build** — honest gap |
| Unlock storage *only* on the expected OS | `systemd-cryptenroll --tpm2-pcrs=7+11` | LUKS opens with the TPM alone; **refuses** after a PCR change | ✅ verified |
| Prove that state to a remote verifier | `tpm2_quote` / `tpm2_checkquote` | an AK-signed, nonce-fresh PCR quote **verifies** | ✅ verified |
| Roll a change to a slice of the fleet | `ConditionFraction=N%` | a **monotonic canary** keyed on machine-id, no orchestrator | ✅ verified |

---

## Showcase moment #1 — the disk unlocks *because the OS is what it claims to be*

This is the payoff of the whole lab. On a measured VM (`tpm=true`, PCR 11 carries
the measured OS), sealing storage to **PCR 7** (secure-boot state) **+ PCR 11**
(the measured UKI) means the disk key is released by the TPM *only* when the
machine booted the expected software:

```console
$ examples/systemd261-nixos-measured-boot/sealed-luks-demo.sh nixos261s
== systemd 261 — TPM2-sealed LUKS + attestation (measured VM nixos261s) ==
  - TPM2 keyslot enrolled, sealed to PCR 7+11
  - UNSEALED by the TPM against live PCRs — /dev/mapper/sealeddemo opened, zero passphrase
  - attestation: AK-signed PCR 7+11 quote over nonce 8ee840f1902f… VERIFIED (fresh + TPM-signed)
  - after PCR 11 changed, the TPM REFUSED to unseal — the seal is bound to the measured OS ✅
PASS: TPM2-sealed LUKS: seal→unseal-on-good-PCRs→refuse-on-changed-PCRs, plus a verified AK PCR-quote
```

The last two lines are the magic: a signed receipt of the boot state that a remote
party can check, and a hard refusal the instant the measured state drifts. Extend
one PCR — as if a *different* kernel booted — and the secret stays sealed forever.
Full walk-through: [`RUNBOOK-sealed-luks.md`](RUNBOOK-sealed-luks.md).

## Showcase moment #2 — "did this machine boot *my* OS?" → yes, measurably

Spike D's dm-verity + UKI image measures itself through `systemd-stub` into PCR 11,
so systemd's own condition engine can gate services on it:

```console
$ systemd-analyze condition 'ConditionSecurity=measured-os'
Conditions succeeded.        # MET
$ tpm2_pcrread sha256:11
  11: 0x1C10E2D1…            # measured — no longer zero
```

Contrast the plain image (Spike C): PCR 11 = 0, no stub → **not** measured, and the
same condition is correctly NOT-MET. The difference is a UKI at the ESP's removable
path, nothing more. That is measured boot reduced to its essence.

## Showcase moment #3 — one image, laid onto bare metal two ways, over iPXE

No Nix on the deploy target, no manual install. A blank disk goes in; a measured,
on-disk NixOS comes out — pick your philosophy:

- **Tier A — assemble on the target.** A netboot installer `nixos-install`s the
  system package-by-package (offline: the closure is baked into the initrd). BIOS.
  → `nixos261disk login:` on `/dev/vda2`.
- **Tier B — ship the whole signed image.** A tiny deployer `dd`s a reproducible
  **dm-verity + UKI golden image** onto the disk and registers an EFI boot entry.
  UEFI, via a **custom `ipxe.efi` built by Nix** (no docker). → the deployed disk is
  the *measured* golden image, byte-identical to what you built.

Both reuse the repo's `pxe-install` backend + nginx:8181. The mechanism is
generalized into the importable [`../nixos-ipxe-deploy/`](../nixos-ipxe-deploy/README.md)
block — and Spike G's **sealed** image rides the exact same Tier-B path (`--sealed`).

## Showcase moment #4 — roll it out to 1/3 of the fleet, no orchestrator

`ConditionFraction=` hashes each node's machine-id to a stable threshold. Widen the
percentage and machines only ever *join* the cohort — a canary rollout that needs
zero central coordinator, just a unit condition:

```console
$ examples/systemd261-nixos-measured-boot/fleet-demo.sh
VM         machine-id   10%   25%   50%   75%   90%
fleet-1    78c6a566      ·     ·     ·     ·     ·
fleet-2    8e35f248      ·     ·    MET   MET   MET
fleet-3    2c09b3ee      ·     ·     ·    MET   MET
included (of 3):          0     0     1     2     2
```

"50% catches fleet-2; widen to 75% adds fleet-3; fleet-1 is the final cohort" — a
deterministic, monotonic rollout you can reason about before you ship it.

---

## Try it (the fast path)

```bash
# 0. one-time: the reusable Nix build box (host needs no Nix)
phase4-podman/lab-podman.sh build --tag nix-build-box --backend build --context examples/nix-build-box

# 1. build the measured + sealed golden image inside it (KVM-assisted)
examples/systemd261-nixos-measured-boot/build-nixos-image.sh --sealed

# 2. boot it under OVMF + swtpm and prove the sealed chain
phase2-qemu-vm/lab-vm.sh create --config examples/systemd261-nixos-measured-boot/vm-nixos261-sealed.toml
phase2-qemu-vm/lab-vm.sh start  nixos261s
examples/systemd261-nixos-measured-boot/sealed-luks-demo.sh nixos261s      # → PASS
```

Full command lists + expected output per capability: [`MANUAL_TESTING.md`](MANUAL_TESTING.md).
The spike-by-spike roadmap and findings: [`PLAN.md`](PLAN.md).

---

## The honesty that makes this a *lab*, not a demo

This runs on QEMU/KVM with **swtpm — a *software* TPM** (it reports manufacturer
`"IBM"`). Every mechanism above executes faithfully, but swtpm **is not a trust
anchor**: anything that can read its userspace can forge PCR state, and the
attestation key chains to a self-made EK with **no manufacturer certificate**
(it proves *"a TPM signed it,"* not *"genuine hardware"*). Read every green check
here as **"the wiring is correct,"** never *"this node is trustworthy."* The
production anchor is a hardware TPM, a hypervisor-backed vTPM rooted in host
silicon, or confidential computing.

And the one unfinished thing, stated plainly: **`RestrictFileSystemAccess=` is not
compiled into nixpkgs' systemd 261 build** (`strings` finds it 0×; `systemd-analyze
verify` says *"Unknown key… ignoring"*). The dm-verity substrate it would enforce
against is in place; demonstrating the enforcement needs the feature upstream plus a
signed verity policy. We ship the gap visible rather than fake the green.
