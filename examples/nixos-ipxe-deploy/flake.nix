# examples/nixos-ipxe-deploy/flake.nix
#
# A reusable building block: deploy NixOS to a machine's local disk over iPXE,
# two ways —
#   Tier A (BIOS)  : a netboot installer `nixos-install`s a target, package-by-package.
#   Tier B (UEFI)  : a netboot deployer `dd`s a whole-disk image (systemd-261 style).
#
# Consumers IMPORT the modules and pass their own payload (see modules/*.nix):
#   inputs.ipxeDeploy.url = "path:../nixos-ipxe-deploy";   # or github:…
#   … modules = [ ipxeDeploy.nixosModules.installer ]; specialArgs.targetSystem = …;
#
# This flake also ships a self-contained DEMO (demo/*.nix) so the block builds
# and boots standalone — see stage-deploy.sh + the two *.toml.
{
  description = "Reusable: deploy NixOS to disk over iPXE — BIOS install / UEFI image lay-down";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      # ── The reusable building blocks (import these from your own flake) ──────
      nixosModules.installer = import ./modules/installer.nix;   # Tier A (targetSystem arg)
      nixosModules.deployer  = import ./modules/deployer.nix;    # Tier B (imageUrl arg)
      lib.mkIpxeEfi = import ./modules/ipxe.nix { inherit pkgs; };  # custom UEFI ipxe.efi

      # ── Self-contained demo exercising both tiers with a minimal payload ─────
      nixosConfigurations = {
        # Tier A: the on-disk target, and the installer that lays it down.
        demo-target = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./demo/target.nix ];
        };
        demo-installer = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs.targetSystem = self.nixosConfigurations.demo-target.config.system.build.toplevel;
          modules = [ self.nixosModules.installer ];
        };
        # Tier B: the image system, and the deployer that dd's it.
        demo-image-sys = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./demo/image.nix ];
        };
        demo-deployer = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs.imageUrl = "http://10.0.2.2:8181/demo/demo-image.raw";
          modules = [ self.nixosModules.deployer ];
        };
      };

      packages.${system} = {
        # Tier A — served over HTTP:8181 by stage-deploy.sh
        installer-kernel = self.nixosConfigurations.demo-installer.config.system.build.kernel;
        installer-initrd = self.nixosConfigurations.demo-installer.config.system.build.netbootRamdisk;
        # Tier B
        deployer-kernel = self.nixosConfigurations.demo-deployer.config.system.build.kernel;
        deployer-initrd = self.nixosConfigurations.demo-deployer.config.system.build.netbootRamdisk;
        demo-image = nixos-generators.nixosGenerate {
          inherit system;
          format = "qcow-efi";
          modules = [ ./demo/image.nix ];
        };
        ipxe-efi = self.lib.mkIpxeEfi {
          initPath  = "${self.nixosConfigurations.demo-deployer.config.system.build.toplevel}/init";
          kernelUrl = "http://10.0.2.2:8181/demo/deployer-bzImage";
          initrdUrl = "http://10.0.2.2:8181/demo/deployer-initrd";
        };
      };
    };
}
