# systemd 261 + NixOS — measured, on-disk, iPXE-deployed fleet

**Deploy NixOS onto local disk over iPXE, then prove systemd 261's new
capabilities on the running machine.** The teaching thesis: **Nix owns
reproducibility and image composition; systemd 261 owns measured boot, execution
restriction, and staged rollout** — each tool at what it's best at.

> **Status: under construction, built in phases.** Spike B (a Nix-built NixOS
> UEFI image boots under OVMF, carrying systemd 261) is **verified**. The measured
> boot / enforcement / fleet / trust-chain spikes are in progress — see
> [`PLAN.md`](PLAN.md) for the roadmap and live status, and
> [`MANUAL_TESTING.md`](MANUAL_TESTING.md) for captured signatures.

## Why systemd 261

261 ([release notes](https://github.com/systemd/systemd/releases/tag/v261)) adds
the *enforcement* half of the image-based model this repo already leans toward:

| 261 knob | What it does | Spike |
|---|---|---|
| `ConditionSecurity=measured-os` | gate a service on having booted with measured-boot semantics | C |
| `systemd-tpm2-swtpm.service` | a software-TPM fallback (for VMs / no-hardware nodes) | C |
| `RestrictFileSystemAccess=` | BPF-LSM: execute only from a signed dm-verity filesystem | D |
| `systemd-repart` verity/UKI | build/lay a dm-verity + UKI golden image | D/E |
| `ConditionFraction=` | fire a unit on a deterministic fraction of the fleet, no orchestrator | F |
| `systemd-cryptenroll --tpm2` | TPM2-sealed LUKS with a PCR policy | G |

## What's here

| File | What it is |
|---|---|
| [`image/flake.nix`](image/flake.nix) + [`configuration.nix`](image/configuration.nix) | The NixOS image (pins `nixos-unstable` → **systemd 261**). Grows per spike. |
| [`build-nixos-image.sh`](build-nixos-image.sh) | Builds the image **inside [`../nix-build-box/`](../nix-build-box/README.md)** — host needs no Nix. |
| [`vm-nixos261-uefi.toml`](vm-nixos261-uefi.toml) | Boot the image under OVMF via `lab-vm.sh` (Spike B). |
| [`PLAN.md`](PLAN.md) | The phased spike roadmap + confirmed feasibility facts. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Per-spike verification log with captured output. |

## Quick start (Spike B — build & boot)

```bash
# 1. Build the reusable Nix box once (see ../nix-build-box/):
phase4-podman/lab-podman.sh build --tag nix-build-box \
    --backend build --context examples/nix-build-box

# 2. Build the NixOS image inside it (KVM-assisted; ~minutes, pulls a closure):
examples/systemd261-nixos-measured-boot/build-nixos-image.sh   # → out/nixos261.qcow2

# 3. Boot it under OVMF and confirm systemd 261:
phase2-qemu-vm/lab-vm.sh create --config examples/systemd261-nixos-measured-boot/vm-nixos261-uefi.toml
phase2-qemu-vm/lab-vm.sh start  nixos261
phase2-qemu-vm/lab-vm.sh console nixos261      # autologin root; `systemctl --version` → systemd 261
```

## Honest framing (load-bearing)

This lab runs on QEMU/KVM with **swtpm**, a *software* TPM. It faithfully exercises
the measured-boot, sealed-LUKS, and attestation **plumbing** — but **swtpm is not a
trust anchor**: anything that can read its userspace can forge PCR state. The real
production anchor is a hardware TPM, a hypervisor-backed vTPM rooted in host
hardware, or confidential computing. Treat every green "measured/attested" check
here as *"the wiring is correct,"* not *"this node is trustworthy."*

## Prerequisites

Rootless **podman** + **KVM** (`/dev/kvm`) + this repo's Phase-2/4 drivers. No Nix
on the host — it lives in the build box. Throwaway lab credentials only
(`root`/`root`).

## Provenance

Built on the systemd v261 release notes and official NixOS docs (cite-don't-mirror,
retrieved 2026-07-11), not one blog post — so no vendored HTML archive. A colleague's
261 deployment analysis seeded the design; it is treated as *opinion, not oracle*.
