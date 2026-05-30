# Rocky Linux — self-contained zero-touch PXE install lab

Boot a brand-new VM (or a real machine) over the network and have it install
**Rocky Linux 9** with **no keystrokes** — PXE → iPXE → Anaconda → kickstart →
reboot into the installed system.

This is the Rocky twin of the AlmaLinux PXE lab (`examples/almalinux-pxe-lab/almalinux-pxe-lab.toml`).
Both are RHEL-family rebuilds, so the Anaconda/kickstart machinery is identical;
only the installer-fetch step and the mirror URLs differ.

Reference: [CIQ — *Booting Rocky Linux via PXE*](https://kb.ciq.com/article/rocky-linux/rl-booting-rocky-linux-via-pxe).
This lab implements **two** paths:

| Path | Use case | DHCP/TFTP source | iPXE delivery |
|---|---|---|---|
| **A — QEMU (default)** | a throwaway VM on your workstation | QEMU's built-in slirp | NIC's iPXE ROM → TFTP `boot.ipxe` (runs it directly) |
| **B — real hardware** | a physical machine on your LAN | `dnsmasq` ProxyDHCP + TFTP | NIC PXE → chainload `ipxe.pxe`/`ipxe.efi` (CIQ-style) |

Path A is the fastest way to *see it work* with zero LAN setup. Path B is the
faithful "real PXE server" the CIQ article describes.

---

## What's in this directory

| File | Role |
|---|---|
| `fetch-rocky-installer.sh` | Download + verify Rocky's `vmlinuz`/`initrd.img` (checksums from `.treeinfo`). |
| `rocky9-zerotouch.ks` | The kickstart that drives the unattended install (**plaintext lab creds**). |
| `rocky-pxe-lab.toml` | Unified config: Phase 4 nginx artifact server + Phase 2 installer VM. |
| `QUICKSTART.md` | Copy-paste runbook for this lab (Rocky only). |
| `README.md` | This file. |

> **Just want the copy-paste steps?** See [`QUICKSTART.md`](QUICKSTART.md) — a short
> Rocky-only runbook. The combined Rocky + AlmaLinux runbook is at
> [`../PXE-INSTALL-QUICKSTART.md`](../PXE-INSTALL-QUICKSTART.md).

Everything else is **reused** from the shared `netboot/` tooling — nothing is
duplicated:

| Shared tool | What this lab uses it for |
|---|---|
| `netboot/build-ipxe.sh` | Build the iPXE ROM with the Rocky boot params embedded. |
| `netboot/gen-almalinux-ks.sh` | Generic template→`ks/<mac>.ks` copier (distro-agnostic; pass `--template`). |
| `netboot/setup-dhcp-tftp.sh` | Path B: dnsmasq ProxyDHCP + TFTP for real hardware. |

---

## Prerequisites

```bash
# Phase 2 (QEMU) + Phase 4 (rootless podman) + the iPXE build (Docker):
sudo apt-get install -y qemu-system-x86 qemu-utils podman docker.io jq yq curl
# (Rocky/Fedora host: dnf install qemu-kvm qemu-img podman moby-engine jq ...)
```

The iPXE build runs inside Docker so your host stays clean. The artifact server
runs **rootless** under podman. Only the optional Path-B dnsmasq step needs root.

---

## Path A — QEMU zero-touch (recommended first run)

Run all commands from the repo root (`/media/sqs/COLD_STORAGE/LAB_CREATE_V2`).
Replace `/home/sqs` in `rocky-pxe-lab.toml` with your `$HOME` first (TOML has no
shell expansion).

### 1. Fetch + verify the Rocky installer kernel and initrd

```bash
examples/rocky-pxe-lab/fetch-rocky-installer.sh --release 9 --arch x86_64
# → ~/netboot/vmlinuz   (~15 MB)
# → ~/netboot/initrd.img (~210 MB)
# Both verified against the sha256 entries in the tree's .treeinfo.
```

### 2. Render the per-host kickstart

The VM's NIC MAC is pinned to `52:54:00:cc:09:09` in the TOML, so iPXE will ask
for `/ks/52-54-00-cc-09-09.ks`. Generate exactly that file from the template:

```bash
netboot/gen-almalinux-ks.sh \
    --mac 52:54:00:cc:09:09 \
    --template examples/rocky-pxe-lab/rocky9-zerotouch.ks
# → ~/netboot/ks/52-54-00-cc-09-09.ks
```

> `gen-almalinux-ks.sh` is just a generic "copy template → `ks/<mac:hexhyp>.ks`"
> helper — the AlmaLinux name is historical; `--template` makes it distro-neutral.

### 3. Build the iPXE ROM with Rocky boot params

```bash
netboot/build-ipxe.sh \
    --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.stage2=http://10.0.2.2:8181/ inst.repo=https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'
# → ~/netboot/boot.ipxe (the script this lab boots), ipxe.pxe (BIOS NBP for real HW),
#   ipxe.efi (UEFI), ipxe.qcow2
```

- `10.0.2.2` is the host as seen from inside a QEMU slirp guest.
- `8181` is the host port the nginx container publishes (step 4).
- `{MAC}` is a **literal placeholder**: `build-ipxe.sh` rewrites it to iPXE's
  runtime `${mac:hexhyp}`, so each booting NIC fetches its own kickstart.
- `inst.stage2=` points Anaconda at the **local** `install.img` (served by this
  nginx at `/images/install.img`), so the ~1 GB stage2 doesn't stream from a
  remote mirror — that large transfer truncates over QEMU slirp and fails the
  install at dracut. `inst.repo=` is the base package repo (still the upstream
  mirror); the kickstart's own `url`/`repo` lines refine the package sources.

### 4. Start the rootless nginx artifact server (Phase 4)

```bash
phase4-podman/lab-podman.sh up --config examples/rocky-pxe-lab/rocky-pxe-lab.toml
curl -sI http://localhost:8181/vmlinuz | head -1     # → HTTP/1.1 200 OK
curl -sI http://localhost:8181/ks/52-54-00-cc-09-09.ks | head -1
```

### 5. Create + start the installer VM (Phase 2)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/rocky-pxe-lab/rocky-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start  rocky-pxe-install     # walk away (~10–15 min)
phase2-qemu-vm/lab-vm.sh console rocky-pxe-install     # optional: watch Anaconda
```

Watch the boot-loop do its thing (`pxe-install`, BIOS):

1. **First boot:** SeaBIOS tries the blank target disk (`vda`, bootindex 0),
   finds no boot sector, and falls to the NIC's option ROM → which on QEMU *is*
   iPXE → it DHCPs and TFTP-fetches `boot.ipxe`, then (the file starts with
   `#!ipxe`) runs it directly → fetches `vmlinuz`/`initrd.img` over HTTP →
   Anaconda runs the kickstart and installs to `vda`; the final `reboot` ends it.
2. **Second boot:** `vda` is now bootable and (being bootindex 0) is tried first;
   the NIC PXE ROM is never reached again. You land at a Rocky login.

> **Why `boot.ipxe`, not the `ipxe.pxe` binary?** QEMU's NIC ROM is already iPXE,
> so handing it the script avoids chainloading a *second* iPXE that re-inits the
> NIC over UNDI and DHCPs again — the flaky step that otherwise drops to
> "No bootable device". Real hardware with a non-iPXE firmware PXE: set
> `pxe_bootfile = "ipxe.pxe"` to chainload the binary (which embeds the same
> script) first.

> **UEFI?** Set `pxe_bootfile = "ipxe.efi"` and drop `firmware` in the TOML.

```bash
phase2-qemu-vm/lab-vm.sh ssh rocky-pxe-install          # login: lab / lab
```

### 6. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab rocky-pxe
phase2-qemu-vm/lab-vm.sh    destroy rocky-pxe-install --force
```

---

## Path B — real hardware (faithful to the CIQ article)

For a physical target on your LAN, QEMU's built-in DHCP/TFTP isn't in the
picture — you need a real PXE responder. The CIQ guide uses `dnsmasq` for
DHCP+TFTP and serves the installer over HTTP. This lab does the same via the
shared `netboot/setup-dhcp-tftp.sh` (ProxyDHCP mode, so it coexists with your
existing router's DHCP instead of fighting it).

Steps 1–4 from Path A are unchanged **except** you rebuild iPXE pointing at this
host's real LAN IP instead of `10.0.2.2`:

```bash
# (step 1: fetch installer — same as Path A)
examples/rocky-pxe-lab/fetch-rocky-installer.sh --release 9 --arch x86_64

# (step 2: kickstart — name it for the TARGET machine's real NIC MAC)
netboot/gen-almalinux-ks.sh --mac AA:BB:CC:DD:EE:FF \
    --template examples/rocky-pxe-lab/rocky9-zerotouch.ks
# Generate ks/default.ks too (fallback for un-enumerated MACs) with --default,
# but understand the risk: ANY machine that PXE-boots will then install itself.

# (step 3: iPXE with your LAN IP, e.g. 192.168.1.10)
netboot/build-ipxe.sh \
    --server http://192.168.1.10:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.repo=https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/ inst.ks=http://192.168.1.10:8181/ks/{MAC}.ks inst.text ip=dhcp'

# (step 4: serve — bind nginx on the LAN, not loopback)
#   Edit rocky-pxe-lab.toml's [[service]] ports to "8181:80" on 0.0.0.0
#   (podman publishes on all interfaces by default), then:
phase4-podman/lab-podman.sh up --config examples/rocky-pxe-lab/rocky-pxe-lab.toml
```

Then stand up the DHCP/TFTP responder (this is the CIQ `dnsmasq` step):

```bash
netboot/setup-dhcp-tftp.sh \
    --dir ~/netboot \
    --server-ip 192.168.1.10 \
    --iface eth0 \
    --bootfile ipxe.efi          # UEFI clients; use ipxe.usb-derived BIOS path for legacy
# It writes a dnsmasq.conf (ProxyDHCP + TFTP) and prints the podman/docker
# command to launch dnsmasq.  ProxyDHCP = your router still hands out IPs;
# dnsmasq only adds DHCP options 66 (TFTP server) + 67 (bootfile) for PXE.
```

PXE-boot the physical machine (enable network boot in its firmware). It will:
DHCP → get the TFTP pointer from dnsmasq → pull `ipxe.efi` over TFTP → iPXE
chainloads → fetches `vmlinuz`/`initrd.img`/kickstart over HTTP → Anaconda
installs. Same boot flow as Path A, just with a real NIC and a real PXE server.

> **CIQ vs. this lab.** The CIQ article boots the installer kernel directly from
> a UEFI **grub** menu on TFTP (`grubx64.efi` + `grub.cfg`) and builds the images
> with `lorax`. This lab instead chainloads **iPXE** (which then pulls everything
> over HTTP), and downloads the ready-made `vmlinuz`/`initrd.img` Rocky already
> publishes in `images/pxeboot/` — no `lorax` build host required. Both end at
> the same Anaconda+kickstart install; iPXE-over-HTTP is simply faster to serve
> and easier to template per-host. If you specifically want the grub-on-TFTP
> layout from the article, `setup-dhcp-tftp.sh --bootfile grubx64.efi` plus a
> `grub.cfg` pointing `linuxefi`/`initrdefi` at your HTTP server reproduces it.

---

## Security posture (read before exposing anything)

- **Plaintext lab credentials.** `rocky9-zerotouch.ks` sets `root:lab` and a
  `lab:lab` sudo user in cleartext. Anyone who can fetch the kickstart can read
  them. **Never** serve this on an untrusted network. For real use, switch
  `--plaintext` to `--iscrypted <sha512-hash>` and restrict nginx to loopback or
  a private VLAN. (Same posture as the rest of mklab — these are throwaway labs.)
- **Path A binds nginx to the host;** for QEMU-only use, it's only reachable via
  the slirp `10.0.2.2` mapping. Path B deliberately widens it to the LAN — only
  do that on a trusted segment.
- **`ks/default.ks` auto-installs unknown machines.** Only create it
  (`gen-almalinux-ks.sh --default`) when you genuinely want any PXE-booting box
  on the segment to wipe and install itself.

---

## Why these specific choices (the "under the hood" notes)

- **Why `.treeinfo`, not a `CHECKSUM` file?** AlmaLinux ships a `CHECKSUM` inside
  `images/pxeboot/`; Rocky does **not** (404). Rocky's canonical integrity source
  for the boot images is the productmd `.treeinfo` at the BaseOS `os/` root, whose
  `[checksums]` section carries `sha256:` for `images/pxeboot/{vmlinuz,initrd.img}`.
  Those hashes change every point release (Rocky 9 → 9.x), so the fetch script
  pulls `.treeinfo` live and parses it rather than pinning a hash that would rot.
- **Why `pxe-install` (NIC PXE) instead of a two-disk iPXE-ROM disk?** SeaBIOS
  only attempts the first hard disk, and x86_64 disk-image VMs default to OVMF
  (which can't boot a BIOS-MBR disk) — so the older two-disk boot-loop doesn't
  boot in QEMU.  Instead the NIC's option ROM — which on QEMU is itself iPXE —
  TFTP-fetches and runs `boot.ipxe` directly (real hardware whose firmware PXE is
  not iPXE chainloads the `ipxe.pxe`/`ipxe.efi` binary first).  The single install
  target carries `bootindex=0`:
  blank on first boot → SeaBIOS falls to the NIC ROM → installs → on the next
  boot the disk wins → true zero-touch, no manual disk swap.
- **Why iPXE instead of plain PXELINUX/grub?** iPXE speaks HTTP, so the installer
  kernel/initrd and the per-host kickstart all come over HTTP from one rootless
  nginx — no large files on TFTP, and `${mac:hexhyp}` lets one boot program serve
  every host its own kickstart. TFTP only ever carries the small iPXE NBP.
- **Why `ignoredisk --only-use=vda` in the kickstart?** The VM's only disk is the
  virtio target `/dev/vda`; pinning the install there keeps Anaconda fully
  unattended (no disk prompt) and lands GRUB on the disk SeaBIOS boots next.
