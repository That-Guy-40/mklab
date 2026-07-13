# PLAN — ZFSBootMenu boot environments on Debian

Build order and honest status. The lab is deliberately split so its *logic* is
provable on any host and its *effects* run under KVM.

## Phase A — the boot-environment engine  ✅ verified on the mklab host
- [`be.sh`](be.sh): a `bectl`-style BE manager over ZFS + ZFSBootMenu
  properties, with injectable `zfs`/`zpool` + a dry-run plan mode.
- [`tests/test-be-logic.sh`](tests/test-be-logic.sh): asserts the exact command
  plan (clone with `canmount=noauto`/`mountpoint=/`, `bootfs` activate,
  `org.zfsbootmenu:commandline`, snapshot/rollback/rename, guardrails) — no pool
  needed.

## Phase B — the generate-zbm config  ✅ verified on the mklab host
- [`config.yaml`](config.yaml): annotated `generate-zbm` config (unified EFI
  output, ESP mount, ZBM's own cmdline).
- [`tests/test-config-yaml.sh`](tests/test-config-yaml.sh): YAML validity +
  required keys.

## Phase C — the phase-2 boot spec  ✅ spec verified / ⏳ argv deferred
- [`zbm-debian.toml`](zbm-debian.toml): a `disk-image`/`uefi` spec that boots the
  root-on-ZFS qcow2 under OVMF via `phase2-qemu-vm/lab-vm.sh`.
- [`tests/test-vm-spec.sh`](tests/test-vm-spec.sh): validates the spec (host-safe)
  and asserts the OVMF/virtio argv when qemu is present (deferred here).

## Phase D — the install  🧑 author-run under KVM
- [`install-zfs-root.sh`](install-zfs-root.sh) + [`RUNBOOK-install.md`](RUNBOOK-install.md):
  partition → pool → datasets → debootstrap → chroot (kernel + zfs-dkms +
  zfs-initramfs) → ZBM onto the ESP → `efibootmgr` entry. Lint-clean here;
  needs a UEFI Debian live VM with ZFS + a blank disk to actually run.

## Phase E — the workflow  🧑 author-run under KVM
- [`RUNBOOK-boot-environments.md`](RUNBOOK-boot-environments.md): the lifecycle —
  snapshot, clone, activate, boot, roll back, promote — and the FreeBSD `bectl`
  cheat sheet. Includes the serial-console char-drop caveat for menu automation.

## Provenance & honesty
- [`UPSTREAM.md`](UPSTREAM.md): cite-don't-mirror of the official ZBM docs +
  FreeBSD handbook (the sources aren't a single blog post, and were unreachable
  from the build egress).
- [`MANUAL_TESTING.md`](MANUAL_TESTING.md): the verified-here vs. author-run
  matrix + captured transcript.
