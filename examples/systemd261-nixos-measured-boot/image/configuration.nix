# examples/systemd261-nixos-measured-boot/image/configuration.nix
#
# The NixOS system inside the image. Spike B keeps this MINIMAL: the goal is only
# to prove a Nix-built UEFI/systemd-boot image boots under OVMF and reaches a
# login on the serial console (so lab-vm.sh can gate on it). Later spikes append
# the systemd-261 showcase (measured-os gating, RestrictFileSystemAccess=,
# ConditionFraction=, TPM2-sealed LUKS) to this same file.
{ lib, pkgs, ... }:
{
  # A past *released* stateVersion (unstable would warn on a future one). This is
  # a throwaway lab image; there is no state to preserve across upgrades.
  system.stateVersion = "26.05";

  # ── UEFI boot via systemd-boot ────────────────────────────────────────────
  # systemd-boot (not GRUB) is the point: it is the 261 boot story, and modern
  # NixOS emits a UKI-style bootable entry. canTouchEfiVariables=false because the
  # image is built offline (no NVRAM to write at build time); OVMF picks up the
  # \EFI\systemd entry at boot.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
  # (the qcow-efi format already pins boot.loader.timeout = 0; don't redefine it.)

  # ── Serial console — load-bearing for the lab harness ─────────────────────
  # lab-vm.sh exposes the guest serial as a unix socket and gates success on a
  # login banner. Put a getty on ttyS0 AND tty0, and route the kernel there.
  boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

  # ── Throwaway lab identity ────────────────────────────────────────────────
  networking.hostName = "nixos261";
  networking.useNetworkd = true;

  # Autologin root on the serial getty so the harness sees a shell without SSH,
  # and a well-known throwaway password for interactive use. LAB CREDS ONLY.
  services.getty.autologinUser = "root";
  users.users.root.initialPassword = "root";

  # SSH for hands-on poking (lab-vm.sh forwards 127.0.0.1:<port>→22). Root login
  # with a password is deliberate for a disposable lab box — not a pattern to copy.
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = true;
  };

  # Tools we will want on the box for the measured-boot spikes: read PCRs, inspect
  # the UKI, check unit conditions. Cheap to include now.
  environment.systemPackages = with pkgs; [ tpm2-tools sbsigntool util-linux ];

  # Keep the closure small: no docs/X/sound in a headless appliance.
  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;
}
