# Kali Linux — self-contained zero-touch PXE install lab

Boot a blank VM (or a real machine) over the network and have it install
**Kali Linux** with **no keystrokes** — PXE → iPXE → the **Debian installer**
(d-i) → preseed → reboot into the installed system.

This is the Debian-family cousin of the Rocky/AlmaLinux PXE labs. Those drive
**Anaconda** with a **kickstart**; Kali is Debian-based, so it drives the
**Debian installer** with a **preseed**. The surrounding machinery — iPXE,
rootless nginx, QEMU `pxe-install` netboot — is identical.

Reference: [Kali docs — *Network PXE Install*](https://www.kali.org/docs/installation/network-pxe/).
This lab implements **two** paths:

| Path | Use case | DHCP/TFTP source | iPXE delivery |
|---|---|---|---|
| **A — QEMU (default)** | a throwaway VM on your workstation | QEMU's built-in slirp | NIC's iPXE ROM → TFTP `boot.ipxe` (runs it directly) |
| **B — real hardware** | a physical machine on your LAN | `dnsmasq` DHCP + TFTP | PXELINUX from `netboot.tar.gz` (Kali-docs style) |

Path A is the fastest way to see it work with zero LAN setup. Path B is the
literal procedure from the Kali documentation.

---

## What's in this directory

| File | Role |
|---|---|
| `fetch-kali-installer.sh` | Download + verify Kali's d-i `linux`/`initrd.gz` (checksums from `SHA256SUMS`). |
| `kali-preseed.cfg` | The Debian-installer preseed driving the unattended install (**plaintext lab creds**). |
| `kali-pxe-lab.toml` | Unified config: Phase 4 nginx artifact server + Phase 2 installer VM. |
| `README.md` | This file. |

Reused unchanged from the shared `netboot/` tooling — nothing duplicated:

| Shared tool | What this lab uses it for |
|---|---|
| `netboot/build-ipxe.sh` | Build the iPXE ROM with the d-i boot params embedded. |
| `netboot/setup-dhcp-tftp.sh` | Path B: dnsmasq DHCP + TFTP for real hardware. |

> Note: unlike the Rocky/Alma labs, Kali does **not** use the per-MAC kickstart
> renderer (`gen-almalinux-ks.sh`). The Kali docs use a single `preseed.cfg`, so
> this lab serves one `kali-preseed.cfg` at a fixed URL. To go per-host, put a
> `{MAC}` token in the `preseed/url=` and name the file after `${mac:hexhyp}` —
> same trick the AlmaLinux lab uses.

---

## Prerequisites

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils podman docker.io jq curl
# (Rocky/Fedora host: dnf install qemu-kvm qemu-img podman moby-engine jq ...)
```

The iPXE build runs in Docker (host stays clean); the artifact server runs
rootless under podman. Only the optional Path-B dnsmasq step needs root.

---

## Path A — QEMU zero-touch (recommended first run)

Run from the repo root. Replace `/home/sqs` in `kali-pxe-lab.toml` with your
`$HOME` first (TOML has no shell expansion).

### 1. Fetch + verify the Kali installer kernel and initrd

```bash
examples/kali-pxe-lab/fetch-kali-installer.sh --arch amd64
# → ~/netboot/kali/linux      (~14 MB, the d-i kernel)
# → ~/netboot/kali/initrd.gz  (~44 MB, the d-i initrd)
# Both verified against the tree's SHA256SUMS.
```

> These land in `~/netboot/kali/` (not `~/netboot/` directly) so their `linux`
> / `initrd.gz` never collide with the AlmaLinux/Rocky `vmlinuz` / `initrd.img`
> that those labs drop in `~/netboot/`. nginx serves all of `~/netboot/`, so
> they're reachable at `/kali/linux` etc.

### 2. Stage the preseed into the served directory

```bash
cp examples/kali-pxe-lab/kali-preseed.cfg ~/netboot/kali/
```

### 3. Build the iPXE boot programs with the d-i boot params

```bash
netboot/build-ipxe.sh \
    --server http://10.0.2.2:8181 \
    --kernel-path /kali/linux --initrd-path /kali/initrd.gz \
    --append 'auto=true priority=critical preseed/url=http://10.0.2.2:8181/kali/kali-preseed.cfg DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---'
# → ~/netboot/boot.ipxe (the script this lab boots, via slirp TFTP),
#   ~/netboot/ipxe.pxe (BIOS NBP for real HW), ~/netboot/ipxe.efi (UEFI),
#   ~/netboot/ipxe.qcow2 (legacy disk image)
```

- `10.0.2.2` is the host as seen from inside a QEMU slirp guest; `8181` is the
  port nginx publishes (step 4).
- `auto=true priority=critical` makes d-i fully unattended — it answers every
  prompt from the preseed instead of asking.
- The trailing **`---`** is the d-i convention: args after it are passed to the
  **installed** kernel (so `console=ttyS0` also reaches the booted system; the
  preseed reinforces this via `add-kernel-opts`).

### 4. Start the rootless nginx artifact server (Phase 4)

```bash
phase4-podman/lab-podman.sh up --config examples/kali-pxe-lab/kali-pxe-lab.toml

# Verify all three artifacts are actually served (the #1 failure point):
curl -sI http://localhost:8181/kali/linux                 | head -1   # 200
curl -sI http://localhost:8181/kali/initrd.gz             | head -1   # 200
curl -sI http://localhost:8181/kali/kali-preseed.cfg      | head -1   # 200
```

A `404` means the file isn't under `~/netboot/kali/` (or the TOML volume still
says `/home/sqs`). A `403` on SELinux means the `:Z` relabel didn't happen —
`lab-podman.sh` adds it automatically.

### 5. Create + start the installer VM (Phase 2)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/kali-pxe-lab/kali-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start  kali-pxe-install
phase2-qemu-vm/lab-vm.sh console kali-pxe-install     # watch; Ctrl-] to detach
```

What you'll see (the boot-loop in motion — `pxe-install`, BIOS):

1. **First boot:** SeaBIOS tries the blank target disk (`vda`, bootindex 0),
   finds no boot sector, and falls to the NIC's option ROM → which on QEMU *is*
   iPXE → it DHCPs and TFTP-fetches `boot.ipxe`, then runs it directly (the file
   starts with `#!ipxe`) → fetches `linux`/`initrd.gz` over HTTP and the Debian
   installer starts with the preseed.
2. **d-i runs the preseed** — partitions `vda`, debootstraps Kali from
   `http.kali.org`, installs GRUB to `vda`, then reboots.
3. **Second boot:** `vda` is now bootable and (being bootindex 0) is tried first;
   the NIC PXE ROM is never reached again. You land at a Kali login.

> **UEFI?** Set `pxe_bootfile = "ipxe.efi"` and drop `firmware` in the TOML —
> OVMF PXE-boots the EFI iPXE instead (`build-ipxe.sh` builds both). Same install.

```bash
phase2-qemu-vm/lab-vm.sh ssh kali-pxe-install          # login: kali / kali  (root / lab also works)
```

A minimal install (the default in `kali-preseed.cfg`) finishes in roughly
10–20 minutes depending on mirror bandwidth. See **Package selection** below to
install a real Kali toolset instead.

### 6. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab kali-pxe
phase2-qemu-vm/lab-vm.sh    destroy kali-pxe-install --force
```

---

## Path B — real hardware (faithful to the Kali docs)

The Kali network-PXE docs use **dnsmasq** for DHCP+TFTP and serve **PXELINUX**
from the official **`netboot.tar.gz`**. For a physical target on your LAN:

```bash
# 1. Pull and unpack the Kali netboot tarball into a TFTP root (the docs' step):
sudo mkdir -p /tftpboot
sudo wget https://http.kali.org/kali/dists/kali-rolling/main/installer-amd64/current/images/netboot/netboot.tar.gz \
    -P /tftpboot/
sudo tar -zxpvf /tftpboot/netboot.tar.gz -C /tftpboot
sudo rm -v /tftpboot/netboot.tar.gz
# → /tftpboot/pxelinux.0, /tftpboot/debian-installer/amd64/{linux,initrd.gz}, etc.

# 2. Point PXELINUX at your preseed.  Edit the append line in
#    /tftpboot/debian-installer/amd64/boot-screens/txt.cfg (or pxelinux.cfg/default)
#    for the "Automated install" label to add:
#       auto=true priority=critical preseed/url=http://<server-ip>/kali-preseed.cfg
#    and host kali-preseed.cfg on any HTTP server reachable by the target.
#    (Or embed it into the initrd exactly as the Kali docs show:
#       cd /tftpboot/debian-installer/amd64
#       sudo gunzip initrd.gz
#       echo preseed.cfg | sudo cpio -H newc -o -A -F initrd
#       sudo gzip initrd )

# 3. Stand up dnsmasq DHCP+TFTP.  The Kali docs write /etc/dnsmasq.conf with
#    dhcp-boot=pxelinux.0 + enable-tftp + tftp-root=/tftpboot.  The shared
#    helper does the ProxyDHCP variant (coexists with your router's DHCP):
netboot/setup-dhcp-tftp.sh \
    --dir /tftpboot \
    --server-ip 192.168.1.10 \
    --iface eth0 \
    --bootfile pxelinux.0
```

PXE-boot the physical machine; it pulls `pxelinux.0` over TFTP, loads the d-i
kernel/initrd, fetches the preseed, and installs unattended.

> **iPXE vs. PXELINUX.** Path A chainloads **iPXE**, which pulls everything over
> HTTP (kernel, initrd, preseed) — faster to serve and trivial to template. The
> Kali docs use **PXELINUX** over TFTP, which is simpler to reason about on bare
> metal and needs no iPXE build. Both end at the same d-i + preseed install. If
> you prefer iPXE on real hardware, run `setup-dhcp-tftp.sh --bootfile ipxe.efi`
> (serving the iPXE binary you built in Path A step 3) and skip the tarball.
>
> **UEFI vs BIOS.** `pxelinux.0` is the BIOS loader. For UEFI clients the Kali
> netboot tree also ships `bootnetx64.efi`/`grubnetx64.efi`; set
> `--bootfile bootnetx64.efi` and use the grub menu the tarball provides.

---

## Package selection — minimal vs. the real Kali toolset

`kali-preseed.cfg` installs a **lean** system by default (standard + SSH) so the
lab finishes quickly. To get an actual Kali toolset, edit the `pkgsel/include`
line in the preseed before step 2:

| Metapackage | What you get | Cost |
|---|---|---|
| *(default: standard + openssh-server)* | a minimal Kali base you can `apt install` into | fastest, ~1–2 GB |
| `kali-linux-headless` | the CLI tool collection, no desktop | large, much longer |
| `kali-linux-default` | the classic Kali toolset **+ XFCE desktop** | very large, longest |

Heavier metapackages pull GBs over the network — expect the install to take
proportionally longer than the minimal default.

---

## Security posture (read before exposing anything)

- **Plaintext lab credentials.** `kali-preseed.cfg` sets `root:lab` and a
  `kali:kali` sudo user in cleartext. Anyone who can fetch the preseed reads
  them. **Never** serve this on an untrusted network. For real use, switch to
  the `*-password-crypted` preseed keys (`mkpasswd -m sha-512`), restrict nginx
  to loopback or a private VLAN, and rotate after first boot.
- **Path A binds nginx to the host;** for QEMU-only use it's reachable only via
  the slirp `10.0.2.2` mapping. Path B widens it to the LAN — trusted segments
  only.
- **Kali is an offensive-security distro.** A `kali-linux-default` install ships
  hundreds of tools. Keep these VMs off networks you don't own.

---

## Why these specific choices (the "under the hood" notes)

- **Why a preseed, not a kickstart?** Kali is Debian-based, so its installer is
  the **Debian installer (d-i)**, configured by a **preseed** file (`d-i …`
  directives). Rocky/AlmaLinux are RHEL-based and use **Anaconda** +
  **kickstart**. Different installer families, same goal — this lab is the d-i
  half of the pair. Everything around the installer (iPXE, nginx, boot-loop) is
  reused verbatim.
- **Why `SHA256SUMS` (two-column), not `.treeinfo`?** Debian/Kali publish a flat
  `SHA256SUMS` in the installer images tree — standard `sha256sum -c` format,
  even simpler than Rocky's productmd `.treeinfo`. We fetch it over HTTPS and
  verify both boot files against it. (Kali ships no detached `.sign` at that
  path, so HTTPS is the trust boundary for the images — same posture as the
  other labs. apt inside d-i still GPG-verifies every *package* against Kali's
  archive key, which is baked into the netboot initrd.)
- **Why `~/netboot/kali/` instead of `~/netboot/`?** So Kali's `linux`/
  `initrd.gz` don't overwrite the Rocky/Alma `vmlinuz`/`initrd.img` if you run
  more than one PXE lab against the same served directory.
- **Why pin partman + grub to `/dev/vda`?** The VM's only disk is the virtio
  target, `/dev/vda`. `partman-auto/disk` + `grub-installer/bootdev` pin the
  install there so it's fully unattended (no disk prompt) and GRUB lands on the
  disk SeaBIOS boots next (the d-i equivalent of `ignoredisk --only-use=vda`).
  iPXE arrives over the network (the NIC PXE ROM), not a disk, so there's no
  second disk to protect.
- **Why `pxe-install` (NIC runs `boot.ipxe`), not a two-disk iPXE-ROM disk?**
  SeaBIOS only attempts the first hard disk, and x86_64 disk-image VMs default to
  OVMF (which can't boot a BIOS-MBR disk), so the old two-disk trick doesn't boot
  in QEMU. QEMU's NIC option ROM *is* iPXE, so it TFTP-fetches and runs `boot.ipxe`
  directly — no second iPXE binary, no UNDI re-DHCP (the flaky "No bootable device"
  step). Real hardware whose firmware PXE is not iPXE: chainload the `ipxe.pxe`
  (BIOS) / `ipxe.efi` (UEFI) binary first.
- **Why the trailing `---` in the kernel append?** It's the d-i marker dividing
  *installer* kernel args from *installed-system* kernel args; putting
  `console=ttyS0,115200n8` after it carries the serial console into the booted
  Kali so `lab-vm.sh console` keeps working post-install.
