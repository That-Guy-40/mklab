# configuration.nix — the base NixOS system baked into the DDI.
#
# Deliberately small: a serial console, an SSH login, and the systemd 261 floor.
# The three pillars live in ./pillars/*.nix; the A/B + update plumbing in
# ./ab-layout.nix + ./sysupdate.nix.  Everything here is composed by Nix and
# frozen into the read-only verity root (../nix/image.nix).

{ config, pkgs, lib, imageVersion, ... }:

{
  system.stateVersion = "25.11";     # pin to your pinned nixpkgs release
  networking.hostName = "nix-measured";

  # ── Serial console: the lab drives everything over ttyS0 (QEMU/swtpm harness) ──
  boot.kernelParams = [ "console=ttyS0,115200" ];
  services.getty.autologinUser = lib.mkDefault null;

  # ── Lab credentials (throwaway) ─────────────────────────────────────────────
  # Immutable users: the password hash is baked into the image, not set at runtime.
  # 'lab' / 'lab'.  ⚠️ THROWAWAY lab only — never a real deployment secret.
  users.users.lab = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # `mkpasswd -m yescrypt lab`  (regenerate; this is a placeholder to replace)
    hashedPassword = "$y$j9T$PLACEHOLDER_REPLACE_WITH_mkpasswd_OUTPUT$0";
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";
  };

  environment.systemPackages = with pkgs; [
    tpm2-tools          # inspect PCRs by hand (Pillar 1)
    cryptsetup          # veritysetup: prove the root is dm-verity
    jq
  ];

  # ── systemd 261 FLOOR ───────────────────────────────────────────────────────
  # The pillars use ConditionSecurity=measured-os, RestrictFileSystemAccess=,
  # ConditionFraction=, ConditionMachineTag= — all systemd >= 261.  Assert it at
  # build time so a stale nixpkgs fails LOUDLY here rather than silently skipping
  # the conditions at runtime.
  assertions = [{
    assertion = lib.versionAtLeast config.systemd.package.version "261";
    message = ''
      This lab requires systemd >= 261 (got ${config.systemd.package.version}).
      Bump nixpkgs, or apply the overlay below and remove this note.
    '';
  }];

  # Overlay fallback if your pinned nixpkgs still ships systemd < 261.  Uncomment,
  # point `src` at the v261 tag, and record it in ../SOURCES.md.
  #
  # nixpkgs.overlays = [ (final: prev: {
  #   systemd = prev.systemd.overrideAttrs (old: rec {
  #     version = "261";
  #     src = final.fetchFromGitHub {
  #       owner = "systemd"; repo = "systemd"; rev = "v261";
  #       hash = "sha256-REPLACE_ME";
  #     };
  #   });
  # }) ];
}
