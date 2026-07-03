# Debian 13 "trixie" — self-contained zero-touch PXE install lab

Boot a blank VM (or a real machine) over the network and have it install
**Debian 13 (trixie)** with **no keystrokes** — PXE → iPXE → the **Debian
installer** (d-i) → preseed → reboot into the installed system.

This is the **upstream** of the Debian-installer family in this repo. The
[Kali PXE lab](../kali-pxe-lab/) runs the *same* machinery pointed at the Kali
mirror; both are the d-i cousins of the Rocky/AlmaLinux labs, which drive
**Anaconda** with a **kickstart**. Debian drives the **Debian installer** with a
**preseed** (`d-i …` directives). The surrounding machinery — iPXE, rootless
nginx, QEMU `pxe-install` netboot — is identical.

Reference: the official **[`example-preseed.txt`](upstream-preseed/README.md)**
(vendored byte-exact) + the *Debian Installation Guide* [Appendix B](https://www.debian.org/releases/trixie/amd64/apb.en.html), as-of **2026-07-03**.

This lab implements **two** paths:

| Path | Use case | DHCP/TFTP source | iPXE delivery |
|---|---|---|---|
| **A — QEMU (default)** | a throwaway VM on your workstation | QEMU's built-in slirp | NIC's iPXE ROM → TFTP `boot.ipxe` (runs it directly) |
| **B — real hardware** | a physical machine on your LAN | `dnsmasq` DHCP + TFTP | pxelinux/GRUB from `netboot.tar.gz` |

Path A is the fastest way to see it work with zero LAN setup. Path B is the
literal netboot-tarball procedure.

---

## What's in this directory

| File | Role |
|---|---|
| `fetch-debian-installer.sh` | Download + verify trixie's d-i `linux`/`initrd.gz` (checksums from `SHA256SUMS`; optional `--verify-sig` GPG check). |
| `debian-preseed.cfg` | The Debian-installer preseed driving the unattended install (**plaintext lab creds**), distilled from the official example. |
| `debian-pxe-lab.toml` | Unified config: Phase 4 nginx artifact server + Phase 2 installer VM. |
| [`upstream-preseed/`](upstream-preseed/README.md) | Byte-exact vendored official `example-preseed.txt` + provenance. |
| `MANUAL_TESTING.md` | End-to-end runbook for the full ~10–20 min install, with the real captured transcript. |
| `ADDING-PACKAGES.md` | How to add packages / a desktop to the installed system. |
| `README.md` | This file. |

Reused unchanged from the shared `netboot/` tooling — nothing duplicated:

| Shared tool | What this lab uses it for |
|---|---|
| `netboot/build-ipxe.sh` | Build the iPXE ROM with the d-i boot params embedded. |
| `netboot/setup-dhcp-tftp.sh` | Path B: dnsmasq DHCP + TFTP for real hardware. |

> **Want lvm / crypto / a separate `/home`?** This lab installs the simplest
> layout (`regular` + `atomic` — one root partition). The companion
> [`debian-preseed-gallery/`](../debian-preseed-gallery/) generates a **gallery
> of variants** (regular-atomic / regular-home / regular-multi / lvm / crypto /
> minimal) from this same official example and lets you boot any one.

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

Run from the repo root. Replace `/home/sqs` in `debian-pxe-lab.toml` with your
`$HOME` first (TOML has no shell expansion).

### 1. Fetch + verify the installer kernel and initrd

```bash
examples/debian-pxe-lab/fetch-debian-installer.sh --arch amd64
# → ~/netboot/debian/linux      (~12 MB, the d-i kernel)
# → ~/netboot/debian/initrd.gz  (~39 MB, the d-i initrd)
# Both verified against the tree's SHA256SUMS.  Add --verify-sig for the GPG check.
```

> These land in `~/netboot/debian/` (not `~/netboot/` directly) so their `linux`
> / `initrd.gz` never collide with the Kali `~/netboot/kali/` or the
> AlmaLinux/Rocky `vmlinuz` / `initrd.img` in `~/netboot/`. nginx serves all of
> `~/netboot/`, so they're reachable at `/debian/linux` etc.

### 2. Stage the preseed into the served directory

```bash
cp examples/debian-pxe-lab/debian-preseed.cfg ~/netboot/debian/
```

### 3. Build the iPXE boot programs with the d-i boot params

```bash
netboot/build-ipxe.sh \
    --server http://10.0.2.2:8181 \
    --kernel-path /debian/linux --initrd-path /debian/initrd.gz \
    --append 'auto=true priority=critical preseed/url=http://10.0.2.2:8181/debian/debian-preseed.cfg DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---'
# → ~/netboot/boot.ipxe (the script this lab boots, via slirp TFTP),
#   ~/netboot/ipxe.pxe (BIOS NBP for real HW), ~/netboot/ipxe.efi (UEFI)
```

- `10.0.2.2` is the host as seen from inside a QEMU slirp guest; `8181` is the
  port nginx publishes (step 4).
- `auto=true priority=critical` makes d-i fully unattended — it answers every
  prompt from the preseed instead of asking.
- The trailing **`---`** is the d-i convention: args after it are passed to the
  **installed** kernel (so `console=ttyS0` also reaches the booted system; the
  preseed reinforces this via `add-kernel-opts`).

> **Sharing `~/netboot/` with the Kali/Rocky/Alma labs?** `build-ipxe.sh` always
> writes `boot.ipxe`, so run one lab at a time (or `cp ~/netboot/boot.ipxe
> ~/netboot/boot-debian.ipxe` and set `pxe_bootfile = "boot-debian.ipxe"` in the
> TOML to keep several around — the sibling labs keep `boot-kali.ipxe` etc. this
> way).

### 4. Start the rootless nginx artifact server (Phase 4)

```bash
phase4-podman/lab-podman.sh up --config examples/debian-pxe-lab/debian-pxe-lab.toml

# Verify all three artifacts are actually served (the #1 failure point):
curl -sI http://localhost:8181/debian/linux               | head -1   # 200
curl -sI http://localhost:8181/debian/initrd.gz           | head -1   # 200
curl -sI http://localhost:8181/debian/debian-preseed.cfg  | head -1   # 200
```

A `404` means the file isn't under `~/netboot/debian/` (or the TOML volume still
says `/home/sqs`). A `403` on SELinux means the `:Z` relabel didn't happen —
`lab-podman.sh` adds it automatically.

### 5. Create + start the installer VM (Phase 2)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/debian-pxe-lab/debian-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start  debian-pxe-install
phase2-qemu-vm/lab-vm.sh console debian-pxe-install     # watch; Ctrl-] to detach
```

What you'll see (the boot in motion — `pxe-install`, BIOS):

1. **First boot:** SeaBIOS tries the blank target disk (`vda`, bootindex 0),
   finds no boot sector, and falls to the NIC's option ROM → which on QEMU *is*
   iPXE → it DHCPs and TFTP-fetches `boot.ipxe`, then runs it directly (the file
   starts with `#!ipxe`) → fetches `linux`/`initrd.gz` over HTTP and the Debian
   installer starts with the preseed.
2. **d-i runs the preseed** — partitions `vda`, debootstraps trixie from
   `deb.debian.org`, installs GRUB to `vda`, then reboots.
3. **Second boot:** `vda` is now bootable and (being bootindex 0) is tried first;
   the NIC PXE ROM is never reached again. You land at a Debian login.

```bash
phase2-qemu-vm/lab-vm.sh ssh debian-pxe-install          # login: debian / debian  (root / lab also works)
```

The lean default install finishes in roughly **10–20 minutes** depending on
mirror bandwidth. See **Package selection** below (and `ADDING-PACKAGES.md`) to
install a desktop or more tooling.

### 6. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab debian-pxe
phase2-qemu-vm/lab-vm.sh    destroy debian-pxe-install --force
```

---

## Path B — real hardware (netboot tarball)

The official Debian netboot uses **pxelinux** (BIOS) / **GRUB** (UEFI) served
from the **`netboot.tar.gz`** over dnsmasq DHCP+TFTP. For a physical target:

```bash
# 1. Pull and unpack the Debian netboot tarball into a TFTP root:
sudo mkdir -p /tftpboot
sudo wget https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/netboot.tar.gz \
    -P /tftpboot/
sudo tar -zxpvf /tftpboot/netboot.tar.gz -C /tftpboot
sudo rm -v /tftpboot/netboot.tar.gz
# → /tftpboot/pxelinux.0, /tftpboot/debian-installer/amd64/{linux,initrd.gz}, etc.

# 2. Point the installer at your preseed.  Add to the "Automated install" append
#    line in /tftpboot/debian-installer/amd64/boot-screens/txt.cfg (BIOS) or the
#    grub.cfg the tarball ships (UEFI):
#       auto=true priority=critical preseed/url=http://<server-ip>/debian-preseed.cfg
#    and host debian-preseed.cfg on any HTTP server reachable by the target.

# 3. Stand up dnsmasq DHCP+TFTP.  The shared helper does the ProxyDHCP variant
#    (coexists with your router's DHCP):
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
> netboot tarball uses **PXELINUX/GRUB** over TFTP, simpler on bare metal and
> needs no iPXE build. Both end at the same d-i + preseed install. For UEFI
> clients the tree ships `bootnetx64.efi`/`grubx64.efi`; set
> `--bootfile bootnetx64.efi`.

---

## Package selection — lean vs. a desktop

`debian-preseed.cfg` installs a **lean** system by default (`standard` +
`ssh-server` tasks + `openssh-server sudo curl`) so the lab finishes quickly. To
get a desktop, add a task to the `tasksel/first` line before step 2:

| `tasksel/first` value | What you get | Cost |
|---|---|---|
| *(default: `standard, ssh-server`)* | a minimal Debian base you can `apt install` into | fastest, ~1–2 GB |
| `standard, ssh-server, gnome-desktop` | GNOME desktop | large, much longer |
| `standard, ssh-server, xfce-desktop` | lighter XFCE desktop | medium |

See `ADDING-PACKAGES.md` for the full add→apply→verify flow.

---

## Security posture (read before exposing anything)

- **Plaintext lab credentials.** `debian-preseed.cfg` sets `root:lab` and a
  `debian:debian` sudo user in cleartext. Anyone who can fetch the preseed reads
  them. **Never** serve this on an untrusted network. For real use, switch to
  the `*-password-crypted` preseed keys (`mkpasswd -m sha-512`), restrict nginx
  to loopback or a private VLAN, and rotate after first boot.
- **Path A binds nginx to the host;** for QEMU-only use it's reachable only via
  the slirp `10.0.2.2` mapping. Path B widens it to the LAN — trusted segments
  only.

---

## Why these specific choices (the "under the hood" notes)

- **Why a preseed, not a kickstart?** Debian's installer is the **Debian
  installer (d-i)**, configured by a **preseed** file. Rocky/AlmaLinux are
  RHEL-based and use **Anaconda** + **kickstart**. Different installer families,
  same goal — this is the *upstream* d-i lab; Kali is the same d-i machinery on
  a different mirror.
- **Why distill the official example instead of writing from scratch?** Debian's
  `example-preseed.txt` is the canonical, authoritative reference (generated
  from the `installer-team/preseed` source package). Our `debian-preseed.cfg`
  un-comments *its* documented choices and adds only the values an unattended
  lab needs — so every directive traces back to upstream. The byte-exact
  original is vendored under [`upstream-preseed/`](upstream-preseed/README.md).
- **Why `SHA256SUMS` (two-column), not `.treeinfo`?** Debian publishes a flat
  `SHA256SUMS` in the installer images tree — standard `sha256sum -c` format. We
  fetch it over HTTPS and verify both boot files against it. Unlike Kali, Debian
  also ships a detached **`SHA256SUMS.sign`**; `--verify-sig` checks it with
  `gpgv` against the Debian signing key for a full GPG chain.
- **Why `~/netboot/debian/` instead of `~/netboot/`?** So Debian's `linux`/
  `initrd.gz` don't overwrite the Kali/Rocky/Alma boot files if you run more
  than one PXE lab against the same served directory.
- **Why pin partman + grub to `/dev/vda`?** The VM's only disk is the virtio
  target, `/dev/vda`. `partman-auto/disk` + `grub-installer/bootdev` pin the
  install there so it's fully unattended (no disk prompt) and GRUB lands on the
  disk SeaBIOS boots next (the d-i equivalent of `ignoredisk --only-use=vda`).
- **Why the trailing `---` in the kernel append?** It's the d-i marker dividing
  *installer* kernel args from *installed-system* kernel args; putting
  `console=ttyS0,115200n8` after it carries the serial console into the booted
  Debian so `lab-vm.sh console` keeps working post-install.
