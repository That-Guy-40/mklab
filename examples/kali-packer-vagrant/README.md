# Kali's Packer build scripts, operationalized

Kali built its **Vagrant base boxes** with [HashiCorp **Packer**](https://developer.hashicorp.com/packer)
until the 2025.2 release, when it switched to [debos](https://github.com/go-debos/debos)
(the same engine `kali-vm` wraps — see [`../kali-vm-builder/`](../kali-vm-builder/)).
The Packer scripts still live at
[`kalilinux/build-scripts/kali-packer`](https://gitlab.com/kalilinux/build-scripts/kali-packer),
now archived — *"no longer in production"*. This lab **fetches them (pinned),
drives a real Packer build, and boots the result** — so you can watch the *other*
image-factory mechanism work.

> ⚠️ **Authorized use only.** This builds a full Kali system (offensive
> tooling). Keep it on an isolated network and only target hosts you own or are
> authorized to test. `vagrant`/`vagrant` is a throwaway lab credential — never
> ship it.

## Why this is the interesting counterpoint

There are two fundamentally different ways to bake an OS image, and this repo now
has both:

| | **assemble-the-rootfs** | **drive-the-installer** |
|---|---|---|
| Labs | [`debian-vm-builder/`](../debian-vm-builder/README.md), [`kali-vm-builder/`](../kali-vm-builder/) (debos) | **this** (`kali-packer-vagrant`, Packer) |
| How | `debootstrap` a filesystem directly, partition it, drop in a bootloader — no installer, no booting | boot the **real installer ISO**, script the boot menu, feed it a **preseed**, let the installer run, then SSH in to provision |
| Interaction | declarative YAML recipe, executed inside a build VM | Packer *screen-scrapes the install*: types a `boot_command` over VNC, serves the preseed over its own HTTP server, waits for SSH |
| Output | a raw/qcow2 disk | a **Vagrant `.box`** (qcow2 + `Vagrantfile` + `metadata.json`) |

Packer automates *exactly what a human does at the installer*. That's why it ties
straight back to the preseed labs
([`kali-preseed-gallery/`](../kali-preseed-gallery/),
[`debian-pxe-lab/`](../debian-pxe-lab/README.md)): the file at `http/preseed.cfg`
in the checkout is an ordinary d-i preseed — the difference is only *how it's
delivered* (Packer's HTTP server + a typed `boot_command`, instead of PXE/iPXE).

## The pipeline (what Packer actually does)

```
kali-linux-YYYY.X-installer-amd64.iso                        (the real Kali installer)
        │  Packer boots it in a throwaway QEMU VM
        ▼
boot_command typed over VNC  ──►  " ... auto=true priority=critical
        │                            url=http://{{.HTTPIP}}:{{.HTTPPort}}/preseed.cfg"
        ▼
http/preseed.cfg  (served by Packer)  ──►  unattended d-i install
        │   user vagrant/vagrant · atomic partitioning · late_command enables ssh
        ▼
Packer SSHes in  ──►  scripts/vagrant.sh   (insecure Vagrant key + passwordless sudo + DHCP)
                      scripts/minimize.sh  (zero-fill free space so the box compresses)
        ▼
`vagrant` post-processor  ──►  packer_kalirolling_libvirt_amd64.box
```

## What's here (a driver — upstream is used unmodified)

| File | Role |
|---|---|
| `fetch-kali-packer.sh` | Clone/pin the upstream `kali-packer` checkout into a work dir **outside** this repo (default pin `b8c9b34`; see [`UPSTREAM.md`](UPSTREAM.md)). |
| `build-kali-box.sh` | Resolve the current Kali ISO + checksum, `packer init`, then `packer build` the **QEMU** builder only (never uploads). `--validate-only` for the fast config check; `--install-packer` if you don't have packer. |
| `run-graphical.sh` | Unpack the QCOW2 out of the `.box` and boot it in a **windowed QEMU desktop** (SeaBIOS/BIOS + **virtio-scsi** to match the build + SSH-forward, on a COW overlay). |
| `README.md` / `MANUAL_TESTING.md` / `UPSTREAM.md` | This file · the runbook · provenance. |

Artifacts live under `$KALI_PACKER_DIR` (default `$HOME/kali-packer-build`),
**not** in this repo — a build pulls a ~4 GB ISO and writes a ~6 GB box plus
scratch. Point `--workdir` at a roomy disk if `$HOME` is tight (needs ~15 GB free).

## Quick start

```bash
# 0. (only if you don't have packer) fetch a pinned static packer into the workdir:
examples/kali-packer-vagrant/build-kali-box.sh --install-packer --validate-only

# 1. Fast sanity check — parse + validate the upstream config, no VM, no download:
examples/kali-packer-vagrant/build-kali-box.sh --validate-only

# 2. Build the box (downloads the ISO + runs a full unattended install; ~30 min on KVM):
examples/kali-packer-vagrant/build-kali-box.sh

# 3. Boot the result in a graphical QEMU window (login vagrant / vagrant):
examples/kali-packer-vagrant/run-graphical.sh
```

`build-kali-box.sh` auto-fetches the checkout on first run, so you don't have to
call `fetch-kali-packer.sh` yourself (it's there for `--force`/`--ref` pinning).

## Getting packer

Packer isn't in Debian/Ubuntu's default repos. Three options, from the upstream README:

- **Let this lab fetch it** (simplest): `--install-packer` grabs a pinned static
  binary (`packer 1.13.1`, SHA256-verified) into `<workdir>/bin/packer` and uses it.
- **HashiCorp apt repo** (Kali/Debian/Ubuntu): add `apt.releases.hashicorp.com`,
  then `sudo apt install -y packer` (see `MANUAL_TESTING.md`).
- **Static binary by hand**: download from `releases.hashicorp.com/packer`, unzip
  onto your `$PATH`, pass `--packer /path/to/packer`.

`packer init` then downloads the plugins the config declares (qemu, virtualbox,
vmware, hyperv, vagrant) — you only *need* the hypervisor whose builder you run.

## Choosing what to build (`--only`) & speed (`--accel`)

The upstream config defines four builders; **QEMU is the one this lab boots**:

| `--only` | Needs | run-graphical.sh boots it? |
|---|---|---|
| `qemu.kalirolling` (default) | qemu + `/dev/kvm` | ✅ yes (the `.box` is a libvirt/qcow2 box) |
| `virtualbox-iso.kalirolling` | VirtualBox + ext-pack | ❌ import the `.box`/VDI into VirtualBox |
| `vmware-iso.kalirolling` | VMware Workstation | ❌ import into VMware |
| `hyperv-iso.kalirolling` | Windows + Hyper-V | ❌ Windows only |

```bash
examples/kali-packer-vagrant/build-kali-box.sh --accel kvm            # fast (default when /dev/kvm exists)
examples/kali-packer-vagrant/build-kali-box.sh --accel tcg --ssh-timeout 180m   # no KVM: HOURS, bump the timeout
examples/kali-packer-vagrant/build-kali-box.sh --headless false       # watch the installer in a QEMU window
```

**Accel matters a lot.** On KVM the QEMU build is ~20–40 min; under `tcg`
(software emulation, e.g. a CI runner with no `/dev/kvm`) it's *hours* — raise
`--ssh-timeout` so Packer doesn't give up mid-install.

## Running it graphically

`run-graphical.sh` unpacks `box.img` from the `.box` and boots it as installed:

- **BIOS, not UEFI.** The packer QEMU image is grub-pc/MBR, so SeaBIOS boots it
  (no OVMF).
- **virtio-scsi**, matching `config.pkr.hcl`'s `disk_interface = "virtio-scsi"`
  — so the disk shows up exactly as it did at install time. (The install used
  `/dev/sda`, i.e. SCSI naming — which is why the upstream preseed's
  `grub-installer/bootdev /dev/sda` is correct here and needs *no* `→/dev/vda`
  rewrite, unlike the virtio-blk PXE labs.)
- **Copy-on-write overlay by default**, so the extracted master stays pristine
  (`--no-overlay` / `--snapshot` / `--fresh` as in the sibling labs).
- **Access:** log in at the GTK window as `vagrant`/`vagrant`; the runner
  forwards host `:2222` → guest `:22` and sshd is enabled by the preseed, so
  `ssh -p 2222 vagrant@127.0.0.1` (password `vagrant`) works immediately.

```bash
examples/kali-packer-vagrant/run-graphical.sh --memory 6G --cpus 4
examples/kali-packer-vagrant/run-graphical.sh --extract-only     # just unpack box.img, don't boot
examples/kali-packer-vagrant/run-graphical.sh --snapshot         # throwaway session
```

> **Prefer Vagrant?** The `.box` is a real `libvirt` Vagrant box. With
> `vagrant` + `vagrant-libvirt` installed you can
> `vagrant box add kali-packer <box>` and `vagrant up` — that's what the box was
> *made* for. This lab boots it directly with QEMU so you don't need the Vagrant
> stack just to see it work.

## How this differs from the other Kali VM labs

| Lab | Mechanism | Output |
|---|---|---|
| **this** (`kali-packer-vagrant`) | **Packer** drives the Kali installer ISO + preseed (the pre-2025.2 way) | a Vagrant `.box` |
| [`kali-vm-builder/`](../kali-vm-builder/) | `kali-vm` → **debos** (assemble a rootfs) — Kali's *current* factory | the "downloadable" Kali VM image |
| [`vm-kali-amd64.toml`](../vm-kali-amd64.toml) | `lab-vm` downloads Kali's **prebuilt** image | same image, pre-baked |
| [`kali-preseed-gallery/`](../kali-preseed-gallery/) | PXE/iPXE + a preseed catalog | a zero-touch **install**, not an image |

## Cost & prerequisites

- **Space/time/network:** ~15 GB free in the work dir; a ~4 GB ISO download; the
  install itself ~20–40 min on KVM (hours on `tcg`).
- **KVM:** `/dev/kvm` + the `kvm` group for a fast build (and for the runner).
- **packer:** installed, or fetched via `--install-packer`.
- **Display:** `run-graphical.sh` opens an X/Wayland window (`--display none` to skip).

## Verification status

Fetch/pin, **`packer validate` on the real upstream config** (packer 1.13.1 + all
five plugins → *"The configuration is valid."*), the driver scripts (syntax +
option handling), and the `.box`→QCOW2 extraction + QEMU boot pipeline are
**verified here** (the extraction/boot proven with a synthetic box; see
`MANUAL_TESTING.md`). The **full Packer build is author-run** — it's long,
downloads gigabytes, and is host-specific (same posture as `kali-vm-builder`).
`MANUAL_TESTING.md` walks the whole thing end to end.
