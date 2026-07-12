# examples/nixos-ipxe-deploy/modules/ipxe.nix
#
# REUSABLE building block — a custom ipxe.efi (UEFI) with a deploy boot-script
# EMBEDDED, built via Nix (pkgs.ipxe.override) so it needs no docker (unlike the
# repo's netboot/build-ipxe.sh, which wants a docker daemon). OVMF UEFI-PXE loads
# this .efi over slirp TFTP and runs the embedded script directly — it DHCPs and
# HTTP-boots the given kernel+initrd (the installer or the deployer).
#
# Usage (from a flake that has `pkgs`):
#   lib.mkIpxeEfi = import ./modules/ipxe.nix { inherit pkgs; };
#   packages.ipxe-efi = lib.mkIpxeEfi {
#     initPath  = "${self.nixosConfigurations.myDeployer.config.system.build.toplevel}/init";
#     kernelUrl = "http://10.0.2.2:8181/img/deployer-bzImage";
#     initrdUrl = "http://10.0.2.2:8181/img/deployer-initrd";
#   };
# The result's $out/ipxe.efi is the file to stage as the pxe_bootfile. `ip=dhcp`
# is on the kernel line because the slirp DHCP lease iPXE gets is NOT inherited
# by the booted kernel.
{ pkgs }:
{ initPath, kernelUrl, initrdUrl }:
let
  embed = pkgs.writeText "nixos-ipxe-deploy-embed.ipxe" ''
    #!ipxe
    :start
    dhcp || goto retry
    kernel ${kernelUrl} init=${initPath} initrd=initrd console=ttyS0,115200 console=tty0 nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf ip=dhcp || goto retry
    initrd ${initrdUrl} || goto retry
    boot || goto retry
    :retry
    echo iPXE boot step failed -- retrying in 3s
    sleep 3
    goto start
  '';
in
pkgs.ipxe.override { embedScript = embed; }
