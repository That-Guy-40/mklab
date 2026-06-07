# Chroot example labs — Phase 1

Ready-to-run [`phase1-chroot/lab-chroot.sh`](../../phase1-chroot/) TOML specs:
disposable root filesystems you can `enter`, boot under `systemd-nspawn`, or feed
into a later phase (a VM, a container image). Build one with
`sudo phase1-chroot/lab-chroot.sh create --config examples/chroot-examples/<file>`
(paths below are from the repo root). Phase 1 needs **root** (🔑) for the bind
mounts, device nodes, and `chroot()` — or run rootless via fakechroot (see below).

> Grouped into this subdir so the flat [`examples/`](../) directory stays
> scannable — these were previously top-level `examples/chroot-*.toml`. The three
> **netboot-tier** chroots (`chroot-netboot-{minimal,busybox,full}.toml`) **stay
> flat on purpose** — they're the build stage of the netboot pipeline and are
> reused by other specs and labs (`vm-netboot-*`, the `docker`/`podman` netboot
> servers, `debian-http-boot/`, the `netboot/` subsystem). For the full
> walkthrough see the phase docs:
> [`START_HERE_CHROOT_WIZARD.md`](../../phase1-chroot/START_HERE_CHROOT_WIZARD.md) ·
> [`SHOWCASE.md`](../../phase1-chroot/SHOWCASE.md) ·
> [`MANUAL_TESTING.md`](../../phase1-chroot/MANUAL_TESTING.md).

## The specs

| File | Backend / manager | What you get |
|---|---|---|
| [`chroot-debian-bookworm.toml`](chroot-debian-bookworm.toml) | `debootstrap` / `schroot` | The canonical starting point: native x86_64 Debian bookworm (`minbase` + build tools), registered with **schroot** (`type=directory`, `sbuild`+`sudo` groups) so it's sbuild-ready. |
| [`chroot-rocky9-vsftpd.toml`](chroot-rocky9-vsftpd.toml) | `dnf` / bare | An RPM-family chroot: Rocky 9 (`@core` + `vsftpd`) into `/srv/ftpjail`, sized for jailing an FTP daemon. Shows the `dnf` backend. |
| [`chroot-host-copy-busybox.toml`](chroot-host-copy-busybox.toml) | `host-copy` / bare | Tiny jail built **without** a package manager: copies `/bin/busybox` + a handful of `/etc` files off the host. Enter with `enter minimal-busybox -- /bin/busybox sh`. |
| [`chroot-nspawn-managed.toml`](chroot-nspawn-managed.toml) | `debootstrap` / `nspawn` | Debian bookworm with `systemd-sysv`+`dbus`, registered as a **machinectl** image (`register=true`) and bootable as a lightweight container: `systemd-nspawn -b -M bookworm-nspawn`. |
| [`chroot-write-files-demo.toml`](chroot-write-files-demo.toml) | `debootstrap` / bare | Demonstrates the `write_files` key — inject arbitrary files (here a custom `/init` + `/etc/motd`) into the tree at build time, host-side. The mechanism behind auto-writing `/init` for netboot initramfs builds. |

## Quick start

```bash
sudo phase1-chroot/lab-chroot.sh create --config examples/chroot-examples/chroot-debian-bookworm.toml
sudo phase1-chroot/lab-chroot.sh enter  bookworm-amd64
# … work inside …  then leave with: exit
sudo phase1-chroot/lab-chroot.sh destroy bookworm-amd64
```

## The three backends — how the rootfs gets built

The `backend` key picks *how* the root filesystem is populated:

- **`debootstrap`** — bootstrap a **Debian-family** rootfs (Debian, Kali, Ubuntu)
  from a mirror: downloads the base packages, unpacks them, and configures a
  minimal `minbase` system. `suite` (e.g. `bookworm`) and `include` (extra
  packages) shape it. This is the workhorse for `.deb` distros.
- **`dnf`** — the **RPM-family** equivalent (Rocky, AlmaLinux): installs a package
  group (`groups = ["core"]`) plus `include` packages into the target with `dnf
  --installroot`. Use this whenever you need a Red-Hat-lineage userspace.
- **`host-copy`** — **no package manager at all**: copies the `binaries` you list
  (and their shared-library dependencies) plus a few `extras` (`/etc` files) out
  of the *running host* into the target. Fast, tiny, and offline — ideal for a
  BusyBox jail or a netboot rootfs where you don't want a full distro.

## The managers — how you run what you built

The `manager` key picks how the chroot is *entered/run* after it's built:

- **bare / `none`** — just a directory tree. `lab-chroot.sh enter <name>` does the
  `chroot()` + bind-mounts `/proc`, `/sys`, `/dev` for you. Simplest.
- **`schroot`** — registers the tree with **schroot** (`/etc/schroot/…`), giving
  session-managed, optionally-ephemeral entry and group-based access (the
  `bookworm-amd64` spec joins `sbuild` + `sudo`, so it doubles as a Debian package
  build environment).
- **`nspawn`** — registers the tree as a **machinectl** image and boots it as a
  lightweight container under `systemd-nspawn -b`: a real PID 1, services, and
  login — much closer to a VM than a plain chroot, but still sharing the host
  kernel. Needs `systemd-sysv` + `dbus` inside (the spec includes them).

## The `write_files` mechanism

`chroot-write-files-demo.toml` shows how to inject files into the tree at create
time, **host-side** (no `chroot` exec needed) — `path` is relative to the chroot
root, `mode` is an octal string, and `executable = true` is shorthand for `0755`.
Its primary real use is auto-writing a custom `/init` for the **netboot** initramfs
builds (the netboot-tier specs that stay flat) without a manual editing step.

## Foreign architectures & rootless

- **Foreign arch** — set `arch` to any of `x86_64`, `aarch64`, `armv7l`,
  `ppc64le`, `riscv64`, `s390x`; `lab-chroot.sh` uses `qemu-user-static` +
  `binfmt_misc` so a foreign-arch rootfs runs transparently on your host.
- **Rootless** — `--rootless` builds via `fakechroot`+`fakeroot` without `sudo`.
  Caveat: a full-**systemd** rootfs (the `nspawn` spec) can't be built rootless —
  systemd's helpers trip the `libsystemd-shared` `LD_PRELOAD` wall — so use `sudo`
  for the systemd tiers.

## Prerequisites

- **root/`sudo`** (or `--rootless` for the non-systemd specs).
- `chroot-debian-bookworm.toml` / `chroot-nspawn-managed.toml` /
  `chroot-write-files-demo.toml`: `debootstrap` installed.
- `chroot-rocky9-vsftpd.toml`: `dnf` (and its RPM keys) available on the host.
- `chroot-nspawn-managed.toml`: `systemd-container` (provides `systemd-nspawn` +
  `machinectl`).
- `chroot-debian-bookworm.toml`: `schroot` for the managed entry.

## Security posture

These are throwaway lab trees that bootstrap into host paths (`/var/chroots`,
`/srv/ftpjail`, `/var/jails`, `/var/lib/lab-create/trees`). They're built and
entered as root and are **not** hardened tenancy boundaries — treat them as
disposable scratch environments, not security sandboxes.

## Testing

The backends, managers, and `enter`/`destroy` lifecycle are walked through with
host-side checks in
[`../../phase1-chroot/MANUAL_TESTING.md`](../../phase1-chroot/MANUAL_TESTING.md) —
that's the authoritative verification path for these specs, so it isn't duplicated
here.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog across all
phases.
