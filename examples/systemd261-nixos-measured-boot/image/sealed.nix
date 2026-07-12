# examples/systemd261-nixos-measured-boot/image/sealed.nix
#
# Spike G — the SEALED-STORAGE golden image: the Spike-D measured/dm-verity base
# (verity.nix, so PCR 11 carries the measured OS), plus everything needed to seal
# LUKS storage to that measured state and to run the attestation demo on-target.
#
# It ships over the SAME Tier-B iPXE/UEFI path as the verity image (Spike E Tier
# B): `stage-netboot.sh --sealed` builds this as a golden raw, a custom Nix-built
# ipxe.efi chainloads the deployer, the deployer `dd`s it onto disk. Sealing is
# necessarily done ON THE TARGET (against the target's own TPM/PCRs), so the image
# carries the POLICY and the demo, not a pre-sealed keyslot.
#
# HONEST FRAMING (load-bearing): under QEMU/KVM the TPM is swtpm — a *software*
# emulator (manufacturer "IBM"). This exercises the sealing/attestation plumbing
# faithfully but is NOT a trust anchor: anything that can read swtpm's userspace
# can forge PCR state or the attestation key. The production anchor is a hardware
# TPM, a hypervisor-backed vTPM rooted in host silicon, or confidential computing.
# See RUNBOOK-sealed-luks.md.
{ config, lib, pkgs, ... }:
{
  imports = [ ./verity.nix ];   # measured base: UKI → PCR 11, dm-verity /usr

  networking.hostName = lib.mkForce "nixos261s";

  # Runtime dm-crypt + loopback so `systemd-cryptsetup` / the demo can open LUKS
  # volumes on the immutable, tmpfs-root appliance.
  boot.kernelModules = [ "dm_crypt" ];

  # Bake the VERIFIED sealed-LUKS + attestation demo into the image, so an
  # operator on the deployed measured host can prove the whole chain against the
  # REAL measured PCR 7+11 with one command:  /etc/lab/sealed-luks-demo
  environment.etc."lab/sealed-luks-demo" = {
    source = ./sealed-luks-demo.guest.sh;
    mode = "0755";
  };

  # A login hint pointing at the demo (this is a throwaway lab appliance).
  users.motd = ''
    systemd-261 sealed-storage lab (nixos261s) — MEASURED image.
      Prove TPM2-sealed LUKS + attestation against the live PCR 7+11:
        /etc/lab/sealed-luks-demo
      swtpm here is PLUMBING, not a trust anchor. See RUNBOOK-sealed-luks.md.
  '';

  # ── Declarative on-target sealed /data — REFERENCE, opt-in ──────────────────
  # The systemd-261 image-based idiom: ship the intent, realize it on first boot
  # against the target's own TPM. This service reproduces the demo's VERIFIED
  # enroll flow (`systemd-cryptenroll --tpm2-pcrs=7+11`) on a real data device.
  #
  # It is `wantedBy = [ ]` (DISABLED) so the measured image always boots cleanly
  # even with no spare data device — enable it (and attach a data disk/partition)
  # to realize persistent sealed /data. The full first-boot realization is
  # author-run (needs a data device + a reboot); the crypto core it uses is the
  # same one proven live by sealed-luks-demo. See MANUAL_TESTING.md §Spike G.
  systemd.services.seal-data = {
    description = "Spike G: enroll + unlock a TPM2-sealed /data (bound to PCR 7+11)";
    wantedBy = lib.mkDefault [ ];              # opt-in; see RUNBOOK-sealed-luks.md
    after = [ "local-fs.target" ];
    unitConfig.ConditionPathExists = "/dev/disk/by-partlabel/data";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = with pkgs; [ cryptsetup systemd util-linux coreutils ];
    script = ''
      set -eu
      DEV=/dev/disk/by-partlabel/data
      MAP=data
      HELPER="${pkgs.systemd}/bin/systemd-cryptsetup"
      if cryptsetup isLuks "$DEV"; then
        echo "seal-data: $DEV is already LUKS — unsealing with the TPM"
        "$HELPER" attach "$MAP" "$DEV" - tpm2-device=auto,headless=true
      else
        echo "seal-data: initializing $DEV as TPM2-sealed LUKS (PCR 7+11)"
        KEY=$(mktemp); trap 'rm -f "$KEY"' EXIT
        head -c 32 /dev/urandom > "$KEY"; chmod 600 "$KEY"
        cryptsetup luksFormat --type luks2 --batch-mode "$DEV" "$KEY"
        systemd-cryptenroll --unlock-key-file="$KEY" \
          --tpm2-device=auto --tpm2-pcrs=7+11 "$DEV"
        cryptsetup luksRemoveKey "$DEV" "$KEY"     # drop the bootstrap key: TPM-only
        "$HELPER" attach "$MAP" "$DEV" - tpm2-device=auto,headless=true
        mkfs.ext4 -q -L data /dev/mapper/"$MAP"
      fi
      mkdir -p /data
      mount /dev/mapper/"$MAP" /data
      echo "seal-data: /data mounted from a TPM2-sealed volume (no passphrase)"
    '';
  };
}
