# VM example labs — Phase 2 (QEMU)

Ready-to-run [`phase2-qemu-vm/lab-vm.sh`](../../phase2-qemu-vm/) TOML specs:
full-system virtual machines under QEMU — their own kernel, firmware, and disk.
Native-arch VMs run on **KVM** (fast); foreign-arch VMs run under **TCG**
emulation (slow, but no matching hardware needed). The usual lifecycle is
`create` → `start` → `ssh`/`console`. Point the tool at one with
`--config examples/vm-examples/<file>` (paths below are from the repo root).

> Grouped into this subdir so the flat [`examples/`](../) directory stays
> scannable — these were previously top-level `examples/vm-*.toml`. Four VM specs
> **stay flat on purpose** because other labs reuse them: `vm-netboot-direct.toml`,
> `vm-netboot-full.toml`, `vm-netboot-ipxe.toml` (the netboot pipeline) and
> `vm-kali-amd64.toml` (the canonical Kali VM that `kali-llm-desktop-lab/`,
> `kali-vm-builder/`, and `KALI_LLM_LAB_PLAN.md` build around). For the full
> walkthrough see the phase docs:
> [`START_HERE_VM_WIZARD.md`](../../phase2-qemu-vm/START_HERE_VM_WIZARD.md) ·
> [`SHOWCASE.md`](../../phase2-qemu-vm/SHOWCASE.md) ·
> [`MANUAL_TESTING.md`](../../phase2-qemu-vm/MANUAL_TESTING.md).

## The specs

| File | Arch / backend | What you get |
|---|---|---|
| [`vm-debian-amd64.toml`](vm-debian-amd64.toml) | x86_64 / `disk-image` | The canonical VM: native Debian bookworm on QEMU/**KVM**, cloud-init seeded, SSH-ready in well under a minute. |
| [`vm-alpine-amd64.toml`](vm-alpine-amd64.toml) | x86_64 / `disk-image` | The tiny one: the upstream Alpine NoCloud cloud image on `q35` + **OVMF (UEFI)**, 256 MB RAM. `suite = "latest"` resolves to the current stable at run time. |
| [`vm-debian-aarch64.toml`](vm-debian-aarch64.toml) | aarch64 / `disk-image` | 🐌 The foreign-arch twin: arm64 Debian on an x86_64 host under **TCG** — slow (~3–5 min to first SSH) but needs no arm hardware. |
| [`vm-from-chroot-debian.toml`](vm-from-chroot-debian.toml) | x86_64 / `from-chroot` | Cross-phase: packages a **Phase-1 chroot** into a bootable BIOS qcow2 (MBR + extlinux + ext4). Also catalogued under *Cross-phase bridges* in [`../00-INDEX.md`](../00-INDEX.md). |

## Quick start

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-examples/vm-debian-amd64.toml
phase2-qemu-vm/lab-vm.sh start  deb-amd64
phase2-qemu-vm/lab-vm.sh ssh    deb-amd64
phase2-qemu-vm/lab-vm.sh destroy deb-amd64
```

## Native (KVM) vs foreign-arch (TCG)

The `arch` key decides how the VM runs. When it **matches the host**
(`vm-debian-amd64`, `vm-alpine-amd64` on an x86_64 box), QEMU uses **KVM** —
hardware virtualization, near-native speed. When it **differs**
(`vm-debian-aarch64` on x86_64), QEMU falls back to **TCG**, a pure-software
instruction translator: every guest instruction is JIT-translated to host
instructions. That's why the arm64 VM is functional but slow — it's the price of
running a CPU your hardware doesn't have. All six arches
(`x86_64`/`aarch64`/`armv7l`/`ppc64le`/`riscv64`/`s390x`) work this way.

## The two backends

- **`disk-image`** — downloads a distro's **cloud image** (a pre-installed qcow2)
  and boots it, seeding hostname/users/SSH keys via **cloud-init** (a NoCloud
  seed ISO). No install step — the image is already a working system. This is the
  fast path and what three of the four specs use.
- **`from-chroot`** — builds a bootable disk **out of a Phase-1 chroot tree**
  (`vm-from-chroot-debian`). It lays down an MBR + extlinux bootloader + a single
  ext4 partition and copies the tree in. Two hard requirements: the chroot must
  live under `LAB_STATE_DIR/chroots/` (lab-chroot.sh's own home — others are
  rejected by design), and it must **already contain a kernel + initrd**
  (`lab-vm.sh` won't install those). x86_64 BIOS only in v0.1.

## Firmware: BIOS vs UEFI

Worth knowing because the specs differ on purpose:

- `vm-alpine-amd64` boots **UEFI** via **OVMF** (the cloud image ships a GPT + ESP).
- `vm-from-chroot-debian` sets `firmware = "bios"` because the `from-chroot`
  backend writes an **MBR/extlinux** disk — SeaBIOS boots it directly. Pointing
  OVMF at an MBR disk finds no EFI loader and drops to the UEFI Shell, so BIOS is
  the correct (and required) choice there.

> **Dracut note** (for `from-chroot` off a non-Debian tree): Debian's
> initramfs-tools includes virtio by default, so its initramfs boots the VM as-is.
> A **dracut**-based distro (e.g. Kali) builds a *host-only* initramfs in the
> chroot that omits the virtio transport — the VM then drops to the dracut
> emergency shell. Force a generic initramfs first (the spec's header has the
> exact `dracut.conf.d` snippet; `examples/offsec-awae-vm/` is a worked example).

## Prerequisites

- **QEMU** installed; **`/dev/kvm`** readable for the native x86_64 specs (the
  aarch64 spec runs under TCG without it, just slower).
- **`vm-from-chroot-debian.toml`**: runs as **root** (loop devices, `mkfs`,
  `extlinux`) and needs `syslinux` + `extlinux` + `parted` + `rsync` on the host;
  build the seed chroot first (the spec's header has the full 5-step workflow).

## Security posture

These are throwaway lab VMs. `vm-from-chroot-debian`'s documented workflow sets a
throwaway **`root` / `lab`** console password, and the cloud-image specs seed
default lab credentials via cloud-init — fine for a local QEMU lab, but don't
expose these VMs (or their SSH forwards) on an untrusted network.

## Testing

The `disk-image` and `from-chroot` backends, the `create`/`start`/`ssh`/`console`
lifecycle, and the chroot→VM bridge are walked through with host-side checks in
[`../../phase2-qemu-vm/MANUAL_TESTING.md`](../../phase2-qemu-vm/MANUAL_TESTING.md) —
that's the authoritative verification path for these specs, so it isn't duplicated
here.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog across all
phases.
