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

**🧭 Want a guided route, not a catalog?** This page lists the labs *by phase*;
[`learning-paths/`](learning-paths/README.md) lists them *by journey* — ordered
**learning paths** (with prerequisites + an observable checkpoint per lab) and
themed **collections**, generated from
[`learning-paths.toml`](learning-paths.toml) by
[`tools/paths.py`](../tools/paths.py) (which also lints that every lab is routed
into ≥1 journey).

---

## 🪤 Throwaway chroots — Phase 1 (`phase1-chroot/lab-chroot.sh`) 🔑

Disposable root filesystems you can `enter`, boot under nspawn, or feed into
later phases. Built with `sudo lab-chroot.sh create --config …`. The standalone
specs are grouped under [`chroot-examples/`](chroot-examples/README.md) (the
netboot-tier chroots stay flat in the netboot section below).

| File | What you get |
|---|---|
| `chroot-examples/chroot-debian-bookworm.toml` | Native x86_64 Debian bookworm, schroot-managed — the canonical starting point. |
| `chroot-examples/chroot-rocky9-vsftpd.toml` | A Rocky 9 chroot sized for jailing `vsftpd` (the RPM/`dnf` backend). |
| `chroot-examples/chroot-host-copy-busybox.toml` | Tiny host-copy chroot: just BusyBox + a few `/etc` files. No debootstrap. |
| `chroot-examples/chroot-nspawn-managed.toml` | Debian bookworm registered with `machinectl` and bootable via `systemd-nspawn -b`. |
| `chroot-examples/chroot-write-files-demo.toml` | Demonstrates the `write_files` key — inject files (e.g. a custom `/init`) into the tree at build time, host-side. The mechanism behind auto-writing `/init` for the netboot initramfs builds. |
| [`kali-nonroot-chroot/`](kali-nonroot-chroot/) | 🔒 A Kali `kali-rolling` chroot with a **non-root** sudo user (`kali`/`kali`, root locked) + a top-10 tool slice (nmap + sqlmap) — the chroot-level take on Kali's `kali-linux-mate-top10-nonroot` live-build recipe. Enables `contrib non-free` (nmap is non-free) + installs `kali-archive-keyring` so the chroot's apt works; full top-10 + MATE-desktop-via-VM documented. ⚠️ offensive tools — authorized targets only. |
| [`debian-nonroot-chroot/`](debian-nonroot-chroot/) | The **Debian** sibling of `kali-nonroot-chroot`: a Debian bookworm chroot with a **non-root** sudo user (`debian`/`debian`, root locked) + a small `main`-only `jq`+`cowsay` slice — **no `non-free`/keyring gymnastics** (the clean Debian contrast with Kali). Its real lesson is the **`--rootless` vise**: a verified matrix of *why* a full systemd base won't `fakechroot`-debootstrap rootless on a host with newer glibc — bookworm's base tree **builds with no host root** but can't be entered (host `chroot` needs `GLIBC_2.38` > the chroot's 2.36); trixie/noble/kali fail mid-build (systemd-sysusers / `mawk` SIGABRT / base-passwd). Rootless **tree-build verified no-root**; the full chroot is the `sudo` build. The applied counterpart to [`phase1-chroot/hand-walk/`](../phase1-chroot/hand-walk/). |
| [`chroot-breakout/`](chroot-breakout/) | 🪤 **A chroot is not a security boundary** — a faithful, by-hand walk of Thomas Van Laere's *[Exploring Containers - Part 1](chroot-breakout/upstream-tutorial/)*. *Not* a `lab-chroot.sh` spec: a disposable **`--privileged` Alpine 3.11** box (built via `lab-podman.sh build --context`) in which you hand-build a busybox chroot jail and **escape it** with the author's verbatim 12-line C program ([`breakout.c`](chroot-breakout/breakout.c)), then meet the primitives that *do* isolate (UTS/mount **namespaces** + **`pivot_root`**). The escape is proven by the before/after `ls /` contrast; **every mechanism the post introduces is verified in-box** — nothing gated/author-only (`RUNBOOK.md` walks it, `MANUAL_TESTING.md` captures the output). ⚠️ runs only in a throwaway container — `breakout.c` as host root escapes to your real `/`. |
| [`exploring-containers/`](exploring-containers/) | 🧩 **Build a container by hand, one primitive at a time** — the full **three-part** operationalization of Thomas Van Laere's *[Exploring Containers](exploring-containers/README.md)* series (Part 1 here is a byte-identical copy of `chroot-breakout/`). [Part 2](exploring-containers/part-2-namespaces/) walks **IPC** (SysV shm isolation), **network** (veth + bridge across net namespaces, by hand), and **time** namespaces; [Part 3](exploring-containers/part-3-pid-cgroups-users/) walks **PID** (you become PID 1), a **memory cgroup** that **OOM-kills** a runaway allocator (exit 137), **cgroup** + **user** namespaces (rootless "root"). All verbatim author C ([`processA/B.c`](exploring-containers/part-2-namespaces/), [`alloc.c`](exploring-containers/part-3-pid-cgroups-users/alloc.c)), verified in rootless `--privileged` podman. Two **era-divergences** are the payoff: **cgroups v1→v2** and the author's **edge `util-linux` trick rotting away** (→ Parts 2/3 bump off 3.11 to latest Alpine for a new-enough `unshare`). Honest rootless/rootful split: `ip netns` bridge + NAT + hand-written cgroupfs are the documented **rootful/author-run** steps (each with a verified rootless equivalent where one exists). ⚠️ throwaway containers only. |

## 🖥️ QEMU machines — Phase 2 (`phase2-qemu-vm/lab-vm.sh`)

Full cloud-image VMs and tiny in-RAM microVMs. `create` then `start`, `ssh` in.
The standalone VM specs are grouped under
[`vm-examples/`](vm-examples/README.md) (`vm-kali-amd64.toml` stays flat — the
Kali labs build around it; the netboot VMs stay flat in the netboot section).

| File | What you get |
|---|---|
| `vm-examples/vm-debian-amd64.toml` | Native x86_64 Debian bookworm via QEMU/KVM — fast, SSH-ready. |
| `vm-examples/vm-debian-aarch64.toml` | 🐌 arm64 Debian on an x86_64 host (TCG). Slow but needs no arm hardware. |
| `vm-examples/vm-alpine-amd64.toml` | Latest Alpine cloud image on `q35` + OVMF. |
| `vm-kali-amd64.toml` | Kali rolling from the upstream prebuilt image (release auto-resolved at create-time). |
| [`kali-vm-builder/`](kali-vm-builder/) | 🔒 Kali's **official image factory** (`kali-vm` + `debos`) operationalized: `fetch` → `build` (host `debos` *or* Podman/Docker container; `--full` graphical XFCE / `--headless`) → `run-graphical.sh` boots the QCOW2 in a **windowed** QEMU desktop (SeaBIOS/virtio/SSH-forward, COW overlay). The build-it-yourself counterpart to `vm-kali-amd64.toml`. ⚠️ offensive tooling — authorized targets only. |
| [`debian-vm-builder/`](debian-vm-builder/README.md) | 🏭 The **Debian twin** of `kali-vm-builder`, pointed at the upstream tool directly: **[debos](https://github.com/go-debos/debos)** — the Debian OS-image builder that `kali-vm` itself wraps. `fetch-debos.sh` (the official `ghcr.io/go-debos/debos` container) → `build-debian-vm.sh` drives a **mklab recipe** (`debian-vm.yaml`: debootstrap → apt kernel → image-partition → filesystem-deploy → systemd-boot) in a fakemachine KVM build VM → **`run-graphical.sh`** boots the QCOW2 (UEFI/**OVMF**, virtio, SSH-forward, COW overlay). Profiles: minimal CLI (default) / `--desktop xfce`. **Verified end-to-end here** — debos built a real trixie qcow2 (5.6 GB → ~700 MB) that boots under OVMF to a login (systemd-boot → 6.12 kernel → `debian-vm login:`; SSH `debian`/`debian`). The build-it-yourself counterpart to `vm-examples/vm-debian-amd64.toml`; recipe is mklab-authored (cite-don't-mirror debos) — see [`UPSTREAM.md`](debian-vm-builder/UPSTREAM.md). |
| `tiny-linux-experiments/microvm-alpine.toml` | True microVM: an Alpine minirootfs as an in-RAM initramfs, auto-built — `network`/`ssh`/`persist` flags. |
| `tiny-linux-experiments/microvm-alpine-custom-init.toml` | Same microVM, but PID 1 is a hand-rolled static C `/sbin/init` (auto-compiled by `lab-vm.sh`). |
| [`kdump-kexec-lab/`](kdump-kexec-lab/) | 💥 **Explore a kernel panic with kexec & kdump** — a faithful, by-hand walk of Petros Koutoupis's *[Oops! Debugging Kernel Panics](kdump-kexec-lab/upstream-tutorial/)* (Linux Journal). A Debian VM where you arm **kdump** (reserve `crashkernel=` at boot), **deliberately panic** (`echo c > /proc/sysrq-trigger`, then a buggy `insmod`), and watch the **kexec** capture kernel save a `vmcore` to `/var/crash` — then open it in **`crash`** and `bt`/`sym`/`mod -s` the panic back to the source line. **Verified end-to-end on KVM:** 42 MB vmcore captured; `sym` → `test-module.c:8`. Needs a VM (boot-time memory reservation + a real panic). `provision-kdump.sh` automates install/config; `RUNBOOK.md` walks it; `MANUAL_TESTING.md` has the real transcript. ⚠️ grow the disk first — kernel debug symbols are ~5.7 GB. |
| [`root-password-reset/`](root-password-reset/) | 🔑 **Reset a lost root password** — a slew of faithful, by-hand tutorials (Arch, Rocky, Kali, Debian) for recovering root on a running VM by interrupting the boot loader. Methods: **`init=/bin/bash`·`/bin/sh`** ([RUNBOOK](root-password-reset/RUNBOOK-init-shell.md) — **verified end-to-end** on Debian/BIOS: edit the GRUB `linux` line → root shell → `passwd` → *old password rejected, new works*), Rocky **and AlmaLinux**/RHEL **`rd.break`** → `chroot /sysroot` + the easy-to-miss **SELinux `/.autorelabel`** ([RUNBOOK](root-password-reset/RUNBOOK-rd-break.md), both verified end-to-end via `reset-demo-{rocky,almalinux}.sh`), the **systemd debug shell** (faithful tty9 *and* a serial-redirect adaptation), and [**other approaches**](root-password-reset/RUNBOOK-other-approaches.md) (live media, offline disk edit, recovery mode, *why `sulogin` can't help a lost password*). A **BIOS + UEFI** pair shows the reset is firmware-agnostic. The lesson — **console/boot access = root** — with defenses (GRUB password, LUKS, Secure Boot) in the README. Also surfaced the **GRUB serial-input char-drop** gotcha (no flow control → type slowly). ⚠️ throwaway lab creds only (`toor`) — never on a real/networked host. |
| [`FREEBSD-simple-templating-serving-RHEL-kickstart-files/`](FREEBSD-simple-templating-serving-RHEL-kickstart-files/README.md) | 🧩 **A FreeBSD box that kickstart-installs AlmaLinux** — operationalizes **[vermaden's](FREEBSD-simple-templating-serving-RHEL-kickstart-files/upstream-tutorial/README.md)** *"Automated Kickstart Install of RHEL/Clones"* (RHEL 8.5 → **AlmaLinux 9**). The reusable gem is a **rudimentary `sed` templating system** for kickstarts: a skeleton + a per-host config → a rendered `ks.cfg` → an **`OEMDRV`**-labelled ISO Anaconda auto-loads (no PXE, no `inst.ks=`). Driven by **custom QEMU** (no FreeBSD backend in `lab-vm.sh`); FreeBSD server + AlmaLinux client share a rootless qemu **socket LAN**. **VERIFIED on real FreeBSD 14.3 (KVM):** the cloud image boots (and turns out to run **nuageinit**, not cloud-init — a documented detour), `pkg`-provisions nginx+`mkisofs`, **serves a real AlmaLinux repo** over HTTP, and the templating engine renders a kickstart that **`ksvalidator` passes for RHEL9** + builds the OEMDRV ISO on **both Linux and BSD `sed`**. The **client Anaconda install is author-run** (ready-to-run + documented; the install mechanics are proven by [`almalinux-pxe-lab/`](almalinux-pxe-lab/README.md)). [`WALKTHROUGH.md`](FREEBSD-simple-templating-serving-RHEL-kickstart-files/WALKTHROUGH.md) is a first-person, checkpoint-by-checkpoint "how I did it"; `RUNBOOK.md` is the clean walk; `MANUAL_TESTING.md` has the transcripts. ⚠️ throwaway lab creds only (`freebsd`/`freebsd`, kickstart `alma`). |
| [`virtualbmc-ipmi-lab/`](virtualbmc-ipmi-lab/) | 🔌 **Give a VM an IPMI BMC, then PXE-provision it over IPMI** — operationalizes OpenStack **[VirtualBMC](virtualbmc-ipmi-lab/upstream-tutorial/)** (the repo's **first libvirt-based lab** — not `lab-vm.sh`; talks to `qemu:///system` directly). A containerised `vbmcd` fakes a Baseboard Management Controller for a libvirt domain, so `ipmitool -I lanplus … chassis power on\|off\|reset` / `bootdev pxe\|disk` drives the VM like bare metal (`ipmitool` ⟷ `vbmc` ⟷ `virsh` all agree). **Verified end-to-end on KVM:** power round-trip ✅, boot-device + serial console ✅, and the **finale** — IPMI `bootdev pxe` → firmware netboots (libvirt's own dnsmasq DHCP/TFTP + the repo's `:8181` HTTP) → real **AlmaLinux 9 Anaconda** kickstart-installs to disk → poweroff → `bootdev disk` → boots the OS you just provisioned (the OpenStack Ironic lifecycle in miniature). [RUNBOOK](virtualbmc-ipmi-lab/RUNBOOK.md) teaches the **real** `vbmcd`/`vbmc`/`ipmitool` by hand incl. host install (venv+systemd / pipx) per the upstream how-tos; `MANUAL_TESTING.md` has the captured transcripts. Scope notes: VirtualBMC has **no IPMI SOL** (console is `virsh console`); `vbmcd` is **rootful** (the `root:libvirt` socket). ⚠️ throwaway lab creds only (`admin`/`password`, `root`/`alpine`) — loopback only, never a real/networked host. |
| [`linuxboot-uefi-kexec/`](linuxboot-uefi-kexec/README.md) | 🪆 **Boot Linux to boot Linux — firmware is just software** — operationalizes **[LinuxBoot](linuxboot-uefi-kexec/upstream-tutorial/README.md)**: replace the firmware's boot logic with a Linux kernel whose `init` *is* the bootloader (**[u-root](https://github.com/u-root/u-root)**, a Go userland), which then **`kexec`s** the target OS. A tour of the closest-to-the-metal moments of a boot: firmware → kernel → custom `init` → kexec handoff. **Two tiers verified end-to-end on KVM** — **Tier C** ([`POC-MATRYOSHKA.md`](linuxboot-uefi-kexec/POC-MATRYOSHKA.md)): the bare mechanic via `qemu -kernel` (fast loop); **Tier B** ([`POC-UEFI-MATRYOSHKA.md`](linuxboot-uefi-kexec/POC-UEFI-MATRYOSHKA.md)): the same on **genuine UEFI (OVMF/EDK II)** by packaging kernel+u-root+cmdline into a **Unified Kernel Image** that the firmware launches off an ESP at `\EFI\BOOT\BOOTX64.EFI` — a single firmware-flashable EFI blob. Success signature both ways: **two** `Welcome to u-root!` banners + cmdlines `STAGE1→STAGE2` with the `[0.000000]` clock reset (a fresh kernel = the kexec). Reusable gems: the **UKI build with `ukify`/`objcopy`**, and obtaining the UKI toolchain **without `sudo`** (`apt-get download` + `dpkg-deb -x`). **Tier A** (the **canonical** coreboot ROM) is **also verified** — a real `coreboot` q35 ROM whose CBFS payload is linux-6.3 + u-root, booted via `qemu -bios coreboot.rom` (coreboot bootblock→ramstage→Linux→u-root); the ~20-min `crossgcc`+ROM build is author-run but needs no sudo. **Finale verified too** — u-root's `boot` parses a real **Debian 12** disk's GRUB config and **kexecs the installed OS** to a login prompt (coreboot → Linux+u-root → kexec → the disk's own kernel), the production LinuxBoot lifecycle. A [`WALKTHROUGH.md`](linuxboot-uefi-kexec/WALKTHROUGH.md) narrates Tier B and explains **`ukify`**/**`pefile`**. **Network-boot / verified-provisioning track** ([`PLAN-PXEBOOT.md`](linuxboot-uefi-kexec/PLAN-PXEBOOT.md)): u-root `pxeboot` auto-installs **AlmaLinux + Rocky + Kali** from the **real ROM** over HTTP ([P1](linuxboot-uefi-kexec/POC-PXEBOOT.md)), then HTTPS verified against a lab CA ([P2](linuxboot-uefi-kexec/POC-PXEBOOT-P2.md)), culminating in **System Transparency** — an `stboot` UKI (built from source) that boots **only a *signed* OSPKG**, its Ed25519 signature verified vs the shared lab CA, refusing rogue packages ([P3](linuxboot-uefi-kexec/POC-PXEBOOT-P3.md)). The firmware-level capstone to the "close to the metal" family ([`tiny-linux-experiments/`](tiny-linux-experiments/), [`kdump-kexec-lab/`](kdump-kexec-lab/)). |

## 🐳 Docker topologies — Phase 3 (`phase3-docker/lab-docker.sh`)

Declarative rootful container topologies. Grouped under
[`docker-examples/`](docker-examples/README.md) (the netboot server spec lives in
the netboot section below).

| File | What you get |
|---|---|
| `docker-examples/docker-3svc-topology.toml` | nginx + postgres + an idle alpine client on a shared bridge — the Phase 3 showcase. |

## 🦭 Podman, rootless — Phase 4 (`phase4-podman/lab-podman.sh`) 🪶

Rootless container topologies — `plain`, `pod`, and `quadlet` managers. Grouped
under [`podman-examples/`](podman-examples/README.md) (the netboot-server and
PXE-DHCP specs stay flat below — they're reused across the netboot labs).

| File | What you get |
|---|---|
| `podman-examples/podman-plain-single.toml` | The simplest topology: one rootless container, one published port. |
| `podman-examples/podman-pod-3svc.toml` | Three containers sharing a **pod** (one net/IPC/PID namespace; localhost between them). |
| `podman-examples/podman-quadlet-service.toml` | Exports a `.container` **quadlet** unit to systemd-user — survives reboots, auto-restarts. |
| `podman-examples/podman-multiarch-build.toml` | Builds an image for a *foreign* arch via `qemu-user-static` (a `build` step, not `up`). |

## 📦 LXD / Incus — Phase 5 (`phase5-lxd/lab-lxd.sh`)

System containers and hardware VMs under one API, with profiles and projects.
Grouped under [`lxd-examples/`](lxd-examples/README.md).

| File | What you get |
|---|---|
| `lxd-examples/lxd-plain-single.toml` | Smallest useful lab: one Alpine **container**, no profiles/projects. |
| `lxd-examples/lxd-vm-single.toml` | One Alpine **VM** (real QEMU virt under LXD — needs `/dev/kvm` + block storage). |
| `lxd-examples/lxd-mixed-topology.toml` | 2 containers + 1 VM in a single lab — exercises the container/VM discriminator. |
| `lxd-examples/lxd-profiles-projects.toml` | `[[profile]]` + `[[project]]` demo — LXD-native config bundles and namespace isolation. |

Cohesive own-subdir lab built on this layer:

| Lab | What you get |
|---|---|
| [`oils-shell-container/`](oils-shell-container/README.md) | Build **Oils for Unix** (OSH/YSH) from the 0.37.0 source tarball in a throwaway system container — **Debian 13** *and* **Alpine**, GNU readline as a hard dependency (`./configure --with-readline`). Verified end-to-end on both. |
| [`UNIX_novice_survival_guide/`](UNIX_novice_survival_guide/README.md) | A ready **BASH** box for Matt Might's **"survival guide for Unix beginners"** (vendored byte-exact) — tools + a `learner` user + a `~/unix-survival/` sandbox mirroring the guide's examples, on **Debian 13** *and* **Alpine** (which lacks *both* `man` and `ssh` by default). The gentle on-ramp before shell-novice. Verified end-to-end on both. |
| [`shell-novice-workshop/`](shell-novice-workshop/README.md) | A ready **BASH** box for the Software Carpentry **shell-novice** full-day lesson (vendored byte-exact, CC-BY) — tools + a `learner` user + the workshop data, on **Debian 13** *and* **Alpine** (which installs bash + GNU tools over BusyBox). Verified end-to-end on both. |
| [`shell-intermediate-workshop/`](shell-intermediate-workshop/README.md) | A **BASH scripting** box for Daniel Robbins' **"Bash by example"** series (3 vendored PDFs) — tools + a `learner` user + a `~/bash-by-example/` playground, on **Debian 13** *and* **Alpine** (which has *no bash* by default). The programming follow-on to shell-novice. Verified end-to-end on both. |
| [`shell-intermediate-programming-by-example/`](shell-intermediate-programming-by-example/README.md) | A **BASH scripting** box for Matt Might's **"bash: by example, by counter-example"** (vendored byte-exact) — tools + a `learner` user + a `~/bash-by-example/` playground with a runnable starter, on **Debian 13** *and* **Alpine** (no bash by default; ash also lacks arrays + `(( ))`). A Matt-Might alternative to shell-intermediate-workshop. Verified end-to-end on both. |
| [`AI-build-a-perceptron/`](AI-build-a-perceptron/README.md) | A **Python 3** box for Matt Might's **"Hello, Perceptron"** neural-net intro (vendored byte-exact) — `python3` + a `learner` user + a `~/hello-perceptron/` starter that **trains a perceptron from scratch** (AND/OR learn, XOR provably cannot), on **Debian 13** *and* **Alpine** (neither ships Python; Debian has no bare `python`, Alpine does). Verified end-to-end on both. |
| [`UNIX-sculpting-text-regex-grep-sed-awk/`](UNIX-sculpting-text-regex-grep-sed-awk/README.md) | A **grep/sed/awk** box for Matt Might's **"Sculpting text with regex, grep, sed and awk"** (vendored byte-exact) — the **GNU** text trio + a `learner` user + a `~/sculpting-text/` sandbox (sample data + a runnable `demo.sh`) + `/usr/share/dict/words`, on **Debian 13** *and* **Alpine** (default tools are BusyBox/mawk, not GNU). Verified end-to-end on both. |
| [`linux-proc-vfs-internals/`](linux-proc-vfs-internals/README.md) | 🔬 A **C + `/proc`** box for Ciro S. Costa's six-part **[ops.tips](linux-proc-vfs-internals/upstream-tutorial/README.md)** `/proc` series (vendored byte-exact), in **three container sets** on **Debian 13** *and* **Alpine**, each with a `learner` + `~/proc-lab/` sandbox. **Set A** (unlimited) — *What is /proc?* + *list PIDs*: `open-fd.c` and a **raw-`getdents64`** `list-pids.c`; procfs as a **VFS** (size-0 files generated on read; PID-namespaced). **Set B** (512 MiB-capped) — *top/free wrong memory* + *resource limits*: `mem-hog.c` (**cgroup-v2 OOM-kill**) + `limit-open-files.c` (**`prlimit()`**, `EPERM` on hard-raise), **lxcfs** rewriting `/proc/meminfo` to the cap. **Set C** (gdb/strace debug box) — *stack traces* + *sockets*: `accept.c` blocked in the kernel shows **`/proc/<pid>/wchan` = `inet_csk_accept`** (full `stack` is host-only), `socket.c` shows **`socket:[inode]`** fds + climbing `sockstat`. Divergences: Alpine needs `linux-headers`; glibc `openat` vs musl/BusyBox `open`. Verified end-to-end, all six base×set combos. |
| [`tiny-internet-project/`](tiny-internet-project/README.md) | 🌐 A **self-contained internet** — John S. Tonello's 3-part **[Tiny Internet Project](tiny-internet-project/upstream-tutorial/)** (Linux Journal, byte-exact vendored) rebuilt as **six Debian 13 containers** on a private bridge: authoritative **BIND9 DNS primary + secondary (real AXFR zone transfer)**, an **apt-cacher-ng** package source, **Postfix + Dovecot** mail, and **LAMP + phpMyAdmin** — all on `tiny.lab` / `10.128.1.0/24`. One `tiny-internet.sh` driver (`up`/`provision`/`verify`) over `lab-lxd.sh`. Documents 10 sharp **Debian-13-vs-Ubuntu-14.04** divergences (Dovecot 2.4 `mail_location`/`mail_inbox_path`, `named` not `bind9`, no `lamp-server^`, dnsmasq-vs-BIND, …). **Verified end-to-end** (ALL PROBES PASSED). ⚠️ throwaway creds, no TLS — NAT bridge only. |

> **Suggested learning order** (formalized as the generated
> [**Shell fluency** path](learning-paths/path-shell-fluency.md), with a
> checkpoint per lab). Two self-contained tracks of the same
> novice → intermediate arc, by different authors:
> - **Matt Might:** [survival guide](UNIX_novice_survival_guide/README.md) → [bash by example](shell-intermediate-programming-by-example/README.md) → [sculpting text](UNIX-sculpting-text-regex-grep-sed-awk/README.md) — *find your feet at the shell, program it, then wield grep/sed/awk on real text.* (Might names the survival guide as the prerequisite to bash-by-example.)
> - **Carpentries + Robbins:** [shell-novice](shell-novice-workshop/README.md) → [shell-intermediate-workshop](shell-intermediate-workshop/README.md) — a full-day hands-on lesson, then the "Bash by example" PDF series.
>
> [`oils-shell-container/`](oils-shell-container/README.md) is orthogonal — it *builds* a shell rather than teaching one. [`AI-build-a-perceptron/`](AI-build-a-perceptron/README.md) is a Matt-Might **bonus in a different subject** — once you can program the shell, the same author builds a neural network from scratch in ~40 lines of **Python**; same vendor-the-page-and-build-the-sandbox shape, not a shell lab. [`linux-proc-vfs-internals/`](linux-proc-vfs-internals/README.md) is another such bonus — same shape, aimed at **systems internals** (what `/proc` *is*, in C + `strace`) by a different author.

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
| [`floppinux/`](tiny-linux-experiments/floppinux/) | Krzysztof Jankowski's **FLOPPINUX** — a whole Linux on a 1.44 MB floppy — operationalized for Debian. A standalone, **rootless** `build-floppinux.sh` cross-builds kernel 6.14.11 + static BusyBox 1.36.1, packs an XZ initramfs (device nodes via `fakeroot`), and writes a `syslinux` FAT floppy you boot with `qemu-system-i386 -fda -cpu 486`. The "physical floppy + syslinux" cousin of the in-RAM micro-linux track; no `lab-vm.sh` TOML (it has no `-fda` backend). Ships `ARTIFACTS.md` (artifact map + data-flow graph), `MANUAL_TESTING.md` (verified pass/fail runbook), `QUALITY_OF_LIFE.md` (add shell niceties live, then `QOL=1`), and knobs: `FLOPPY_KB` (1440/1680/2880), `BUSYBOX_FULL` (~400 applets), `QOL` (login shell + profile/passwd/hostname). ⚠️ throwaway — boots to a passwordless root shell, no networking. |
| [`floppinux/floppinux-2.88mb/`](tiny-linux-experiments/floppinux/floppinux-2.88mb/) | The **2.88 MB extended-density** FLOPPINUX variant (the `FLOPPY_KB=2880` knob) — a `build-2.88.sh` wrapper + differential README/MANUAL_TESTING. ~1.7 MiB free (vs 264 KiB), boots in QEMU as `fd0 is 2.88M`. Verified end-to-end. Home of the `BUSYBOX_FULL=1` option (the whole ~400-applet BusyBox toolbox, which only fits the bigger floppy). |
| [`minimal-arm-linux-qemu/`](tiny-linux-experiments/minimal-arm-linux-qemu/) | David Corvoysier's **[*Build and boot a minimal Linux system with qemu*](tiny-linux-experiments/minimal-arm-linux-qemu/upstream-tutorial/README.md)** (kaizou.org, 2016, CC BY-NC-SA 3.0) operationalized for a modern Debian host. A rootless `build-minimal-arm.sh` shallow-clones **Linux 6.1** (the last kernel that still carries `mainstone_defconfig` before PXA went device-tree-only), cross-compiles it with Debian's `arm-linux-gnueabi` toolchain, hand-writes the post's **static C `/init`** (`printf("Tiny init ...")`), packs an initramfs (`/dev/console` via `fakeroot`), and boots `qemu-system-arm -M mainstone` (PXA270) to that one line. The **ARM cross-compile** cousin of the from-source micro-linux/floppinux tracks — a from-scratch kernel running a single static binary as PID 1, no BusyBox/shell/net. Vendored byte-exact tutorial + `MANUAL_TESTING.md`; build verified rootless (GCC 10), boot verified on qemu 8.2.2. ⚠️ throwaway toy (no shell, cannot be logged into). |
| [`micro_linux_dhcp_lease/`](tiny-linux-experiments/micro_linux_dhcp_lease/) | The networking demo: the from-source distro pulls a **DHCP lease** over a virtio NIC. One `micro-linux-<arch>-dhcp.toml` per arch — x86_64/aarch64/ppc64le/s390x auto-bring-up via BusyBox `udhcpc` (opt-in `mllab.net` token; ppc64le/s390x need a `WITH_EXTRA_ARCHES=1` build), riscv64 runs u-root's `dhclient` at the shell. ⚠️ root has a well-known password — see its README + AUDIT F1. |

## 🚶 Hand-walk the tutorials — follow the upstream post by hand in a box

The inverse of the automated `build-*.sh` pipelines: a **disposable container that
reproduces the tutorial author's own environment** (their distro + the exact
prerequisites + an in-box QEMU where the recipe needs one), so you type the steps
yourself and watch each stage. Each pairs with the byte-exact `upstream-tutorial/`
archive it walks ([provenance convention](../CLAUDE.md)). Driven through the
existing phase tools via a `build =` Containerfile — no one-off images. (TODO #3.)

| Lab | What you hand-walk |
|---|---|
| [`micro-linux/hand-walk/`](../micro-linux/hand-walk/) | Uros Popovic's *Making a micro Linux distro* on the author's own **Debian** box (riscv64 cross-toolchain + `qemu-system-riscv64`). Build a kernel from source, watch it panic with no rootfs, hand-write a static `init.c` → "Hello world", fork a Go `little_shell`, then a real **u-root** shell — all in a rootless Phase-4 container. [`RUNBOOK.md`](../micro-linux/hand-walk/RUNBOOK.md) mirrors the post stage by stage; verified end-to-end. |
| [`phase1-chroot/hand-walk/`](../phase1-chroot/hand-walk/) | Alex Bradbury's *Rootless cross-architecture debootstrap* (muxup.com). Build a **foreign-arch** (riscv64) Debian rootfs with **no root** — `fakeroot` + `unshare -Ur` + `qemu-user-static` two-stage debootstrap — then optionally boot it as a full systemd VM. Rootless container, launched `--cap-add SYS_ADMIN` so it can register `binfmt` in-box (the post's host gets that from `apt install qemu-user-static`). The learning counterpart to [`lab-chroot.sh --rootless`](../phase1-chroot/lab-chroot.sh); [`RUNBOOK.md`](../phase1-chroot/hand-walk/RUNBOOK.md) verified end-to-end (`uname -m → riscv64`). |
| [`debian-http-boot/hand-walk/`](debian-http-boot/hand-walk/) | Kenneth Finnegan's *Booting Linux over HTTP*. The **server-side build**: `fakeroot debootstrap` a whole Debian system, pack it into one gzipped-cpio initramfs (Kenneth's exact `find \| cpio \| gzip`), build an iPXE ROM with an embedded boot script, and serve kernel+initrd over HTTP (:8181). Artifacts land in a bind-mounted `out/`; the **client** is the existing [`vm-debian-http-boot.toml`](debian-http-boot/vm-debian-http-boot.toml). [`RUNBOOK.md`](debian-http-boot/hand-walk/RUNBOOK.md) — rootfs+initrd+iPXE build verified in-box. |
| [`almalinux-pxe-lab/hand-walk/`](almalinux-pxe-lab/hand-walk/) | Kenneth Finnegan's *zero-touch AlmaLinux PXE install*. The **PXE-server build**: compile an iPXE **EFI** binary with an embedded script (`EMBED=almascript.ipxe`) that DHCPs → chainloads the AlmaLinux installer over HTTP → feeds Anaconda a kickstart; plus a `dnsmasq` ProxyDHCP/TFTP responder for real hardware (Path B). Reuses the lab's installer-fetcher + kickstarts; the **install target** is the existing [`vm-almalinux-pxe-install.toml`](almalinux-pxe-lab/vm-almalinux-pxe-install.toml). [`RUNBOOK.md`](almalinux-pxe-lab/hand-walk/RUNBOOK.md) — iPXE EFI build + dnsmasq config verified in-box. |
| [`rocky-pxe-lab/hand-walk/`](rocky-pxe-lab/hand-walk/) | The CIQ KB article's **Lorax + dnsmasq + TFTP** route, in a **Rocky Linux** box: `lorax` builds the PXE boot images, `dnsmasq` serves DHCP+TFTP, HTTP serves the install tree + kickstart. ⚠️ the **Lorax run is author-only** here (it needs loop/`mknod`, blocked in this sandbox — run it on your host with `--privileged`); the box, `lorax`/`dnsmasq`/`tftp-server` presence, and dnsmasq config are verified. Install target = existing [`rocky-pxe-lab.toml`](rocky-pxe-lab/rocky-pxe-lab.toml). [`RUNBOOK.md`](rocky-pxe-lab/hand-walk/RUNBOOK.md). |
| [`kali-llm-lab/hand-walk/`](kali-llm-lab/hand-walk/) | The Kali blog *Ollama & 5ire* **server side**, in a **Kali** box: install Ollama the post's way (fetch + sha512-verify + unpack), run a model **on CPU**, expose Kali's tools via `mcp-kali-server`. ⚠️ **authored, you-build** — multi-GB Kali base + model, and Ollama is a fetch-and-exec you authorize on your own machine (RUNBOOK §1 verifies it). Turnkey, verified counterpart = the Phase-4 pod [`kali-llm-lab.toml`](kali-llm-lab/kali-llm-lab.toml); the 5ire GUI client = [`kali-llm-desktop-lab/`](kali-llm-desktop-lab/). [`RUNBOOK.md`](kali-llm-lab/hand-walk/RUNBOOK.md). |
| [`tiny-linux-experiments/floppinux/hand-walk/`](tiny-linux-experiments/floppinux/hand-walk/) | Krzysztof Jankowski's *FLOPPINUX* — a whole bootable Linux on a 1.44 MB floppy — in an **Arch** box (the author's distro). Cross-build a kernel + static musl BusyBox, pack an XZ initramfs, write a syslinux floppy, boot `qemu-system-i386 -fda`. ⚠️ two **author-only** steps here: the **musl.cc toolchain fetch + compile** (fetch gate) and the **`mknod`/loop-mount floppy** (sandbox blocks devices) — both run on your host (`--privileged`); the Arch build environment is verified. Automated route: [`build-floppinux.sh`](tiny-linux-experiments/floppinux/build-floppinux.sh). [`RUNBOOK.md`](tiny-linux-experiments/floppinux/hand-walk/RUNBOOK.md). |

## 🌉 Cross-phase bridges — build once, run elsewhere

Take a Phase-1 chroot and turn it into a VM or a container image. Build the
chroot first, then point the target phase at the same artifact.

| File | What you get |
|---|---|
| `vm-examples/vm-from-chroot-debian.toml` | Chroot → bootable BIOS qcow2 (MBR + extlinux + ext4) for Phase 2. |
| `podman-examples/podman-from-chroot.toml` | Chroot → a rootless Podman image (e.g. import a Kali minbase tree). |
| `lxd-examples/lxd-from-chroot.toml` | Chroot → a Phase 5 LXD/Incus container image. |
| [`offsec-awae-vm/`](offsec-awae-vm/) | 🔒 End-to-end **automated** chroot→VM: a Kali `kali-rolling` chroot carrying the **OffSec AWAE (WEB-300)** toolset, made self-bootable (kernel + init + SSH) and packaged into a headless BIOS VM by `from-chroot`. `build-vm.sh` chains both phases + boots it (serial/SSH); `--smoke` proves the pipeline first. Chroot-level take on Kali's `offsec-awae-live.sh` live-build recipe. ⚠️ offensive tooling — authorized targets only. |
| [`rhel-bootc-minimal/`](rhel-bootc-minimal/) | 🥾 **Build a custom *minimal* bootc base image, then boot it** — a faithful walk of Red Hat's *[Creating bootc images from scratch](rhel-bootc-minimal/upstream-tutorial/)* (RHEL 9 image mode). Use the base image's `bootc-base-imagectl build-rootfs --manifest=minimal` to compose a *bootc + systemd + kernel + dnf* rootfs, `COPY` it into `FROM scratch`, add only `NetworkManager`/`openssh-server`, and get a bootable image **~59% smaller** than the stock base — then `bootc install to-disk` it to a qcow2 and boot it as a real OS in Phase 2. Keeps the byte-faithful `Containerfile.rhel` (`registry.redhat.io`, subscription) **and** a verified `Containerfile.centos` (CentOS Stream 9, RHEL's upstream) side by side. **VERIFIED end-to-end on podman 4.9.3 + KVM** (1.98 GB → 812 MB; `bootc container lint` ✓; serial login shows a real `ostree=` boot of the image's own kernel). `RUNBOOK.md` reproduces §9.1–§9.5; `MANUAL_TESTING.md` captures the §9.3 build-privilege ladder, the heredoc/EPEL gotchas, and the **four boot gotchas** (`--rootfs`, the missing `bubblewrap`, root locked, the rootless→root storage trap). ⚠️ build needs `--cap-add=all … --device /dev/fuse`; boot install needs `sudo`. |

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
| `docker-examples/docker-netboot-server.toml` | Rootful Docker nginx serving the netboot artifacts on :8181. |
| `podman-netboot-server.toml` | 🪶 The rootless Podman equivalent — preferred when you only need to serve. |
| `podman-pxe-dhcp.toml` | 🔑 Rootless Podman `dnsmasq` in **ProxyDHCP + TFTP** mode for **real-hardware** PXE: adds TFTP-server + bootfile info to PXE requests (DHCP option 60) without replacing your LAN's existing DHCP server. Needs `--network=host` to hear DHCP broadcasts (so run with `sudo`); pairs with a serve spec above for the HTTP side. QEMU testing uses `[[vm]] pxe_dir` instead — no dnsmasq. |
| [`lab-ca/`](lab-ca/README.md) | 🔐 **Shared lab root CA** — one reusable trust anchor for *real* (non-`-k`) HTTPS + signed artifacts across labs. `make-ca.sh` (idempotent ECDSA root), `issue-server-cert.sh <cn>` (TLS leaf, SANs), `issue-signing-cert.sh <name>` (Ed25519 signing leaf, e.g. for System-Transparency OSPKGs). Public `lab-ca.crt` + fingerprint **tracked**; private keys **gitignored** — the teachable PKI split. Consumed by the LinuxBoot HTTPS + System-Transparency tiers ([`linuxboot-uefi-kexec/PLAN-PXEBOOT.md`](linuxboot-uefi-kexec/PLAN-PXEBOOT.md) P2/P3). |
| [`debian-http-boot/`](debian-http-boot/) | 🔗 Self-contained clone of Kenneth Finnegan's *“Booting Linux over HTTP”* on **Debian 13 trixie**: a full systemd rootfs run **entirely from RAM** via his **verbatim** hand-rolled `/init` (`exec /sbin/init`, no `switch_root`). README explains *why* the initramfs-as-rootfs hand-off works; a `MANUAL_TESTING.md` runs each piece + the full boot with real captured output. The teaching twin of `chroot-netboot-full.toml` (same blog, bookworm). |
| [`pxe-boot-mechanics/`](pxe-boot-mechanics/) | PXE **boot-mechanics** demos (how a VM boots, not what it installs): `vm-pxe-tftp-boot.toml` (DHCP+TFTP delivery) and `vm-pxe-secureboot.toml` (UEFI Secure Boot enforced, snakeoil-signed iPXE). Both reuse `netboot/build-ipxe.sh`. Plus `tools/` — hand-driven TFTP/HTTP fetch probes (`pxe-fetch.sh` + vendored `socwrap.sh`) to watch & record the transport steps. |
| [`almalinux-pxe-lab/`](almalinux-pxe-lab/) | 🔗 Self-contained AlmaLinux 9 zero-touch PXE lab in its own directory: fetch+verify installer (checksums from `.treeinfo`), kickstart (rendered per-host; **plaintext lab creds**), unified P4+P2 TOML, README with the QEMU path **and** real-hardware notes, and a `MANUAL_TESTING.md` walking the full Anaconda install. The Rocky twin. Now also houses the **UEFI / aarch64 / standalone-BIOS** variant configs (`vm-almalinux-*.toml` + matching `*-zerotouch.ks`) and the `nginx-ks-fallback.conf` snippet. |
| [`rocky-pxe-lab/`](rocky-pxe-lab/) | 🔗 Self-contained Rocky Linux 9 zero-touch PXE lab in its own directory: fetch+verify installer (checksums from `.treeinfo`), kickstart, unified P4+P2 TOML, and a README with both the QEMU path **and** the CIQ-style real-hardware dnsmasq/TFTP path. Plus a `MANUAL_TESTING.md` walking the full ~15-min Anaconda install. |
| [`libvirt-ipxe-http-pxe/`](libvirt-ipxe-http-pxe/README.md) | 🔗 **PXE-boot an installer over HTTP only — no TFTP** — operationalizes **[Dusty Mabe's](libvirt-ipxe-http-pxe/upstream-tutorial/README.md)** two posts on easy PXE testing with **iPXE + libvirt**. The gem: **libvirt's netboot firmware _is_ iPXE, which fetches the DHCP bootfile over HTTP**, so an `http://` URL in the network's `<bootp file=…>` makes the whole flow (bootfile, kernel, initrd, kickstart, DVD repo) come off one `python3 -m http.server` — no TFTP. Two variants: `pxelinux` (bootfile = `pxelinux.0`) and the punchline **`minus-pxelinux`** (bootfile = a `#!ipxe` script iPXE runs natively). A rootless `setup-pxe-http.sh` (stage/serve/netxml/virtinstall) **extracts the ISO with `xorriso`** instead of a sudo loop-mount and only ever *prints* the libvirt-mutating steps. **Rootless half verified** (2026-07-02): ISO extract, config gen for both variants, every iPXE/Anaconda fetch path HTTP-200, generated net XML valid (`xmllint`) with `<bootp>` injected, and `virt-install --dry-run` green (caught the modern **`--osinfo` requirement**). The libvirt half (apply net XML + run VM) is **yours to run** — the second libvirt lab, alongside [`virtualbmc-ipmi-lab/`](virtualbmc-ipmi-lab/). Plus an [`https/`](libvirt-ipxe-http-pxe/https/README.md) extension: a custom iPXE (HTTPS re-enabled for BIOS + `TRUST=lab-ca.crt` baked in) that fetches kernel+initrd over **TLS verified against the shared [lab CA](lab-ca/README.md)** — verified rootless in qemu, **positive and negative** (rogue cert → iPXE refuses). ⚠️ throwaway (`rootpw foobar`, wipes the VM disk; edits the `default` net — restore printed). |
| [`kali-pxe-lab/`](kali-pxe-lab/) | 🔗 Self-contained Kali Linux zero-touch PXE lab: the **Debian-installer + preseed** cousin (not Anaconda/kickstart). Fetch+verify d-i `linux`/`initrd.gz` (checksums from `SHA256SUMS`), preseed, unified P4+P2 TOML, README with the QEMU path **and** the Kali-docs `netboot.tar.gz` + dnsmasq/TFTP/PXELINUX path. Plus a `MANUAL_TESTING.md` walking the full ~15-min d-i install — incl. the one install-breaking risk (d-i clobbering the iPXE ROM disk) and how the `vda` pinning closes it. |
| [`kali-preseed-gallery/`](kali-preseed-gallery/) | 🔗 The **pick-a-variant** companion to `kali-pxe-lab`: fetches the *whole* upstream [Kali preseed-examples catalog](https://gitlab.com/kalilinux/recipes/kali-preseed-examples) (~15 variants — xfce/kde/gnome/headless × regular/lvm/crypto/multi/skip-wipe/packer) and installs any one zero-touch via QEMU **`pxe-install`** (BIOS: the NIC's iPXE ROM runs `boot.ipxe`), selectable with `select-preseed.sh <variant>`. `fetch-preseeds.sh` stages each verbatim **and** auto-patches `/dev/sda`→`/dev/vda` for the virtio target (`--verbatim` to opt out). `headless-default` boot-verified end-to-end on KVM; `MANUAL_TESTING.md` has the fetch/patch checks. |
| [`debian-pxe-lab/`](debian-pxe-lab/) | 🔗 Self-contained **Debian 13 (trixie)** zero-touch PXE lab — the **upstream** of the d-i+preseed family (`kali-pxe-lab` is the same machinery on an offensive distro). Fetch+verify trixie d-i `linux`/`initrd.gz` (checksums from `SHA256SUMS`, optional `--verify-sig` GPG check), a preseed **distilled from Debian's official [`example-preseed.txt`](debian-pxe-lab/upstream-preseed/README.md)** (vendored byte-exact; **plaintext lab creds** root/`lab`, `debian`/`debian`), unified P4+P2 TOML, README with the QEMU path **and** the `netboot.tar.gz` real-hardware path. **Verified end-to-end on KVM** (trixie, kernel 6.12, atomic `vda1`+swap, `apt` not `dnf`); `MANUAL_TESTING.md` has the real transcript + the d-i network-preseed hostname quirk. |
| [`debian-preseed-gallery/`](debian-preseed-gallery/) | 🔗 The **pick-a-variant** companion to `debian-pxe-lab`: since Debian ships **one** official example (not a Kali-style upstream catalog), `fetch-preseeds.sh` **generates** six partitioning variants — `regular-atomic`/`-home`/`-multi`, `lvm-atomic`, `crypto-atomic` (LUKS→LVM, passphrase `labcrypto`), `minimal` (tasksel off) — by stamping the official example's own documented `method`/`recipe` options into `base-preseed.cfg`, each `/dev/vda`-pinned. Select with `select-preseed.sh <variant>`. **`lvm-atomic` + `crypto-atomic` boot-verified end-to-end on KVM** (LVM VG + LUKS container in `lsblk`); `MANUAL_TESTING.md` has both transcripts. The derive-from-official contrast to Kali's fetch-a-catalog gallery. |
| [`debian-hands-off-install/`](debian-hands-off-install/README.md) | 🔗 Operationalizes **Philip Hands' [Hands-Off](https://hands.com/d-i/)** — a Debian Developer's canonical d-i preseed **framework** (fetched + pinned, not vendored, like `kali-vm-builder`). Unlike the static-preseed labs, the entry `preseed.cfg` is nearly empty and **chains** via `preseed/run` → `checksigs.sh` (**gpgv** bootstraps trust from a signed `MD5SUMS`) → `start.sh` → `assemble_preseed.sh`, which **composes** the real preseed live from a tree of per-**class** fragments selected by `auto-install/classes=`. `fetch-hands-off.sh` clones it; `setup-hands-off.sh` stages it + a lab `local/` overlay and **re-signs with a throwaway lab key**. **Verified end-to-end on KVM** (trixie; `partition/atomic` → LVM; the framework's tell-tale `molly-guard`/`pwgen` defaults). Two findings documented: `hands-off/checksigs=false` is **broken on trixie** (signing is load-bearing — no `preseed_lookup_checksum` without it), and the framework's host-absolute `/files`+`/classes`+`/local` fetches need docroot symlinks. The framework sibling of `debian-pxe-lab`/`debian-preseed-gallery`. |
| [`rocky-kickstart-gallery/`](rocky-kickstart-gallery/) | 🔗 The **Rocky/Anaconda** sibling of `kali-preseed-gallery`: fetches the *whole* upstream [rocky-linux/kickstarts](https://github.com/rocky-linux/kickstarts) **r9** catalog (~34 variants — GenericCloud/EC2/Azure/OCP/Vagrant/Workstation/KDE/XFCE/MATE/Cinnamon/Container/RPI) and installs any disk-installing one zero-touch via QEMU **`pxe-install`** (NIC's iPXE ROM runs `boot.ipxe`), selectable with `select-kickstart.sh <variant>`. `fetch-kickstarts.sh` stages each verbatim under `raw/` **and** patches the image-build `shutdown`→`reboot` + unlocks root (`root`/`lab`, `--no-unlock-root` to opt out); disk refs are already `/dev/vda` (no patch needed, unlike Kali). `GenericCloud-Base` boot-verified end-to-end on KVM; `MANUAL_TESTING.md` has the fetch/patch checks. |
| [`almalinux-kickstart-gallery/`](almalinux-kickstart-gallery/) | 🔗 The **AlmaLinux/Anaconda** counterpart of `rocky-kickstart-gallery`: fetches AlmaLinux's image-build kickstarts from [AlmaLinux/cloud-images](https://github.com/AlmaLinux/cloud-images) `http/` (5 variants — gencloud/oci/gcp/azure/vagrant) and installs any one zero-touch via QEMU **`pxe-install`**, selectable with `select-kickstart.sh <variant>`. Unlike Rocky, these are *Packer* kickstarts hardcoding **`/dev/sda`** — so `fetch-kickstarts.sh`'s `/dev/sda`→`/dev/vda` + `onpart=sda`→`onpart=vda` rewrite is **load-bearing** (fails closed if any `sda` survives); it also drops `reboot --eject`→`reboot` and normalises the already-unlocked root to `root`/`lab` (`--no-unlock-root` to keep upstream `almalinux`). Reuses `almalinux-pxe-lab/fetch-almalinux-installer.sh`. `gencloud` boot-verified end-to-end on KVM; `MANUAL_TESTING.md` has the fetch/patch checks. |

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
| [`debian-pxe-lab/debian-pxe-lab.toml`](debian-pxe-lab/) | 🔗 The Debian trixie zero-touch PXE lab: serve (P4) + install-target VM (P2) via debian-installer + preseed. Self-contained dir — see `debian-pxe-lab/README.md`. |
| [`debian-preseed-gallery/debian-preseed-gallery.toml`](debian-preseed-gallery/) | 🔗 The Debian preseed **gallery**: serve (P4) + install-target VM (P2), with any of six partitioning variants generated from Debian's official example, selectable via `select-preseed.sh`. Self-contained dir — see `debian-preseed-gallery/README.md`. |
| [`debian-hands-off-install/debian-hands-off-lab.toml`](debian-hands-off-install/) | 🔗 The Hands-Off framework install lab: serve (P4) + install-target VM (P2) driven by Phil Hands' chained/class-composed preseed. Self-contained dir — see `debian-hands-off-install/README.md`. |
| [`rocky-kickstart-gallery/rocky-kickstart-gallery.toml`](rocky-kickstart-gallery/) | 🔗 The Rocky kickstart **gallery**: serve (P4) + install-target VM (P2), with any of ~34 upstream Rocky-9 kickstarts selectable via `select-kickstart.sh`. Self-contained dir — see `rocky-kickstart-gallery/README.md`. |
| [`almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml`](almalinux-kickstart-gallery/) | 🔗 The AlmaLinux kickstart **gallery**: serve (P4) + install-target VM (P2), with any of the 5 upstream AlmaLinux-9 image kickstarts selectable via `select-kickstart.sh`. Self-contained dir — see `almalinux-kickstart-gallery/README.md`. |

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

*New here? Start with `chroot-examples/chroot-debian-bookworm.toml` or `vm-examples/vm-debian-amd64.toml`
for a feel, then jump to `netboot-lab.toml` or `lab-unified-demo.toml` to watch
one file light up several phases at once. Each phase also ships a `SHOWCASE.md`
with copy-pasteable tours.*
