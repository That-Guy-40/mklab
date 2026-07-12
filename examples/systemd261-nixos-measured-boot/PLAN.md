# PLAN — systemd 261 + NixOS: measured, on-disk, iPXE-deployed fleet

A phased, spike-driven build. This file is the living roadmap (mirrors
[`../linuxboot-uefi-kexec/PLAN.md`](../linuxboot-uefi-kexec/PLAN.md)): each spike
de-risks one unknown and lands a verifiable checkpoint before the next begins.
The approved design lives in the session plan; this tracks execution + findings.

## Thesis

**Nix owns reproducibility + image composition; systemd 261 owns measured boot,
execution restriction, and staged rollout.** The lab deploys NixOS **on disk**
(not RAM) over the repo's existing iPXE pipeline, then proves the 261 knobs on the
running machine.

## Confirmed facts (de-risked early)

| Question | Answer | How |
|---|---|---|
| Is systemd 261 obtainable from nixpkgs? | **Yes — `nixos-unstable` ships 261** (stable `nixos-26.05` is 260.2). No overlay needed. | `nix eval …#systemd.version` (2026-07-11) |
| Does the toolchain-fetch gate block Nix? | **No** — `nix build` from `cache.nixos.org` works in a rootless podman box. | [`../nix-build-box/MANUAL_TESTING.md`](../nix-build-box/MANUAL_TESTING.md) |
| Is `/dev/kvm` reachable for KVM-assisted builds? | **Yes** — `podman run --device /dev/kvm` → usable. | build host, 2026-07-11 |
| Does a Nix-built UEFI image carry systemd 261? | **Yes — `261`** baked into the qcow-efi image. | `nix eval .#…pkgs.systemd.version` |

## Building blocks (reuse, don't reinvent)

- **Nix build substrate:** [`../nix-build-box/`](../nix-build-box/) — the reusable box
  every image build runs inside (host needs no Nix).
- **Netboot to disk:** `phase2-qemu-vm/lab-vm.sh` `backend = "pxe-install"` + `boot.ipxe`
  + nginx :8181; templates [`../debian-pxe-lab/`](../debian-pxe-lab/), [`../almalinux-pxe-lab/`](../almalinux-pxe-lab/).
- **UKI/OVMF:** [`../linuxboot-uefi-kexec/`](../linuxboot-uefi-kexec/) (`build-uki.sh`,
  `run-uefi-linuxboot.sh`); `lab-vm.sh` OVMF pflash + `secure_boot`.
- **dm-verity+UKI golden image:** nixpkgs `image.repart.verityStore` (Tier B substrate).
- **DHCP-over-slirp fix:** kernel `ip=dhcp` on the iPXE append line (see
  [`../linuxboot-uefi-kexec/POC-PXEBOOT.md`](../linuxboot-uefi-kexec/POC-PXEBOOT.md)).

## Spike roadmap & status

| # | Spike | De-risks | Status |
|---|---|---|---|
| A | `nix-build-box` reusable env | Nix in this environment at all | ✅ **DONE** — built + verified, committed |
| B | Minimal NixOS UEFI image boots under OVMF | Nix→bootable qcow2; systemd version | ✅ **DONE** — Nix-built qcow2 (systemd **261**, kernel 6.18.38) boots under OVMF to autologin root shell; verified via lab-vm.sh |
| C | swtpm in `lab-vm.sh` + measured boot | shared-driver vTPM change; PCRs; `ConditionSecurity=measured-os` | ✅ **driver+plumbing DONE** — `tpm=true` wires swtpm; guest gets TPM 2.0, PCR7 measured, 25 PCRs; reaped by PID. `measured-os` correctly NOT-MET (PCR11=0, no stub/UKI) → gate turns green in D |
| D | dm-verity + UKI golden image | verity /usr; UKI measured; `measured-os`; `RestrictFileSystemAccess=` | ✅ **verity+UKI+measured-os DONE** — image builds+boots (verity `/usr`, tmpfs root, systemd 261); `measured-os` **MET** (PCR 11 measured, stub present) → closes Spike-C seam. ⚠️ `RestrictFileSystemAccess=` NOT in nixpkgs' systemd 261 build (0 in binary) — honest gap, needs the feature upstream + signed verity |
| E | iPXE on-disk deploy, both tiers | netboot integration; NixOS-initrd DHCP-over-slirp; UEFI PXE | ✅ **DONE (both tiers)** — **A** BIOS iPXE → netboot installer (offline; target baked in) → `nixos-install` → on-disk NixOS (root /dev/vda2). **B** UEFI iPXE (custom Nix-built `ipxe.efi`) → deployer dd's the dm-verity **golden image** → reboot → measured verity NixOS on disk (`measured-os` MET). Reuses `pxe-install` + nginx:8181 |
| F | `ConditionFraction=` 3-VM mock fleet | deterministic staged rollout across machine-IDs | ✅ **DONE** — `fleet.toml` (3 VMs, distinct machine-ids) + `fleet-demo.sh`; sweeping `ConditionFraction=N%` shows monotonic canary rollout (0→0→1→2→2 as 10→90%), no orchestrator. Syntax = **percentage** (`99%`, not `0.99`); it **is** in nixpkgs' systemd 261 |
| G | TPM2-sealed LUKS + attestation stub | `systemd-cryptenroll` PCR policy; PCR quote | ⏳ |

Tiers within E: **Tier A** netboot the NixOS installer → `disko`+`nixos-install` to disk;
**Tier B** golden dm-verity+UKI image (Spike D output) laid down by `systemd-repart`/`systemd-sysinstall`.

## Honest framing (load-bearing)

This runs on QEMU/KVM with **swtpm**, a *software* TPM. It faithfully exercises the
measured-boot / sealed-LUKS / attestation **plumbing**, but swtpm is **not a trust
anchor** — anything that can read its userspace can forge PCR state. The production
anchor is a hardware TPM, a hypervisor-backed vTPM rooted in host hardware, or
confidential computing. Every measured/attestation doc in this lab says so plainly.

## What's verified vs author-run

Nix image builds and OVMF boots are **agent-verifiable here** (KVM + ungated Nix).
The genuinely privileged bits — iPXE install-to-disk end-to-end, live PCR/enforcement
readouts needing a booted measured VM — are run by the operator and their success
signatures pasted into `MANUAL_TESTING.md`. Nothing measured is claimed as machine-
verified without a captured transcript.
