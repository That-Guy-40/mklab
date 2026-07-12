# MANUAL_TESTING — nixos-ipxe-deploy

Both tiers of the reusable block, verified end-to-end with the self-contained demo
payloads (different systems than the systemd-261 lab — proving the modules
parameterize). Host: this repo's COLD_STORAGE host (rootless podman + KVM),
2026-07-12.

## The abstraction evaluates

```
$ nix eval .#packages.x86_64-linux.installer-kernel.drvPath   → …linux-6.18.38.drv
$ nix eval .#packages.x86_64-linux.deployer-kernel.drvPath    → …linux-6.18.38.drv
$ nix eval .#packages.x86_64-linux.ipxe-efi.drvPath           → …ipxe-2.0.0.drv
$ nix eval .#packages.x86_64-linux.demo-image.drvPath         → …nixos-disk-image.drv
```

Modules (`nixosModules.installer`/`deployer`) + `lib.mkIpxeEfi` wire together with
the demo payload.

## Tier A — iPXE → `nixos-install` the demo target (BIOS) ✅

```
$ ./stage-deploy.sh                              # → ~/netboot/demo/{bzImage(13M),initrd(562M)} + demo-install.ipxe
$ phase4-podman/lab-podman.sh up   --config …/nixos-ipxe-install.toml
$ phase2-qemu-vm/lab-vm.sh create  --config …/nixos-ipxe-install.toml
$ phase2-qemu-vm/lab-vm.sh start   ipxe-install-demo
# serial:
SeaBIOS (blank disk) → NIC iPXE ROM → demo-install.ipxe → installer
  → nixos-ipxe-deploy[install]: partitioning /dev/vda … installing …
GRUB 2.12 → ipxe-demo-disk login: root (automatic login)
```

The `nixosModules.installer` laid the demo target onto `/dev/vda` and it booted —
a **different payload** than the systemd-261 lab's target, through the same module.

## Tier B — iPXE → `dd` the demo image (UEFI) ✅

```
$ ./stage-deploy.sh --tier-b                     # → deployer + custom ipxe.efi + demo-image.raw(4.3G)
$ phase4-podman/lab-podman.sh up   --config …/nixos-ipxe-deploy.toml
$ phase2-qemu-vm/lab-vm.sh create  --config …/nixos-ipxe-deploy.toml   # UEFI
$ phase2-qemu-vm/lab-vm.sh start   ipxe-deploy-demo
# serial:
BdsDxe: loading Boot0002 "UEFI PXEv4 (MAC:5254001DEB0B)"
iPXE 2.0.0 -- Open Source Network Boot Firmware              → the custom Nix-built ipxe.efi
  → nixos-ipxe-deploy[image]: dd the demo image onto /dev/vda … efibootmgr … reboot
ipxe-demo-image login: root (automatic login)               → the dd'd image, from disk
```

The `nixosModules.deployer` + `lib.mkIpxeEfi` (custom UEFI `ipxe.efi`, no docker)
dd'd a **different image** than the systemd-261 golden image, through the same
modules — and the UEFI re-PXE loop was avoided by the deployer's `efibootmgr` entry.

## Verdict

Both reusable tiers work with an arbitrary payload. The **measured/dm-verity
application** of the exact same modules is verified end-to-end (incl.
`ConditionSecurity=measured-os` MET) in
[`../systemd261-nixos-measured-boot/MANUAL_TESTING.md`](../systemd261-nixos-measured-boot/MANUAL_TESTING.md) —
this block is that mechanism, generalized.
