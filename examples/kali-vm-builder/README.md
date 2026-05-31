# Kali VM image factory — `kali-vm`, operationalized

Wraps Kali's **official VM image builder**
([`kali-vm`](https://gitlab.com/kalilinux/build-scripts/kali-vm)) so you can,
from this repo: **fetch** it, **build** a real Kali VM image (choosing *where*
the build runs), and **run** the result in a windowed QEMU desktop.

`kali-vm` is the machinery Kali uses to produce the VM images you'd otherwise
download. Under the hood it drives [`debos`](https://github.com/go-debos/debos),
which spins up its *own* QEMU/KVM build VM (via `fakemachine`) and assembles the
image from a YAML recipe. This directory is a thin, lab-flavoured front-end —
the heavy lifting is all upstream.

> ⚠️ **Authorized use only.** This builds a full Kali system (offensive
> tooling). Keep it on an isolated network and only target hosts you own or are
> authorized to test. `kali`/`kali` is a throwaway lab credential — never ship it.

## What's here

| File | Role |
|---|---|
| `fetch-kali-vm.sh` | Clone/update the upstream `kali-vm` checkout into a work dir **outside** this repo. |
| `build-kali-vm.sh` | Drive the build: pick the **engine** (host `debos` or Podman/Docker container) + a **profile** (`--full` / `--headless`); forwards extra flags to upstream. |
| `run-graphical.sh` | Boot the built image in a **windowed QEMU desktop** (SeaBIOS + virtio + gtk + SSH forward), on a copy-on-write overlay so the build stays pristine. |
| `README.md` / `MANUAL_TESTING.md` | This file + the step-by-step. |

The build artifacts and the upstream checkout live under a **work dir** (default
`$HOME/kali-vm-build`, override with `--workdir` or `$KALI_VM_DIR`) — *not* in
this repo, because a build writes a multi-GB image plus a ~45 GB scratch area.
Point `--workdir` at a roomy disk if `$HOME` is tight.

## Quick start

```bash
# Build a full graphical Kali XFCE image (long — multi-GB download + build):
examples/kali-vm-builder/build-kali-vm.sh

# …or a lean headless one (faster, smaller):
examples/kali-vm-builder/build-kali-vm.sh --headless

# Then boot it in a graphical QEMU window (newest image is auto-found):
examples/kali-vm-builder/run-graphical.sh
```

`build-kali-vm.sh` auto-fetches the upstream checkout on first run, so you don't
have to call `fetch-kali-vm.sh` yourself (it's there for pinning a `--ref` or a
`--force` re-clone).

## Choosing where the build runs (`--engine`)

The build itself happens inside a debos QEMU/KVM VM either way; the engine only
decides what hosts *debos*:

| `--engine` | What runs | Prereqs |
|---|---|---|
| `auto` (default) | container if a container engine + `/dev/kvm` are present, else host | — |
| `podman` | upstream `build-in-container.sh` (rootless Podman) | `podman`, `/dev/kvm`, you in the `kvm` group |
| `docker` | same, forcing Docker | `docker`, `/dev/kvm`, docker access |
| `host` | upstream `build.sh` directly | `sudo apt install -y 7zip debos dosfstools qemu-utils zerofree` + `kvm` group |

> **On Ubuntu/non-Kali hosts, prefer `--engine podman`** — `debos` often isn't
> packaged for the host, but the container path builds inside a Kali image that
> ships it. First container run also builds that image (a one-time download).

Add yourself to the `kvm` group once (`sudo adduser $USER kvm`, then re-login);
debos needs KVM and the container needs `/dev/kvm` passed in.

## Profiles & extra options

| Flag | Expands to | Result |
|---|---|---|
| `--full` (default) | `-D xfce -T default` | The faithful full Kali XFCE desktop + default toolset (large). |
| `--headless` | `-D none -T headless -s 20` | No desktop, headless toolset, 20 GB (fast, lean). |

**Variant & format** — pick which VM engine the image targets and its disk
format with `--variant` (`-v`) / `--format` (`-f`):

| `--variant` | default `--format` | disk produced |
|---|---|---|
| `qemu` (default) | `qemu` | QCOW2 — what `run-graphical.sh` boots |
| `generic` | `raw` | raw sparse (or `--format ova`/`ovf` for VMDK + OVF) |
| `virtualbox` | `virtualbox` | VDI (+ `.vbox`) |
| `vmware` | `vmware` | VMDK (+ `.vmx`) |
| `hyperv` | `hyperv` | VHDX (UEFI) |
| `rootfs` | — | a `.tar.gz` rootfs (no kernel/bootloader; reuse with `build.sh -r`) |

```bash
examples/kali-vm-builder/build-kali-vm.sh --variant virtualbox --full      # VDI for VirtualBox
examples/kali-vm-builder/build-kali-vm.sh --variant generic --format ova    # OVA for VBox/VMware
```

`run-graphical.sh` boots only the **qemu/QCOW2** output; for the other variants,
import the produced file(s) into that hypervisor.

Anything without a dedicated flag is still forwarded verbatim after `--` (branch,
size, extra packages, custom user, release label, …):

```bash
examples/kali-vm-builder/build-kali-vm.sh --headless -- -P metasploit-framework -U hacker:hunter2 -x lean -- --scratchsize=50G
```

(See `build.sh -h` in the checkout for the full upstream option set: `-b` branch,
`-s` size, `-D` desktop, `-T` toolset, `-K`/`-L`/`-Z` keyboard/locale/tz, etc.)

**Mirror (applies to every build):** the wrapper defaults the apt mirror to Kali's
Cloudflare CDN, `http://kali.download/kali` — reliable, and it dodges the
`http.kali.org` *redirector* occasionally rolling onto a community mirror whose
TLS cert the minimal build VM can't verify (which aborts debootstrap, more likely
on big `--full` builds). Override with `--mirror URL` (e.g. a local mirror, or
`--mirror http://http.kali.org/kali` for the geo-redirector).

## Running it graphically

`run-graphical.sh` boots the image the way it's *meant* to be run — with a real
display. Key behaviour:

- **BIOS, not UEFI.** The `qemu` variant is a grub-pc/MBR image, so the runner
  uses QEMU's SeaBIOS (no OVMF). Booting it under UEFI would drop to a UEFI shell.
- **Copy-on-write overlay by default.** It boots a `run/<image>.overlay.qcow2`
  backed by the master, so your tinkering persists across runs but the freshly
  built image stays pristine. `--no-overlay` mutates the master; `--snapshot`
  discards all writes on shutdown; `--fresh` recreates the overlay.
- **Access:** log in at the GTK window as `kali`/`kali`. The runner also forwards
  host `:2222` → guest `:22`; SSH works once you enable it in the guest
  (`sudo systemctl enable --now ssh`) — Kali ships sshd installed but disabled.

```bash
examples/kali-vm-builder/run-graphical.sh --memory 6G --cpus 4
examples/kali-vm-builder/run-graphical.sh --image ~/kali-vm-build/kali-vm/images/kali-linux-rolling-qemu-amd64.qcow2
examples/kali-vm-builder/run-graphical.sh --snapshot          # throwaway session
```

## Why this is separate from the other Kali labs

| Lab | Mechanism | Output |
|---|---|---|
| **this** (`kali-vm-builder`) | upstream `kali-vm` + `debos` (a real image factory) | a full, graphical Kali VM image (the "downloadable" kind) |
| `offsec-awae-vm/` | `from-chroot`: debootstrap → BIOS/extlinux qcow2 | a headless, serial/SSH Kali for `lab-vm` |
| `vm-kali-amd64.toml` | `lab-vm` downloads Kali's **prebuilt** image | the same official image, but pre-baked, not built locally |

This lab is the **build-it-yourself** counterpart to `vm-kali-amd64.toml`: same
kind of image, but produced on your machine with full control over desktop,
toolset, packages, user, locale, size, branch, etc. Because it's a graphical
image (no serial console, sshd off by default), it's run with its own graphical
QEMU helper rather than `lab-vm` (which is serial-only).

> Headless via `lab-vm` (optional): the produced QCOW2 *can* be booted by
> `lab-vm` with a `[[vm]]` of `backend="disk-image"`, `image="<that qcow2>"`,
> `distro="kali"`, `firmware="bios"` — but you'd first enable a serial console +
> sshd in the image, since the factory image has neither. The graphical runner
> above avoids that entirely.

## Cost & prerequisites

- **Space:** tens of GB free in the work dir (image + ~45 GB scratch). Use
  `--workdir`/`$KALI_VM_DIR` to place it on a roomy disk.
- **Time/network:** a full build downloads a large Kali package set; the
  container path also pulls/builds a Kali builder image once.
- **KVM:** `/dev/kvm` + membership in the `kvm` group (both the debos build VM
  and the graphical runner want hardware virtualization).
- **Display:** `run-graphical.sh` needs an X/Wayland session (it opens a window).

## Verification status

Scripts are syntax-checked and their option handling is exercised; an
**end-to-end build has not been run here** (it's long and host-specific). See
`MANUAL_TESTING.md` to drive it and report back.
