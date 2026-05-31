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

> Most specs sit flat in `examples/`; a cohesive multi-file lab gets its own
> subdir (the kali/pxe labs, and the from-source
> [`tiny-linux-experiments/`](tiny-linux-experiments/) family). Paths are
> referenced across the docs, so when a group earns a subdir, move it as a unit
> and fix the links (`tools/link_check.py` finds them).

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
| [`kali-nonroot-chroot/`](kali-nonroot-chroot/) | 🔒 A Kali `kali-rolling` chroot with a **non-root** sudo user (`kali`/`kali`, root locked) + a top-10 tool slice (nmap + sqlmap) — the chroot-level take on Kali's `kali-linux-mate-top10-nonroot` live-build recipe. Enables `contrib non-free` (nmap is non-free) + installs `kali-archive-keyring` so the chroot's apt works; full top-10 + MATE-desktop-via-VM documented. ⚠️ offensive tools — authorized targets only. |

## 🖥️ QEMU machines — Phase 2 (`phase2-qemu-vm/lab-vm.sh`)

Full cloud-image VMs and tiny in-RAM microVMs. `create` then `start`, `ssh` in.

| File | What you get |
|---|---|
| `vm-debian-amd64.toml` | Native x86_64 Debian bookworm via QEMU/KVM — fast, SSH-ready. |
| `vm-debian-aarch64.toml` | 🐌 arm64 Debian on an x86_64 host (TCG). Slow but needs no arm hardware. |
| `vm-alpine-amd64.toml` | Latest Alpine cloud image on `q35` + OVMF. |
| `vm-kali-amd64.toml` | Kali rolling from the upstream prebuilt image (release auto-resolved at create-time). |
| [`kali-vm-builder/`](kali-vm-builder/) | 🔒 Kali's **official image factory** (`kali-vm` + `debos`) operationalized: `fetch` → `build` (host `debos` *or* Podman/Docker container; `--full` graphical XFCE / `--headless`) → `run-graphical.sh` boots the QCOW2 in a **windowed** QEMU desktop (SeaBIOS/virtio/SSH-forward, COW overlay). The build-it-yourself counterpart to `vm-kali-amd64.toml`. ⚠️ offensive tooling — authorized targets only. |
| `tiny-linux-experiments/microvm-alpine.toml` | True microVM: an Alpine minirootfs as an in-RAM initramfs, auto-built — `network`/`ssh`/`persist` flags. |
| `tiny-linux-experiments/microvm-alpine-custom-init.toml` | Same microVM, but PID 1 is a hand-rolled static C `/sbin/init` (auto-compiled by `lab-vm.sh`). |

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
`mlbuild.sh all --arch …` first, then boot via `lab-vm.sh`. These specs live
under [`tiny-linux-experiments/`](tiny-linux-experiments/) — the filenames in
the table below are relative to that dir.

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
| [`micro_linux_dhcp_lease/`](tiny-linux-experiments/micro_linux_dhcp_lease/) | The networking demo: the from-source distro pulls a **DHCP lease** over a virtio NIC. One `micro-linux-<arch>-dhcp.toml` per arch — x86_64/aarch64/ppc64le/s390x auto-bring-up via BusyBox `udhcpc` (opt-in `mllab.net` token; ppc64le/s390x need a `WITH_EXTRA_ARCHES=1` build), riscv64 runs u-root's `dhclient` at the shell. ⚠️ root has a well-known password — see its README + AUDIT F1. |

## 🌉 Cross-phase bridges — build once, run elsewhere

Take a Phase-1 chroot and turn it into a VM or a container image. Build the
chroot first, then point the target phase at the same artifact.

| File | What you get |
|---|---|
| `vm-from-chroot-debian.toml` | Chroot → bootable BIOS qcow2 (MBR + extlinux + ext4) for Phase 2. |
| `podman-from-chroot.toml` | Chroot → a rootless Podman image (e.g. import a Kali minbase tree). |
| `lxd-from-chroot.toml` | Chroot → a Phase 5 LXD/Incus container image. |
| [`offsec-awae-vm/`](offsec-awae-vm/) | 🔒 End-to-end **automated** chroot→VM: a Kali `kali-rolling` chroot carrying the **OffSec AWAE (WEB-300)** toolset, made self-bootable (kernel + init + SSH) and packaged into a headless BIOS VM by `from-chroot`. `build-vm.sh` chains both phases + boots it (serial/SSH); `--smoke` proves the pipeline first. Chroot-level take on Kali's `offsec-awae-live.sh` live-build recipe. ⚠️ offensive tooling — authorized targets only. |

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
| [`almalinux-pxe-lab/`](almalinux-pxe-lab/) | 🔗 Self-contained AlmaLinux 9 zero-touch PXE lab in its own directory: fetch+verify installer (checksums from `.treeinfo`), kickstart (rendered per-host; **plaintext lab creds**), unified P4+P2 TOML, README with the QEMU path **and** real-hardware notes, and a `MANUAL_TESTING.md` walking the full Anaconda install. The Rocky twin. Now also houses the **UEFI / aarch64 / standalone-BIOS** variant configs (`vm-almalinux-*.toml` + matching `*-zerotouch.ks`) and the `nginx-ks-fallback.conf` snippet. |
| [`rocky-pxe-lab/`](rocky-pxe-lab/) | 🔗 Self-contained Rocky Linux 9 zero-touch PXE lab in its own directory: fetch+verify installer (checksums from `.treeinfo`), kickstart, unified P4+P2 TOML, and a README with both the QEMU path **and** the CIQ-style real-hardware dnsmasq/TFTP path. Plus a `MANUAL_TESTING.md` walking the full ~15-min Anaconda install. |
| [`kali-pxe-lab/`](kali-pxe-lab/) | 🔗 Self-contained Kali Linux zero-touch PXE lab: the **Debian-installer + preseed** cousin (not Anaconda/kickstart). Fetch+verify d-i `linux`/`initrd.gz` (checksums from `SHA256SUMS`), preseed, unified P4+P2 TOML, README with the QEMU path **and** the Kali-docs `netboot.tar.gz` + dnsmasq/TFTP/PXELINUX path. Plus a `MANUAL_TESTING.md` walking the full ~15-min d-i install — incl. the one install-breaking risk (d-i clobbering the iPXE ROM disk) and how the `vda` pinning closes it. |
| [`kali-preseed-gallery/`](kali-preseed-gallery/) | 🔗 The **pick-a-variant** companion to `kali-pxe-lab`: fetches the *whole* upstream [Kali preseed-examples catalog](https://gitlab.com/kalilinux/recipes/kali-preseed-examples) (~15 variants — xfce/kde/gnome/headless × regular/lvm/crypto/multi/skip-wipe/packer) and installs any one zero-touch via QEMU **`pxe-install`** (BIOS: the NIC's iPXE ROM runs `boot.ipxe`), selectable with `select-preseed.sh <variant>`. `fetch-preseeds.sh` stages each verbatim **and** auto-patches `/dev/sda`→`/dev/vda` for the virtio target (`--verbatim` to opt out). `headless-default` boot-verified end-to-end on KVM; `MANUAL_TESTING.md` has the fetch/patch checks. |
| [`rocky-kickstart-gallery/`](rocky-kickstart-gallery/) | 🔗 The **Rocky/Anaconda** sibling of `kali-preseed-gallery`: fetches the *whole* upstream [rocky-linux/kickstarts](https://github.com/rocky-linux/kickstarts) **r9** catalog (~34 variants — GenericCloud/EC2/Azure/OCP/Vagrant/Workstation/KDE/XFCE/MATE/Cinnamon/Container/RPI) and installs any disk-installing one zero-touch via QEMU **`pxe-install`** (NIC's iPXE ROM runs `boot.ipxe`), selectable with `select-kickstart.sh <variant>`. `fetch-kickstarts.sh` stages each verbatim under `raw/` **and** patches the image-build `shutdown`→`reboot` + unlocks root (`root`/`lab`, `--no-unlock-root` to opt out); disk refs are already `/dev/vda` (no patch needed, unlike Kali). `GenericCloud-Base` boot-verified end-to-end on KVM; `MANUAL_TESTING.md` has the fetch/patch checks. |

## 🔗 One file, every phase — unified demos

These drive a whole multi-phase workflow from a single spec; run the phase
tools in sequence against the same file.

| File | What it orchestrates |
|---|---|
| `lab-unified-demo.toml` | 🔗 The capstone: one TOML feeding **all five** phase tools (`[lab]` groups them). |
| `netboot-lab.toml` | 🔗 The full Debian netboot pipeline: build initrd (P1) → serve (P4) → direct-boot (P2). |
| [`almalinux-pxe-lab/almalinux-pxe-lab.toml`](almalinux-pxe-lab/) | 🔗 The AlmaLinux zero-touch PXE lab: serve (P4) + install-target VM (P2). Self-contained dir — see `almalinux-pxe-lab/README.md`. |
| [`rocky-pxe-lab/rocky-pxe-lab.toml`](rocky-pxe-lab/) | 🔗 The Rocky Linux zero-touch PXE lab: serve (P4) + install-target VM (P2). Self-contained dir — see `rocky-pxe-lab/README.md`. |
| [`kali-pxe-lab/kali-pxe-lab.toml`](kali-pxe-lab/) | 🔗 The Kali Linux zero-touch PXE lab: serve (P4) + install-target VM (P2) via Debian-installer + preseed. Self-contained dir — see `kali-pxe-lab/README.md`. |
| [`kali-preseed-gallery/kali-preseed-gallery.toml`](kali-preseed-gallery/) | 🔗 The Kali preseed **gallery**: serve (P4) + install-target VM (P2), but with any of ~15 upstream preseed variants selectable via `select-preseed.sh`. Self-contained dir — see `kali-preseed-gallery/README.md`. |
| [`rocky-kickstart-gallery/rocky-kickstart-gallery.toml`](rocky-kickstart-gallery/) | 🔗 The Rocky kickstart **gallery**: serve (P4) + install-target VM (P2), with any of ~34 upstream Rocky-9 kickstarts selectable via `select-kickstart.sh`. Self-contained dir — see `rocky-kickstart-gallery/README.md`. |

## 🤖 AI / LLM — run a model locally

| File | What you get |
|---|---|
| [`kali-llm-lab/`](kali-llm-lab/) | 🔗🪶 Local LLM on Kali, headless: a rootless **Ollama + Open WebUI** pod (Phase 4) reached over SSH-forward — the self-contained Tier 1 of the [Kali Ollama+5ire blog](https://www.kali.org/blog/kali-llm-ollama-5ire/). README also wires the **real 5ire** desktop client (Tier 2). ⚠️ unauthenticated model API — loopback + SSH-forward only. Design doc: `KALI_LLM_LAB_PLAN.md`. |
| [`kali-llm-desktop-lab/`](kali-llm-desktop-lab/) | 🖥️ **Tier 2-full** — the *whole* blog stack in one Kali XFCE VM (Phase 2): Ollama + the **real 5ire GUI** (over VNC-through-SSH) + **mcp-kali-server** driving real Kali tools (the agentic Tier 3 payoff). In-VM provisioner; ~8 GB RAM. ⚠️ an LLM that runs `nmap`/`sqlmap`/`metasploit` — isolated network + authorized targets only. README marks what's verified vs documented. |

## 🔧 Ansible — configuration management

A control node runs Ansible playbooks against managed target host(s) — see the category [`ansible/`](ansible/) README.

| File | What you get |
|---|---|
| [`ansible/almalinux-infra-ansible/`](ansible/almalinux-infra-ansible/) | 🔧 Run AlmaLinux's own [infra-ansible](https://github.com/AlmaLinux/infra-ansible) recipes from an Ansible **control** container against an AlmaLinux **target** container (both Phase-5 LXD/Incus). `fetch-recipes.sh` stages the catalog verbatim under `raw/` **and** patches the playbooks (comments the Zabbix/FreeIPA/Vault/hardening roles that need AlmaLinux's real infra; roles untouched); `run-recipe.sh` bootstraps + runs one. **Verified green:** `common` (base setup, idempotent), `gitea` (SQLite + Valkey + Caddy, web UI on :3000), and `matterbridge` (daemon on :4242); heavier recipes (mattermost/matrix/keycloak/mirror/…) deferred — need Postgres/Vault/FreeIPA. |

## 📚 Reference & notes

| Path | What it is |
|---|---|
| [`tiny-linux-experiments/reference/`](tiny-linux-experiments/reference/) | Standalone build scripts that predate `lab-vm.sh`'s auto-build — read them to see the microVM initramfs built without the framework. |
| `tiny-linux-experiments/alpine-custom-init.TXT` | A side-by-side walkthrough of busybox-init vs. a custom C PID 1 (companion to `microvm-alpine-custom-init.toml`). |
| `<kali-lab>/ADDING-PACKAGES.md` | Per-lab "how to add a package" guides — same add→apply→verify shape, tailored to each lab's real mechanism: chroot `apt` (`kali-nonroot-chroot`), in-guest provisioner (`kali-llm-desktop-lab`), Podman model/service (`kali-llm-lab`), and d-i preseed reinstall (`kali-pxe-lab`, `kali-preseed-gallery`). The offsec-awae flow lives in that lab's own README. |

---

*New here? Start with `chroot-debian-bookworm.toml` or `vm-debian-amd64.toml`
for a feel, then jump to `netboot-lab.toml` or `lab-unified-demo.toml` to watch
one file light up several phases at once. Each phase also ships a `SHOWCASE.md`
with copy-pasteable tours.*
