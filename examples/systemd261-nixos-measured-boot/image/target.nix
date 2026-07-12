# examples/systemd261-nixos-measured-boot/image/target.nix
#
# Spike E, Tier A: the minimal NixOS that the netboot installer lays onto the VM's
# local disk (/dev/vda). A plain BIOS/GRUB system (so the pxe-install VM can use
# firmware="bios" — QEMU's native iPXE NIC ROM runs a hand-written boot.ipxe with
# no iPXE rebuild), carrying systemd 261 and the shared lab identity.
{ lib, modulesPath, ... }:
{
  imports = [
    ./lab-common.nix
    (modulesPath + "/profiles/qemu-guest.nix")   # virtio disk/net modules
  ];

  networking.hostName = "nixos261disk";

  # BIOS/GRUB on the whole disk. After install, SeaBIOS boots /dev/vda → GRUB → this.
  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };
  boot.loader.systemd-boot.enable = false;

  # Root filesystem the installer creates + labels (see installer.nix).
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
}
