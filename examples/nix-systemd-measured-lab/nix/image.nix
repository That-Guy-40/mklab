# image.nix — Nix's image COMPOSITION half.
#
# Builds a reproducible immutable DDI (Disk Image) with NixOS's `image.repart`
# module:  a read-only **dm-verity** root partition + an ESP carrying a **UKI**.
# This is the artifact systemd 261 then measures, exec-locks, and rolls out.
#
# The verity root is the load-bearing bridge to Pillar 2: because /nix/store
# lives on a signed, integrity-checked dm-verity filesystem, systemd 261's
# `RestrictFileSystemAccess=/nix/store` (a BPF-LSM) can refuse to exec anything
# NOT on it.  No verity -> nothing for the LSM to anchor to.
#
# Reference implementations this mirrors (cite-don't-mirror — see ../SOURCES.md):
#   - github:msanft/reproducible-immutable-nixos
#   - github:applicative-systems/simple-systemd-repart-nixos-image
#
# [YOU-RUN-THIS] — needs Nix; exact `image.repart` option names track the pinned
# nixpkgs rev.  Finish/adjust against your rev; the shape below is the target.

{ config, pkgs, lib, imageVersion, ... }:

{
  # Stamp the image so A and B are distinguishable and sysupdate can order them.
  system.image.id = "nix-measured";
  system.image.version = imageVersion;

  # ── The UKI: kernel + initrd + cmdline + os-release fused into one signed PE ──
  # A UKI is what systemd-stub measures into PCR 11 (Pillar 1) and what iPXE
  # chainloads (../ipxe/boot.ipxe).  systemd-boot lives in the ESP as the entry
  # point; the UKI is the single bootable blob.
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = true;
  boot.initrd.systemd.enable = true;      # required for verity + a measured initrd
  boot.uki.name = "nixos-measured";

  # The kernel finds its root by the verity roothash, not a device path — the
  # roothash is injected by image.repart at build time (see the `Verity` keys
  # below) and appended to the UKI cmdline as `roothash=` / `usrhash=`.
  boot.kernelParams = [
    "console=ttyS0"
    "systemd.verity=yes"
    "rootfstype=erofs"
    "ro"
  ];

  # ── image.repart: the declarative partition table of the DDI ────────────────
  image.repart = {
    name = "nixos-measured-ddi";
    version = imageVersion;

    # Split-artifact output so sysupdate can transfer the pieces independently
    # onto the A/B slots (see ./sysupdate.nix).
    split = true;

    partitions = {
      # ESP: FAT32, holds systemd-boot + the UKI.  Small, mutable-at-deploy.
      "10-esp" = {
        contents = {
          "/EFI/BOOT/BOOTX64.EFI".source =
            "${config.systemd.package}/lib/systemd/boot/efi/systemd-bootx64.efi";
          "/EFI/Linux/${config.boot.uki.name}_${imageVersion}.efi".source =
            "${config.system.build.uki}/${config.boot.uki.name}.efi";
        };
        repartConfig = {
          Type = "esp";
          Format = "vfat";
          SizeMinBytes = "128M";
          SizeMaxBytes = "128M";
        };
      };

      # dm-verity HASH partition — paired to the data partition by VerityMatchKey.
      # Its Type marker (`root-x86-64-verity`) is what systemd-repart/-gpt-auto and
      # the initrd use to find and verify the root at boot.
      "20-root-verity" = {
        repartConfig = {
          Type = "root-verity";
          Verity = "hash";
          VerityMatchKey = "root";
          Label = "verity-${imageVersion}";
          Minimize = "best";
        };
      };

      # dm-verity DATA partition — the read-only erofs /nix/store-backed root.
      # erofs: compact, read-only, hashes cleanly under verity.
      "21-root" = {
        storePaths = [ config.system.build.toplevel ];
        repartConfig = {
          Type = "root";
          Verity = "data";
          VerityMatchKey = "root";
          Label = "root-${imageVersion}";
          Format = "erofs";
          Minimize = "best";
        };
      };
    };
  };

  # ── Reproducibility: nixpkgs#286969 workaround ──────────────────────────────
  # systemd-repart runs inside its own mount+user namespace, which can DROP
  # SOURCE_DATE_EPOCH / TZ from the environment, so timestamps baked into the
  # image drift and the DDI stops being byte-reproducible.  Pin them explicitly
  # and force a fixed timezone so repeated builds hash identically.
  environment.sessionVariables.SOURCE_DATE_EPOCH = "0";
  image.repart.mkfsEnv = {
    SOURCE_DATE_EPOCH = "0";
    TZ = "UTC";
  };

  # Immutable, stateless root: state lives on the separate writable partition
  # declared in ./ab-layout.nix, created by systemd-repart on first boot.
  fileSystems."/".options = [ "ro" ];
  users.mutableUsers = false;
}
