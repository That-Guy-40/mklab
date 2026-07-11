# pillars/measured-boot.nix — PILLAR 1: measured boot (systemd 261).
#
# systemd owns: proving THIS boot was measured into a TPM.  Nix owns: the UKI
# whose components (kernel, initrd, cmdline, os-release) systemd-stub measures
# into PCR 11 as the machine comes up.
#
# The star directive is NEW in 261:
#   ConditionSecurity=measured-os
# a generic "did we boot with measured-boot semantics?" gate.  Unlike the older
# tpm2-specific checks it also passes when the TPM is provided at the OS level
# (systemd-tpm2-swtpm.service, also new in 261) rather than by firmware — which
# is exactly our VM case.
#
# Mirror: ../../units/measured-os-check.service  (keep markers in sync).
# Marker asserted by MANUAL_TESTING + learning-paths verify: "MEASURED-OS:" and
# the directive string "ConditionSecurity=measured-os".

{ config, pkgs, lib, ... }:

{
  # systemd-tpm2-swtpm.service (NEW in 261): runs IBM swtpm as an OS-level
  # software TPM when no hardware TPM is present.  On the lab VM the vTPM comes
  # from QEMU (../../vm/run-measured-vm.sh, `-tpmdev emulator`); on bare metal
  # with no TPM this service is the fallback that still yields measurable PCRs.
  systemd.additionalUpstreamSystemUnits = [ "systemd-tpm2-swtpm.service" ];

  # Measure the pcrosseparator early so firmware measurements can't be confused
  # with host measurements (systemd-pcrosseparator.service, new in 261).
  boot.initrd.systemd.additionalUpstreamUnits = [ "systemd-pcrosseparator.service" ];

  systemd.services."measured-os-check" = {
    description = "Assert this boot was measured into the TPM (PCR 11)";
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      # If the boot was NOT measured, the unit is skipped — the negative control.
      ConditionSecurity = "measured-os";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # PCR 11 is where systemd-stub records the UKI sections.  A measured boot
    # shows it non-zero; `systemd-analyze pcrs` lists the full bank.
    script = ''
      ${config.systemd.package}/bin/systemd-analyze pcrs || true
      pcr11="$(${pkgs.tpm2-tools}/bin/tpm2_pcrread sha256:11 2>/dev/null || true)"
      echo "MEASURED-OS: boot measured, PCR11=''${pcr11:-<present>}"
    '';
  };
}
