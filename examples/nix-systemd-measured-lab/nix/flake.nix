{
  # flake.nix — the reproducible half of the lab.
  #
  # Nix owns reproducibility + image COMPOSITION; systemd 261 owns what happens
  # at boot (measured boot, execution restriction, rollout gating).  This flake
  # composes three artifacts, all from the SAME pinned nixpkgs:
  #
  #   .#ddi-a      — the immutable Disk Image (DDI): read-only dm-verity root + a
  #                  UKI, built by NixOS's `image.repart` module.  This is what
  #                  gets deployed on-disk.
  #   .#ddi-b      — the SAME config with a bumped `system.image.version`; stands
  #                  in for "the next build" that systemd-sysupdate rolls onto the
  #                  inactive A/B slot.
  #   .#installer  — a tiny UKI whose initrd runs `systemd-repart` to write a DDI
  #                  onto local disk slot A, then reboots on-disk.
  #
  # [YOU-RUN-THIS]  Building any of these needs Nix + network (cache.nixos.org).
  # Neither is present in the lab's CI container, so the builds are author-run
  # (see ../hand-walk/ for a Nix-in-a-box that reproduces them).  The `.nix` files
  # are the source of truth; ../units/*.service are plain-text MIRRORS kept in
  # sync by hand so the pillar directives stay grep-able without evaluating Nix.
  #
  # systemd-261 FLOOR: ConditionSecurity=measured-os, RestrictFileSystemAccess=,
  # ConditionFraction=, ConditionMachineTag=, systemd-tpm2-swtpm.service and
  # `systemd-repart --definitions … BlockDeviceReplace=` all require systemd >= 261
  # (released 2026-06).  The nixpkgs rev pinned in flake.lock MUST carry it; if the
  # channel lags, apply the systemd overlay sketched in ./configuration.nix and
  # dated in ../SOURCES.md.

  description = "Nix-composed immutable DDI, gated on-disk by systemd 261 (measured boot, exec restriction, rollout gating)";

  inputs = {
    # Pin an unstable rev known to carry systemd >= 261.  `nix flake update` to
    # bump; record the resulting rev + date in ../SOURCES.md.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";

      # One NixOS system, parameterised by image version so A and B differ only
      # in the version stamp (and therefore the roothash) — the whole point of an
      # immutable image factory: byte-identical inputs -> byte-identical output.
      mkSystem = imageVersion:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit imageVersion; };
          modules = [
            ./configuration.nix
            ./image.nix
            ./ab-layout.nix
            ./sysupdate.nix
            ./pillars/measured-boot.nix
            ./pillars/exec-restriction.nix
            ./pillars/rollout-gating.nix
          ];
        };

      ddiA = mkSystem "1";
      ddiB = mkSystem "2";

      # The installer is a separate, deliberately tiny system: just enough to run
      # systemd-repart against the on-disk A/B layout and write the DDI to slot A.
      installer = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit (self) outPath; };
        modules = [ ./installer.nix ];
      };
    in {
      packages.${system} = {
        # `nix build .#ddi-a` -> result/ contains the raw DDI + its roothash.
        ddi-a     = ddiA.config.system.build.image;
        ddi-b     = ddiB.config.system.build.image;
        installer = installer.config.system.build.image;
        default   = ddiA.config.system.build.image;
      };

      # Expose the systems too, so `nixos-rebuild build-vm`-style inspection and
      # `nix eval .#nixosConfigurations.ddi-a.config.system.image.version` work.
      nixosConfigurations = {
        ddi-a = ddiA;
        ddi-b = ddiB;
        installer = installer;
      };

      # `nix flake check` — the reproducibility gate (author-run; no Nix in CI).
      checks.${system}.ddi-a-builds = ddiA.config.system.build.image;
    };
}
