# Manual testing — what's verified where

This lab is split honestly between what runs on the **mklab host** (static +
logic checks, all green) and what is **author-run under KVM** (anything needing a
real ZFS pool or a boot). The host used here had **no KVM, no ZFS, and no
outbound reach to the ZFSBootMenu release/docs endpoints**, so the ZFS-root
install and the ZBM boot are necessarily author-run — see the matrix.

## Verification matrix

| Piece | How it's checked | Where |
|---|---|---|
| `be.sh` boot-environment command plan (snapshot/clone/activate/destroy/rollback/cmdline/rename) | `tests/test-be-logic.sh` — dry-run plan asserted, no pool needed | ✅ mklab host |
| BE properties correct (`canmount=noauto`, `mountpoint=/`, `bootfs`, `org.zfsbootmenu:commandline`) | asserted in `test-be-logic.sh` | ✅ mklab host |
| `config.yaml` valid + has generate-zbm keys | `tests/test-config-yaml.sh` (PyYAML parse + structure) | ✅ mklab host |
| `be.sh` + `install-zfs-root.sh` lint clean | `tests/test-scripts-shellcheck.sh` (shellcheck 0.9.0) | ✅ mklab host |
| `zbm-debian.toml` is a well-formed UEFI disk-image spec | `tests/test-vm-spec.sh` (tomllib parse + field asserts) | ✅ mklab host |
| `zbm-debian.toml` → OVMF pflash + virtio-blk QEMU argv | same test, second layer (needs `qemu-system-x86_64`) | ⏳ deferred (no qemu here) |
| Root-on-ZFS Debian install (`install-zfs-root.sh`) | run inside a UEFI Debian live VM w/ ZFS + blank disk | 🧑 author-run under KVM |
| ZFSBootMenu boots + `kexec`s the BE | reboot the installed VM; `/proc/cmdline` + `findmnt / → zfs` | 🧑 author-run under KVM |
| Clone → boot → break → reboot original (the BE round trip) | `be.sh` inside the VM per RUNBOOK §3–5 | 🧑 author-run under KVM |

## Captured transcript — host-safe suite (green)

Environment: `Ubuntu 24.04.4 LTS`, `kvm: ABSENT`, `zfs: absent`, `shellcheck 0.9.0`.

```console
$ tests/run-all.sh
  - create: snapshot + clone -o canmount=noauto -o mountpoint=/  ✓
  - create (no -e): sources the active BE  ✓
  - activate: zpool set bootfs=...  ✓
  - cmdline: org.zfsbootmenu:commandline=...  ✓
  - snapshot + rollback  ✓
  - rename  ✓
  - guardrail: create with no NAME is rejected  ✓
PASS: be.sh emits the correct ZFS + ZFSBootMenu boot-environment command plan
  - valid YAML; ManageImages=true; EFI output enabled; ESP + cmdline present
PASS: config.yaml is valid and carries the keys generate-zbm needs for a Debian EFI build
  - shellcheck clean: be.sh
  - shellcheck clean: install-zfs-root.sh
PASS: all lab shell scripts pass shellcheck
  - spec ok: name=zbm-debian backend=disk-image firmware=uefi cloud_init=false
  - zbm-debian.toml: UEFI disk-image spec is well-formed  ✓
  - qemu-system-x86_64 absent — argv-wiring assertion deferred to a KVM-capable host
PASS: zbm-debian.toml is a well-formed UEFI disk-image spec (argv wiring deferred: no qemu here)

== 4 passed, 0 skipped, 0 failed ==
```

Spot-check of the actual command plan `be.sh` emits (this is what the logic test
asserts, shown here for the reader):

```console
$ BE_DRYRUN=1 ZBM_POOL=rpool BE_SNAPSHOT_TAG=preupgrade ./be.sh create -e default testupgrade
+ zfs snapshot rpool/ROOT/default@preupgrade
+ zfs clone -o canmount=noauto -o mountpoint=/ rpool/ROOT/default@preupgrade rpool/ROOT/testupgrade
$ BE_DRYRUN=1 ZBM_POOL=rpool ./be.sh activate testupgrade
+ zpool set bootfs=rpool/ROOT/testupgrade rpool
```

## Author-run checklist (under KVM) — fill in when you run it

Run on a KVM-capable UEFI host, then record real output here:

- [ ] Built a UEFI Debian live VM with ZFS (`/dev/zfs` present, `[ -d /sys/firmware/efi ]`).
- [ ] `DISK=/dev/vdb sudo ./install-zfs-root.sh` completed; `zpool status rpool` healthy.
- [ ] Rebooted; **ZFSBootMenu banner** appeared, then `zbm-debian login:`.
- [ ] `findmnt -no FSTYPE /` → `zfs`; `cat /proc/cmdline` → `root=zfs:rpool/ROOT/debian …`.
- [ ] `./be.sh create testupgrade && ./be.sh activate testupgrade && reboot`.
- [ ] After reboot `cat /proc/cmdline` → `…rpool/ROOT/testupgrade…` (booted the clone).
- [ ] `./be.sh activate debian && reboot` → back on the original BE (rollback proven).

> The ZFS-root install + ZBM boot were **not** executed in the authoring
> environment (no KVM/ZFS/egress). The scripts and RUNBOOKs are ready-to-run and
> faithful to the upstream Debian guide ([`UPSTREAM.md`](UPSTREAM.md)); this
> checklist is the honest boundary of what's proven vs. what you run.
