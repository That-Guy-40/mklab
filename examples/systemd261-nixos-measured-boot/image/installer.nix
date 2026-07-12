# examples/systemd261-nixos-measured-boot/image/installer.nix
#
# Spike E, Tier A: a NixOS netboot installer that, when iPXE-booted, AUTO-INSTALLS
# the target system (target.nix) onto /dev/vda and reboots into it — unattended,
# the NixOS analogue of the repo's kickstart/preseed labs.
#
# Made offline + fast by baking the target's whole closure into the installer's
# store (`system.extraDependencies`), so `nixos-install --system` is a LOCAL store
# copy — no cache.nixos.org fetch mid-install (the slirp network only carries the
# iPXE HTTP fetch of kernel+initrd).
{ config, lib, pkgs, modulesPath, targetSystem, ... }:
{
  imports = [ (modulesPath + "/installer/netboot/netboot-minimal.nix") ];

  # Serial console so lab-vm.sh can watch the install + the post-install login.
  boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

  # Bake the target system into the installer's squashfs store → offline install.
  system.extraDependencies = [ targetSystem ];

  environment.systemPackages = with pkgs; [ parted e2fsprogs ];

  # The unattended installer. Partitions /dev/vda (GPT: a 2 MiB BIOS-boot part +
  # an ext4 root labelled `nixos`), installs the pre-built target, then reboots.
  systemd.services.auto-install = {
    description = "Spike E: install NixOS onto /dev/vda, then reboot";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    # nixos-install shells out to nix-env/nix-store/nix, so `nix` must be on the
    # service PATH (systemd services don't inherit the interactive PATH).
    path = [ pkgs.parted pkgs.e2fsprogs pkgs.util-linux pkgs.coreutils
             pkgs.nixos-install-tools config.nix.package ];
    script = ''
      set -eu
      echo "=== SPIKE-E: partitioning /dev/vda ==="
      parted -s /dev/vda mklabel gpt
      parted -s /dev/vda mkpart BIOSBOOT 1MiB 3MiB
      parted -s /dev/vda set 1 bios_grub on
      parted -s /dev/vda mkpart root 3MiB 100%
      udevadm settle
      mkfs.ext4 -F -L nixos /dev/vda2
      udevadm settle
      mkdir -p /mnt
      mount /dev/disk/by-label/nixos /mnt
      echo "=== SPIKE-E: installing the (pre-built, local) target system ==="
      nixos-install --system ${targetSystem} --no-root-passwd --no-channel-copy --root /mnt
      umount -R /mnt || true
      echo "=== SPIKE-E: install complete — rebooting into on-disk NixOS ==="
      sync
      systemctl reboot
    '';
  };
}
