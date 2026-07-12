# RUNBOOK — nixos-ipxe-deploy

Run the self-contained demo of both tiers. (To deploy your OWN payload, import
the modules from a consumer flake per [`README.md`](README.md) and adapt
`stage-deploy.sh`'s `nix build` targets + served paths.)

Prereqs: [`../nix-build-box/`](../nix-build-box/) built, rootless podman + KVM.

## Tier A — iPXE → `nixos-install` to disk (BIOS)

```bash
# 1. Build + stage the installer (kernel+initrd bake the demo target; offline install):
examples/nixos-ipxe-deploy/stage-deploy.sh                # → ~/netboot/demo/{bzImage,initrd} + demo-install.ipxe

# 2. Serve on :8181 + boot the BIOS pxe-install VM:
phase4-podman/lab-podman.sh up     --config examples/nixos-ipxe-deploy/nixos-ipxe-install.toml
phase2-qemu-vm/lab-vm.sh    create --config examples/nixos-ipxe-deploy/nixos-ipxe-install.toml
phase2-qemu-vm/lab-vm.sh    start  ipxe-install-demo
phase2-qemu-vm/lab-vm.sh    console ipxe-install-demo     # watch; Ctrl-] to detach
```

*Flow:* SeaBIOS finds the blank disk unbootable → the NIC's iPXE ROM TFTP-runs
`demo-install.ipxe` → boots the installer → it partitions `/dev/vda` and
`nixos-install`s the demo target → reboots → **`ipxe-demo-disk login:`** (on `/dev/vda2`).

## Tier B — iPXE → `dd` a whole-disk image (UEFI)

```bash
# 1. Build + stage the deployer + custom ipxe.efi + demo image (converted to raw):
examples/nixos-ipxe-deploy/stage-deploy.sh --tier-b       # → ~/netboot/demo/{deployer-*,demo-image.raw} + demo-deploy.efi

# 2. Serve + boot the UEFI pxe-install VM:
phase4-podman/lab-podman.sh up     --config examples/nixos-ipxe-deploy/nixos-ipxe-deploy.toml
phase2-qemu-vm/lab-vm.sh    create --config examples/nixos-ipxe-deploy/nixos-ipxe-deploy.toml
phase2-qemu-vm/lab-vm.sh    start  ipxe-deploy-demo
phase2-qemu-vm/lab-vm.sh    console ipxe-deploy-demo
```

*Flow:* OVMF UEFI-PXE loads the custom `ipxe.efi` (deploy script embedded) → boots
the deployer → it `curl | dd`s the demo image onto `/dev/vda`, registers an NVRAM
entry, reboots → **`ipxe-demo-image login:`** (the dd'd image).

## Tear down

```bash
phase2-qemu-vm/lab-vm.sh    destroy ipxe-install-demo --force
phase2-qemu-vm/lab-vm.sh    destroy ipxe-deploy-demo  --force
phase4-podman/lab-podman.sh down    --lab nixos-ipxe-install-demo
# staged artifacts under ~/netboot/demo/ are yours to `rm` when done.
```
