# Debian VM image factory — `debos`, operationalized

Bake a real, bootable **Debian 13 (trixie)** VM image on your machine with
[**debos**](https://github.com/go-debos/debos), then boot it in a windowed QEMU
desktop. **fetch → build → run.**

This is the Debian twin of [`kali-vm-builder`](../kali-vm-builder/README.md).
That lab wraps Kali's `kali-vm`; `kali-vm` is itself a thin wrapper around
**debos** — so the honest Debian equivalent is to drive **debos directly**. debos
is a Debian project: it reads a YAML **recipe** (`debian-vm.yaml`), spins up its
own KVM build VM via `fakemachine`, and runs each action (`debootstrap` → `apt` →
`image-partition` → `filesystem-deploy` → bootloader) to assemble a partitioned,
self-booting disk image.

> **Provenance:** debos is fetched (official container), the recipe is
> mklab-authored following a proven pattern — see [`UPSTREAM.md`](UPSTREAM.md).

> ✅ **Verified end-to-end on this host** — a real trixie qcow2 built by debos in
> a rootless-podman container and booted under OVMF to a login. (Contrast
> `kali-vm-builder`, whose multi-GB Kali build is documented but author-run.)

---

## What's here

| File | Role |
|---|---|
| `debian-vm.yaml` | The debos recipe: a bootable trixie image (UEFI + systemd-boot, ext4 root, serial + graphical console, throwaway lab creds). |
| `fetch-debos.sh` | Pre-pull the official debos container (or check for a host `debos`). |
| `build-debian-vm.sh` | Drive debos (container or host) on the recipe → `debian-vm.qcow2`. Profiles/knobs: `--desktop`, `--suite`, `--disksize`, `--mirror`. |
| `run-graphical.sh` | Boot the qcow2 in a windowed QEMU (OVMF/UEFI, virtio, SSH-forward, COW overlay). |
| [`UPSTREAM.md`](UPSTREAM.md) | Provenance (debos + the recipe pattern). |
| `MANUAL_TESTING.md` | The end-to-end runbook + the real verified transcript. |

Build artifacts live under a **work dir** outside this repo (default
`~/debian-vm-build`, or `$DEBIAN_VM_DIR` / `--workdir`) — a build writes a
multi-hundred-MB image plus scratch.

---

## Prerequisites

```bash
sudo apt-get install -y podman qemu-system-x86 qemu-utils ovmf
# host-native debos instead of the container? also: sudo apt install -y debos
```

debos needs **`/dev/kvm`** (its build VM) — be in the `kvm` group
(`sudo adduser $USER kvm`, then re-login). The container path needs **no** host
debos; it ships its own.

---

## Quick start

```bash
# (optional) pre-pull the debos container:
examples/debian-vm-builder/fetch-debos.sh

# build a minimal trixie image (~a few minutes, a few hundred MB of downloads):
examples/debian-vm-builder/build-debian-vm.sh
#   → ~/debian-vm-build/debian-vm.qcow2

# boot it in a graphical QEMU window (login: debian / debian, or root / lab):
examples/debian-vm-builder/run-graphical.sh
```

Headless boot-check (no window, serial to your terminal):

```bash
examples/debian-vm-builder/run-graphical.sh --display none --serial
# → GRUB-less systemd-boot menu → kernel → `debian-vm login:` on the serial
```

### Choosing where the build runs (`--engine`)

The build always happens inside debos's own KVM VM; the engine only decides what
hosts *debos*:

| `--engine` | What runs | Prereqs |
|---|---|---|
| `auto` (default) | the debos container if a container engine + `/dev/kvm` are present, else host debos | — |
| `container` / `podman` / `docker` | `ghcr.io/go-debos/debos` with `--device /dev/kvm` | podman/docker, `/dev/kvm`, `kvm` group |
| `host` | host-native `debos` | `debos` installed, `/dev/kvm` |

> On non-Debian hosts prefer the **container** — `debos` often isn't packaged,
> and the image ships it plus `fakemachine`/`qemu`.

### Profiles & knobs

| Flag | Effect |
|---|---|
| *(default)* | a minimal CLI trixie (base + kernel + sshd + sudo), ~6 GB image |
| `--desktop xfce` | add an XFCE desktop (`task-xfce-desktop`); also `gnome`/`kde`/`mate`/`lxqt`. Use `--disksize 12G+`. |
| `--suite bookworm` | build a different suite |
| `--disksize 8G` | image size |
| `--mirror URL` | apt mirror baked into the build |
| `--keep-img` | keep the raw `.img` next to the `.qcow2` |

```bash
examples/debian-vm-builder/build-debian-vm.sh --desktop xfce --disksize 14G
```

### Running it

`run-graphical.sh` boots the image under **OVMF** (it's a UEFI/systemd-boot
image, unlike kali-vm-builder's BIOS/grub image), on a **copy-on-write overlay**
by default so the master stays pristine:

```bash
examples/debian-vm-builder/run-graphical.sh --memory 4G --cpus 4
examples/debian-vm-builder/run-graphical.sh --snapshot            # throwaway session
examples/debian-vm-builder/run-graphical.sh --no-overlay          # mutate the master
ssh -p 2222 debian@127.0.0.1                                       # forwarded :22 (password: debian)
```

---

## Why this is separate from the other Debian VM labs

| Lab | Mechanism | Output |
|---|---|---|
| **this** (`debian-vm-builder`) | **debos** + a recipe (a real image factory) | a self-booting Debian qcow2, built locally |
| `debian-pxe-lab` / `-preseed-gallery` / `-hands-off-install` | d-i + a preseed over PXE | an *installed* system (the installer runs in a target VM) |
| `vm-examples/vm-debian-amd64.toml` | `lab-vm` downloads Debian's **prebuilt** cloud image | the official image, pre-baked |

The preseed labs run the **installer**; this one **assembles the image itself**
from debootstrap up — declaratively, reproducibly, no installer involved. It's
the exact structural twin of `kali-vm-builder`, but pointed at the upstream tool
(`debos`) that Kali's builder is built on.

---

## Security posture

Throwaway plaintext lab creds baked into the image: **`root` / `lab`** and a
sudo user **`debian` / `debian`**. Fine for a local throwaway VM; never ship the
image or expose it on an untrusted network. Rebuild with your own accounts
(edit the `run` account block in `debian-vm.yaml`) for anything real.

## Under the hood (the recipe's load-bearing bits)

- **UEFI + systemd-boot, not grub.** systemd-boot just needs files in a mounted
  ESP — far simpler in debos than installing grub to a loop device. The image is
  therefore booted with **OVMF**, not SeaBIOS (that's the one real difference
  from `kali-vm-builder`'s runner).
- **Bootloader ordering matters.** `linux-image-amd64` installs *before* the ESP
  exists; `systemd-boot` installs *after* `filesystem-deploy` (ESP now mounted),
  so its postinst runs `bootctl install` + populates a boot entry for the
  already-installed kernel. A `kernel-install add` loop after it is the
  belt-and-braces guarantee. Reshuffle these and you get an image that partitions
  fine but won't boot — see the comments in `debian-vm.yaml`.
- **Serial console baked in.** `append-kernel-cmdline: … console=ttyS0` lets the
  image be boot-verified headless (`run-graphical.sh --display none --serial`),
  while `console=tty0` keeps the graphical console working.
