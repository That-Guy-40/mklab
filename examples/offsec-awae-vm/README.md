# OffSec AWAE — kali-rolling chroot → bootable VM

A **Phase-1 Kali chroot** carrying the **OffSec AWAE (WEB-300)** toolset, with an
**automated pipeline** (`build-vm.sh`) that turns it into a **bootable VM** via the
`from-chroot` backend — chroot build, VM imaging, and boot in one command.

> ⚠️ **Authorized use only.** AWAE is OffSec's *Advanced Web Attacks and
> Exploitation* course; this builds a system full of offensive web-exploitation
> tooling. Use it only against systems you own or are explicitly authorized to
> test, on an isolated network. `kali`/`kali` and `root`/`toor` are throwaway lab
> credentials — never ship them.

## Lineage

Adapted from Kali's live-build recipe
[`offsec-awae-live.sh`](https://gitlab.com/kalilinux/recipes/live-build-config-examples/-/blob/main/offsec-awae-live.sh).
That recipe builds a **live ISO** with `lb build`:

| Upstream recipe (live ISO) | This lab (chroot → VM) |
|---|---|
| `lb build` → bootable Kali Live ISO | `lab-chroot create` → chroot, then `lab-vm create` (from-chroot) → bootable qcow2 |
| `kali-desktop-xfce` (full XFCE desktop) | **omitted** — the from-chroot VM is headless/serial (see "Getting the desktop") |
| `offsec-awae` metapackage + `code-oss` + `gobuster` + `jd-gui` | same toolset, installed in the chroot |
| installer preseed: user `kali`/`kali`, UTC, US keymap | `users = [kali]` (kali/kali) + `root`/`toor` for console |
| installer partitions `/dev/sda`, GRUB | `from-chroot` writes MBR + extlinux + a single ext4 partition |

The point of this lab is the **chroot → VM automation**: the same `offsec-awae-vm.toml`
feeds both phases, and `build-vm.sh` chains them.

## Why headless (no XFCE by default)

`lab-vm`'s `from-chroot` backend boots QEMU with `-nographic` — **serial console
only**, no display. A full XFCE desktop would install fine but you couldn't *see*
it through a serial line, so it's left out and the VM is reached over **SSH** or
the **serial console** instead. The AWAE toolset is the substance, and most of it
is CLI / works headless. See "Getting the desktop" for the graphical route.

## What's in this directory

| File | Role |
|---|---|
| `offsec-awae-vm.toml` | The unified spec: `[[chroot]]` (AWAE Kali chroot) + `[[vm]]` (from-chroot VM). |
| `offsec-awae-vm-smoke.toml` | A lean version (Kali base + kernel + SSH, no AWAE tools) to smoke-test the pipeline fast. |
| `build-vm.sh` | The automated pipeline: chroot → VM image → boot. |
| `README.md` / `MANUAL_TESTING.md` | This file + the build/verify walkthrough. |
| `INITRAMFS-TROUBLESHOOTING.md` | Field guide for `lsinitrd`/`dracut`: inspect an initrd, rebuild it generic, diagnose an emergency-shell boot. |

Everything else is the shared `phase1-chroot/lab-chroot.sh` + `phase2-qemu-vm/lab-vm.sh`.

## Quick start

```bash
# Host prereqs (Debian/Ubuntu/Kali) for the from-chroot backend:
sudo apt-get install -y debootstrap kali-archive-keyring \
                        syslinux extlinux parted rsync qemu-utils qemu-system-x86

# 1) Smoke-test the pipeline first (Kali base → VM, a couple of GB, a few minutes):
sudo examples/offsec-awae-vm/build-vm.sh --smoke
#    → boots a minimal Kali VM on the serial console; log in kali/kali.

# 2) The real thing (offsec-awae toolset — several GB, takes a while):
sudo examples/offsec-awae-vm/build-vm.sh
```

`build-vm.sh` runs, all as root:

1. `lab-chroot create --config offsec-awae-vm.toml` — debootstrap the Kali base,
   add the `kali` user, enable all repo components, install a **kernel + init +
   SSH** (so the tree is self-bootable), then the **AWAE toolset**.
2. `lab-vm create --config offsec-awae-vm.toml` — package the chroot into a
   BIOS/MBR/ext4 qcow2 with extlinux (`from-chroot` backend).
3. `lab-vm start offsec-awae-vm` — boot it headless.

```bash
# attach the serial console (quit with Ctrl-A X):
sudo phase2-qemu-vm/lab-vm.sh console offsec-awae-vm
# log in: kali / kali   (or root / toor)
```

SSH works too once the VM has a DHCP lease (the chroot enables `systemd-networkd`
to bring up any `en*`/`eth*` NIC): `ssh kali@<vm-ip>`.

## Why `firmware = "bios"`

The `from-chroot` backend writes an **MBR + extlinux** disk (legacy BIOS layout —
no EFI System Partition). `lab-vm` otherwise defaults to **UEFI/OVMF** for x86_64,
and OVMF can't boot an MBR disk — it finds no `\EFI\BOOT\BOOTX64.EFI` and drops to
the **UEFI Shell**. So the `[[vm]]` spec sets `firmware = "bios"`, which makes
`lab-vm` use QEMU's built-in **SeaBIOS** (it reads the MBR and runs extlinux). This
is mandatory for any from-chroot VM.

## How the chroot is made self-bootable

The `from-chroot` backend packages a chroot **tree** into a disk image but does
**not** install a kernel — so `offsec-awae-vm.toml`'s `post_commands` do, inside
the chroot (where `/proc`, `/sys`, `/dev` are bind-mounted, so `update-initramfs`
works):

- `linux-image-amd64` → `/boot/vmlinuz*` + `/boot/initrd*` for extlinux to boot
- a **generic initramfs** — Kali's `dracut` defaults to a *host-only* initramfs,
  and built inside a chroot that bakes in the build host's storage and drops the
  VM's virtio transport, so the VM lands in the dracut **emergency shell**. A
  `/etc/dracut.conf.d/90-lab-vm.conf` with `hostonly=no` + the virtio drivers
  (written *before* the kernel postinst) fixes it; the build also regenerates the
  initramfs to be sure.
- `systemd-sysv` + `udev` → a real init + device nodes
- `openssh-server`, `serial-getty@ttyS0`, `systemd-networkd` (DHCP) → ways in
- `kali`/`kali` (sudo) + `root`/`toor` (explicitly unlocked) for console login

## The two Kali-chroot gotchas (handled in the TOML)

1. **`kali-archive-keyring` in `include`** — `lab-chroot` gives the host keyring
   to debootstrap only to verify the *download*; the chroot's own apt then needs
   the Kali key installed *inside* it or `apt-get update` fails OpenPGP
   verification. A `minbase` debootstrap won't pull it.
2. **Enable `contrib non-free non-free-firmware`** — a debootstrap sources.list is
   `main`-only, but a lot of offensive tooling lives in `non-free`/`contrib`
   (licensing), giving "no installation candidate" on `main`-only. A `post_commands`
   `sed` adds the components before the install.

## Getting the desktop (the graphical route)

The headless VM is great for the tools; for the actual XFCE *desktop* you have two
options:

- **Build the upstream ISO** with `offsec-awae-live.sh` (full `lb build`, XFCE
  included) and run that ISO in a graphical VM — the recipe's original intent.
- **Add the desktop here and boot the qcow2 graphically**: append
  `kali-desktop-xfce` (and a display manager) to the TOML's last `apt-get install`,
  rebuild, then boot the produced disk in a *graphical* QEMU yourself, e.g.
  `qemu-system-x86_64 -enable-kvm -m 4G -hda <disk>.qcow2 -display gtk` (or import
  it into virt-manager). `lab-vm start` itself stays serial-only.

## What's verified

The **`--smoke` pipeline is verified end-to-end** on Ubuntu 24.04: `build-vm.sh
--smoke` builds the Kali chroot, images it (BIOS/MBR/extlinux), and boots it — it
reaches the Kali serial `login:` and **`root`/`toor` logs in** (kernel
6.19.14+kali, generic initramfs mounts the virtio root). Getting there took four
from-chroot lessons, all now baked into the configs:

1. **chroot under `LAB_STATE_DIR/chroots/`** — the backend rejects chroots elsewhere.
2. **`firmware = "bios"`** — the disk is MBR/extlinux; the UEFI default drops to a UEFI Shell.
3. **generic dracut initramfs** (`hostonly=no` + virtio) — else it can't mount the virtio root.
4. **a kernel installed in the chroot** — the backend installs none.

The full `offsec-awae` build is the **same pipeline** with the AWAE toolset added
on top. See `MANUAL_TESTING.md`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| host: `missing /usr/share/keyrings/kali-archive-keyring.gpg` | `sudo apt-get install kali-archive-keyring` on the **host**. |
| chroot apt: `OpenPGP … Missing key …` | the chroot lacks the Kali key — it's in `include` now; rebuild (or `apt-get install --reinstall kali-archive-keyring` in the tree). |
| `Package 'offsec-awae' has no installation candidate` | components — the TOML's `sed` must enable `contrib non-free non-free-firmware` before the install. |
| heavy install hits `… not installable` (transient kali-rolling skew) | `sudo phase1-chroot/lab-chroot.sh enter offsec-awae -- apt-get full-upgrade -y`, then re-run the install. |
| `build-vm.sh` warns about missing `extlinux`/`parted`/`qemu-img` | install them (see Quick start) — needed by the from-chroot backend. |
| VM drops to a **UEFI Shell** (`Shell>`) | the disk is MBR/BIOS but it booted UEFI — set `firmware = "bios"` in `[[vm]]` (handled here), then `lab-vm destroy` + re-`create` so the manifest picks it up. |
| VM enters the **dracut emergency shell** / "root account is locked" | a host-only initramfs that can't mount the virtio root (the locked root is the *initramfs's*, not yours). The TOML forces `hostonly=no` + virtio drivers — **rebuild the chroot** (not just the VM) so the new initramfs is baked in. A chroot built *before* that fix needs a manual regenerate — see **INITRAMFS-TROUBLESHOOTING.md**. |
| `console`/`destroy` say "no VM named …" after a `sudo` build | `lab-vm` keys its state dir off EUID (root → `/var/lib/lab-create`, user → `~/.local/state`); run those **as root** too. The VM is addressed **by name**, so `sudo lab-vm.sh console <name>` works even if `sudo lab-vm.sh list` looks empty. |
| VM boots but serial console is blank | the kernel cmdline must carry `console=ttyS0` (lab-vm sets it); the chroot also enables `serial-getty@ttyS0`. Give it ~20s past extlinux. |
| SSH won't connect | wait for a DHCP lease; confirm the NIC came up on the serial console (`ip a`). The chroot's `systemd-networkd` matches `en*`/`eth*`. |
| dracut: `could not locate dlopen dependency for gcrypt …` | **harmless** — an optional systemd feature; the VM boots fine. `libgcrypt20` is now pulled to silence it. |
| `ssh … lab@127.0.0.1` / "dropbear" in the start output | lab-vm's generic hint for its cloud-image VMs — ignore it. This VM's logins are `kali`/`kali` and `root`/`toor`; SSH as `ssh -p 2222 kali@127.0.0.1`. |
| want the XFCE GUI | the from-chroot VM is serial-only — see "Getting the desktop". |
