# examples/systemd261-nixos-measured-boot/image/deployer.nix
#
# Spike E, Tier B: a tiny NixOS netboot "deployer" that lays the dm-verity + UKI
# GOLDEN image (Spike D) onto /dev/vda over HTTP, then reboots into it — the
# systemd-261 image-based-deploy thesis (compose with Nix, ship the whole signed
# image), the counterpart to Tier A's package-by-package `nixos-install`.
#
# Unlike Tier A's installer this bakes NOTHING in — it just curls the raw image
# and dd's it. The golden image is UEFI (UKI at the removable ESP path), so the
# pxe-install VM is UEFI and iPXE-boots this via a custom ipxe.efi (see flake.nix).
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/netboot/netboot-minimal.nix") ];

  boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

  environment.systemPackages = with pkgs; [ curl coreutils util-linux ];

  systemd.services.deploy-image = {
    description = "Spike E Tier B: lay the dm-verity golden image onto /dev/vda";
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
      URL=http://10.0.2.2:8181/nixos/nixos261-verity.raw
      echo "=== SPIKE-E-B: waiting for the image server ==="
      for i in $(seq 1 30); do curl -fsI "$URL" && break || sleep 2; done
      echo "=== SPIKE-E-B: streaming the dm-verity golden image onto /dev/vda ==="
      curl -fL "$URL" | dd of=/dev/vda bs=4M
      sync
      partprobe /dev/vda || true
      # Register an NVRAM boot entry for the golden image's ESP UKI so OVMF boots
      # the DISK on reboot instead of re-PXE'ing (the VM boots network-first until
      # an OS entry exists — the same dance Anaconda/d-i do under UEFI). The UKI is
      # at the removable path, so this is belt-and-suspenders with the fallback.
      efibootmgr -c -d /dev/vda -p 1 -L "NixOS-measured" -l '\EFI\BOOT\BOOTX64.EFI' || true
      echo "=== SPIKE-E-B: deploy complete — rebooting into the MEASURED on-disk NixOS ==="
      systemctl reboot
    '';
  };
}
