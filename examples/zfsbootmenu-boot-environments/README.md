# ZFSBootMenu boot environments — FreeBSD `bectl`, on Debian

Bring **FreeBSD-style boot environments** to Linux: put Debian on a ZFS root, make
**[ZFSBootMenu](https://zfsbootmenu.org/)** the UEFI bootloader, then clone the
whole OS into a bootable environment before every risky change — and reboot into
the old one in seconds if it breaks. A Phase-2 QEMU lab.

> ## The lesson
> A **boot environment** (BE) is one ZFS filesystem holding one coupled version
> of the OS — kernel, `/usr`, `/etc`, all of it. ZFS clones are copy-on-write, so
> a new BE is instant and nearly free. **ZFSBootMenu** is what makes each clone
> *selectable at boot*: it isn't a traditional bootloader but a small Linux
> kernel + a ZFS-capable initramfs packaged as an EFI executable — it imports
> your pool, reads the OS kernel straight off ZFS, and `kexec`s it. That's the
> thing GRUB can't reliably do, and it's why "upgrade in a throwaway clone, roll
> back by rebooting" becomes a 2-second operation on Linux, exactly like FreeBSD.

## The matrix

| Piece | File | Status |
|---|---|---|
| Boot-environment manager (`bectl` for Linux) | [`be.sh`](be.sh) | ✅ logic verified on host |
| The BE workflow — snapshot/clone/activate/boot/rollback | [`RUNBOOK-boot-environments.md`](RUNBOOK-boot-environments.md) | 🧑 author-run under KVM |
| Root-on-ZFS + ZBM install | [`RUNBOOK-install.md`](RUNBOOK-install.md) · [`install-zfs-root.sh`](install-zfs-root.sh) | 🧑 author-run under KVM |
| `generate-zbm` config | [`config.yaml`](config.yaml) | ✅ validated on host |
| Boot the image under OVMF | [`zbm-debian.toml`](zbm-debian.toml) | ✅ spec validated / ⏳ argv on KVM |

## Quick start

**On the mklab host** — run the host-safe checks (no ZFS/KVM needed):

```bash
# from this directory
tests/run-all.sh
# → 4 passed: be.sh command plan, config.yaml, shellcheck, the UEFI spec

# see the exact ZFS/ZBM commands a boot-environment op would run:
BE_DRYRUN=1 ZBM_POOL=rpool ./be.sh create testupgrade
BE_DRYRUN=1 ZBM_POOL=rpool ./be.sh activate testupgrade
```

**On a KVM-capable UEFI host** — do the real thing (see the RUNBOOKs):

```bash
# 1) inside a Debian live/rescue VM with ZFS + a blank disk /dev/vdb:
DISK=/dev/vdb sudo ./install-zfs-root.sh          # → Debian on root-on-ZFS + ZBM

# 2) boot the resulting qcow2 under OVMF (edit image= to your path first):
#    from the repo root
phase2-qemu-vm/lab-vm.sh create --config examples/zfsbootmenu-boot-environments/zbm-debian.toml
phase2-qemu-vm/lab-vm.sh start   zbm-debian
phase2-qemu-vm/lab-vm.sh console zbm-debian       # watch ZFSBootMenu, then Debian

# 3) craft boot environments (inside the VM):
./be.sh create testupgrade        # clone the OS
./be.sh activate testupgrade      # make it the default BE
reboot                            # ZFSBootMenu boots the clone; break it freely
./be.sh activate debian && reboot # back to the original in seconds
```

## Honest scope

The authoring host had **no KVM, no ZFS, and no reach to the ZBM release/docs
endpoints**, so the ZFS-root install and the ZBM boot are **author-run under
KVM**. What *is* verified here: the boot-environment command logic, the
`generate-zbm` config, script lint, and the UEFI boot spec — all green. See
[`MANUAL_TESTING.md`](MANUAL_TESTING.md) for the matrix + transcript, and
[`PLAN.md`](PLAN.md) for the build phasing.

## Why ZFSBootMenu (and not GRUB or `zsys`)

- **GRUB** reads ZFS only partially — it lags OpenZFS feature flags and can't do
  native encryption; booting from arbitrary datasets is fragile.
- **Ubuntu's `zsys`** did BEs on ZFS but through GRUB, and is deprecated.
- **ZFSBootMenu** has *real* OpenZFS in its initramfs, so it reads any modern
  pool (encryption, recent features) and boots the kernel from inside the
  dataset — which is precisely what makes distro-agnostic boot environments work.

## What's in here

| File | What |
|---|---|
| [`README.md`](README.md) | This overview. |
| [`RUNBOOK-install.md`](RUNBOOK-install.md) | By-hand root-on-ZFS + ZBM install (the *why* at each step). |
| [`RUNBOOK-boot-environments.md`](RUNBOOK-boot-environments.md) | The BE lifecycle + FreeBSD `bectl` ⇄ Linux cheat sheet. |
| [`install-zfs-root.sh`](install-zfs-root.sh) | Automates the install (author-run under KVM). |
| [`be.sh`](be.sh) | The `bectl`-style BE manager (dry-run testable). |
| [`config.yaml`](config.yaml) | Annotated `generate-zbm` config. |
| [`zbm-debian.toml`](zbm-debian.toml) | Phase-2 spec to boot the image under OVMF. |
| [`PLAN.md`](PLAN.md) | Build phasing + status. |
| [`UPSTREAM.md`](UPSTREAM.md) | Cited upstream sources (ZBM docs, FreeBSD handbook). |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Verified-here vs. author-run matrix + transcript. |
| [`tests/`](tests/run-all.sh) | Host-safe verdict tests (`be.sh` logic, config, lint, spec). |

⚠️ Throwaway lab creds only (`root`/`zbmlab`). `install-zfs-root.sh` **erases the
target disk** — double-check `DISK`. Never point it at a real/networked host.
