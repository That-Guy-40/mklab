# PLAN.md — nix-systemd-measured-lab

Design history + the open engineering decisions, for the next person to pick up.

## Thesis

From an earlier design session: **let Nix keep reproducibility + image
composition; let systemd own measured boot, execution restriction, and rollout
gating.** systemd 261 (2026-06) happens to ship a *new* directive for each of
those three, and NixOS's `image.repart` is the mature bridge that produces the
signed dm-verity + UKI image the systemd side needs. See
[`README.md`](README.md) for the user-facing story.

## Phases (build order)

1. **Compose the image (Nix).** [`nix/image.nix`](nix/image.nix) — `image.repart`
   with an ESP (UKI + systemd-boot), a dm-verity **data** partition (erofs
   `/nix/store`), and a dm-verity **hash** partition, paired by `VerityMatchKey`.
   The roothash is injected into the UKI cmdline at build time. Output split so
   sysupdate can move root/verity/UKI independently.
2. **Bake the three pillars.** [`nix/pillars/`](nix/pillars/) — one module each;
   mirrored to plain-text [`units/`](units/) so the directives stay grep-able
   without Nix.
3. **On-disk A/B + updates.** [`nix/ab-layout.nix`](nix/ab-layout.nix) (runtime
   `systemd.repart` slots + boot counting) and
   [`nix/sysupdate.nix`](nix/sysupdate.nix) (transfer files).
4. **Deploy.** [`nix/installer.nix`](nix/installer.nix) writes slot A via
   `BlockDeviceReplace=`; iPXE glue in [`ipxe/`](ipxe/README.md); the unified
   Phase-4+2 spec in [`vm/nix-measured-deploy.toml`](vm/nix-measured-deploy.toml).
5. **Measured boot harness.** [`vm/run-measured-vm.sh`](vm/run-measured-vm.sh)
   (swtpm) and [`vm/run-fleet.sh`](vm/run-fleet.sh) (fleet fractioning).

## Open engineering decisions & gotchas

### 1. `lab-vm.sh` has no vTPM — measured boot uses a raw-QEMU harness

`phase2-qemu-vm/lab-vm.sh` emits no TPM device (`grep tpmdev|swtpm` → 0 hits),
and measured boot needs PCRs. Rather than thread a swtpm daemon lifecycle through
`lab-vm.sh`'s create/start/stop/destroy/manifest — a large change to the core
tool for one lab — the lab ships its own launcher
([`vm/run-measured-vm.sh`](vm/run-measured-vm.sh)) that reuses the same OVMF
two-file pflash wiring and adds `swtpm` + `-tpmdev emulator` + `-device tpm-crb`.
This mirrors the repo's other out-of-`lab-vm.sh` labs (FreeBSD, libvirt).

**Future work — optional `lab-vm.sh` patch.** If measured boot should run through
the core tool, add a `tpm` field (`""` | `"crb"` | `"tis"`) to the `[[vm]]`
schema and spawn swtpm in the arg builder:
- schema default: beside `secure_boot` in `specs_from_config` (~`lab-vm.sh:1713`)
- CLI: `--tpm` in `spec_from_cli` (~`:1626`, into the jq object ~`:1667`)
- manifest: `tpm=` in the heredoc (~`:368`), `MF_TPM` export (~`:2528`),
  `read_manifest_field … tpm` (~`:2619`)
- validate: require `firmware="uefi"` when `tpm!=""` (~`:2379`)
- argv: after the firmware block (~`:2144`) spawn swtpm to `$(vm_dir)/swtpm.sock`
  and append the `-chardev/-tpmdev/-device tpm-*` trio; tear the swtpm PID down
  in `stop`/`destroy` (**kill by recorded PID, never by pattern** — CLAUDE.md).

Kept as a note here, **not implemented**, so the core tool stays untouched.

### 2. UEFI, not BIOS

UKI + measured boot both require UEFI. The richest pxe-install exemplar
(almalinux) is BIOS + `boot.ipxe`, but UEFI pxe-install is first-class supported
(`vm-almalinux-uefi-pxe.toml`). The lab uses `firmware = "uefi"` +
`pxe_bootfile = "ipxe.efi"`; do **not** copy the BIOS two-disk `boot.ipxe`
pattern.

### 3. Reproducibility — nixpkgs#286969

`systemd-repart` runs in its own mount+user namespace, which can drop
`SOURCE_DATE_EPOCH` / `TZ`, so baked timestamps drift and the DDI stops being
byte-reproducible. Worked around in [`nix/image.nix`](nix/image.nix) by pinning
both into `image.repart.mkfsEnv`. Re-verify byte-identical output after any
nixpkgs bump: `nix build .#ddi-a` twice, `cmp` the results.

### 4. systemd 261 version floor

`ConditionSecurity=measured-os`, `RestrictFileSystemAccess=`, `ConditionFraction=`,
`ConditionMachineTag=`, `systemd-tpm2-swtpm.service`, and
`systemd-repart … BlockDeviceReplace=` are all **≥ 261** (2026-06 — very new).
[`nix/configuration.nix`](nix/configuration.nix) asserts `systemd ≥ 261` at build
time so a stale nixpkgs fails loudly rather than silently skipping the conditions
at runtime. If the pinned channel lags, use the systemd overlay sketched in that
file and date the tag in [`SOURCES.md`](SOURCES.md).

### 5. Placeholder to replace before running

`nix/configuration.nix` ships a **placeholder** `hashedPassword`. Regenerate with
`mkpasswd -m yescrypt lab` before building, or SSH/login will fail.

## Honest partition

Every runtime step is **[YOU-RUN-THIS]** (Nix, TPM, dm-verity, BPF-LSM, KVM — none
in CI). **[VERIFIABLE-HERE]**: the directive markers in [`units/`](units/), the
catalog routing, link integrity, TOML/shell syntax. Full tagged transcript in
[`MANUAL_TESTING.md`](MANUAL_TESTING.md).
