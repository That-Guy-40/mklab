# examples/systemd261-nixos-measured-boot/image/configuration.nix
#
# Spike B image: a plain systemd-boot (separate kernel+initrd) UEFI NixOS system.
# It boots and carries systemd 261, but does NOT measure the OS into PCR 11 (no
# systemd-stub/UKI) — so `ConditionSecurity=measured-os` is correctly NOT-MET here.
# The dm-verity + UKI variant that DOES satisfy measured-os is verity.nix (Spike D).
{ lib, ... }:
{
  imports = [ ./lab-common.nix ];

  networking.hostName = "nixos261";

  # UEFI boot via systemd-boot (not GRUB). canTouchEfiVariables=false: the image
  # is built offline; OVMF picks up the \EFI\systemd entry at boot.
  # (the qcow-efi format already pins boot.loader.timeout = 0; don't redefine it.)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
}
