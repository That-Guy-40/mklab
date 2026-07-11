# examples/systemd261-nixos-measured-boot/image/lab-common.nix
#
# Bits shared by BOTH image variants — the plain systemd-boot image
# (configuration.nix, Spike B) and the dm-verity + UKI golden image
# (verity.nix, Spike D). Keeps the lab identity (serial console, autologin,
# tooling) in one place so the two boot stories differ ONLY in how they boot.
{ lib, pkgs, ... }:
{
  # A past *released* stateVersion (unstable warns on a future one). Throwaway.
  system.stateVersion = "26.05";

  # Serial console — load-bearing: lab-vm.sh gates success on a serial banner.
  # These params merge with whatever the boot path adds (e.g. verity's usrhash).
  boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

  networking.useNetworkd = true;

  # Autologin root on the serial getty + a well-known throwaway password.
  # LAB CREDENTIALS ONLY — never a pattern to copy.
  services.getty.autologinUser = "root";
  users.users.root.initialPassword = "root";
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = true;
  };

  # Tooling for the measured-boot / verity spikes: read PCRs, inspect the UKI,
  # examine the verity device.
  environment.systemPackages = with pkgs; [
    tpm2-tools sbsigntool util-linux cryptsetup
  ];

  # Keep the closure lean — headless appliance.
  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;
}
