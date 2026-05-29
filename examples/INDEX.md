# Examples — a field guide

Every `.toml` here is a ready-to-run lab spec for one of the `mklab` phase
tools. Point a tool at one with `--config examples/<file>` and it builds the
thing the file describes — a chroot, a VM, a container topology, a netboot
pipeline, or a from-source micro-distro.

**One nice trick up front:** a single TOML can feed *several* phases at once.
Each tool reads only the blocks it owns (`[[chroot]]`, `[[vm]]`, `[[service]]`,
`[[instance]]`) and silently ignores the rest — so the "unified" specs below
drive an entire build → serve → boot pipeline from one file. Look for the
**🔗 unified** tag.

**Legend:** 🔗 unified (feeds multiple phases) · 🔑 needs `sudo`/root ·
🐌 runs under TCG emulation (slow, no host HW needed) · 🪶 rootless.

> Files stay in `examples/` (their paths are referenced across the docs); this
> index is the map, not a move.

---

## 🪤 Throwaway chroots — Phase 1 (`phase1-chroot/lab-chroot.sh`) 🔑

Disposable root filesystems you can `enter`, boot under nspawn, or feed into
later phases. Built with `sudo lab-chroot.sh create --config …`.

| File | What you get |
|---|---|
| `chroot-debian-bookworm.toml` | Native x86_64 Debian bookworm, schroot-managed — the canonical starting point. |
| `chroot-rocky9-vsftpd.toml` | A Rocky 9 chroot sized for jailing `vsftpd` (the RPM/`dnf` backend). |
| `chroot-host-copy-busybox.toml` | Tiny host-copy chroot: just BusyBox + a few `/etc` files. No debootstrap. |
| `chroot-nspawn-managed.toml` | Debian bookworm registered with `machinectl` and bootable via `systemd-nspawn -b`. |

## 🖥️ QEMU machines — Phase 2 (`phase2-qemu-vm/lab-vm.sh`)

Full cloud-image VMs and tiny in-RAM microVMs. `create` then `start`, `ssh` in.

| File | What you get |
|---|---|
| `vm-debian-amd64.toml` | Native x86_64 Debian bookworm via QEMU/KVM — fast, SSH-ready. |
| `vm-debian-aarch64.toml` | 🐌 arm64 Debian on an x86_64 host (TCG). Slow but needs no arm hardware. |
| `vm-alpine-amd64.toml` | Latest Alpine cloud image on `q35` + OVMF. |
| `vm-kali-amd64.toml` | Kali rolling from the upstream prebuilt image (release auto-resolved at create-time). |
| `microvm-alpine.toml` | True microVM: an Alpine minirootfs as an in-RAM initramfs, auto-built — `network`/`ssh`/`persist` flags. |
| `microvm-alpine-custom-init.toml` | Same microVM, but PID 1 is a hand-rolled static C `/sbin/init` (auto-compiled by `lab-vm.sh`). |

## 🐳 Docker topologies — Phase 3 (`phase3-docker/lab-docker.sh`)

| File | What you get |
|---|---|
| `docker-3svc-topology.toml` | nginx + postgres + an idle alpine client on a shared bridge — the Phase 3 showcase. |

## 🦭 Podman, rootless — Phase 4 (`phase4-podman/lab-podman.sh`) 🪶

| File | What you get |
|---|---|
| `podman-plain-single.toml` | The simplest topology: one rootless container, one published port. |
| `podman-pod-3svc.toml` | Three containers sharing a **pod** (one net/IPC/PID namespace; localhost between them). |
| `podman-quadlet-service.toml` | Exports a `.container` **quadlet** unit to systemd-user — survives reboots, auto-restarts. |
| `podman-multiarch-build.toml` | Builds an image for a *foreign* arch via `qemu-user-static` (a `build` step, not `up`). |

## 📦 LXD / Incus — Phase 5 (`phase5-lxd/lab-lxd.sh`)

System containers and hardware VMs under one API, with profiles and projects.

| File | What you get |
|---|---|
| `lxd-plain-single.toml` | Smallest useful lab: one Alpine **container**, no profiles/projects. |
| `lxd-vm-single.toml` | One Alpine **VM** (real QEMU virt under LXD — needs `/dev/kvm` + block storage). |
| `lxd-mixed-topology.toml` | 2 containers + 1 VM in a single lab — exercises the container/VM discriminator. |
| `lxd-profiles-projects.toml` | `[[profile]]` + `[[project]]` demo — LXD-native config bundles and namespace isolation. |

## ⚙️ From source: micro-linux — compile → boot in RAM (`micro-linux/mlbuild.sh` → Phase 2)

Compile a kernel + a tiny userspace from upstream source and boot to a **console
login prompt** (`root` / `micro`) — no disk, no packages. Build with
`mlbuild.sh all --arch …` first, then boot via `lab-vm.sh`.

| File | What you get |
|---|---|
| `micro-linux-x86_64.toml` | x86_64 kernel + static BusyBox → getty/login shell over serial (boots on `q35`). |
| `micro-linux-x86_64-microvm.toml` | The same artifacts on QEMU's real `microvm` machine (qboot, virtio-mmio) — the minimal, fast-boot device model. |
| `micro-linux-aarch64.toml` | 🐌 The arm64 twin, cross-compiled; boots on QEMU `virt` (TCG on x86 hosts). |
| `micro-linux-aarch64-microvm.toml` | 🐌 arm64 microvm-style: a minimized, firmware-free `virt` + virtio-mmio (QEMU has no arm `microvm` machine). |
| `micro-linux-riscv64.toml` | The "faithful track": riscv64 kernel + a u-root (pure-Go) **plain** cpio — closest to the source post. |
| `micro-linux-ppc64le.toml` | 🐌 ppc64le cross-compiled; boots on QEMU `pseries` (POWER emulation, TCG on x86 hosts). SLOF firmware bundled in qemu-system-ppc64; HVC console. |
| `micro-linux-s390x.toml` | 🐌 s390x cross-compiled; boots on QEMU `s390-ccw-virtio` (IBM mainframe emulation, TCG). CCW VirtIO bus; SCLP VT220 console → ttyS0. |

The same compiled kernel boots both the plain and `-microvm` twins: `mlbuild.sh`
bakes `CONFIG_VIRTIO_MMIO` into every micro-linux kernel (except s390x which uses
the VirtIO-CCW transport), so virtio works on the microvm mmio bus as well as PCI.

| Dir | What you get |
|---|---|
| [`micro_linux_dhcp_lease/`](micro_linux_dhcp_lease/) | The networking demo: the from-source distro pulls a **DHCP lease** over a virtio NIC. x86_64/aarch64/ppc64le/s390x auto-bring-up via BusyBox `udhcpc` (opt-in `mllab.net` token); riscv64 runs u-root's `dhclient` at the shell. ⚠️ root has a well-known password — see its README + AUDIT F1. |

## 🌉 Cross-phase bridges — build once, run elsewhere

Take a Phase-1 chroot and turn it into a VM or a container image. Build the
chroot first, then point the target phase at the same artifact.

| File | What you get |
|---|---|
| `vm-from-chroot-debian.toml` | Chroot → bootable BIOS qcow2 (MBR + extlinux + ext4) for Phase 2. |
| `podman-from-chroot.toml` | Chroot → a rootless Podman image (e.g. import a Kali minbase tree). |
| `lxd-from-chroot.toml` | Chroot → a Phase 5 LXD/Incus container image. |

## 🌐 Netboot & PXE — build → serve → boot

The repo's richest pipeline: build a RAM-bootable rootfs (Phase 1), serve the
kernel+initrd over HTTP (Phase 3/4), and boot it in QEMU directly or via iPXE
(Phase 2). Three fidelity tiers — *minimal* (busybox, no net) → *busybox*
(net-capable shell) → *full* (systemd + SSH).

| File | Role in the pipeline |
|---|---|
| `chroot-netboot-minimal.toml` | 🔑 Tier 1 — kernel + BusyBox only, no networking; auto-writes a busybox `/init`. |
| `chroot-netboot-busybox.toml` | 🔑 Tier 2 — adds iproute2/ping/curl: a fast, networked RAM shell. |
| `chroot-netboot-full.toml` | 🔑 Tier 3 — systemd PID 1 + SSH + cloud-init (~300–500 MB initrd). |
| `vm-netboot-direct.toml` | Boots the tier-2 busybox initrd via QEMU `-kernel/-initrd` (no iPXE — short debug loop). |
| `vm-netboot-full.toml` | Boots the full systemd initrd (given 2 GB so it can unpack ~1 GB in RAM). |
| `vm-netboot-ipxe.toml` | Boots an iPXE disk that fetches kernel+initrd over HTTP — simulates real PXE hardware. |
| `docker-netboot-server.toml` | Rootful Docker nginx serving the netboot artifacts on :8080. |
| `podman-netboot-server.toml` | 🪶 The rootless Podman equivalent — preferred when you only need to serve. |
| `vm-almalinux-pxe-install.toml` | Zero-touch AlmaLinux installer target: a boot-loop that chainloads Anaconda, then boots the installed disk. |
| `almalinux-zerotouch.ks` | 🔑 The kickstart that drives that unattended install (rendered per-host; **plaintext lab creds**). |
| [`rocky-pxe-lab/`](rocky-pxe-lab/) | 🔗 Self-contained Rocky Linux 9 zero-touch PXE lab in its own directory: fetch+verify installer (checksums from `.treeinfo`), kickstart, unified P4+P2 TOML, and a README with both the QEMU path **and** the CIQ-style real-hardware dnsmasq/TFTP path. Plus a `MANUAL_TESTING.md` walking the full ~15-min Anaconda install. |
| [`kali-pxe-lab/`](kali-pxe-lab/) | 🔗 Self-contained Kali Linux zero-touch PXE lab: the **Debian-installer + preseed** cousin (not Anaconda/kickstart). Fetch+verify d-i `linux`/`initrd.gz` (checksums from `SHA256SUMS`), preseed, unified P4+P2 TOML, README with the QEMU path **and** the Kali-docs `netboot.tar.gz` + dnsmasq/TFTP/PXELINUX path. Plus a `MANUAL_TESTING.md` walking the full ~15-min d-i install — incl. the one install-breaking risk (d-i clobbering the iPXE ROM disk) and how the `vda` pinning closes it. |

## 🔗 One file, every phase — unified demos

These drive a whole multi-phase workflow from a single spec; run the phase
tools in sequence against the same file.

| File | What it orchestrates |
|---|---|
| `lab-unified-demo.toml` | 🔗 The capstone: one TOML feeding **all five** phase tools (`[lab]` groups them). |
| `netboot-lab.toml` | 🔗 The full Debian netboot pipeline: build initrd (P1) → serve (P4) → direct-boot (P2). |
| `almalinux-pxe-lab.toml` | 🔗 The AlmaLinux zero-touch PXE lab: serve (P4) + install-target VM (P2). |
| [`rocky-pxe-lab/rocky-pxe-lab.toml`](rocky-pxe-lab/) | 🔗 The Rocky Linux zero-touch PXE lab: serve (P4) + install-target VM (P2). Self-contained dir — see `rocky-pxe-lab/README.md`. |
| [`kali-pxe-lab/kali-pxe-lab.toml`](kali-pxe-lab/) | 🔗 The Kali Linux zero-touch PXE lab: serve (P4) + install-target VM (P2) via Debian-installer + preseed. Self-contained dir — see `kali-pxe-lab/README.md`. |

## 🤖 AI / LLM — run a model locally

| File | What you get |
|---|---|
| [`kali-llm-lab/`](kali-llm-lab/) | 🔗🪶 Local LLM on Kali, headless: a rootless **Ollama + Open WebUI** pod (Phase 4) reached over SSH-forward — the self-contained Tier 1 of the [Kali Ollama+5ire blog](https://www.kali.org/blog/kali-llm-ollama-5ire/). README also wires the **real 5ire** desktop client (Tier 2). ⚠️ unauthenticated model API — loopback + SSH-forward only. Design doc: `KALI_LLM_LAB_PLAN.md`. |
| [`kali-llm-desktop-lab/`](kali-llm-desktop-lab/) | 🖥️ **Tier 2-full** — the *whole* blog stack in one Kali XFCE VM (Phase 2): Ollama + the **real 5ire GUI** (over VNC-through-SSH) + **mcp-kali-server** driving real Kali tools (the agentic Tier 3 payoff). In-VM provisioner; ~8 GB RAM. ⚠️ an LLM that runs `nmap`/`sqlmap`/`metasploit` — isolated network + authorized targets only. README marks what's verified vs documented. |

## 📚 Reference & notes

| Path | What it is |
|---|---|
| [`reference/`](reference/) | Standalone build scripts that predate `lab-vm.sh`'s auto-build — read them to see the microVM initramfs built without the framework. |
| `alpine-custom-init.TXT` | A side-by-side walkthrough of busybox-init vs. a custom C PID 1 (companion to `microvm-alpine-custom-init.toml`). |

---

*New here? Start with `chroot-debian-bookworm.toml` or `vm-debian-amd64.toml`
for a feel, then jump to `netboot-lab.toml` or `lab-unified-demo.toml` to watch
one file light up several phases at once. Each phase also ships a `SHOWCASE.md`
with copy-pasteable tours.*
