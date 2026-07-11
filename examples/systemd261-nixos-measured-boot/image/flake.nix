# examples/systemd261-nixos-measured-boot/image/flake.nix
#
# The NixOS image the lab boots. Built INSIDE ../../nix-build-box (the reusable
# Nix build box), never on the host directly — see ../build-nixos-image.sh.
#
# Pins nixpkgs to **nixos-unstable**, which ships **systemd 261** (nixos-26.05
# stable is still on 260.2 — verified 2026-07-11: `nix eval …#systemd.version`).
# That is the whole reason for the unstable pin; the lab is *about* 261.
#
# Spike B (this file's first job) proves only that a Nix-built, UEFI/systemd-boot
# NixOS image boots under OVMF via `lab-vm.sh`. Later spikes grow configuration.nix
# to exercise the 261 knobs (ConditionSecurity=measured-os, RestrictFileSystemAccess=,
# ConditionFraction=, TPM2-sealed LUKS); the dm-verity+UKI *golden image* (Tier B)
# swaps this qcow-efi output for image.repart.verityStore in a sibling flake output.
{
  description = "systemd-261 measured-boot NixOS image (built in nix-build-box)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }:
    let system = "x86_64-linux";
    in {
      # `nix build .#image` → a UEFI-bootable qcow2 (systemd-boot). KVM-assisted
      # (make-disk-image builds in a throwaway VM), so the build box is run with
      # `--device /dev/kvm` (see ../build-nixos-image.sh).
      packages.${system}.image = nixos-generators.nixosGenerate {
        inherit system;
        format = "qcow-efi";
        modules = [ ./configuration.nix ];
      };

      # Also expose the system so we can prove which systemd it contains:
      #   nix eval .#nixosConfigurations.measured.pkgs.systemd.version --raw
      nixosConfigurations.measured = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./configuration.nix ];
      };
    };
}
