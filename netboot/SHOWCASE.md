# Netboot pipeline — HTTP-boot any chroot, QEMU to real hardware

## What it gives you

A fully automated pipeline that turns a Phase 1 debootstrap chroot into
a network-bootable Linux system that runs **entirely in RAM** — Kenneth
Finnegan's HTTP netboot approach, end-to-end in three shell scripts and
a handful of TOMLs.

The complete chain:

```
Phase 1: lab-chroot.sh create + export-initrd
      ↓  builds cpio.gz initrd + copies kernel
netboot/build-ipxe.sh
      ↓  compiles iPXE from source (inside Docker), embeds boot.ipxe
Phase 4: lab-podman.sh up (podman-netboot-server.toml)
      ↓  rootless nginx serves kernel + initrd + boot.ipxe over HTTP
Phase 2: lab-vm.sh start (vm-netboot-ipxe.toml)
      ↓  QEMU boots ipxe.qcow2 → iPXE fetches + boots initrd in RAM
      ↓  (or: dd ipxe.usb → USB stick → boot real hardware)
```

No TFTP server. No DHCP infrastructure. No PXE ROM configuration.
Just HTTP.

## 60-second demo

After one-time setup (see MANUAL_TESTING.md), the working loop is:

```bash
# Rebuild the initrd after chroot changes:
sudo phase1-chroot/lab-chroot.sh export-initrd netboot-minimal \
    --kernel ~/netboot/kernel \
    --output ~/netboot/initrd.gz

# Bounce the VM to pick up the new initrd:
phase2-qemu-vm/lab-vm.sh stop  netboot-ipxe
phase2-qemu-vm/lab-vm.sh start netboot-ipxe
# → iPXE fetches the new kernel + initrd, boots in RAM, no disk write needed
```

The nginx container keeps running between iterations — it serves
whatever files are in `~/netboot/` and picks up changes immediately.

## Feature tour

### `setup-netboot-dir.sh` — one-time host setup (no root needed)

Creates `~/netboot/` (the artifact directory) and
`~/.config/lab-netboot/ipxe-mime.conf` (the nginx MIME snippet that
makes iPXE accept `.ipxe` files as chainboot scripts).

```bash
netboot/setup-netboot-dir.sh
# [info] creating artifact directory: /home/you/netboot
# [info] creating config directory:   /home/you/.config/lab-netboot
# [info] writing nginx MIME snippet:  /home/you/.config/lab-netboot/ipxe-mime.conf
```

Override the paths with env vars or flags if your layout differs:

```bash
LAB_NETBOOT_DIR=/data/netboot LAB_NETBOOT_CONF=/etc/lab-netboot \
    netboot/setup-netboot-dir.sh
# or:
netboot/setup-netboot-dir.sh --dir /data/netboot --conf /etc/lab-netboot
```

### `export-initrd` — any chroot becomes an initrd (Phase 1)

The new verb added to `lab-chroot.sh`. It:

1. Detects or writes `/init` inside the chroot (busybox or systemd preset)
2. Strips kernel modules if `--strip-modules` is passed (saves ~50 MB)
3. Packs the chroot tree with `find | cpio -H newc -o | gzip -9 -n`
4. Copies the chroot's own kernel to `--kernel`

```bash
sudo phase1-chroot/lab-chroot.sh export-initrd netboot-minimal \
    --kernel ~/netboot/kernel \
    --output ~/netboot/initrd.gz
# [info] writing busybox /init preset
# [info] packing initrd: find | cpio | gzip → ~/netboot/initrd.gz
# [info] copying kernel → ~/netboot/kernel
# [info] initrd: 142 MB (compressed), kernel: 8.3 MB
```

**`init_script` TOML field** — set it in the `[[chroot]]` block at
create time so you never have to manually write or edit `/init`:

```toml
[[chroot]]
name        = "netboot-minimal"
init_script = "busybox"    # or "systemd", or a path to your own script
include     = ["linux-image-amd64", "busybox-static", "kmod"]
```

`export-initrd` auto-detects the preset at pack time if no `/init`
exists — it checks for `/bin/busybox` vs `/sbin/init`.

### `build-ipxe.sh` — iPXE from source, in Docker

Compiles iPXE inside a `debian:bookworm` container so the host is not
polluted with compiler toolchains. Produces four artifacts in
`~/netboot/`:

| File | Use |
|---|---|
| `boot.ipxe` | Plain-text chainboot script served by nginx |
| `ipxe.usb` | Raw disk image — `dd` to a USB stick |
| `ipxe.efi` | UEFI binary — copy to EFI partition |
| `ipxe.qcow2` | qcow2 of `ipxe.usb` — `lab-vm.sh` Phase 2 boot |

```bash
# QEMU (host is 10.0.2.2 from inside the VM via slirp):
netboot/build-ipxe.sh --server http://10.0.2.2:8181

# Real hardware (use your LAN IP):
netboot/build-ipxe.sh --server http://192.168.1.50:8181 --arch x86_64
```

The `--server` URL is embedded into `boot.ipxe` at build time.
**The port here must match the `ports = []` line in your nginx TOML.**
If you rebuild with a different `--server`, you don't need to recompile
the chroot or initrd — just restart the VM.

### HTTPS / TLS — encrypted netboot with an embedded cert

By default the pipeline uses plain HTTP.  Two flags flip it to HTTPS:

**Step 1 — generate a self-signed cert once:**

```bash
netboot/setup-netboot-dir.sh --tls
```

Writes three files to `~/.config/lab-netboot/`:

| File | Purpose |
|---|---|
| `netboot.crt` | PEM cert — nginx `ssl_certificate` |
| `netboot.key` | PEM private key — nginx `ssl_certificate_key` |
| `netboot.der` | DER cert — embedded into the iPXE binary |
| `ipxe-ssl.conf` | nginx TLS protocol snippet (`include` it in your server{} block) |

The cert has a 10-year validity and carries SANs for `127.0.0.1` and
`10.0.2.2` (the QEMU slirp gateway, so QEMU boots work out of the box).

**Step 2 — build HTTPS-capable iPXE with the cert embedded:**

```bash
netboot/build-ipxe.sh \
    --server   https://10.0.2.2:8443 \
    --tls \
    --tls-cert ~/.config/lab-netboot/netboot.der
```

`--tls` adds `#define DOWNLOAD_PROTO_HTTPS` to iPXE's compiled config
via a `local/general.h` override inside the build container.  `--tls-cert`
passes the DER file into the container and feeds it to `CERTSTORE=`,
embedding it in the binary trust store.  **Result: iPXE trusts our
self-signed cert at boot time without any `trust` command in the boot
script.**

The generated `boot.ipxe` will read:

```
#!ipxe
dhcp
kernel https://10.0.2.2:8443/kernel console=ttyS0 root=/dev/ram0 rw
initrd https://10.0.2.2:8443/initrd.gz
boot
```

**Step 3 — serve over HTTPS:**

Add the cert/key to an nginx server block alongside `ipxe-ssl.conf` and
`ipxe-mime.conf` (both auto-generated by `setup-netboot-dir.sh`).
See [`MANUAL_TESTING.md §10.4`](MANUAL_TESTING.md) for a copy-pasteable
nginx config and a Docker one-liner to test it.

**Why embed the cert instead of using a `trust` command?**  PXE boot
happens before the OS is running, so there is no system CA store.  If you
used an external `trust` you would have to fetch the cert over **HTTP**
first, defeating the security goal.  Embedding via `CERTSTORE=` means the
trust anchor is part of the signed binary itself.

### Traditional DHCP/TFTP PXE — no USB stick, no HTTP-first

iPXE-over-HTTP is the cleanest path, but some hardware or network policies
require classic DHCP/TFTP PXE.  This pipeline adds that layer without
replacing the HTTP-serving nginx.

**QEMU (no extra container):**

QEMU's slirp network has a built-in DHCP+TFTP server.  Specify `pxe_dir`
in the VM spec and QEMU advertises the bootfile via DHCP option 67 and
serves it via TFTP from 10.0.2.2:

```toml
# examples/pxe-boot-mechanics/vm-pxe-tftp-boot.toml
[[vm]]
name         = "pxe-tftp"
pxe_dir      = "/home/sqs/netboot"   # serves ipxe.efi via TFTP
pxe_bootfile = "ipxe.efi"
```

```bash
# VM boots: DHCP → TFTP → iPXE → HTTP boot.ipxe → kernel+initrd
phase2-qemu-vm/lab-vm.sh create --config examples/pxe-boot-mechanics/vm-pxe-tftp-boot.toml
phase2-qemu-vm/lab-vm.sh start  pxe-tftp
```

**Real hardware (ProxyDHCP + TFTP — safe on a shared LAN):**

```bash
# 1. Populate TFTP root + generate dnsmasq ProxyDHCP config:
netboot/setup-dhcp-tftp.sh --server-ip 192.168.1.50 --iface eth0

# 2. Start dnsmasq (needs host networking + root for DHCP broadcasts):
sudo docker run --rm -d --name pxe-dnsmasq --network host \
    --cap-add NET_ADMIN \
    -v ~/netboot/tftp:/tftp:ro \
    -v ~/.config/lab-netboot/dnsmasq-pxe.conf:/etc/dnsmasq.conf:ro \
    alpine:latest sh -c 'apk add -q dnsmasq && dnsmasq --no-daemon'
```

ProxyDHCP mode responds **only to PXE clients** (DHCP option 60 = `PXEClient`)
and adds TFTP server/bootfile info alongside your router's DHCP response.
Your existing DHCP server keeps assigning IPs — no conflict.

Architecture-aware responses are configured automatically: UEFI x64 clients
get `ipxe.efi`; legacy BIOS clients get `ipxe.usb`.

### Secure Boot — sign iPXE and boot with firmware enforcement

OVMF's Secure Boot enforcement rejects unsigned EFI binaries.  Two paths:

**QEMU (snakeoil key — instant, no firmware interaction):**

```bash
# Build and sign in one step:
netboot/build-ipxe.sh --server http://10.0.2.2:8181 --sign --use-snakeoil

# Or sign an existing binary:
netboot/sign-ipxe.sh --use-snakeoil

# Boot with Secure Boot enforcement (secboot OVMF + snakeoil VARS):
cp ~/netboot/ipxe-signed.efi ~/netboot/ipxe.efi
phase2-qemu-vm/lab-vm.sh create --config examples/pxe-boot-mechanics/vm-pxe-secureboot.toml
```

```toml
# examples/pxe-boot-mechanics/vm-pxe-secureboot.toml
[[vm]]
secure_boot  = true   # → OVMF_CODE_4M.secboot.fd + OVMF_VARS_4M.snakeoil.fd
pxe_dir      = "/home/sqs/netboot"
pxe_bootfile = "ipxe.efi"   # must be signed with snakeoil key
```

The `snakeoil` OVMF has the Ubuntu/Debian test key pre-enrolled in the
UEFI Signature Database.  `sign-ipxe.sh --use-snakeoil` signs with the
corresponding private key (`/usr/share/ovmf/PkKek-1-snakeoil.key`).  The
signed binary boots; an unsigned one triggers `Secure Boot violation`.

**Real hardware (MOK enrollment):**

```bash
# Generate a personal MOK key pair and sign:
netboot/sign-ipxe.sh --generate-mok

# Enroll the MOK (requires monitor + keyboard — one-time per machine):
sudo mokutil --import ~/.config/lab-netboot/MOK.crt
sudo reboot   # → blue MokManager screen → "Enroll MOK"
```

After enrollment, any binary signed with your MOK key boots under Secure
Boot on that machine, regardless of vendor keys.

### Rootless nginx — serve without root (Phase 4)

`podman-netboot-server.toml` starts a rootless nginx container that
bind-mounts `~/netboot/` read-only and side-loads the iPXE MIME type
so `.ipxe` responses carry `Content-Type: application/x-ipxe`:

```bash
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml

curl -sI http://localhost:8181/kernel     # → 200 OK, Content-Type: application/octet-stream
curl -sI http://localhost:8181/initrd.gz  # → 200 OK
curl -s  http://localhost:8181/boot.ipxe  # → the embedded iPXE script
```

**Why the MIME type matters:** iPXE validates `Content-Type` before
executing a fetched script. Without `application/x-ipxe`, iPXE refuses
to chainload `boot.ipxe` with a cryptic "Could not boot image" error.
The `ipxe-mime.conf` snippet volume-mounted into the container fixes
this transparently — no host nginx changes needed.

### Two boot modes (Phase 2)

**Direct kernel+initrd** (`vm-netboot-direct.toml`) — QEMU's
`-kernel`/`-initrd` flags load the files from disk and hand them
straight to the kernel, skipping iPXE entirely. Fastest way to
validate that the initrd actually boots:

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-direct.toml
phase2-qemu-vm/lab-vm.sh start  netboot-direct
# Serial console: busybox sh prompt in a few seconds
```

**Full iPXE simulation** (`vm-netboot-ipxe.toml`) — boots from
`ipxe.qcow2`, exactly as real hardware would from a USB stick. iPXE
does DHCP via QEMU slirp, then fetches kernel + initrd from the nginx
container at `http://10.0.2.2:8181/`:

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-ipxe.toml
phase2-qemu-vm/lab-vm.sh start  netboot-ipxe
```

Watch the serial console: iPXE banner → DHCP → HTTP fetch → kernel
decompress → busybox `sh` prompt.

### Real hardware path

The same `ipxe.usb` that QEMU boots can be flashed to a USB stick:

```bash
sudo dd if=~/netboot/ipxe.usb of=/dev/sdX bs=4M status=progress
# Plug into thin client / SBC, boot from USB
# → iPXE fetches kernel + initrd from your LAN server → boots in RAM
```

For permanent installation (e.g. a thin client that always netboots):
copy `ipxe.efi` to the EFI partition and add a boot entry, or chain
from your existing bootloader.

## How the chain works

```
[QEMU/USB] boots ipxe.qcow2 / ipxe.usb
      └─ iPXE ROM starts
         └─ runs embedded boot.ipxe:
              dhcp
              kernel http://10.0.2.2:8181/kernel console=ttyS0 root=/dev/ram0 rw
              initrd http://10.0.2.2:8181/initrd.gz
              boot
         └─ downloads kernel + cpio.gz initrd over HTTP
         └─ jumps to kernel entry point
[Linux kernel]
      └─ unpacks initrd into RAM (tmpfs)
      └─ executes /init (busybox sh or systemd)
      └─ DHCP via udhcpc (busybox) / dhcpcd (systemd track)
      └─ system is running entirely in RAM — no disk needed
```

`10.0.2.2` is the QEMU slirp host address — the guest's view of the
host's loopback interface. Traffic to `10.0.2.2:8181` reaches the
rootless nginx container on the host. For real hardware, replace with
your LAN IP and rebuild iPXE with `--server http://<LAN-IP>:8181`.

## The two initrd tracks

| Track | TOML | `/init` | RAM needed | Boot time | Use case |
|---|---|---|---|---|---|
| **Minimal** | `chroot-netboot-minimal.toml` | busybox sh | ~200 MB | ~5 s | Rescue shell, PXE testing, fast iteration |
| **Full Debian** | `chroot-netboot-full.toml` | systemd | ~1 GB | ~20 s | Full Debian userland in RAM, SSH access |

The minimal track is the right starting point. Switch to full Debian
when you need a real init system, udev-driven device discovery, or SSH
without a serial console.

## The unified cross-phase TOML

`examples/netboot-lab.toml` ties Phase 1, Phase 4, and Phase 2 into one
file. Each phase tool reads only its own blocks:

```bash
# Phase 1 reads [[chroot]]:
sudo phase1-chroot/lab-chroot.sh create --config examples/netboot-lab.toml

# Phase 4 reads [[service]] where engine="podman":
phase4-podman/lab-podman.sh up --config examples/netboot-lab.toml

# Phase 2 reads [[vm]]:
phase2-qemu-vm/lab-vm.sh create --config examples/netboot-lab.toml
phase2-qemu-vm/lab-vm.sh start  netboot-ipxe
```

Phase 6's TUI surfaces all three together under one `🌐 netboot` lab
group in the browser tree.

## Port note

Port 8181 is used by default in the example TOMLs and build scripts.
Port 8080 is the iPXE convention but may be in use (e.g. SABnzbd).
If 8080 is free on your host:

1. Change `ports = ["8080:80"]` in the nginx TOML
2. Rebuild iPXE: `netboot/build-ipxe.sh --server http://10.0.2.2:8080`

Both must match — the `--server` URL is baked into `boot.ipxe` at compile time.

## Where next

- [`MANUAL_TESTING.md`](MANUAL_TESTING.md) — step-by-step walkthrough
  with exact commands, expected output, and a troubleshooting table
- [`../NETBOOT_LAB_PLAN.md`](../NETBOOT_LAB_PLAN.md) — full design doc
  and architecture rationale
- [`../examples/`](../examples/) — all referenced TOMLs:
  - [`chroot-netboot-minimal.toml`](../examples/chroot-netboot-minimal.toml)
  - [`chroot-netboot-full.toml`](../examples/chroot-netboot-full.toml)
  - [`podman-netboot-server.toml`](../examples/podman-netboot-server.toml)
  - [`docker-netboot-server.toml`](../examples/docker-netboot-server.toml)
  - [`vm-netboot-direct.toml`](../examples/vm-netboot-direct.toml)
  - [`vm-netboot-ipxe.toml`](../examples/vm-netboot-ipxe.toml)
  - [`netboot-lab.toml`](../examples/netboot-lab.toml)
- Sibling SHOWCASEs:
  [Phase 1 (chroots)](../phase1-chroot/SHOWCASE.md) ·
  [Phase 2 (VMs)](../phase2-qemu-vm/SHOWCASE.md) ·
  [Phase 4 (podman)](../phase4-podman/SHOWCASE.md) ·
  [Phase 6 (TUI)](../phase6-tui/SHOWCASE.md)

---

### AlmaLinux zero-touch PXE install — fully unattended kickstart over iPXE

A six-command pipeline that downloads the AlmaLinux installer, generates a
per-host kickstart, builds an iPXE ROM, and boots a QEMU VM that installs
AlmaLinux to disk and reboots into it — no manual steps between `start` and
`ssh`.

#### The boot-loop design

The key to zero-touch behaviour is QEMU's `bootindex` ordering combined with
a two-disk VM layout:

- **disk0 = blank install target** (20 GB qcow2), `bootindex=0`: on the first
  boot the disk has no boot sector, so BIOS skips it and falls through to disk1.
  After Anaconda installs, disk0 is bootable and wins every subsequent boot.
- **disk1 = `ipxe.qcow2`** (iPXE ROM), `bootindex=1`: runs on the first boot
  only, chainloads the AlmaLinux Anaconda installer, then is never reached again.

| Boot | disk0 state | What happens |
|---|---|---|
| 1st | empty (no boot sector) | BIOS skips disk0 → boots iPXE (disk1) → Anaconda installs to disk0 → kickstart `reboot` |
| 2nd+ | bootable AlmaLinux | BIOS boots disk0; iPXE is never reached again |

Result: `create` the VM, `start` it, walk away. SSH in ~10 minutes later to a
fully installed AlmaLinux system.

#### Six-step happy path

```bash
# 1. Fetch the AlmaLinux installer kernel and initrd (verifies sha256 checksums):
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh \
    --mirror https://repo.almalinux.org/almalinux --release 9 --arch x86_64

# 2. Generate a per-host kickstart named after the VM's pinned MAC:
netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01

# 3. Build iPXE with the AlmaLinux boot parameters embedded:
netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'

# 4. Serve artifacts over HTTP via rootless nginx (Phase 4):
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml

# 5. Create the two-disk target VM:
phase2-qemu-vm/lab-vm.sh create --config examples/almalinux-pxe-lab/vm-almalinux-pxe-install.toml

# 6. Start it and walk away — Anaconda installs unattended:
phase2-qemu-vm/lab-vm.sh start almalinux-pxe-install   # walk away; SSH in after ~10 min
```

After install completes, SSH in with `lab` / `lab`:

```bash
phase2-qemu-vm/lab-vm.sh ssh almalinux-pxe-install
```

#### The {MAC} placeholder — why not `${mac:hexhyp}` directly

The embedded `boot.ipxe` script is written via an **unquoted** bash heredoc
inside `netboot/ipxe-build-inner.sh`. Any `$`-tokens in an unquoted heredoc
are expanded by bash at build time — so writing `${mac:hexhyp}` literally
in `--append` would be consumed by bash immediately (expanding to empty) and
never reach the iPXE script.

The solution is a literal placeholder: write `{MAC}` in `--append`. After the
heredoc is written, a `sed` pass rewrites `{MAC}` to `${mac:hexhyp}` in the
resulting file. From that point on it is an iPXE variable — bash has already
finished expanding — and iPXE's runtime expands `${mac:hexhyp}` to the
booting NIC's lowercase hyphen-separated MAC (e.g. `52-54-00-a1-9a-01`) when
it fetches the kickstart URL.

In short: you type `{MAC}` as the placeholder; the sed rewrite turns it into
`${mac:hexhyp}`; iPXE expands it at boot. Bash never sees the `$`.

#### Real-hardware variant

The same pipeline works on physical machines. Rebuild iPXE pointing at your
LAN IP, generate one kickstart per NIC MAC, and flash the USB image:

```bash
netboot/build-ipxe.sh --server http://<LAN-IP>:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://<LAN-IP>:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'
netboot/gen-almalinux-ks.sh --mac <NIC-MAC>
dd if=~/netboot/ipxe.usb of=/dev/sdX bs=4M status=progress
# Boot the target machine from the USB stick — same pipeline, only URL and MACs change.
```

#### Security posture

The kickstart uses `lab:lab` plaintext credentials (root and the `lab` sudo
user), matching the throwaway posture of the rest of this toolkit. These are
suitable only for disposable, isolated lab VMs.

- **Do not expose to an untrusted network.** Anyone who can reach the nginx
  server can download the kickstart and learn the root password.
- For real deployments, replace `--plaintext` with `--iscrypted` and a
  SHA-512 hash (see `examples/almalinux-pxe-lab/almalinux-zerotouch.ks` comments for the
  `python3 -c "import crypt…"` one-liner).
- For the QEMU-only path, bind nginx to loopback (`127.0.0.1:8181`) — the
  QEMU slirp stack reaches `10.0.2.2` regardless, and the kickstart never
  leaves the host.

#### Referenced files

- [`../examples/almalinux-pxe-lab/vm-almalinux-pxe-install.toml`](../examples/almalinux-pxe-lab/vm-almalinux-pxe-install.toml) — the two-disk QEMU VM spec
- [`../examples/almalinux-pxe-lab/almalinux-pxe-lab.toml`](../examples/almalinux-pxe-lab/almalinux-pxe-lab.toml) — unified cross-phase lab (Phase 4 + Phase 2)
- [Phase 2 (QEMU VMs)](../phase2-qemu-vm/SHOWCASE.md) — `install_target`, `mac`, and `bootindex` VM spec fields
- [Phase 4 (Podman)](../phase4-podman/SHOWCASE.md) — rootless nginx serving the artifact directory
