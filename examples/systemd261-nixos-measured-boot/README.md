# systemd 261 + NixOS — measured, on-disk, iPXE-deployed fleet

**Deploy NixOS onto local disk over iPXE, then prove systemd 261's new
capabilities on the running machine.** The teaching thesis: **Nix owns
reproducibility and image composition; systemd 261 owns measured boot, execution
restriction, and staged rollout** — each tool at what it's best at.

> **Status: all spikes A–G landed.** A Nix-built NixOS UEFI image carrying
> systemd 261 boots under OVMF (B); swtpm + measured boot (C); dm-verity + UKI
> golden image with `measured-os` MET (D); iPXE on-disk deploy, both tiers (E);
> `ConditionFraction=` 3-VM fleet (F); TPM2-sealed LUKS + attestation (G). See
> [`PLAN.md`](PLAN.md) for the roadmap and per-spike status, and
> [`MANUAL_TESTING.md`](MANUAL_TESTING.md) for captured signatures. One honest gap
> stands: `RestrictFileSystemAccess=` is not compiled into nixpkgs' systemd 261.

## Why systemd 261

261 ([release notes](https://github.com/systemd/systemd/releases/tag/v261)) adds
the *enforcement* half of the image-based model this repo already leans toward:

| 261 knob | What it does | Spike |
|---|---|---|
| `ConditionSecurity=measured-os` | gate a service on having booted with measured-boot semantics | C/D — **MET on the verity/UKI image** |
| `systemd-tpm2-swtpm.service` | a software-TPM fallback (for VMs / no-hardware nodes) | C — swtpm wired into `lab-vm.sh` |
| `RestrictFileSystemAccess=` | BPF-LSM: execute only from a signed dm-verity filesystem | D — ⚠️ **not compiled into nixpkgs' systemd 261** (honest gap; substrate ready) |
| `systemd-repart` verity/UKI | build/lay a dm-verity + UKI golden image | D — **image builds + boots** |
| `ConditionFraction=` | fire a unit on a deterministic fraction of the fleet, no orchestrator | F |
| `systemd-cryptenroll --tpm2` | TPM2-sealed LUKS with a PCR policy | G — **verified: seal→unseal→attest→refuse, bound to PCR 7+11** |

## What's here

| File | What it is |
|---|---|
| [`image/flake.nix`](image/flake.nix) + [`configuration.nix`](image/configuration.nix) | The NixOS image (pins `nixos-unstable` → **systemd 261**). Grows per spike. |
| [`build-nixos-image.sh`](build-nixos-image.sh) | Builds the image **inside [`../nix-build-box/`](../nix-build-box/README.md)** — host needs no Nix (`--verity` for the Spike-D golden image). |
| [`vm-nixos261-uefi.toml`](vm-nixos261-uefi.toml) / [`vm-nixos261-verity.toml`](vm-nixos261-verity.toml) | Boot the plain / verity image under OVMF (+swtpm) via `lab-vm.sh` (Spikes B/C/D). |
| [`image/installer.nix`](image/installer.nix) + [`target.nix`](image/target.nix) · [`stage-netboot.sh`](stage-netboot.sh) · [`nixos-pxe-install.toml`](nixos-pxe-install.toml) | **Spike E, Tier A** — iPXE → `nixos-install` NixOS to local disk (BIOS), reusing the `pxe-install` backend + nginx:8181. |
| [`image/deployer.nix`](image/deployer.nix) · [`stage-netboot.sh --tier-b`](stage-netboot.sh) · [`nixos-pxe-deploy.toml`](nixos-pxe-deploy.toml) | **Spike E, Tier B** — iPXE (custom Nix-built `ipxe.efi`, UEFI) → dd the **dm-verity golden image** onto disk → reboot → measured on-disk NixOS. |
| [`fleet.toml`](fleet.toml) · [`fleet-demo.sh`](fleet-demo.sh) | **Spike F** — a 3-VM mock fleet; `ConditionFraction=N%` fires on a deterministic, monotonically-widening slice (canary rollout, no orchestrator). |
| [`image/sealed.nix`](image/sealed.nix) · [`sealed-luks-demo.sh`](sealed-luks-demo.sh) + [`image/sealed-luks-demo.guest.sh`](image/sealed-luks-demo.guest.sh) · [`stage-netboot.sh --sealed`](stage-netboot.sh) · [`nixos-pxe-sealed.toml`](nixos-pxe-sealed.toml) · [`RUNBOOK-sealed-luks.md`](RUNBOOK-sealed-luks.md) | **Spike G** — TPM2-sealed LUKS bound to the measured PCR 7+11 + a PCR-quote attestation stub; the sealed golden image rides the **same Tier-B iPXE/UEFI path**. |

> The Spike-E deploy mechanism (both tiers) is generalized into a reusable,
> importable block — [`../nixos-ipxe-deploy/`](../nixos-ipxe-deploy/README.md).
> This lab is its measured/dm-verity application.
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
