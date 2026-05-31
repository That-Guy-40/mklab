# AlmaLinux — self-contained zero-touch PXE install lab

Boot a brand-new VM (or a real machine) over the network and have it install
**AlmaLinux 9** with **no keystrokes** — PXE → iPXE → Anaconda → kickstart →
reboot into the installed system.

This is the twin of the Rocky Linux PXE lab (`examples/rocky-pxe-lab/`). Both are
RHEL-family rebuilds, so the Anaconda/kickstart machinery is identical; only the
installer-fetch step and the mirror URLs differ.

This lab implements **two** paths:

| Path | Use case | DHCP/TFTP source | iPXE delivery |
|---|---|---|---|
| **A — QEMU (default)** | a throwaway VM on your workstation | QEMU's built-in slirp | NIC's iPXE ROM → TFTP `boot.ipxe` (runs it directly) |
| **B — real hardware** | a physical machine on your LAN | `dnsmasq` ProxyDHCP + TFTP | NIC PXE → chainload `ipxe.pxe`/`ipxe.efi` |

Path A is the fastest way to *see it work* with zero LAN setup. Path B is a real
PXE server for physical targets.

---

## What's in this directory

| File | Role |
|---|---|
| `fetch-almalinux-installer.sh` | Download + verify Alma's `vmlinuz`/`initrd.img`/`install.img` (checksums from `.treeinfo`). |
| `almalinux-zerotouch.ks` | The kickstart that drives the unattended install (**plaintext lab creds**); also the `gen-almalinux-ks.sh` default template. |
| `almalinux-pxe-lab.toml` | Unified config: Phase 4 nginx artifact server + Phase 2 installer VM. |
| `nginx-ks-fallback.conf` | Optional nginx `server{}` snippet that serves `ks/default.ks` to any un-enumerated MAC (Path B; ⚠️ auto-installs unknown machines — see Security). |
| `QUICKSTART.md` | Copy-paste runbook for this lab (AlmaLinux only). |
| `MANUAL_TESTING.md` | The full ~install walkthrough + boot-chain checks. |
| `ALMALINUX_PXE_LAB_PLAN.md` | The original design/plan doc (history). |
| `README.md` | This file. |

> **Just want the copy-paste steps?** See [`QUICKSTART.md`](QUICKSTART.md) — a short
> AlmaLinux-only runbook. The combined Rocky + AlmaLinux runbook is at
> [`../PXE-INSTALL-QUICKSTART.md`](../PXE-INSTALL-QUICKSTART.md).

Everything else is **reused** from the shared `netboot/` tooling — nothing is
duplicated:

| Shared tool | What this lab uses it for |
|---|---|
| `netboot/build-ipxe.sh` | Build `boot.ipxe` + the `ipxe.pxe`/`ipxe.efi` binaries with the Alma boot params embedded. |
| `netboot/gen-almalinux-ks.sh` | Generic template→`ks/<mac>.ks` copier (distro-agnostic; defaults to this lab's `almalinux-zerotouch.ks`). |
| `netboot/setup-dhcp-tftp.sh` | Path B: dnsmasq ProxyDHCP + TFTP for real hardware. |

**Variant configs** (also in this directory — firmware/arch spins on the lab above):

| File | Variant |
|---|---|
| [`vm-almalinux-pxe-install.toml`](vm-almalinux-pxe-install.toml) | Standalone **BIOS** install-target VM: just the `[[vm]]` half of `almalinux-pxe-lab.toml` (no `[[service]]` block). Same install — use the lab `.toml` for the one-shot serve **and** boot; use this when the artifact server is already up and you just want to (re)boot the VM. |
| [`vm-almalinux-uefi-pxe.toml`](vm-almalinux-uefi-pxe.toml) + [`almalinux-uefi-zerotouch.ks`](almalinux-uefi-zerotouch.ks) | **UEFI** variant (OVMF + `ipxe.efi`, `bootloader --location=boot`). |
| [`vm-almalinux-aarch64-pxe.toml`](vm-almalinux-aarch64-pxe.toml) + [`almalinux-aarch64-zerotouch.ks`](almalinux-aarch64-zerotouch.ks) | **aarch64** variant (AAVMF, `console=ttyAMA0`, TCG). |

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

Run all commands from the repo root. Replace `/home/sqs` in `almalinux-pxe-lab.toml`
with your `$HOME` first (TOML has no shell expansion).

### 1. Fetch + verify the AlmaLinux installer + stage2

```bash
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --release 9 --arch x86_64
# → ~/netboot/vmlinuz            (~15 MB)
# → ~/netboot/initrd.img         (~210 MB)
# → ~/netboot/images/install.img (~1.2 GB stage2, served locally)
# All three verified against the sha256 entries in the tree's .treeinfo.
```

### 2. Render the per-host kickstart

The VM's NIC MAC is pinned to `52:54:00:a1:9a:01` in the TOML, so iPXE will ask
for `/ks/52-54-00-a1-9a-01.ks`. Generate exactly that file (with no `--template`,
`gen-almalinux-ks.sh` defaults to this lab's `almalinux-zerotouch.ks`):

```bash
netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01
# → ~/netboot/ks/52-54-00-a1-9a-01.ks
```

> `gen-almalinux-ks.sh` lives in `netboot/` (not this dir) because Rocky shares it
> as a generic "copy template → `ks/<mac:hexhyp>.ks`" helper — pass `--template` to
> point it at any other kickstart.

### 3. Build iPXE with AlmaLinux boot params

```bash
netboot/build-ipxe.sh \
    --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.stage2=http://10.0.2.2:8181/ inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'
# → ~/netboot/boot.ipxe (the script this lab boots), ipxe.pxe (BIOS NBP for real HW),
#   ipxe.efi (UEFI), ipxe.qcow2
```

- `10.0.2.2` is the host as seen from inside a QEMU slirp guest; `8181` is the host
  port the nginx container publishes (step 4).
- `{MAC}` is a **literal placeholder**: `build-ipxe.sh` rewrites it to iPXE's
  runtime `${mac:hexhyp}`, so each booting NIC fetches its own kickstart.
- `inst.stage2=` points Anaconda at the **local** `install.img`, so the ~1.2 GB
  stage2 doesn't stream from a remote mirror (that large transfer truncates over
  QEMU slirp and fails the install at dracut). The kickstart's own `url`/`repo`
  lines refine the package sources (the upstream mirror).

### 4. Start the rootless nginx artifact server (Phase 4)

```bash
phase4-podman/lab-podman.sh up --config examples/almalinux-pxe-lab/almalinux-pxe-lab.toml
curl -sI http://localhost:8181/vmlinuz | head -1                  # → HTTP/1.1 200 OK
curl -sI http://localhost:8181/ks/52-54-00-a1-9a-01.ks | head -1
```

### 5. Create + start the installer VM (Phase 2)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/almalinux-pxe-lab/almalinux-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start  almalinux-pxe-install     # walk away
phase2-qemu-vm/lab-vm.sh console almalinux-pxe-install     # optional: watch Anaconda
```

What you'll see (`pxe-install`, BIOS):

1. **First boot:** SeaBIOS tries the blank target disk (`vda`, bootindex 0), finds
   no boot sector, and falls to the NIC's option ROM → which on QEMU *is* iPXE → it
   DHCPs and TFTP-fetches `boot.ipxe`, then (the file starts with `#!ipxe`) runs it
   directly → fetches `vmlinuz`/`initrd.img` + the per-MAC kickstart over HTTP →
   Anaconda installs to `vda`; the final `reboot` ends it.
2. **Second boot:** `vda` is now bootable and (being bootindex 0) is tried first;
   the NIC ROM is never reached again. You land at an AlmaLinux login.

> **Why `boot.ipxe`, not the `ipxe.pxe` binary?** QEMU's NIC ROM is already iPXE,
> so handing it the script avoids chainloading a *second* iPXE that re-inits the
> NIC over UNDI and DHCPs again — the flaky step that otherwise drops to
> "No bootable device". Real hardware with a non-iPXE firmware PXE: set
> `pxe_bootfile = "ipxe.pxe"` to chainload the binary (which embeds the same
> script) first.

> **UEFI?** Use [`vm-almalinux-uefi-pxe.toml`](vm-almalinux-uefi-pxe.toml), or
> set `pxe_bootfile = "ipxe.efi"` and drop `firmware` in this TOML.

```bash
phase2-qemu-vm/lab-vm.sh ssh almalinux-pxe-install        # login: lab / lab
cat /etc/almalinux-release                                 # → AlmaLinux release 9.x
```

### 6. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab almalinux-pxe
phase2-qemu-vm/lab-vm.sh    destroy almalinux-pxe-install --force
```

---

## Path B — real hardware

For a physical target on your LAN, QEMU's built-in DHCP/TFTP isn't in the picture —
you need a real PXE responder. Use `dnsmasq` for DHCP+TFTP (ProxyDHCP mode, so it
coexists with your router's DHCP) via the shared `netboot/setup-dhcp-tftp.sh`.

Steps 1–4 from Path A are unchanged **except** you rebuild iPXE pointing at this
host's real LAN IP instead of `10.0.2.2`, and (because a vendor PXE ROM usually
isn't iPXE) you serve the `ipxe.efi`/`ipxe.pxe` **binary** for it to chainload:

```bash
# (step 1: fetch installer — same as Path A)
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --release 9 --arch x86_64

# (step 2: kickstart — name it for the TARGET machine's real NIC MAC)
netboot/gen-almalinux-ks.sh --mac AA:BB:CC:DD:EE:FF
# Generate ks/default.ks too (fallback for un-enumerated MACs) with --default,
# but understand the risk: ANY machine that PXE-boots will then install itself.

# (step 3: iPXE with your LAN IP, e.g. 192.168.1.10)
netboot/build-ipxe.sh \
    --server http://192.168.1.10:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.stage2=http://192.168.1.10:8181/ inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://192.168.1.10:8181/ks/{MAC}.ks inst.text ip=dhcp'

# (step 4: serve — bind nginx on the LAN, not loopback)
#   Edit almalinux-pxe-lab.toml's [[service]] ports to "8181:80" on 0.0.0.0
#   (podman publishes on all interfaces by default), then:
phase4-podman/lab-podman.sh up --config examples/almalinux-pxe-lab/almalinux-pxe-lab.toml
```

Then stand up the DHCP/TFTP responder:

```bash
netboot/setup-dhcp-tftp.sh \
    --dir ~/netboot \
    --server-ip 192.168.1.10 \
    --iface eth0 \
    --bootfile ipxe.efi          # UEFI clients; ipxe.pxe for legacy BIOS PXE
# It writes a dnsmasq.conf (ProxyDHCP + TFTP) and prints the podman/docker command
# to launch dnsmasq.  ProxyDHCP = your router still hands out IPs; dnsmasq only
# adds DHCP options 66 (TFTP server) + 67 (bootfile) for PXE.
```

PXE-boot the physical machine (enable network boot in its firmware). It will:
DHCP → get the TFTP pointer from dnsmasq → pull `ipxe.efi` over TFTP → iPXE
chainloads → fetches `vmlinuz`/`initrd.img`/kickstart over HTTP → Anaconda installs.

---

## Security posture (read before exposing anything)

- **Plaintext lab credentials.** `almalinux-zerotouch.ks` sets `root:lab` and a
  `lab:lab` sudo user in cleartext. Anyone who can fetch the kickstart can read
  them. **Never** serve this on an untrusted network. For real use, switch the
  plaintext password to `--iscrypted <sha512-hash>` and restrict nginx to loopback
  or a private VLAN. (Same posture as the rest of mklab — these are throwaway labs.)
- **Path A binds nginx to the host;** for QEMU-only use it's only reachable via the
  slirp `10.0.2.2` mapping. Path B deliberately widens it to the LAN — only do that
  on a trusted segment.
- **`ks/default.ks` auto-installs unknown machines.** Only create it
  (`gen-almalinux-ks.sh --default`) when you genuinely want any PXE-booting box on
  the segment to wipe and install itself.

---

## Why these specific choices (the "under the hood" notes)

- **Why `.treeinfo`, not a `CHECKSUM` file?** AlmaLinux's `images/pxeboot/CHECKSUM`
  isn't reliably published (404s on some mirrors) and never covered `install.img`
  (the ~1.2 GB stage2, one dir up). The os tree's productmd `.treeinfo` is the
  standard that lists `sha256:` for **every** image — `vmlinuz`, `initrd.img` *and*
  `install.img`. Those hashes change every point release (9 → 9.x), so the fetch
  script pulls `.treeinfo` live and parses it rather than pinning a hash that rots.
- **Why `pxe-install` running `boot.ipxe`, not a two-disk iPXE-ROM disk?** SeaBIOS
  only attempts the first hard disk, and x86_64 disk-image VMs default to OVMF
  (which can't boot a BIOS-MBR disk) — so the older two-disk boot-loop doesn't boot
  in QEMU. Instead the NIC's option ROM — which on QEMU is itself iPXE —
  TFTP-fetches and runs `boot.ipxe` directly (no `ipxe.pxe` binary chainload, so no
  UNDI re-DHCP — the flaky "No bootable device" step). The single install target
  carries `bootindex=0`: blank on first boot → SeaBIOS falls to the NIC ROM →
  installs → on the next boot the disk wins → true zero-touch, no manual disk swap.
- **Why a local `inst.stage2` + 4 GB RAM?** Anaconda downloads `install.img` into
  the initramfs tmpfs (~½ of RAM). Streamed from a remote mirror it truncates over
  slirp (`curl 18`); served locally it loads fast — but at 2.5 GB the tmpfs filled
  at ~814 MB (`dracut: FATAL: No space left`), so the lab runs at 4 GB.
- **Why iPXE instead of plain PXELINUX/grub?** iPXE speaks HTTP, so the installer
  kernel/initrd, the stage2, and the per-host kickstart all come over HTTP from one
  rootless nginx, and `${mac:hexhyp}` lets one boot program serve every host its own
  kickstart. TFTP only ever carries the small `boot.ipxe` script (or, on real
  hardware, the iPXE NBP).
- **Why `ignoredisk --only-use=vda` in the kickstart?** The VM's only disk is the
  virtio target `/dev/vda`; pinning the install there keeps Anaconda fully
  unattended (no disk prompt) and lands GRUB on the disk SeaBIOS boots next.
