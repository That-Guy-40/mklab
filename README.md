# LAB_CREATE_V2

A staged toolkit for creating throwaway lab environments — chroots, VMs,
and (in later phases) containers — across multiple architectures.

See [`PLAN.md`](PLAN.md) for the full design and rationale, and
[`TODO.md`](TODO.md) for the project backlog.

> **Note on the backlog's hash-cracking item:** it's an educational exercise on
> *our own* throwaway lab credential (the published FLOPPINUX `root`/`lab`
> login) — demonstrating the recovery and the cryptographic *why*, not targeting
> anyone else's secret.

## Status

| Phase | Component | Status | Tour |
|---|---|---|---|
| 1 | [`phase1-chroot/lab-chroot.sh`](phase1-chroot/) | **v0.1 landed** — debootstrap / dnf / host-copy backends, schroot / nspawn / bare managers, foreign-arch via qemu-user-static, rootless (fakechroot+fakeroot), `--json` / `--keep-cache` | [SHOWCASE](phase1-chroot/SHOWCASE.md) |
| 2 | [`phase2-qemu-vm/lab-vm.sh`](phase2-qemu-vm/) | **v0.1 landed** — QEMU full VMs and microvms, cloud-init seeded, all 6 arches; + from-chroot disks, qcow2 snapshots, CPU topology/pinning, bridge/tap, cloud-init overrides | [SHOWCASE](phase2-qemu-vm/SHOWCASE.md) |
| 3 | [`phase3-docker/lab-docker.sh`](phase3-docker/) | **v0.1 landed** — `run`/`up`/`down`/`exec`/`logs`/`list`/`destroy`, multi-arch buildx, `from-chroot` import, TOML topologies | [SHOWCASE](phase3-docker/SHOWCASE.md) |
| 4 | [`phase4-podman/lab-podman.sh`](phase4-podman/) | **v0.1 landed** — pods, quadlet systemd-user export, `from-chroot` + `from-tarball` import, rootless-first | [SHOWCASE](phase4-podman/SHOWCASE.md) |
| 5 | [`phase5-lxd/lab-lxd.sh`](phase5-lxd/) | **v0.1 landed** — LXD/Incus containers + VMs, projects, profiles, `from_qcow2` bridge from Phase 2, `--format lxc-yaml` export | [SHOWCASE](phase5-lxd/SHOWCASE.md) |
| 6 | [`phase6-tui/`](phase6-tui/) (Textual) | **v0.1 landed** — read-only inventory across all 5 phases + cross-phase topology bring-up / tear-down. Create wizards deferred to v0.2. | [SHOWCASE](phase6-tui/SHOWCASE.md) |
| 6b | [`phase6b-web/`](phase6b-web/) (FastAPI + HTMX) | **landed** — the same read-only inventory + topology surface as Phase 6, lifted into FastAPI + HTMX routes for SSH-forward browser use | [README](phase6b-web/README.md) |

**New here?** Each `SHOWCASE.md` above is a 5-minute "what this phase
gets you" tour with copy-pasteable demos and integration notes. Phase 6
is the capstone — it surfaces all five underlying phases in one TUI.

Each phase is a self-contained script (or, for the Python phases, a
self-contained package). Deleting later-phase directories does not break
earlier ones.

## Quick starts

The recipes below are a sampler. For the full catalog of every ready-to-run
spec — grouped by phase, theme, and cross-phase pipeline — see
[`examples/00-INDEX.md`](examples/00-INDEX.md).

### A throwaway Debian chroot

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch x86_64 --target /var/chroots/bookworm
sudo phase1-chroot/lab-chroot.sh enter bookworm
```

See [`phase1-chroot/README.md`](phase1-chroot/README.md) and
[`phase1-chroot/MANUAL_TESTING.md`](phase1-chroot/MANUAL_TESTING.md).

### A throwaway Debian VM

```bash
phase2-qemu-vm/lab-vm.sh create --name deb1 --distro debian --suite bookworm --arch x86_64
phase2-qemu-vm/lab-vm.sh start  deb1
phase2-qemu-vm/lab-vm.sh ssh    deb1
phase2-qemu-vm/lab-vm.sh destroy deb1
```

See [`phase2-qemu-vm/README.md`](phase2-qemu-vm/README.md) and
[`phase2-qemu-vm/MANUAL_TESTING.md`](phase2-qemu-vm/MANUAL_TESTING.md).

### A throwaway 3-service Docker lab

```bash
phase3-docker/lab-docker.sh up   --config examples/docker-examples/docker-3svc-topology.toml
phase3-docker/lab-docker.sh list --lab demo
curl http://localhost:8088/
phase3-docker/lab-docker.sh down --lab demo
```

See [`phase3-docker/README.md`](phase3-docker/README.md) and
[`phase3-docker/MANUAL_TESTING.md`](phase3-docker/MANUAL_TESTING.md).

### A netboot lab (build → serve → boot)

```bash
sudo phase1-chroot/lab-chroot.sh create --config examples/netboot-lab.toml
# Package as initrd (one-time step — requires root):
cd /var/chroots/netboot-busybox
sudo find . | cpio -H newc -o | gzip -9 -n > ~/netboot/initrd.gz
sudo cp boot/vmlinuz-* ~/netboot/kernel
# Serve artifacts (rootless):
phase4-podman/lab-podman.sh up --config examples/netboot-lab.toml
# Boot in QEMU:
phase2-qemu-vm/lab-vm.sh create --config examples/netboot-lab.toml
phase2-qemu-vm/lab-vm.sh start  netboot-direct
```

See [`examples/netboot-lab.toml`](examples/netboot-lab.toml) for the unified
cross-phase config that drives all three steps from one file.

### A netboot lab (build → serve → boot in RAM)

```bash
# 1. One-time host setup (creates ~/netboot and MIME config):
netboot/setup-netboot-dir.sh

# 2. Build the initrd rootfs (debootstrap, needs sudo, ~2 min):
sudo phase1-chroot/lab-chroot.sh create --config examples/chroot-netboot-minimal.toml

# 3. Package as kernel + initrd (needs sudo):
sudo phase1-chroot/lab-chroot.sh export-initrd netboot-minimal \
    --kernel ~/netboot/kernel --output ~/netboot/initrd.gz

# 4. Build iPXE (inside Docker, ~15 min first run):
netboot/build-ipxe.sh --server http://10.0.2.2:8181

# 5. Serve over HTTP (rootless):
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml

# 6. Boot in QEMU (no sudo needed — disk-image backend is rootless):
phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-ipxe.toml
phase2-qemu-vm/lab-vm.sh start  netboot-ipxe

# For real hardware: dd ~/netboot/ipxe.usb → USB → boot
```

See [`examples/netboot-lab.toml`](examples/netboot-lab.toml) and
[`NETBOOT_LAB_PLAN.md`](NETBOOT_LAB_PLAN.md) for the full design.

### AlmaLinux zero-touch PXE install

Installs AlmaLinux unattended via iPXE + kickstart into a QEMU VM — walk away after `start`, SSH in ~10 minutes later to a running system.

```bash
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --mirror https://repo.almalinux.org/almalinux --release 9 --arch x86_64
netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01
netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml
phase2-qemu-vm/lab-vm.sh create --config examples/almalinux-pxe-lab/vm-almalinux-pxe-install.toml
phase2-qemu-vm/lab-vm.sh start  almalinux-pxe-install   # walk away; SSH in after ~10 min
```

See [`netboot/SHOWCASE.md`](netboot/SHOWCASE.md) and
[`examples/almalinux-pxe-lab/ALMALINUX_PXE_LAB_PLAN.md`](examples/almalinux-pxe-lab/ALMALINUX_PXE_LAB_PLAN.md) for the full design.

### A from-source micro-distro (compile → boot in RAM)

Compile a Linux kernel + a static BusyBox (or u-root) from upstream source and
boot to a console login prompt — no disk, no packages. Downloads are PGP-verified
against a vendored key; the build is rootless.

```bash
micro-linux/mlbuild.sh image                                  # toolchain container (once)
micro-linux/mlbuild.sh all --arch x86_64,aarch64              # compile + pack → micro-linux/out/
phase2-qemu-vm/lab-vm.sh create --config examples/tiny-linux-experiments/micro-linux-x86_64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64            # log in: root / micro; Ctrl-A X to quit
# Same kernel on QEMU's real microvm machine (qboot + virtio-mmio, minimal/fast):
#   ...create/start --config examples/tiny-linux-experiments/micro-linux-x86_64-microvm.toml
# Faithful "match the source post" track: --arch riscv64  (u-root shell + plain cpio)
```

See [`micro-linux/README.md`](micro-linux/README.md),
[`micro-linux/SHOWCASE.md`](micro-linux/SHOWCASE.md), and
[`MICRO_LINUX_LAB_PLAN.md`](MICRO_LINUX_LAB_PLAN.md) for the full design.

## Repo layout

```
LAB_CREATE_V2/
├── PLAN.md                    # full project plan
├── README.md                  # this file
├── examples/                  # ready-to-use TOML configs (see examples/00-INDEX.md)
├── phase1-chroot/
│   ├── lab-chroot.sh
│   ├── README.md
│   ├── MANUAL_TESTING.md
│   └── tests/
├── phase2-qemu-vm/
│   ├── lab-vm.sh
│   ├── README.md
│   ├── MANUAL_TESTING.md
│   └── tests/
└── phase3-docker/
    ├── lab-docker.sh
    ├── README.md
    ├── MANUAL_TESTING.md
    └── tests/
```

## Conventions

- Phases 1–5 are bash (`/bin/bash`, `set -euo pipefail`, POSIX tools, with
  targeted use of `awk`/`sed`/`dd`).
- Phases 6 and 6b are Python 3.11+ (Textual / FastAPI + HTMX); they shell
  out to the bash phases and never reimplement provisioning logic.
- All phases use TOML for declarative config (CLI flags also work for one-off
  use; the two paths are tested for byte-equivalent output).
- Each phase ships with `tests/` (autotools-style: exit 77 to skip, 0 to
  pass, anything else to fail) and a `MANUAL_TESTING.md` walkthrough.

## Architectures

`x86_64`, `aarch64`, `armv7l`, `ppc64le`, `riscv64`, `s390x` —
foreign-arch chroots use `qemu-user-static` + `binfmt_misc`; foreign-arch
VMs use QEMU system emulation (TCG).
