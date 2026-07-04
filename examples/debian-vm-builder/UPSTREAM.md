# Upstream provenance — debos + the recipe pattern

This lab is the Debian twin of [`kali-vm-builder`](../kali-vm-builder/README.md):
it drives **debos** — a Debian project, and the very tool Kali's `kali-vm` wraps
— to bake a bootable Debian VM image. debos is **fetched** (as the official
container image), not vendored; the **recipe** (`debian-vm.yaml`) is
mklab-authored, following a well-known bootable-image pattern, so it's **cited**,
not copied.

## The tool: debos

| Field | Value |
|---|---|
| Project | **debos** — Debian OS builder |
| Home | <https://github.com/go-debos/debos> |
| Container | `ghcr.io/go-debos/debos:main` (also `godebos/debos` on Docker Hub) |
| Recipe format | [`debos.1`](https://manpages.debian.org/testing/debos/debos.1.en.html) — YAML actions (`debootstrap`, `apt`, `image-partition`, `filesystem-deploy`, `run`, …) run inside a fakemachine KVM build VM |
| License | Apache-2.0 |
| As-of | 2026-07-03 (pinned by container tag `:main`; `fetch-debos.sh` records the digest) |

`build-debian-vm.sh` runs debos via that container (`--device /dev/kvm`), or a
host `debos` if you have one.

## The recipe: `debian-vm.yaml` (mklab-authored)

Written for this lab, not copied — but its **structure and the load-bearing
ordering** (install the kernel first; install `systemd-boot` only *after*
`filesystem-deploy` so its postinst populates the mounted ESP) follow a proven
public pattern. References consulted:

- **debos' own test recipes** — `tests/debian/test.yaml` (debootstrap) and
  `tests/partitioning/test.yaml` (the `image-partition` + `filesystem-deploy`
  syntax): <https://github.com/go-debos/debos/tree/main/tests>
- **Andrew Bradford's `bradfa/debos-configs`** — `x86_64-uefi-*.yaml`, a real
  amd64 UEFI + systemd-boot Debian disk-image recipe (GPL-3.0):
  <https://github.com/bradfa/debos-configs> — the closest working template; ours
  adapts it to trixie, adds a serial console + throwaway lab creds, uses ext4
  (not btrfs), and drops the external overlay dir to stay single-file.

Nothing from those repos is committed here; they're credited references. To
re-pin: bump the container tag in `fetch-debos.sh`/`build-debian-vm.sh` and note
the date here.

## What debos downloads at build time

debos debootstraps Debian from `deb.debian.org` and `apt`-installs the kernel +
`systemd-boot` — normal, GPG-verified apt traffic. Nothing prebuilt is
fetched-and-executed; the only prebuilt artifact is the debos **container**
itself (an official image), pulled like any other.
