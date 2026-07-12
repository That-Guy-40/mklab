# examples/nixos-ipxe-deploy/modules/deployer.nix
#
# REUSABLE building block — Tier B (image lay-down). A tiny NixOS netboot deployer
# that, when iPXE-booted (UEFI), streams a caller-supplied raw disk image over
# HTTP straight onto /dev/vda, registers an NVRAM boot entry, and reboots into it.
#
# Import into your own netboot nixosSystem and pass the image URL as the
# `imageUrl` module arg (specialArgs). The image must be a whole-disk raw image
# whose ESP is bootable with fresh firmware NVRAM — either a bootloader at the
# removable path (\EFI\BOOT\BOOTX64.EFI, e.g. a systemd-stub UKI or bootctl's
# fallback) or rely on the efibootmgr entry this module registers.
#
#   nixosConfigurations.myDeployer = nixpkgs.lib.nixosSystem {
#     inherit system;
#     specialArgs.imageUrl = "http://10.0.2.2:8181/img/whole-disk.raw";
#     modules = [ nixos-ipxe-deploy.nixosModules.deployer ];
#   };
{ config, lib, pkgs, modulesPath, imageUrl, ... }:
{
  imports = [ (modulesPath + "/installer/netboot/netboot-minimal.nix") ];

  boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

  systemd.services.nixos-ipxe-deploy = {
    description = "nixos-ipxe-deploy: dd a whole-disk image onto /dev/vda, then reboot";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = with pkgs; [ curl coreutils util-linux parted efibootmgr ];
    script = ''
      set -eu
      URL=${imageUrl}
      echo "=== nixos-ipxe-deploy[image]: waiting for the image server ==="
      for i in $(seq 1 30); do curl -fsI "$URL" && break || sleep 2; done
      echo "=== nixos-ipxe-deploy[image]: streaming $URL onto /dev/vda ==="
      curl -fL "$URL" | dd of=/dev/vda bs=4M
      sync
      partprobe /dev/vda || true
      # Register an NVRAM boot entry so UEFI firmware boots the DISK on reboot
      # instead of re-PXE'ing (a pxe-install VM boots network-first until an OS
      # entry exists — the same dance Anaconda/d-i do under UEFI). Belt-and-
      # suspenders with a removable-path bootloader on the image's ESP.
      efibootmgr -c -d /dev/vda -p 1 -L "nixos-ipxe-deploy" -l '\EFI\BOOT\BOOTX64.EFI' || true
      echo "=== nixos-ipxe-deploy[image]: done — rebooting into the on-disk NixOS ==="
      systemctl reboot
    '';
  };
}
