# examples/nixos-ipxe-deploy/modules/installer.nix
#
# REUSABLE building block — Tier A (package install). A NixOS netboot installer
# that, when iPXE-booted, auto-partitions /dev/vda (GPT: BIOS-boot + ext4 root
# "nixos") and `nixos-install`s a caller-supplied system, then reboots into it.
#
# Import this module into your own netboot-installer nixosSystem and pass the
# target's toplevel as the `targetSystem` module arg (specialArgs). The target
# closure is baked into the installer (system.extraDependencies) so the install
# is OFFLINE — a local store copy, no cache.nixos.org fetch mid-boot.
#
#   nixosConfigurations.myInstaller = nixpkgs.lib.nixosSystem {
#     inherit system;
#     specialArgs.targetSystem = self.nixosConfigurations.myTarget.config.system.build.toplevel;
#     modules = [ nixos-ipxe-deploy.nixosModules.installer ];
#   };
#
# Your target config must provide its own fileSystems + bootloader for a plain
# BIOS disk, e.g.: boot.loader.grub = { enable = true; device = "/dev/vda"; };
# fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
{ config, lib, pkgs, modulesPath, targetSystem, ... }:
{
  imports = [ (modulesPath + "/installer/netboot/netboot-minimal.nix") ];

  boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

  # Bake the target into the installer's squashfs store → offline install.
  system.extraDependencies = [ targetSystem ];

  systemd.services.nixos-ipxe-install = {
    description = "nixos-ipxe-deploy: install NixOS onto /dev/vda, then reboot";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    # nixos-install shells out to nix-env/nix-store → `nix` must be on the PATH
    # (systemd services do not inherit the interactive PATH).
    path = [ pkgs.parted pkgs.e2fsprogs pkgs.util-linux pkgs.coreutils
             pkgs.nixos-install-tools config.nix.package ];
    script = ''
      set -eu
      echo "=== nixos-ipxe-deploy[install]: partitioning /dev/vda ==="
      parted -s /dev/vda mklabel gpt
      parted -s /dev/vda mkpart BIOSBOOT 1MiB 3MiB
      parted -s /dev/vda set 1 bios_grub on
      parted -s /dev/vda mkpart root 3MiB 100%
      udevadm settle
      mkfs.ext4 -F -L nixos /dev/vda2
      udevadm settle
      mkdir -p /mnt
      mount /dev/disk/by-label/nixos /mnt
      echo "=== nixos-ipxe-deploy[install]: installing the (pre-built, local) target ==="
      nixos-install --system ${targetSystem} --no-root-passwd --no-channel-copy --root /mnt
      umount -R /mnt || true
      sync
      echo "=== nixos-ipxe-deploy[install]: done — rebooting into the on-disk NixOS ==="
      systemctl reboot
    '';
  };
}
