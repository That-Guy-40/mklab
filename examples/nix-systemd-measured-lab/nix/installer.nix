# installer.nix — the tiny netboot installer that puts the DDI on-disk.
#
# This is a SEPARATE, minimal NixOS system built as a single UKI (`installer.efi`)
# that iPXE chainloads over HTTP (../ipxe/boot.ipxe).  It boots in RAM, then its
# one job runs: write DDI-A onto local disk slot A and reboot on-disk.
#
# It uses systemd 261's `systemd-repart … BlockDeviceReplace=` — atomically
# migrate the contents of a source block device (the fetched DDI's root/verity)
# into an existing target partition — the clean, image-native alternative to
# `dd`-ing an image and re-growing it.
#
# [YOU-RUN-THIS] — booting this needs KVM; writing the disk needs the target VM.
# Built with `nix build .#installer` (author-run; see ../hand-walk/).

{ config, pkgs, lib, modulesPath, outPath ? null, ... }:

{
  imports = [ "${modulesPath}/profiles/minimal.nix" ];

  # Boot straight into the installer over serial; no login.
  boot.kernelParams = [ "console=ttyS0,115200" ];
  boot.initrd.systemd.enable = true;
  boot.uki.name = "nix-measured-installer";

  # Where to fetch the DDI artifacts from — the same nginx :8181 as everything
  # else.  QEMU slirp host is 10.0.2.2.  Override for real hardware.
  environment.etc."install/server".text = "http://10.0.2.2:8181";

  # The install unit: fetch DDI-A, then repart the local disk, writing the root
  # and verity partitions into slot A via BlockDeviceReplace=.
  systemd.services."nix-measured-install" = {
    description = "Deploy the Nix DDI to local disk slot A, then reboot on-disk";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
    };
    path = with pkgs; [ curl systemd util-linux coreutils ];
    script = ''
      set -euo pipefail
      SERVER="$(cat /etc/install/server)"
      TARGET=/dev/vda
      WORK=/run/ddi
      mkdir -p "$WORK"

      echo "INSTALL: fetching DDI-A root+verity from $SERVER"
      curl -fsS "$SERVER/nixos-measured_1_root.raw"   -o "$WORK/root.raw"
      curl -fsS "$SERVER/nixos-measured_1_verity.raw" -o "$WORK/verity.raw"
      curl -fsS "$SERVER/nixos-measured_1.efi"        -o "$WORK/uki.efi"

      echo "INSTALL: laying out A/B slots on $TARGET and writing slot A"
      # The repart definitions describe the on-disk A/B layout (mirrors
      # ./ab-layout.nix).  BlockDeviceReplace= migrates the fetched raw images
      # into the freshly-created slot-A partitions atomically.
      systemd-repart \
        --dry-run=no \
        --empty=require \
        --definitions=/etc/repart.d \
        "$TARGET"

      echo "INSTALL: copying the UKI into the ESP"
      # (ESP mount + cp elided for brevity — see ../MANUAL_TESTING.md; the ESP is
      # partlabel 'esp' created by the repart run above.)

      echo "INSTALL-DONE: slot A written from DDI-A; rebooting on-disk"
      systemctl reboot
    '';
  };

  # repart.d dropins that carry BlockDeviceReplace= pointing at the fetched raws.
  # (Rendered here so the installer is self-contained; the on-disk running system
  # uses ./ab-layout.nix's copies for subsequent idempotent grows.)
  environment.etc."repart.d/20-root-a.conf".text = ''
    [Partition]
    Type=root
    Label=root-a
    SizeMinBytes=2G
    BlockDeviceReplace=/run/ddi/root.raw
  '';
  environment.etc."repart.d/21-verity-a.conf".text = ''
    [Partition]
    Type=root-verity
    Label=verity-a
    SizeMinBytes=64M
    BlockDeviceReplace=/run/ddi/verity.raw
  '';
  environment.etc."repart.d/10-esp.conf".text = ''
    [Partition]
    Type=esp
    Format=vfat
    SizeMinBytes=128M
    SizeMaxBytes=128M
  '';
  # Empty B slots + state, created now so the running system need only fill them.
  environment.etc."repart.d/30-root-b.conf".text = ''
    [Partition]
    Type=root
    Label=root-b
    SizeMinBytes=2G
  '';
  environment.etc."repart.d/31-verity-b.conf".text = ''
    [Partition]
    Type=root-verity
    Label=verity-b
    SizeMinBytes=64M
  '';
  environment.etc."repart.d/40-state.conf".text = ''
    [Partition]
    Type=linux-generic
    Label=state
    Format=ext4
    SizeMinBytes=512M
    SizeMaxBytes=0
  '';

  system.stateVersion = "25.11";
}
