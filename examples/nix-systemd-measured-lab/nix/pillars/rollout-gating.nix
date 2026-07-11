# pillars/rollout-gating.nix — PILLAR 3: rollout gating (systemd 261).
#
# systemd owns: deciding WHICH machines in a fleet activate a unit — without a
# central orchestrator, purely from local identity.  Nix owns: shipping the SAME
# immutable image to every machine, so the only variable is the gate.
#
# Two NEW-in-261 directives:
#   ConditionFraction=10%      run on a hash(machine-id)-selected ~10% of the fleet
#   ConditionMachineTag=canary run only where /etc/machine-info tags it "canary"
#
# Boot the SAME DDI as N VMs with different machine-ids/tags
# (../../vm/run-fleet.sh) and watch the canary fire on the selected minority and
# skip on the rest — a staged rollout off one golden image.
#
# Mirror: ../../units/canary-rollout.service  (keep markers in sync).
# Marker asserted by MANUAL_TESTING + learning-paths verify: "CANARY-ACTIVE" and
# the directive strings "ConditionFraction=" / "ConditionMachineTag=".

{ config, pkgs, lib, ... }:

{
  # The tag ConditionMachineTag= reads.  On the golden image this ships empty;
  # ../../vm/run-fleet.sh writes MACHINE_TAGS=canary into /etc/machine-info on
  # the subset it wants to canary (via a credential / systemd-firstboot).
  # `imageMachineTags` can also bake a default tag into a whole build if desired.
  environment.etc."machine-info".text = lib.mkDefault ''
    # Tags consumed by ConditionMachineTag=.  Overridden per-machine at deploy.
    MACHINE_TAGS=
  '';

  systemd.services."canary-rollout" = {
    description = "Canary unit — activates on only a fraction (or tagged subset) of the fleet";
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      # Either gate alone is enough to demo; both together AND: a tagged machine
      # that also falls in the 10% hash bucket.  For the fleet demo we rely on
      # the tag (deterministic) and SHOW the fraction bucketing in the journal.
      ConditionFraction = "10%";
      ConditionMachineTag = "canary";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      echo "CANARY-ACTIVE on $(cat /etc/machine-id)"
    '';
  };
}
