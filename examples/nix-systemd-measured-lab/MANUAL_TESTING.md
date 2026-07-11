# MANUAL_TESTING.md — nix-systemd-measured-lab

Every checkpoint below is tagged **[VERIFIABLE-HERE]** (runs in the repo CI
container, no privilege) or **[YOU-RUN-THIS]** (needs Nix / KVM / root / TPM /
BPF-LSM — authored here, run by you). Nothing [YOU-RUN-THIS] is claimed as
CI-verified.

---

## Part 0 — Static checks [VERIFIABLE-HERE]

These are exactly what `tools/paths.py smoke --run` executes (the learning-path
`verify_cmd`s), plus TOML/shell syntax. Real captured output:

### 0.1 The three pillar directives are wired (grep the `units/` mirrors)

```console
$ grep -q 'ConditionSecurity=measured-os' examples/nix-systemd-measured-lab/units/measured-os-check.service && echo MEAS-OK
MEAS-OK
$ grep -q 'RestrictFileSystemAccess=/nix/store' examples/nix-systemd-measured-lab/units/verity-exec-restrict.service && echo RFA-OK
RFA-OK
$ grep -Eq 'ConditionFraction=|ConditionMachineTag=' examples/nix-systemd-measured-lab/units/canary-rollout.service && echo GATE-OK
GATE-OK
```

### 0.2 The deploy TOML is a UEFI pxe-install spec

```console
$ grep -Eq 'backend *= *"pxe-install"' .../vm/nix-measured-deploy.toml \
    && grep -Eq 'firmware *= *"uefi"' .../vm/nix-measured-deploy.toml && echo TOML-OK
TOML-OK
$ python3 -c "import tomllib;d=tomllib.load(open('.../vm/nix-measured-deploy.toml','rb'));print([v['name'] for v in d['vm']],[s['name'] for s in d['service']])"
['nix-measured-install'] ['http']
```

### 0.3 Shell + iPXE syntax

```console
$ bash -n ipxe/build-boot-rom.sh vm/run-measured-vm.sh vm/run-fleet.sh && echo BASH-OK
BASH-OK
$ head -1 ipxe/boot.ipxe
#!ipxe
$ grep -q 'chain ${server}/installer.efi' ipxe/boot.ipxe && echo CHAIN-OK
CHAIN-OK
```

### 0.4 The `units/` mirrors match their `.nix` sources

Eyeball each pillar's marker string appears in **both** the `.nix` and the
`.service` mirror (they must stay in sync by hand):

```console
$ for m in ConditionSecurity=measured-os RestrictFileSystemAccess=/nix/store ConditionFraction= ; do
    echo "== $m =="; grep -rl -- "$m" examples/nix-systemd-measured-lab/nix examples/nix-systemd-measured-lab/units; done
```

Expect each marker found under both `nix/pillars/` and `units/`.

---

## Part 1 — Build the image with Nix [YOU-RUN-THIS]

Needs Nix + network. Use [`hand-walk/`](hand-walk/RUNBOOK.md) for a container
that has Nix.

```console
$ cd nix && nix build .#ddi-a
$ ls result*/
nixos-measured_1.efi  nixos-measured_1_root.raw  nixos-measured_1_verity.raw
$ # Reproducibility (nixpkgs#286969 workaround): build twice, compare.
$ nix build .#ddi-a -o a1 && nix build .#ddi-a --rebuild -o a2 && cmp a1/*_root.raw a2/*_root.raw && echo REPRO-OK
REPRO-OK
$ # Prove the root really is dm-verity:
$ veritysetup dump nixos-measured_1_verity.raw | grep 'Root hash'
Root hash:      <64 hex chars>
```

**Checkpoint:** three split artifacts (UKI + root + verity); a stable roothash;
byte-identical rebuild.

---

## Part 2 — Deploy on-disk via iPXE [YOU-RUN-THIS]

```console
$ nix build .#installer && cp result/installer.efi ~/netboot/
$ ipxe/build-boot-rom.sh --server http://10.0.2.2:8181 --output-dir ~/netboot
[build-boot-rom] done: ipxe.efi + boot.ipxe staged
$ phase4-podman/lab-podman.sh up     --config .../vm/nix-measured-deploy.toml
$ phase2-qemu-vm/lab-vm.sh    create --config .../vm/nix-measured-deploy.toml
$ phase2-qemu-vm/lab-vm.sh    start  nix-measured-install
... OVMF → iPXE → chain installer.efi ...
INSTALL: fetching DDI-A root+verity from http://10.0.2.2:8181
INSTALL: laying out A/B slots on /dev/vda and writing slot A
INSTALL-DONE: slot A written from DDI-A; rebooting on-disk
```

**Checkpoint:** the installer's `INSTALL-DONE:` line, then a second boot that
comes off `/dev/vda` (the NIC ROM is never reached again).

---

## Part 3 — Measured boot (Pillar 1) [YOU-RUN-THIS]

Boot the installed disk **with a software TPM**:

```console
$ vm/run-measured-vm.sh --disk ~/.local/share/mklab-vm/nix-measured-install/disk.qcow2
[run-measured-vm] starting swtpm ...
[run-measured-vm] booting ... with a measured TPM (accel=kvm)
nix-measured login: lab   (password: lab)

$ journalctl -u measured-os-check
MEASURED-OS: boot measured, PCR11=0x<...>
$ systemd-analyze pcrs | grep ' 11 '
 11 ...  <non-zero>
```

**Negative control** — boot the SAME disk through plain `lab-vm.sh` (no TPM):

```console
$ journalctl -u measured-os-check
... measured-os-check.service - Condition check resulted in ... being skipped.
```

**Checkpoint:** with swtpm → `MEASURED-OS: boot measured` + PCR 11 non-zero;
without a TPM → the unit is **skipped** by `ConditionSecurity=measured-os`.

---

## Part 4 — Execution restriction (Pillar 2) [YOU-RUN-THIS]

On the measured on-disk system:

```console
$ journalctl -u verity-exec-restrict
EXEC-RESTRICT: on-store exec allowed
EXEC-RESTRICT: off-store exec denied rc=126
$ cp /run/current-system/sw/bin/true /tmp/rogue && chmod +x /tmp/rogue && /tmp/rogue
sh: /tmp/rogue: Permission denied      # BPF-LSM refuses off-verity exec
$ findmnt -no FSTYPE /nix/store        # prove it is the verity fs
erofs
```

**Checkpoint:** an on-store binary runs; a rogue binary copied to `/tmp` (not on
the dm-verity fs) is refused execution by `RestrictFileSystemAccess=/nix/store`.

---

## Part 5 — Rollout gating (Pillar 3) [YOU-RUN-THIS]

```console
$ vm/run-fleet.sh --disk .../disk.qcow2 --count 10 --canary 2
[run-fleet] launching 10 VMs (2 tagged canary) ...
=== Rollout gating result (marker: CANARY-ACTIVE) ===================
  vm-1: CANARY-ACTIVE (tagged)
  vm-2: CANARY-ACTIVE (tagged)
  vm-3: skipped (gate not satisfied)
  ...
  vm-10: skipped (gate not satisfied)
====================================================================
canary active on 2/10 machines — off ONE golden image.
```

**Checkpoint:** the canary fires only on the tagged/selected minority; every VM
booted the identical image — the only difference is local machine-id + tag.

---

## Part 6 — A/B update + rollback (sysupdate) [YOU-RUN-THIS]

```console
$ (cd nix && nix build .#ddi-b) && cp result*/* ~/netboot/     # the "next" build
$ # on the running system:
$ systemctl start systemd-sysupdate
Selected update 'nixos-measured_2' → slot B
$ reboot        # boots v2 from slot B (PCR 11 now reflects the v2 UKI)
$ cat /etc/os-release | grep IMAGE_VERSION
IMAGE_VERSION=2
$ # Simulate a bad v2: break it, reboot 3×; boot-counting rolls back to A(v1):
$ cat /etc/os-release | grep IMAGE_VERSION
IMAGE_VERSION=1
```

**Checkpoint:** v2 boots from the inactive slot; a slot that fails
`boot-complete.target` three times is automatically rolled back to v1.
