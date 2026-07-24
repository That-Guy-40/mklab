# nixos-ipxe-deploy — deploy NixOS to local disk over iPXE (a reusable building block)

Two ways to put NixOS **on a machine's disk over the network**, factored out as
importable Nix modules so future labs reuse them instead of re-implementing:

| | **Tier A — install** | **Tier B — image lay-down** |
|---|---|---|
| Firmware | **BIOS** | **UEFI** |
| Method | `nixos-install` (package-by-package) | `dd` a whole-disk image |
| Payload | any NixOS system config | any UEFI-bootable whole-disk raw image |
| Module | `nixosModules.installer` | `nixosModules.deployer` + `lib.mkIpxeEfi` |

It's the **deploy** analogue of [`../nix-build-box/`](../nix-build-box/README.md)
(the reusable *build* box): the machinery lives here once, parameterized; each lab
supplies only *what* it deploys. The measured/dm-verity application of the same
pattern is [`../systemd261-nixos-measured-boot/`](../systemd261-nixos-measured-boot/README.md),
where this mechanism was first proven end-to-end.

Everything reuses the repo's existing `pxe-install` backend
(`phase2-qemu-vm/lab-vm.sh`) + a rootless nginx on `:8181` — no new infrastructure.

> **New to Nix?** [`WHY-NIX.md`](WHY-NIX.md) is a ground-up primer (*what, why, how,
> where, and the problems it solves*) written against these exact Tier A / Tier B
> modules — it explains why the two tiers are really *one* idea (a Nix **closure**)
> moved two ways.

## Use it from your own flake

```nix
{
  inputs.ipxeDeploy.url = "path:../nixos-ipxe-deploy";   # or a github: ref
  outputs = { self, nixpkgs, ipxeDeploy, ... }: {
    # Tier A — install YOUR system:
    nixosConfigurations.myInstaller = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs.targetSystem = self.nixosConfigurations.myTarget.config.system.build.toplevel;
      modules = [ ipxeDeploy.nixosModules.installer ];
    };
    # Tier B — dd YOUR image:
    nixosConfigurations.myDeployer = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs.imageUrl = "http://10.0.2.2:8181/img/whole-disk.raw";
      modules = [ ipxeDeploy.nixosModules.deployer ];
    };
  };
}
```

Your **target** (Tier A) supplies its own bootloader + root filesystem for a BIOS
disk; your **image** (Tier B) must be a whole-disk raw whose ESP boots under fresh
firmware NVRAM (a removable-path bootloader and/or the `efibootmgr` entry the
deployer registers). See [`modules/`](modules/) for the exact contracts.

## What's here

| Path | What it is |
|---|---|
| [`modules/installer.nix`](modules/installer.nix) | Tier A module — netboot installer, `nixos-install`s `targetSystem` (offline; closure baked in). |
| [`modules/deployer.nix`](modules/deployer.nix) | Tier B module — netboot deployer, `dd`s `imageUrl`, registers an NVRAM entry, reboots. |
| [`modules/ipxe.nix`](modules/ipxe.nix) | `lib.mkIpxeEfi` — a custom UEFI `ipxe.efi` (deploy script embedded) built **via Nix**, no docker. |
| [`demo/`](demo/) — BIOS [`target.nix`](demo/target.nix) + UEFI [`image.nix`](demo/image.nix) | Self-contained minimal payloads (a `nixos-install` target + a whole-disk UEFI image) so the block builds/boots standalone. |
| [`stage-deploy.sh`](stage-deploy.sh) · [`nixos-ipxe-install.toml`](nixos-ipxe-install.toml) · [`nixos-ipxe-deploy.toml`](nixos-ipxe-deploy.toml) | Build/stage the demo + run it through `pxe-install`. |
| [`RUNBOOK.md`](RUNBOOK.md) · [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Step-by-step + the captured verification. |
| [`WHY-NIX.md`](WHY-NIX.md) | Background primer on Nix (what/why/how/where + problems it solves), anchored to these Tier A/B modules. |

## Gotchas already solved (the reusable value)

- **`ip=dhcp`** — the slirp DHCP lease iPXE gets is *not* inherited by the booted kernel.
- **BIOS `bootindex=0`** (the blank disk is tried before the NIC ROM) vs **UEFI re-PXE loop** — a `pxe-install` VM boots network-first, so the Tier-B deployer must register an NVRAM entry (`efibootmgr`), exactly as Anaconda/d-i do.
- **Custom `ipxe.efi` via Nix** (`pkgs.ipxe.override { embedScript }`) — `netboot/build-ipxe.sh` needs a docker daemon; this host is rootless-podman.
- **Offline install** — Tier A bakes the target closure into the installer initrd (`system.extraDependencies`), so `nixos-install` is a local store copy.

## Prerequisites

Rootless **podman** + **KVM** + this repo's Phase-2/4 drivers, and
[`../nix-build-box/`](../nix-build-box/) (the artifacts build inside it — host needs no Nix).
Throwaway demo credentials only (`root`/`root`).
