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
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      # All package outputs live in ONE packages.${system} set — Nix forbids
      # defining the dynamic ${system} attribute across separate statements.
      packages.${system} = {
        # `nix build .#image` → a UEFI-bootable qcow2 (systemd-boot). KVM-assisted
        # (make-disk-image builds in a throwaway VM); build box gets --device /dev/kvm.
        image = nixos-generators.nixosGenerate {
          inherit system;
          format = "qcow-efi";
          modules = [ ./configuration.nix ];
        };

        # Spike D — the dm-verity + UKI golden image. `image.repart` produces a
        # RAW image; ../build-nixos-image.sh --verity converts it to qcow2.
        # Booting the UKI measures PCR 11 → measured-os MET.
        image-verity = self.nixosConfigurations.verity.config.system.build.image;

        # Spike E, Tier A — the netboot installer's kernel + initrd (served over
        # HTTP:8181; ../stage-netboot.sh stages them). The initrd bakes in the
        # target closure so the install is offline.
        installer-kernel = self.nixosConfigurations.installer.config.system.build.kernel;
        installer-initrd = self.nixosConfigurations.installer.config.system.build.netbootRamdisk;

        # Spike E, Tier B — the deployer's kernel + initrd, and a CUSTOM ipxe.efi
        # with the deploy boot-script embedded (so OVMF UEFI-PXE runs it directly).
        # Built via Nix (pkgs.ipxe.override) — no docker, unlike netboot/build-ipxe.sh.
        deployer-kernel = self.nixosConfigurations.deployer.config.system.build.kernel;
        deployer-initrd = self.nixosConfigurations.deployer.config.system.build.netbootRamdisk;
        ipxe-efi =
          let
            deployerInit = "${self.nixosConfigurations.deployer.config.system.build.toplevel}/init";
            embed = pkgs.writeText "deploy-embed.ipxe" ''
              #!ipxe
              :start
              dhcp || goto retry
              kernel http://10.0.2.2:8181/nixos/deployer-bzImage init=${deployerInit} initrd=initrd console=ttyS0,115200 console=tty0 nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf ip=dhcp || goto retry
              initrd http://10.0.2.2:8181/nixos/deployer-initrd || goto retry
              boot || goto retry
              :retry
              echo iPXE boot step failed -- retrying in 3s
              sleep 3
              goto start
            '';
          in pkgs.ipxe.override { embedScript = embed; };

        # Spike G — the SEALED-STORAGE golden image (measured base + sealed-LUKS
        # policy + baked demo). Deployed over the SAME Tier-B path as image-verity.
        image-sealed = self.nixosConfigurations.sealed.config.system.build.image;

        # Spike G's Tier-B deployer trio — same shape as the verity deployer, but
        # its init dd's `nixos261-sealed.raw` and its ipxe.efi chainloads it.
        deployer-sealed-kernel = self.nixosConfigurations.deployerSealed.config.system.build.kernel;
        deployer-sealed-initrd = self.nixosConfigurations.deployerSealed.config.system.build.netbootRamdisk;
        ipxe-efi-sealed =
          let
            init = "${self.nixosConfigurations.deployerSealed.config.system.build.toplevel}/init";
            embed = pkgs.writeText "deploy-sealed-embed.ipxe" ''
              #!ipxe
              :start
              dhcp || goto retry
              kernel http://10.0.2.2:8181/nixos/sealed-deployer-bzImage init=${init} initrd=initrd console=ttyS0,115200 console=tty0 nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf ip=dhcp || goto retry
              initrd http://10.0.2.2:8181/nixos/sealed-deployer-initrd || goto retry
              boot || goto retry
              :retry
              echo iPXE boot step failed -- retrying in 3s
              sleep 3
              goto start
            '';
          in pkgs.ipxe.override { embedScript = embed; };
      };

      nixosConfigurations = {
        # Expose the systemd version: nix eval .#…measured.pkgs.systemd.version --raw
        measured = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./configuration.nix ];
        };
        verity = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./verity.nix { nixpkgs.hostPlatform = system; } ];
        };

        # Spike E, Tier A: the on-disk target system, and the netboot installer
        # that lays it down. The installer is handed the target's toplevel so it
        # can bake it in and install offline.
        target = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./target.nix ];
        };
        installer = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            targetSystem = self.nixosConfigurations.target.config.system.build.toplevel;
          };
          modules = [ ./installer.nix ];
        };

        # Spike E, Tier B: the deployer that dd's the golden image onto disk.
        deployer = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./deployer.nix ];
        };

        # Spike G: the sealed-storage golden image, and the deployer that lays it
        # down over the SAME Tier-B path (only the raw filename differs).
        sealed = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./sealed.nix { nixpkgs.hostPlatform = system; } ];
        };
        deployerSealed = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { imageFile = "nixos261-sealed.raw"; };
          modules = [ ./deployer.nix ];
        };
      };
    };
}
