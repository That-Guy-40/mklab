# Upstream sources — cite, don't mirror

This lab operationalizes the **official ZFSBootMenu documentation** (a
multi-page doc site + upstream code), the FreeBSD boot-environment model it
mirrors, and one good secondary primer. Per the mklab provenance rule, sources
that track *official docs / an upstream catalog / upstream code* (rather than a
single blog post) are **cited with a retrieved date — not archived byte-exact**.
So there is no `upstream-tutorial/` here; the citations below are the record.

**As-of / retrieved:** 2026-07-13. **ZFSBootMenu version referenced:** the 3.1.x
release series (current stable line at time of writing).

> **Honesty note.** The build environment for this lab enforces an egress
> allowlist that does **not** reach `docs.zfsbootmenu.org` or
> `get.zfsbootmenu.org`, so these URLs were **not** re-fetched or HTTP-verified
> from here. They are recorded from the upstream project's stable doc layout and
> the author's prior knowledge; verify them live before relying on exact
> section anchors, and pin `ZBM_EFI_URL` to a specific release for
> reproducibility.

## ZFSBootMenu (primary)

| What | URL |
|---|---|
| Project home | <https://zfsbootmenu.org/> |
| Documentation (root) | <https://docs.zfsbootmenu.org/en/latest/> |
| **Debian install guide (UEFI)** — the install this lab automates | <https://docs.zfsbootmenu.org/en/latest/guides/debian/uefi.html> |
| **Boot Environments and You: A Primer** — the BE model | <https://docs.zfsbootmenu.org/en/latest/general/bootenvs-and-you.html> |
| **Snapshot Management** — rollback / clone / clone+promote from the menu | <https://docs.zfsbootmenu.org/en/latest/online/snapshot-management.html> |
| Configuration reference — the `config.yaml` keys | <https://docs.zfsbootmenu.org/en/latest/online/BOOT-ENVIRONMENT.html> |
| `generate-zbm` (image builder) | <https://docs.zfsbootmenu.org/en/latest/man/generate-zbm.5.html> |
| Source code | <https://github.com/zbm-dev/zfsbootmenu> |
| Pre-built release EFI (redirect to latest) | <https://get.zfsbootmenu.org/efi> |

Mapping to this lab:
- [`RUNBOOK-install.md`](RUNBOOK-install.md) + [`install-zfs-root.sh`](install-zfs-root.sh)
  follow the **Debian UEFI guide** (single unencrypted pool, `sgdisk` layout,
  `debootstrap`, `zfs-dkms`/`zfs-initramfs`, ESP + `efibootmgr` entry).
- [`config.yaml`](config.yaml) is an annotated instance of the **Configuration
  reference** for `generate-zbm`.
- [`RUNBOOK-boot-environments.md`](RUNBOOK-boot-environments.md) + [`be.sh`](be.sh)
  implement the **Boot Environments primer** and **Snapshot Management** model
  (the `bootfs` + `org.zfsbootmenu:commandline` properties, clone/promote/rollback).

## FreeBSD boot environments (the model being ported)

| What | URL |
|---|---|
| FreeBSD Handbook — ZFS boot environments (`bectl`) | <https://docs.freebsd.org/en/books/handbook/zfs/#zfs-zfs-boot-env> |
| `bectl(8)` manual page | <https://man.freebsd.org/cgi/man.cgi?bectl(8)> |

The [`be.sh`](be.sh) verb set and the cheat-sheet in
[`RUNBOOK-boot-environments.md`](RUNBOOK-boot-environments.md) deliberately track
`bectl`'s `list`/`create`/`activate`/`destroy`/`rename` surface.

## Secondary reading (optional)

| What | URL |
|---|---|
| Klara Systems — *ZBM 101: Introduction to ZFSBootMenu* | <https://klarasystems.com/articles/zbm-101-introduction-to-zfsbootmenu/> |
| OpenZFS docs — Debian root-on-ZFS (the ZFS half) | <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/> |

## Copyright & attribution

ZFSBootMenu is authored by the **ZFSBootMenu contributors** (MIT-licensed); its
documentation is the project's. FreeBSD documentation is © the **FreeBSD
Documentation Project**. All rights remain with the respective upstreams; the
links above are the authoritative, maintained sources — always prefer them over
this lab's paraphrase. Nothing upstream is redistributed here.
