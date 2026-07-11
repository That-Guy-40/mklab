# ab-layout.nix — the ON-DISK A/B slot layout, grown by systemd-repart at boot.
#
# Two distinct uses of systemd-repart, don't confuse them:
#   - BUILD time (../nix/image.nix `image.repart`)   -> composes the DDI itself.
#   - RUN/INSTALL time (`systemd.repart` here)        -> lays out the LOCAL disk
#     into A/B verity slots + a shared writable /state, on first boot.
#
# The installer (../nix/installer.nix) writes DDI-A's root+verity into slot A via
# systemd 261's `BlockDeviceReplace=` (atomic content migration into an existing
# partition).  systemd-sysupdate (./sysupdate.nix) later fills the INACTIVE slot
# with DDI-B, and the boot counting in the ESP rolls over / rolls back.
#
# Layout on /dev/vda after install:
#   p1  ESP           (shared, holds both UKIs + boot-counter entries)
#   p2  root-A        (dm-verity data, slot A)
#   p3  verity-A      (dm-verity hash, slot A)
#   p4  root-B        (dm-verity data, slot B)   <- sysupdate target
#   p5  verity-B      (dm-verity hash, slot B)
#   p6  state         (writable, encrypted-capable; /var, machine-id, tags)

{ config, lib, ... }:

{
  # systemd-repart runs in the initrd on every boot; it is idempotent — it only
  # CREATES what is missing, so it grows the disk once and is a no-op thereafter.
  boot.initrd.systemd.repart.enable = true;
  systemd.repart.enable = true;

  systemd.repart.partitions = {
    # ESP already exists from the DDI; declare it so repart won't stomp it.
    "10-esp" = {
      Type = "esp";
      Format = "vfat";
      SizeMinBytes = "128M";
      SizeMaxBytes = "128M";
    };

    # Slot A — filled by the installer from DDI-A.
    "20-root-a" = { Type = "root"; Label = "root-a"; SizeMinBytes = "2G"; };
    "21-verity-a" = { Type = "root-verity"; Label = "verity-a"; SizeMinBytes = "64M"; };

    # Slot B — left EMPTY at install; systemd-sysupdate writes DDI-B here.
    "30-root-b" = { Type = "root"; Label = "root-b"; SizeMinBytes = "2G"; };
    "31-verity-b" = { Type = "root-verity"; Label = "verity-b"; SizeMinBytes = "64M"; };

    # Writable state — the ONLY mutable partition.  Everything else is verity-RO.
    "40-state" = {
      Type = "linux-generic";
      Label = "state";
      Format = "ext4";
      SizeMinBytes = "512M";
      # Grows to fill the disk (GrowFileSystem) so the appliance uses all space.
      SizeMaxBytes = "0";
    };
  };

  # Boot-assessment / automatic rollback: if a freshly-updated slot fails to
  # reach `boot-complete.target` N times, systemd-boot's boot counter falls back
  # to the previous good slot.  This is what makes an A/B rollout safe.
  boot.loader.systemd-boot.bootCounting.enable = true;

  # State lives on the writable partition, discovered by GPT label.
  fileSystems."/var" = {
    device = "/dev/disk/by-partlabel/state";
    fsType = "ext4";
    neededForBoot = true;
  };
}
