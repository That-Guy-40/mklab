# LXD / Incus example labs — Phase 5

Ready-to-run [`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/) TOML specs: system
containers and hardware VMs under one API, with profiles and projects. Point the
tool at one with `--config examples/lxd-examples/<file>` (paths below are from the
repo root, where you run `lab-lxd.sh`).

> Grouped into this subdir so the flat [`examples/`](../) directory stays
> scannable — these were previously top-level `examples/lxd-*.toml`. For the full
> walkthrough see the phase docs:
> [`START_HERE_LXC_WIZARD.md`](../../phase5-lxd/START_HERE_LXC_WIZARD.md) ·
> [`SHOWCASE.md`](../../phase5-lxd/SHOWCASE.md) ·
> [`MANUAL_TESTING.md`](../../phase5-lxd/MANUAL_TESTING.md).

## The specs

| File | What you get |
|---|---|
| [`lxd-plain-single.toml`](lxd-plain-single.toml) | Smallest useful lab: one Alpine **container**, no profiles/projects. |
| [`lxd-vm-single.toml`](lxd-vm-single.toml) | One Alpine **VM** (real QEMU virt under LXD — needs `/dev/kvm` + block-backed storage). |
| [`lxd-mixed-topology.toml`](lxd-mixed-topology.toml) | 2 containers + 1 VM in one lab — exercises the container/VM discriminator. |
| [`lxd-profiles-projects.toml`](lxd-profiles-projects.toml) | `[[profile]]` + `[[project]]` demo — LXD-native config bundles + namespace isolation. |
| [`lxd-from-chroot.toml`](lxd-from-chroot.toml) | Cross-phase: a Phase-1 chroot → a Phase 5 container image (via tarball; a VM-via-Phase-2 workaround is noted inline). |

## Quick start

```bash
# simplest: one Alpine container
phase5-lxd/lab-lxd.sh up   --config examples/lxd-examples/lxd-plain-single.toml
phase5-lxd/lab-lxd.sh list --lab hello-lxd
phase5-lxd/lab-lxd.sh exec hello-lxd/shell -- cat /etc/os-release
phase5-lxd/lab-lxd.sh down --lab hello-lxd
```

## Prerequisites

- **LXD or Incus initialised** — `lxd init` (or `incus admin init`).
- **VMs** (`lxd-vm-single.toml`, and the VM in `lxd-mixed-topology.toml`): a
  readable `/dev/kvm` and a **block-backed** storage pool (zfs / btrfs / lvm —
  not `dir`). The specs set `security.secureboot=false` because most community
  Alpine VM images aren't signed for UEFI Secure Boot.
- **`lxd-from-chroot.toml`**: build and export a Phase-1 chroot tarball first —
  the exact steps are in that file's header comment.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog across all
phases.
