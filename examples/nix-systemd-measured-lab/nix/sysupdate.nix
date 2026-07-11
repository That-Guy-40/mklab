# sysupdate.nix — A/B image updates with systemd-sysupdate.
#
# systemd owns the rollout mechanic: fetch the next DDI, write it to the
# INACTIVE slot, flip the boot entry, and (with ab-layout's boot counting) roll
# back automatically if the new slot won't come up.  Nix owns producing that next
# DDI reproducibly — `nix build .#ddi-b` is literally the same recipe with a
# bumped version, so the update is a pure content swap.
#
# `/etc/sysupdate.d/*.transfer` tells systemd-sysupdate what to fetch and where
# to put it.  MatchPattern carries the version; the `@v` token lets sysupdate
# discover newer versions on the server and pick the highest.
#
# Update flow (../MANUAL_TESTING.md walks it):
#   nix build .#ddi-b      -> produces nixos-measured_2 split artifacts
#   serve them next to installer.efi
#   systemctl start systemd-sysupdate   -> writes slot B, sets it next-boot
#   reboot                              -> boots v2 from slot B
#   (break v2) reboot x3                -> boot counter rolls back to slot A (v1)

{ config, pkgs, lib, ... }:

{
  systemd.sysupdate.enable = true;

  # Where the update artifacts are served from (the same nginx :8181 as the
  # installer).  Override per-site.
  systemd.sysupdate.transfers = {
    # The read-only root (dm-verity DATA) partition image.
    "10-root" = {
      Source = {
        Type = "url-file";
        Path = "http://10.0.2.2:8181/";
        MatchPattern = "nixos-measured_@v_root.raw";
      };
      Target = {
        Type = "partition";
        Path = "auto";
        MatchPattern = "root-@v";
        MatchPartitionType = "root";
        # Two slots: sysupdate keeps the current + writes the other.
        InstancesMax = 2;
        ReadOnly = "yes";
      };
    };

    # The dm-verity HASH partition (must move in lockstep with its data).
    "20-verity" = {
      Source = {
        Type = "url-file";
        Path = "http://10.0.2.2:8181/";
        MatchPattern = "nixos-measured_@v_verity.raw";
      };
      Target = {
        Type = "partition";
        Path = "auto";
        MatchPattern = "verity-@v";
        MatchPartitionType = "root-verity";
        InstancesMax = 2;
        ReadOnly = "yes";
      };
    };

    # The UKI dropped into the ESP (systemd-boot picks the newest; boot counting
    # gives it the rollback tries).
    "30-uki" = {
      Source = {
        Type = "url-file";
        Path = "http://10.0.2.2:8181/";
        MatchPattern = "nixos-measured_@v.efi";
      };
      Target = {
        Type = "regular-file";
        Path = "/EFI/Linux";
        PathRelativeTo = "esp";
        MatchPattern = "nixos-measured_@v+@l-@d.efi";  # +tries-left, done markers
        Mode = "0444";
        TriesLeft = 3;   # boot-counting: 3 attempts before rollback
        TriesDone = 0;
        InstancesMax = 2;
      };
    };
  };

  # Check for updates on a timer (disabled by default so the lab drives it by
  # hand; flip to enable for an auto-updating appliance).
  systemd.timers."systemd-sysupdate".enable = lib.mkDefault false;
}
