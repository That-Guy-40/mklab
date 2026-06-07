# LAB_CREATE_V2 — Manual Testing Guide

Tests are ordered from fastest (no daemon, no root) to slowest (full builds,
network operations). Each test lists its prerequisites, the exact command to
run, and what a passing result looks like.

**Legend**
- `(root)` — requires `sudo` or root shell
- `(kvm)` — benefits from KVM; works without it but is slow
- `(lxd)` — requires a running LXD/Incus daemon
- `(net)` — downloads from the internet
- `⚡` — runs in under 30 seconds
- `🐢` — takes several minutes

---

## 0. Prerequisites

```bash
# Confirm all phase scripts are executable and report their version
phase1-chroot/lab-chroot.sh   version
phase2-qemu-vm/lab-vm.sh      version
phase3-docker/lab-docker.sh   version
phase4-podman/lab-podman.sh   version
# phase5-lxd/lab-lxd.sh      version   # if LXD is installed

# Confirm host tools
qemu-system-x86_64 --version
jq          --version
python3 -c "import tomllib; print('tomllib OK')"

# KVM availability (optional but recommended)
ls -l /dev/kvm && echo "KVM: yes" || echo "KVM: no (will use TCG — slower)"

# Netboot dir for later tests
mkdir -p ~/netboot/ks
```

**All TOML files must parse without error:**

```bash
for f in examples/*.toml; do
    python3 -c "import tomllib; tomllib.load(open('$f','rb'))" \
        && echo "OK $f" || echo "FAIL $f"
done
```

Expected: every line prints `OK examples/...`.

---

## 1. Phase 1 — Chroot (lab-chroot.sh)

### 1.1 Help and list ⚡

```bash
phase1-chroot/lab-chroot.sh help
phase1-chroot/lab-chroot.sh list
```

Pass: help text prints usage; list exits 0 (may show empty table if no chroots
exist yet).

### 1.2 Busybox jail via host-copy ⚡ (root)

The fastest chroot to build — no debootstrap, just copies host binaries.

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --config examples/chroot-host-copy-busybox.toml
```

Verify:

```bash
sudo phase1-chroot/lab-chroot.sh list
sudo phase1-chroot/lab-chroot.sh verify busybox-jail   # name from TOML
```

```bash
sudo phase1-chroot/lab-chroot.sh enter busybox-jail -- busybox sh -c 'echo hello from jail'
```

Expected output: `hello from jail`

```bash
sudo phase1-chroot/lab-chroot.sh inspect busybox-jail
sudo phase1-chroot/lab-chroot.sh destroy busybox-jail
```

Pass: no errors at any step; inspect shows backend=host-copy.

---

### 1.3 Debian debootstrap (minimal, netboot-ready) 🐢 (root, net)

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --config examples/chroot-netboot-busybox.toml
```

Takes ~2 minutes. Verify:

```bash
sudo phase1-chroot/lab-chroot.sh enter netboot-busybox -- ip --version
sudo phase1-chroot/lab-chroot.sh enter netboot-busybox -- curl --version
sudo phase1-chroot/lab-chroot.sh inspect netboot-busybox
```

Pass: `ip` and `curl` respond inside the chroot; inspect shows
`init_script=busybox` and hostname `netboot-busybox`.

### 1.4 export-initrd (busybox variant) ⚡ (root, needs 1.3)

```bash
sudo phase1-chroot/lab-chroot.sh export-initrd netboot-busybox \
    --kernel ~/netboot/kernel \
    --output ~/netboot/initrd.gz
ls -lh ~/netboot/kernel ~/netboot/initrd.gz
```

Pass: both files exist; `initrd.gz` is in the 100–200 MB range (compressed);
`file ~/netboot/initrd.gz` reports `gzip compressed data`.

### 1.5 export-tarball ⚡ (root, needs 1.3)

```bash
sudo phase1-chroot/lab-chroot.sh export-tarball netboot-busybox \
    --output /tmp/netboot-busybox.tar.gz
ls -lh /tmp/netboot-busybox.tar.gz
```

Pass: file created; `file` reports `gzip compressed data`.

Cleanup:

```bash
sudo phase1-chroot/lab-chroot.sh destroy netboot-busybox
```

### 1.6 Full Debian systemd chroot 🐢 (root, net)

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --config examples/chroot-netboot-full.toml
```

Takes ~10 minutes (includes locales-all, cloud-init, SSH). Verify:

```bash
sudo phase1-chroot/lab-chroot.sh enter netboot-full -- systemctl --version
sudo phase1-chroot/lab-chroot.sh enter netboot-full -- locale
sudo phase1-chroot/lab-chroot.sh enter netboot-full -- hostname
```

Pass: systemd version prints; locale shows `LANG=en_US.UTF-8`; hostname
shows `netboot-full`.

```bash
sudo phase1-chroot/lab-chroot.sh export-initrd netboot-full \
    --kernel ~/netboot/kernel-full \
    --output ~/netboot/initrd-full.gz
ls -lh ~/netboot/kernel-full ~/netboot/initrd-full.gz
```

Pass: `initrd-full.gz` is 400–500 MB (the locales-all bulk).

---

## 2. Phase 2 — QEMU VMs (lab-vm.sh)

### 2.1 Help and list ⚡

```bash
phase2-qemu-vm/lab-vm.sh help
phase2-qemu-vm/lab-vm.sh list
```

### 2.2 Alpine disk-image VM (native x86_64) 🐢 (kvm, net)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-alpine-amd64.toml
phase2-qemu-vm/lab-vm.sh list
phase2-qemu-vm/lab-vm.sh start vm-alpine-amd64
```

Wait ~30 seconds for boot. Then:

```bash
phase2-qemu-vm/lab-vm.sh ssh vm-alpine-amd64 -- uname -a
phase2-qemu-vm/lab-vm.sh ssh vm-alpine-amd64 -- cat /etc/os-release
phase2-qemu-vm/lab-vm.sh inspect vm-alpine-amd64
```

Pass: `uname -a` prints `Linux ... x86_64`; `os-release` shows Alpine;
inspect shows backend=disk-image, accel=kvm (or tcg).

```bash
phase2-qemu-vm/lab-vm.sh stop   vm-alpine-amd64
phase2-qemu-vm/lab-vm.sh destroy vm-alpine-amd64
```

### 2.3 Microvm (Alpine, minimal machine type) 🐢 (kvm, net)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/tiny-linux-experiments/microvm-alpine.toml
phase2-qemu-vm/lab-vm.sh start  microvm-alpine
phase2-qemu-vm/lab-vm.sh ssh    microvm-alpine -- cat /proc/cpuinfo | grep 'model name'
phase2-qemu-vm/lab-vm.sh stop   microvm-alpine
phase2-qemu-vm/lab-vm.sh destroy microvm-alpine
```

Pass: SSH succeeds; `/proc/cpuinfo` responds. If microvm machine type is
active, `dmesg` will show `microvm` in the machine type line.

### 2.4 Foreign-arch VM (aarch64 on x86_64) 🐢 (TCG, net)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-debian-aarch64.toml
phase2-qemu-vm/lab-vm.sh start  vm-debian-aarch64
```

Expect this to take 3–5 minutes to boot under TCG emulation.

```bash
phase2-qemu-vm/lab-vm.sh ssh vm-debian-aarch64 -- uname -m
phase2-qemu-vm/lab-vm.sh stop   vm-debian-aarch64
phase2-qemu-vm/lab-vm.sh destroy vm-debian-aarch64
```

Pass: `uname -m` prints `aarch64`.

### 2.5 Direct kernel+initrd boot (busybox netboot) 🐢 (needs 1.4)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-direct.toml
phase2-qemu-vm/lab-vm.sh start  netboot-direct
```

Attach the serial console to see the busybox shell:

```bash
phase2-qemu-vm/lab-vm.sh console netboot-direct
# Press Enter if needed; type: ip addr show; then Ctrl-] to detach
```

Pass: busybox shell prompt appears on the serial console; `ip addr` shows
a network interface.

```bash
phase2-qemu-vm/lab-vm.sh destroy netboot-direct
```

### 2.6 Full Debian systemd netboot VM 🐢 (4 GB RAM, needs 1.6)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-full.toml
phase2-qemu-vm/lab-vm.sh start  netboot-full
```

Wait ~2 minutes for systemd to fully boot:

```bash
phase2-qemu-vm/lab-vm.sh ssh netboot-full -- systemctl status
phase2-qemu-vm/lab-vm.sh ssh netboot-full -- locale
phase2-qemu-vm/lab-vm.sh ssh netboot-full -- hostname
```

Pass: systemd shows `State: running`; locale is `en_US.UTF-8`; hostname
is `netboot-full`; no locale errors. Console via `lab-vm.sh console netboot-full`
shows `TERM=linux` set; `less /etc/os-release` works without "not fully
functional" warning.

```bash
phase2-qemu-vm/lab-vm.sh stop   netboot-full
phase2-qemu-vm/lab-vm.sh destroy netboot-full
```

---

## 3. Phase 3 — Docker (lab-docker.sh)

### 3.1 Help and list ⚡

```bash
phase3-docker/lab-docker.sh help
phase3-docker/lab-docker.sh list
```

### 3.2 Three-service topology ⚡ (net)

```bash
phase3-docker/lab-docker.sh up --config examples/docker-examples/docker-3svc-topology.toml
phase3-docker/lab-docker.sh list
phase3-docker/lab-docker.sh status --config examples/docker-examples/docker-3svc-topology.toml
```

Verify connectivity:

```bash
# Confirm nginx is reachable
curl -si http://localhost:8181/ | head -3

# Confirm postgres is up (port published in TOML)
phase3-docker/lab-docker.sh exec --config examples/docker-examples/docker-3svc-topology.toml \
    db -- pg_isready
```

Pass: nginx returns HTTP 200; `pg_isready` reports `accepting connections`.

```bash
phase3-docker/lab-docker.sh down --config examples/docker-examples/docker-3svc-topology.toml
```

### 3.3 Netboot artifact server ⚡ (net, needs ~/netboot/kernel + initrd.gz)

```bash
phase3-docker/lab-docker.sh up --config examples/docker-examples/docker-netboot-server.toml
curl -sI http://localhost:8181/kernel    | head -2
curl -sI http://localhost:8181/initrd.gz | head -2
phase3-docker/lab-docker.sh down --config examples/docker-examples/docker-netboot-server.toml
```

Pass: both `curl -I` responses return `HTTP/1.1 200 OK`.

---

## 4. Phase 4 — Podman (lab-podman.sh)

### 4.1 Help and list ⚡

```bash
phase4-podman/lab-podman.sh help
phase4-podman/lab-podman.sh list
```

### 4.2 Plain rootless container ⚡ (net)

```bash
phase4-podman/lab-podman.sh up --config examples/podman-examples/podman-plain-single.toml
phase4-podman/lab-podman.sh list
phase4-podman/lab-podman.sh exec --config examples/podman-examples/podman-plain-single.toml \
    http -- nginx -v
phase4-podman/lab-podman.sh down --config examples/podman-examples/podman-plain-single.toml
```

Pass: `nginx -v` prints the version; `list` shows the container running
without root.

### 4.3 Pod with three services ⚡ (net)

```bash
phase4-podman/lab-podman.sh up --config examples/podman-examples/podman-pod-3svc.toml
phase4-podman/lab-podman.sh status --config examples/podman-examples/podman-pod-3svc.toml
curl -si http://localhost:8181/ | head -3
phase4-podman/lab-podman.sh down --config examples/podman-examples/podman-pod-3svc.toml
```

Pass: all three services running in the same pod; nginx accessible.

### 4.4 Quadlet (systemd-user persistent unit) ⚡ (net)

```bash
phase4-podman/lab-podman.sh generate --config examples/podman-examples/podman-quadlet-service.toml
ls ~/.config/containers/systemd/
```

Pass: `.container` unit file(s) appear under `~/.config/containers/systemd/`.

Then bring it up via systemd:

```bash
systemctl --user daemon-reload
systemctl --user start lab-quadlet-http   # name from TOML
systemctl --user status lab-quadlet-http
curl -si http://localhost:8181/ | head -3
systemctl --user stop lab-quadlet-http
```

Pass: service starts via systemd; nginx responds; logs visible via
`journalctl --user -u lab-quadlet-http`.

### 4.5 Rootless netboot server ⚡ (needs ~/netboot/kernel + initrd.gz)

```bash
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml
curl -sI http://localhost:8181/kernel    | head -2
curl -sI http://localhost:8181/initrd.gz | head -2
phase4-podman/lab-podman.sh down --config examples/podman-netboot-server.toml
```

Pass: both return HTTP 200; no root required (`id` shows normal user).

---

## 5. Phase 5 — LXD (lab-lxd.sh) (lxd)

> Skip this section if LXD/Incus is not installed.

### 5.1 Single Alpine container ⚡ (net)

```bash
phase5-lxd/lab-lxd.sh run --config examples/lxd-examples/lxd-plain-single.toml
phase5-lxd/lab-lxd.sh list
phase5-lxd/lab-lxd.sh exec --config examples/lxd-examples/lxd-plain-single.toml \
    alpine -- uname -a
phase5-lxd/lab-lxd.sh destroy --config examples/lxd-examples/lxd-plain-single.toml
```

Pass: `uname -a` runs inside the LXD container.

### 5.2 Mixed topology (containers + VM) 🐢 (net)

```bash
phase5-lxd/lab-lxd.sh up --config examples/lxd-examples/lxd-mixed-topology.toml
phase5-lxd/lab-lxd.sh status --config examples/lxd-examples/lxd-mixed-topology.toml
phase5-lxd/lab-lxd.sh down --config examples/lxd-examples/lxd-mixed-topology.toml
```

Pass: status shows 2 containers and 1 VM running; all reachable via
`lxd exec`.

### 5.3 Profiles and projects ⚡

```bash
phase5-lxd/lab-lxd.sh up --config examples/lxd-examples/lxd-profiles-projects.toml
phase5-lxd/lab-lxd.sh inspect --config examples/lxd-examples/lxd-profiles-projects.toml
phase5-lxd/lab-lxd.sh down --config examples/lxd-examples/lxd-profiles-projects.toml
```

Pass: instances created inside the custom project; profiles applied.

---

## 6. Cross-Phase Integration

### 6.1 Phase 1 → Phase 4: chroot as rootless image ⚡ (root for chroot build)

```bash
# Build the chroot
sudo phase1-chroot/lab-chroot.sh create \
    --config examples/chroot-debian-bookworm.toml

# Export as tarball (runs rootless)
sudo phase1-chroot/lab-chroot.sh export-tarball debian-bookworm \
    --output /tmp/debian-bookworm.tar.gz

# Import into rootless Podman
phase4-podman/lab-podman.sh up --config examples/podman-examples/podman-from-chroot.toml

# Verify the chroot's files are in the container
phase4-podman/lab-podman.sh exec --config examples/podman-examples/podman-from-chroot.toml \
    app -- cat /etc/debian_version

phase4-podman/lab-podman.sh down --config examples/podman-examples/podman-from-chroot.toml
sudo phase1-chroot/lab-chroot.sh destroy debian-bookworm
```

Pass: `/etc/debian_version` returns a Debian release string from inside the
rootless container. No root required for the Podman steps.

### 6.2 Unified cross-phase TOML (lab-unified-demo.toml) 🐢 (root, net, kvm)

This exercises the cross-phase label feature — one TOML feeds all five phases.

```bash
# Phase 1 reads only [[chroot]] blocks
sudo phase1-chroot/lab-chroot.sh create --config examples/lab-unified-demo.toml

# Phase 2 reads only [[vm]] blocks
phase2-qemu-vm/lab-vm.sh create --config examples/lab-unified-demo.toml
phase2-qemu-vm/lab-vm.sh start  alpine-victim   # name from TOML

# Phase 3 reads only [[service]] with engine=docker
phase3-docker/lab-docker.sh up --config examples/lab-unified-demo.toml

# Phase 4 reads only [[service]] with engine=podman + [[pod]]
phase4-podman/lab-podman.sh up --config examples/lab-unified-demo.toml
```

Verify:

```bash
phase2-qemu-vm/lab-vm.sh list
phase3-docker/lab-docker.sh list
phase4-podman/lab-podman.sh list
```

Pass: each phase shows its own resources; all belong to the same lab label.
Phase 6 TUI (if available) shows all resources correlated under one topology.

Tear down:

```bash
phase4-podman/lab-podman.sh down --config examples/lab-unified-demo.toml
phase3-docker/lab-docker.sh down --config examples/lab-unified-demo.toml
phase2-qemu-vm/lab-vm.sh stop    alpine-victim
phase2-qemu-vm/lab-vm.sh destroy alpine-victim
sudo phase1-chroot/lab-chroot.sh destroy kali-attacker
```

---

## 7. Netboot Utilities

### 7.1 Kickstart generation ⚡

```bash
# Generate a per-host kickstart for the pinned VM MAC
netboot/gen-almalinux-ks.sh --mac 52:54:00:AA:BB:CC --out /tmp/ks-test
cat /tmp/ks-test/ks/52-54-00-aa-bb-cc.ks | head -10
```

Pass: file exists at `ks/52-54-00-aa-bb-cc.ks`; content starts with `text`
and `eula --agreed`.

### 7.2 AlmaLinux installer fetch ⚡→🐢 (net)

```bash
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh \
    --mirror https://repo.almalinux.org/almalinux \
    --release 9 --arch x86_64 --out ~/netboot
ls -lh ~/netboot/vmlinuz ~/netboot/initrd.img
```

Pass: both files download and checksum-verify; sizes are ~12 MB (vmlinuz)
and ~80 MB (initrd.img); re-running the script skips them ("already present
and checksum matches").

### 7.3 iPXE build ⚡→🐢 (Docker, net)

```bash
netboot/build-ipxe.sh \
    --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz \
    --initrd-path /initrd.img \
    --append 'inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'
ls -lh ~/netboot/ipxe.qcow2 ~/netboot/ipxe.usb
```

Pass: `ipxe.qcow2` and `ipxe.usb` created in `~/netboot/`; sizes ~1 MB each;
`{MAC}` is present as a literal in the embedded boot script (it gets rewritten
to `${mac:hexhyp}` at build time, then iPXE expands it at boot — not at
build time).

---

## 8. Scenario: Debian RAM-Initrd Netboot Lab

This exercises Phase 1 → export-initrd → Phase 4 (serve) → Phase 2 (boot)
using the unified `netboot-lab.toml`.

```bash
# 1. Build the busybox chroot (the rootfs that becomes the initrd)
sudo phase1-chroot/lab-chroot.sh create --config examples/netboot-lab.toml

# 2. Package as cpio.gz initrd (manual step — not automated)
cd /var/chroots/netboot-busybox
sudo find . | cpio -H newc -o | gzip -9 -n > ~/netboot/initrd.gz
sudo cp boot/vmlinuz-* ~/netboot/kernel
ls -lh ~/netboot/kernel ~/netboot/initrd.gz
cd -

# 3. Serve the artifacts rootlessly (Phase 4 reads [[service]] blocks)
phase4-podman/lab-podman.sh up --config examples/netboot-lab.toml
curl -sI http://localhost:8181/kernel    | head -2
curl -sI http://localhost:8181/initrd.gz | head -2

# 4. Boot the initrd directly in QEMU (Phase 2 reads [[vm]] blocks)
phase2-qemu-vm/lab-vm.sh create --config examples/netboot-lab.toml
phase2-qemu-vm/lab-vm.sh start  netboot-direct

# 5. Attach to the serial console — you should see a busybox shell
phase2-qemu-vm/lab-vm.sh console netboot-direct
# At the prompt: ip addr show ; curl -I http://10.0.2.2:8181/kernel
# Ctrl-] to detach
```

**Pass criteria:**
- `initrd.gz` is 100–200 MB; `kernel` is ~8 MB
- nginx returns HTTP 200 for both artifacts
- QEMU serial console drops to a busybox shell within ~5 seconds
- `ip addr show` inside the VM shows a network interface
- `curl -I http://10.0.2.2:8181/kernel` from inside the VM returns 200
  (the VM successfully reaching the host-side nginx proves the full
  build → serve → boot chain)

Tear down:

```bash
phase2-qemu-vm/lab-vm.sh destroy netboot-direct
phase4-podman/lab-podman.sh down --config examples/netboot-lab.toml
sudo phase1-chroot/lab-chroot.sh destroy netboot-busybox
```

---

## 9. Scenario: AlmaLinux Zero-Touch PXE Install

This exercises the full Track B pipeline: iPXE boot-loop → Anaconda kickstart
install → SSH into installed system. Walk away after step 6; it takes ~10 min.

```bash
# 1. Fetch the AlmaLinux installer kernel + initrd
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh \
    --mirror https://repo.almalinux.org/almalinux --release 9 --arch x86_64

# 2. Generate the per-host kickstart for the VM's pinned MAC
netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01

# 3. Build the iPXE ROM with {MAC} kickstart URL embedded
netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'

# 4. Serve the artifacts (rootless nginx on :8181)
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml
curl -sI http://localhost:8181/vmlinuz    | head -2
curl -sI http://localhost:8181/initrd.img | head -2
curl -sI http://localhost:8181/ks/52-54-00-a1-9a-01.ks | head -2

# 5. Create the installer VM (blank target + iPXE ROM, two-disk boot-loop)
phase2-qemu-vm/lab-vm.sh create --config examples/almalinux-pxe-lab/vm-almalinux-pxe-install.toml

# 6. Start the VM — Anaconda installs unattended, then reboots
phase2-qemu-vm/lab-vm.sh start almalinux-pxe-install

# 7. Watch progress on the serial console (optional)
phase2-qemu-vm/lab-vm.sh console almalinux-pxe-install
# You should see: iPXE boot → Anaconda initialising → disk partitioning →
# package installation → reboot. Ctrl-] to detach.
```

After ~10 minutes (package install over HTTPS), the VM reboots into AlmaLinux:

```bash
# 8. SSH into the installed system
phase2-qemu-vm/lab-vm.sh ssh almalinux-pxe-install -- cat /etc/os-release
phase2-qemu-vm/lab-vm.sh ssh almalinux-pxe-install -- id lab
phase2-qemu-vm/lab-vm.sh ssh almalinux-pxe-install -- sudo systemctl status sshd
```

**Pass criteria:**
- `os-release` shows `AlmaLinux release 9`
- `id lab` shows the `lab` user in the `wheel` group
- `sshd` is active (running)
- The VM only needed `create` + `start` — no manual intervention

Tear down:

```bash
phase2-qemu-vm/lab-vm.sh stop    almalinux-pxe-install
phase2-qemu-vm/lab-vm.sh destroy almalinux-pxe-install
phase4-podman/lab-podman.sh down --config examples/podman-netboot-server.toml
```

---

## 10. Scenario: Multi-Arch Build Comparison

Demonstrates cross-architecture support by booting the same distro on two
different architectures and comparing `uname -m`.

```bash
# Native x86_64 (KVM — fast)
phase2-qemu-vm/lab-vm.sh create --config examples/vm-debian-amd64.toml
phase2-qemu-vm/lab-vm.sh start  vm-debian-amd64
phase2-qemu-vm/lab-vm.sh ssh vm-debian-amd64 -- uname -m   # → x86_64

# Emulated aarch64 (TCG — slow, ~5 min to boot)
phase2-qemu-vm/lab-vm.sh create --config examples/vm-debian-aarch64.toml
phase2-qemu-vm/lab-vm.sh start  vm-debian-aarch64
phase2-qemu-vm/lab-vm.sh ssh vm-debian-aarch64 -- uname -m  # → aarch64

# Verify both are actually different
echo "x86_64 accel: $(phase2-qemu-vm/lab-vm.sh inspect vm-debian-amd64   | jq -r .accel)"
echo "aarch64 accel: $(phase2-qemu-vm/lab-vm.sh inspect vm-debian-aarch64 | jq -r .accel)"
```

**Pass criteria:**
- x86_64 VM shows `accel=kvm` (or tcg if /dev/kvm unavailable)
- aarch64 VM shows `accel=tcg`
- `uname -m` returns the correct architecture inside each VM

Tear down:

```bash
phase2-qemu-vm/lab-vm.sh stop    vm-debian-amd64
phase2-qemu-vm/lab-vm.sh destroy vm-debian-amd64
phase2-qemu-vm/lab-vm.sh stop    vm-debian-aarch64
phase2-qemu-vm/lab-vm.sh destroy vm-debian-aarch64
```

---

## Quick Reference: Known-Good States

| Test | Command | Expected output |
|------|---------|-----------------|
| TOML parse all examples | `python3 -c "import tomllib; ..."` | `OK examples/...` × 34 |
| Phase 1 tests | `bash phase1-chroot/tests/test-cli-vs-config-parity.sh` | `PASS` (needs root) |
| Phase 2 tests | `bash phase2-qemu-vm/tests/test-validation.sh` | `PASS: validation guardrails OK` |
| Phase 3 tests | `bash phase3-docker/tests/test-validation.sh` | `PASS` |
| Phase 4 tests | `bash phase4-podman/tests/test-validation.sh` | `PASS` |
| Script syntax | `bash -n netboot/*.sh` | no output (no errors) |

---

## Edge Cases Worth Checking

- **No KVM:** `rm -f /dev/kvm` (or run in a container); Phase 2 should fall
  back to TCG and print a warning, not error.
- **Missing kernel file:** `lab-vm.sh create` with `kernel = "/nonexistent"`
  should fail at create time with a clear error, not silently at start.
- **Duplicate VM name:** `create` a VM twice with the same name; second call
  should refuse or prompt, not silently overwrite.
- **Export without chroot:** `export-initrd nonexistent-name` should produce
  a clear "chroot not found" message.
- **SELinux (if enforcing):** the Podman volume bind in
  `podman-netboot-server.toml` should work because lab-podman.sh appends `:Z`
  automatically when SELinux is enforcing. Verify with
  `sestatus | grep -i enabled`.
