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

## How the chroot is made self-bootable

The `from-chroot` backend packages a chroot **tree** into a disk image but does
**not** install a kernel — so `offsec-awae-vm.toml`'s `post_commands` do, inside
the chroot (where `/proc`, `/sys`, `/dev` are bind-mounted, so `update-initramfs`
works):

- `linux-image-amd64` → `/boot/vmlinuz*` + `/boot/initrd*` for extlinux to boot
- `systemd-sysv` + `udev` → a real init + device nodes
- `openssh-server`, `serial-getty@ttyS0`, `systemd-networkd` (DHCP) → ways in
- a `root`/`toor` password for console rescue

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

See `MANUAL_TESTING.md`. The intended verification path is **`--smoke` first**
(proves a Kali chroot boots as a from-chroot VM — kernel, serial console, DHCP,
SSH, kali login), then the full `offsec-awae` build on top of that proven pipeline.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| host: `missing /usr/share/keyrings/kali-archive-keyring.gpg` | `sudo apt-get install kali-archive-keyring` on the **host**. |
| chroot apt: `OpenPGP … Missing key …` | the chroot lacks the Kali key — it's in `include` now; rebuild (or `apt-get install --reinstall kali-archive-keyring` in the tree). |
| `Package 'offsec-awae' has no installation candidate` | components — the TOML's `sed` must enable `contrib non-free non-free-firmware` before the install. |
| heavy install hits `… not installable` (transient kali-rolling skew) | `sudo phase1-chroot/lab-chroot.sh enter offsec-awae -- apt-get full-upgrade -y`, then re-run the install. |
| `build-vm.sh` warns about missing `extlinux`/`parted`/`qemu-img` | install them (see Quick start) — needed by the from-chroot backend. |
| VM boots but serial console is blank | the kernel cmdline must carry `console=ttyS0` (lab-vm sets it); the chroot also enables `serial-getty@ttyS0`. Give it ~20s past GRUB/extlinux. |
| SSH won't connect | wait for a DHCP lease; confirm the NIC came up on the serial console (`ip a`). The chroot's `systemd-networkd` matches `en*`/`eth*`. |
| want the XFCE GUI | the from-chroot VM is serial-only — see "Getting the desktop". |
