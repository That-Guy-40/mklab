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

## What's here (a driver + two small compat patches)

| File | Role |
|---|---|
| `fetch-kali-packer.sh` | Clone/pin the upstream `kali-packer` checkout into a work dir **outside** this repo (default pin `b8c9b34`; see [`UPSTREAM.md`](UPSTREAM.md)). |
| `build-kali-box.sh` | Resolve the current Kali ISO + checksum, apply the two [compat patches](#known-issues-retired-script-bitrot) (`--verbatim` to skip), `packer init`, then `packer build` the **QEMU** builder only (never uploads). `--validate-only` for the fast config check; `--install-packer` if you don't have packer. |
| `run-graphical.sh` | Unpack the QCOW2 out of the `.box` and boot it in a **windowed QEMU desktop** (SeaBIOS/BIOS + **virtio-scsi** to match the build + SSH-forward, on a COW overlay). |
| `README.md` / `MANUAL_TESTING.md` / `UPSTREAM.md` | This file · the runbook · provenance. |

The upstream is used **as-is except for two documented one-line compat patches**
(applied by default, opt out with `--verbatim`) — without them the *retired*
scripts no longer build on 2026 Kali. See
[Known issues](#known-issues-retired-script-bitrot) for exactly what and why.

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
examples/kali-packer-vagrant/build-kali-box.sh --verbatim             # NO compat patches → reproduces the bitrot
```

**Accel matters a lot.** On KVM the QEMU build is ~20–40 min; under `tcg`
(software emulation, e.g. a CI runner with no `/dev/kvm`) it's *hours* — raise
`--ssh-timeout` so Packer doesn't give up mid-install.

**Watch it install (VNC), even headless.** A headless build still serves the
guest screen over VNC — Packer logs `connect via VNC without a password to
vnc://127.0.0.1:59XX`. Point a viewer at it to watch d-i run:
`xtightvncviewer 127.0.0.1::59XX` (note the **`::`** = a literal TCP port; a
single `:` is read as a VNC *display number*). The port is chosen fresh each
build — read it from the log. `MANUAL_TESTING.md` has the details.

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
- **Display backend:** windowed `--display gtk` (default; needs an X/Wayland
  session); use `--display sdl` if GTK/GL misbehaves on your host, or
  `--display none` for a headless boot-check.

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

## Known issues (retired-script bitrot)

The upstream is **archived / "no longer in production"**, and it has **bit-rotted
against 2026 Kali** in two independent spots — each aborts the build. Both are
patched by default (opt out with `--verbatim` to watch them fail); each is one
line, and the *why* is the interesting part:

1. **`disk_cache = "unsafe"` → read-only root after the install reboot** *(→ `writeback`)*
   The QEMU builder sets `disk_cache = "unsafe"`, which tells QEMU to **ignore the
   guest's flush/barrier requests** (a build-speed trick). When d-i finishes and
   the guest **reboots** — a guest reset, *not* a clean QEMU shutdown — writes the
   guest "flushed" during install may still be in host RAM, so the box boots on
   slightly-inconsistent ext4. The provisioner's first write then trips an ext4
   error, and the root fstab's **`errors=remount-ro`** flips `/` read-only — so
   `scripts/vagrant.sh`'s `mkdir /home/vagrant/.ssh` dies with **"Read-only file
   system."** (The error line can't even be logged — the journal's own fs is now
   read-only.) Kali's CI only builds under **`tcg`** and never hits it; a KVM host
   does, reliably. `writeback` honors flushes and fixes it. The *installed image*
   is fine either way — it's read back after a clean shutdown.
2. **`mkdir` without `-p` → `~/.ssh` already exists** *(→ `mkdir -p`)*
   `scripts/vagrant.sh` runs a bare `mkdir /home/vagrant/.ssh`. On modern Kali the
   `vagrant` login's **systemd-user session auto-creates `~/.ssh`** (gcr /
   ssh-agent socket), so by the time the provisioner runs, the dir exists →
   **"File exists"** → `set -e` aborts. `mkdir -p` is idempotent.

Only #1 is masked-and-deadly (it looks like a filesystem/hardware fault); #2 is a
plain bitrot. Together they're a neat lesson in why a *retired* image factory
stops working even though nothing in it "changed."

## Verification status

**Built + booted end-to-end here (2026-07-03, KVM).** With the two compat patches,
`build-kali-box.sh` produced a real **`packer_kalirolling_libvirt_amd64.box`
(5.7 GB)**; `run-graphical.sh` unpacked its QCOW2 and booted it to a working Kali
(`Kali GNU/Linux Rolling`, kernel 6.19; **passwordless sudo** + the **Vagrant
insecure key** in `~/.ssh/authorized_keys` confirm `scripts/vagrant.sh` ran; 2877
pkgs incl. the XFCE desktop; zero failed units). Also verified: fetch/pin,
`packer validate` on the real config (packer 1.13.1 + all five plugins), and the
`.box`→QCOW2 extraction. Getting there **surfaced the two bitrots above** (2 failed
builds → root-caused from the aborted VM's journal → fixed → green). `--verbatim`
reproduces the failures; `MANUAL_TESTING.md` has the full transcript.
