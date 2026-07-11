# examples/systemd261-nixos-measured-boot/image/verity.nix
#
# Spike D image: a dm-verity-protected /nix/store + a UKI, on a volatile tmpfs
# root. Adapted from nixpkgs' own boot-tested config
# (nixos/tests/appliance-repart-image-verity-store.nix).
#
# WHY this shape wins two things at once:
#   - The UKI is placed at the ESP's REMOVABLE path \EFI\BOOT\BOOTX64.EFI, so
#     OVMF boots it directly (no systemd-boot menu, no NVRAM entry needed — also
#     fixes Spike B's fresh-NVRAM boot gap), and `systemd-stub` MEASURES the UKI
#     into PCR 11 → `ConditionSecurity=measured-os` becomes MET.
#   - /usr (with /nix/store bind-mounted in) sits on a dm-verity device, so its
#     contents are integrity-verified — the substrate `RestrictFileSystemAccess=`
#     (exec-only-from-signed-verity) builds on.
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    ./lab-common.nix
    "${modulesPath}/image/repart.nix"
  ];

  networking.hostName = "nixos261v";

  # Volatile root: the system is immutable; state lives in tmpfs.
  fileSystems."/" = {
    fsType = "tmpfs";
    options = [ "mode=0755" ];
  };

  image.repart = {
    name = "nixos261-verity";
    verityStore = {
      enable = true;
      # Boot the UKI directly off the removable path so OVMF finds it with a
      # fresh NVRAM (efiArch → BOOTX64 on x86_64).
      ukiPath = "/EFI/BOOT/BOOT${lib.toUpper config.nixpkgs.hostPlatform.efiArch}.EFI";
    };
    partitions.${config.image.repart.verityStore.partitionIds.esp} = {
      # The verityStore module injects the UKI into this ESP partition.
      repartConfig = {
        Type = "esp";
        Format = "vfat";
        SizeMinBytes = "96M";
      };
    };
  };

  boot.loader.grub.enable = false;
  boot.initrd.systemd.enable = true;   # systemd stage-1 (also does PCR measurement)

  # Verity-boot robustness + diagnosability (this is a lab image; verbose is fine):
  #  - emergencyAccess: if the verity/usr setup fails, drop to a shell on ttyS0
  #    instead of hanging silently at loglevel=4.
  #  - explicit disk/fs modules so udev can see the virtio disk + erofs /usr.
  #  - earlycon + louder console so the serial harness sees the boot from t=0.
  boot.initrd.systemd.emergencyAccess = true;
  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_scsi" "erofs" ];
  boot.consoleLogLevel = lib.mkForce 7;
  boot.kernelParams = [ "earlycon=uart8250,io,0x3f8" ];

  system.image.id = "nixos261-measured";
  system.image.version = "1";

  # /usr is read-only (verity) — skip the /usr/bin/env activation the test skips.
  system.activationScripts.usrbinenv = lib.mkForce "";
}
