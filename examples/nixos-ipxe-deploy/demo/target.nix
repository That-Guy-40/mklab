# examples/nixos-ipxe-deploy/demo/target.nix
#
# DEMO payload for Tier A — the minimal BIOS/GRUB NixOS the installer lays onto
# disk. Self-contained (imports nothing lab-specific); swap this for your own
# system config to deploy something real. It must supply its own bootloader +
# root filesystem for a plain BIOS disk (the installer just partitions + installs).
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  system.stateVersion = "26.05";
  boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

  boot.loader.grub = { enable = true; device = "/dev/vda"; };
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };

  networking.hostName = "ipxe-demo-disk";
  services.getty.autologinUser = "root";
  users.users.root.initialPassword = "root";   # THROWAWAY demo credential
  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;
}
