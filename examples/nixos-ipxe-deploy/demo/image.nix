# examples/nixos-ipxe-deploy/demo/image.nix
#
# DEMO payload for Tier B — a minimal UEFI/systemd-boot NixOS, built into a
# whole-disk qcow-efi image (see flake.nix `demo-image`) that the deployer dd's
# onto disk. Self-contained; swap for any UEFI-bootable whole-disk raw image
# (e.g. the systemd-261 lab's dm-verity + UKI golden image).
#
# systemd-boot installs a removable-path fallback (\EFI\BOOT\BOOTX64.EFI), so the
# image boots under fresh firmware NVRAM after the dd (plus the deployer's
# efibootmgr entry as backup).
{ lib, ... }:
{
  system.stateVersion = "26.05";
  boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  networking.hostName = "ipxe-demo-image";
  services.getty.autologinUser = "root";
  users.users.root.initialPassword = "root";   # THROWAWAY demo credential
  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;
}
