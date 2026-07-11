# pillars/exec-restriction.nix — PILLAR 2: execution restriction (systemd 261).
#
# THE SEAM between Nix and systemd.  Nix owns: a signed, integrity-checked
# dm-verity /nix/store (../../nix/image.nix).  systemd owns: refusing to execute
# anything that isn't on it.
#
# The star directive is NEW in 261:
#   RestrictFileSystemAccess=/nix/store
# a BPF-LSM program that permits execve() ONLY for binaries residing on the
# listed (signed, verified) dm-verity filesystem.  A binary copied to /tmp — not
# on the verity fs — is refused, even though it is +x and the caller is root.
#
# Mirror: ../../units/verity-exec-restrict.service  (keep markers in sync).
# Marker asserted by MANUAL_TESTING + learning-paths verify: "EXEC-RESTRICT:" and
# the directive string "RestrictFileSystemAccess=/nix/store".

{ config, pkgs, lib, ... }:

let
  # An on-store binary that MUST be allowed to run (it lives on the verity root).
  helloOnStore = lib.getExe pkgs.hello;
in
{
  # RestrictFileSystemAccess= is a BPF-LSM; the kernel must load bpf in its LSM
  # stack.  NixOS kernels ship it, but it has to be selected on the cmdline.
  boot.kernelParams = [ "lsm=landlock,bpf,yama,integrity" ];

  systemd.services."verity-exec-restrict" = {
    description = "Workload allowed to exec ONLY from the signed verity /nix/store";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Pillar 2, the whole point:
      RestrictFileSystemAccess = "/nix/store";

      # Belt-and-suspenders hardening that composes with it.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
    # 1) prove an ON-store binary runs.  2) drop a rogue binary OFF-store (into
    # the service's PrivateTmp) and prove the LSM refuses to exec it.
    script = ''
      ${helloOnStore} >/dev/null && echo "EXEC-RESTRICT: on-store exec allowed"
      cp ${pkgs.coreutils}/bin/true /tmp/rogue && chmod +x /tmp/rogue
      if /tmp/rogue 2>/dev/null; then
        echo "EXEC-RESTRICT: FAIL off-store exec was ALLOWED (LSM not enforcing)"
        exit 1
      fi
      echo "EXEC-RESTRICT: off-store exec denied rc=$?"
    '';
  };
}
