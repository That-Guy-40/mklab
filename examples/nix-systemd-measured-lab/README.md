# nix-systemd-measured-lab — a Nix-composed immutable image, gated on-disk by systemd 261

**Nix owns reproducibility + image composition. systemd 261 owns measured boot,
execution restriction, and rollout gating.** This lab operationalizes that split
end-to-end, iPXE-deployed **on-disk** (not RAM-resident):

1. **Nix** builds a reproducible immutable **DDI** (Disk Image) — a read-only
   **dm-verity** root + a **UKI** — with NixOS's [`image.repart`](nix/image.nix)
   module.
2. **iPXE** chainloads a tiny **installer UKI** ([`ipxe/boot.ipxe`](ipxe/boot.ipxe))
   that uses `systemd-repart … BlockDeviceReplace=` (systemd 261) to write the DDI
   onto a local disk **A/B slot**, then reboots on-disk.
3. **systemd 261** then does its three jobs on every boot:
   - **measured boot** — [`ConditionSecurity=measured-os`](units/measured-os-check.service)
   - **execution restriction** — [`RestrictFileSystemAccess=/nix/store`](units/verity-exec-restrict.service)
   - **rollout gating** — [`ConditionFraction=` / `ConditionMachineTag=`](units/canary-rollout.service)
4. **systemd-sysupdate** ([`nix/sysupdate.nix`](nix/sysupdate.nix)) lands the next
   Nix build in the **inactive** slot; boot-counting rolls back a bad update.

> This is the repo's **first Nix content**. It reuses the existing netboot
> pipeline ([`netboot/build-ipxe.sh`](../../netboot/build-ipxe.sh)) and Phase 2/4
> tools; it does **not** fork them.

## Why these three, and why 261

Every pillar is a directive that is **new in systemd 261** (released 2026-06),
and each maps onto exactly one thing Nix is *bad* at delegating:

| Pillar | systemd 261 mechanism | What Nix provides |
|---|---|---|
| **Measured boot** | `ConditionSecurity=measured-os`; `systemd-tpm2-swtpm.service`; SMBIOS→PCR1 | the UKI whose sections `systemd-stub` measures into PCR 11 |
| **Execution restriction** | `RestrictFileSystemAccess=` (BPF-LSM) | the signed **dm-verity** `/nix/store` the LSM anchors to |
| **Rollout gating** | `ConditionFraction=` / `ConditionMachineTag=` | one byte-identical golden image shipped to the whole fleet |
| **On-disk deploy** | `systemd-repart BlockDeviceReplace=`; `systemd-sysupdate`; A/B + boot-counting | reproducible `ddi-a` / `ddi-b` from one recipe + a version bump |

The seam is Pillar 2: `RestrictFileSystemAccess=/nix/store` only *means* anything
because `/nix/store` is a **verified** dm-verity filesystem — Nix's immutable
image is what makes systemd's exec-lock trustworthy.

## ⚠️ Honest verification map — what runs where

Almost every runtime step needs **Nix + KVM + root + a TPM + a BPF-LSM kernel**,
none of which exist in this repo's CI container. So, like the repo's other
toolchain-gated labs (floppinux, muxup, the pxe-labs' installs), the runtime is
**authored here and run by you**. Nothing below is falsely claimed as
verified-in-CI.

| Step | Where |
|---|---|
| `nix build .#ddi-a / .#installer / .#ddi-b` | **[YOU-RUN-THIS]** — needs Nix + `cache.nixos.org` |
| iPXE → installer → `systemd-repart` writes slot A | **[YOU-RUN-THIS]** — KVM |
| Measured on-disk boot (swtpm PCRs, Pillar 1) | **[YOU-RUN-THIS]** — `swtpm` + KVM |
| `RestrictFileSystemAccess=` enforcement (Pillar 2) | **[YOU-RUN-THIS]** — root + BPF-LSM kernel |
| Fleet fractioning (Pillar 3) | **[YOU-RUN-THIS]** — KVM |
| Pillar **directives** are wired as written | **[VERIFIABLE-HERE]** — grep the [`units/`](units/) mirrors |
| Catalog routing, links, TOML/shell lint | **[VERIFIABLE-HERE]** — `link_check.py`, `paths.py --check`, `bash -n` |

The plain-text [`units/`](units/) files are **rendered mirrors** of the pillar
`.nix` modules, kept in sync by hand, so the 261 directives stay grep-able
without evaluating Nix. See [`MANUAL_TESTING.md`](MANUAL_TESTING.md) for the full
tagged transcript and [`hand-walk/`](hand-walk/RUNBOOK.md) for a Nix-in-a-box.

## Quickstart (author-run, on a Nix + KVM host)

```bash
# 1. Build the artifacts with Nix (see hand-walk/ for a container that has Nix):
cd nix && nix build .#installer .#ddi-a && cp result*/* ~/netboot/ && cd ..

# 2. Signed iPXE ROM + our UKI-chainloading boot.ipxe into pxe_dir:
ipxe/build-boot-rom.sh --server http://10.0.2.2:8181 --output-dir ~/netboot

# 3. Serve (Phase 4) + deploy to disk (Phase 2) from the unified TOML:
phase4-podman/lab-podman.sh up     --config examples/nix-systemd-measured-lab/vm/nix-measured-deploy.toml
phase2-qemu-vm/lab-vm.sh    create --config examples/nix-systemd-measured-lab/vm/nix-measured-deploy.toml
phase2-qemu-vm/lab-vm.sh    start  nix-measured-install     # installs to slot A, reboots on-disk

# 4. Boot the installed disk WITH a measured TPM (Pillar 1 needs a vTPM):
vm/run-measured-vm.sh --disk ~/.local/share/mklab-vm/nix-measured-install/disk.qcow2

# 5. Rollout gating across a fleet (Pillar 3):
vm/run-fleet.sh --disk ~/.local/share/mklab-vm/nix-measured-install/disk.qcow2 --count 10 --canary 2
```

## Layout

```
nix/                    the reproducible half (Nix owns this)
  flake.nix             ddi-a / ddi-b / installer outputs from one pinned nixpkgs
  image.nix             image.repart DDI: dm-verity root + UKI (+ #286969 fix)
  configuration.nix     base system + systemd>=261 assertion + overlay fallback
  installer.nix         netboot installer: systemd-repart BlockDeviceReplace=
  ab-layout.nix         on-disk A/B verity slots + boot-counting rollback
  sysupdate.nix         A/B image updates via systemd-sysupdate transfers
  pillars/*.nix         the three systemd-261 pillars (source of truth)
units/*.service         plain-text MIRRORS of the pillars (grep-able without Nix)
ipxe/                   boot.ipxe (UKI chainloader) + build-boot-rom.sh wrapper
vm/                     nix-measured-deploy.toml (P4+P2) + swtpm + fleet harnesses
hand-walk/              Nix-in-a-box: a container that reproduces the nix builds
PLAN.md                 build log, the lab-vm.sh vTPM gap, #286969, version floor
MANUAL_TESTING.md       every checkpoint, tagged [VERIFIABLE-HERE]/[YOU-RUN-THIS]
SOURCES.md              cite-don't-mirror provenance (image.repart, 261, 2 repos)
```

## Provenance

This lab operationalizes **official docs + the systemd 261 release notes + two
reference repos** — not a single blog page — so per the repo's provenance
convention it **cites** rather than vendors. See [`SOURCES.md`](SOURCES.md).

## Prerequisites (learning path)

Sits after [`linuxboot-uefi-kexec/`](../linuxboot-uefi-kexec/) (UKI/`ukify`),
[`rhel-bootc-minimal/`](../rhel-bootc-minimal/) (image-based install-to-disk),
and the [`zero-touch-provisioning`](../learning-paths/) PXE-install path. It is
the deep end: reproducible image factory + measured, self-updating fleet.
