# Phase 2 — QEMU VMs, ready in seconds

## What it gives you

Full VMs *or* microvms, cloud-init seeded with your SSH key on first boot, across
all six architectures the rest of the stack speaks (`x86_64`, `aarch64`, `armv7l`,
`ppc64le`, `riscv64`, `s390x`). One bash script (`lab-vm.sh`), three backends —
cached cloud images, direct kernel+initrd, or a Phase-1 chroot turned into a
bootable qcow2 — and KVM transparently when guest arch matches host, TCG when it
doesn't. Per-VM SSH port allocation, QMP-backed graceful shutdown, and a
machine-readable `inspect --json` for everything that's running.

## 60-second demo

A clean Debian/Ubuntu host to a logged-in Alpine microvm:

```bash
sudo apt-get install -y jq yq curl socat genisoimage qemu-utils \
    qemu-system-x86 ovmf
sudo usermod -aG kvm "$USER" && newgrp kvm

# Create, start, log in, destroy. Total wall time on KVM: well under a minute.
sudo phase2-qemu-vm/lab-vm.sh create \
    --name al1 --distro alpine --suite latest --arch x86_64 \
    --memory 256M --microvm
sudo phase2-qemu-vm/lab-vm.sh start  al1
sudo phase2-qemu-vm/lab-vm.sh ssh    al1 -- uname -a
sudo phase2-qemu-vm/lab-vm.sh destroy al1 --force
```

```text
# sample output
[info] starting al1 (accel=kvm arch=x86_64 mem=256M cpus=1 microvm=true)
[info] al1 running (pid 24817)
[info] ssh:     ssh -p 2222 lab@127.0.0.1
[info] console: lab-vm.sh console al1
Linux al1 6.6.41-0-virt #1-Alpine SMP PREEMPT_DYNAMIC Mon, 22 Jul 2024 ... x86_64 Linux
```

## Feature tour

### Full VMs vs microvms (the kernel+initrd story)

Three backends, picked with `--backend`:

| Backend          | What it boots                                                        | When to reach for it |
|------------------|----------------------------------------------------------------------|----------------------|
| `disk-image`     | A cached upstream cloud image, overlaid as qcow2, seeded with cloud-init | The default — "give me a working Debian/Alpine/Rocky/Kali/Ubuntu in one command" |
| `kernel+initrd`  | Direct kernel boot, no firmware, no bootloader                       | Microvm fast paths, kernel hacking, no-disk experiments |
| `from-chroot`    | A Phase-1 chroot tree packaged as a bootable qcow2 (MBR + extlinux + ext4) | "I built it as a chroot, now boot it." x86_64 BIOS only in v0.1 |

`--microvm` asks for QEMU's minimal, fast-boot device model. On **x86_64** that's
the genuine `microvm` machine (`-machine microvm,pic=off,pit=off,rtc=off`) with a
~kilobyte qboot BIOS instead of OVMF — no PCIe, no ACPI tables to speak of, virtio
on the **mmio** bus. QEMU's `microvm` machine is **x86-only**, so on **aarch64**
`--microvm` synthesizes the equivalent: a stripped-down `virt` booted directly via
`-kernel` with **no UEFI firmware at all** and virtio on mmio (arm's `virt` is the
de-facto arm microvm). On Alpine the boot is **measurably sub-second** after the
rootfs is warm; the rest of the wait is just cloud-init setting up the user. On the
remaining arches the flag is ignored with a warning and you fall back to the
standard machine. (Direct `-kernel` boot is required either way — stock cloud
images are UEFI-only and won't boot off qboot.)

### Cloud-init out of the box

Every `disk-image` VM gets a `seed.iso` generated automatically — a NoCloud
datasource carrying:

- your hostname (`--name`),
- your SSH public key (auto-discovered from `~/.ssh/*.pub`, or override with `--pubkey`),
- a `lab` user with passwordless sudo,
- an auto-allocated SSH port that probes upward from `2222` until it finds a free one.

That's why `lab-vm.sh ssh deb1` Just Works the first time — no manual
`ssh-copy-id` round-trip. To pin the port, pass `--ssh-port 2245`.

### Multi-architecture boot (foreign arches via qemu-system-X)

The same `create` flow with `--arch aarch64` will:

1. Pull the **aarch64** Debian cloud image (different URL, different filename).
2. Use `qemu-system-aarch64` instead of `qemu-system-x86_64`.
3. Pick `accel=tcg` (because your host is x86 and KVM only works when arch
   matches), and load the AAVMF EFI firmware.
4. Cloud-init the same `lab` user, on the same SSH port allocator.

```bash
sudo phase2-qemu-vm/lab-vm.sh create \
    --name arm1 --distro debian --suite bookworm --arch aarch64 \
    --memory 1G --cpus 1
sudo phase2-qemu-vm/lab-vm.sh start arm1
sudo phase2-qemu-vm/lab-vm.sh ssh   arm1 -- uname -m
# → aarch64
```

TCG emulation is slow (5–10 minutes to first SSH for a Debian aarch64 boot on a
laptop), but the only thing you change is one flag.

### Alpine "latest" resolver

You write `--suite latest`, the script reads
`https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml`
at run time and grabs the current stable release. No more bumping
`3.19` → `3.20` → `3.21` in your configs every quarter:

```bash
sudo phase2-qemu-vm/lab-vm.sh create \
    --name alp --distro alpine --suite latest --arch x86_64 --microvm
# Pin if you must:
sudo phase2-qemu-vm/lab-vm.sh create \
    --name alp-pinned --distro alpine --suite 3.20 --arch x86_64 --microvm
```

### Bridging from a chroot — Phase 1 → bootable qcow2

`backend = "from-chroot"` takes a Phase-1 chroot tree, MBR-partitions a raw
disk, mkfs.ext4's it, rsyncs the chroot in, writes `/etc/fstab` from `blkid`,
writes an extlinux config with `console=ttyS0,115200`, dd's the syslinux MBR,
and converts to qcow2. The chroot must already have a kernel and initrd
installed (Phase 2 won't `apt-get install linux-image-amd64` for you):

```bash
# Phase 1 builds the tree:
sudo phase1-chroot/lab-chroot.sh create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch x86_64 --target /var/chroots/vm-seed --variant minbase \
    --name vm-seed

# Install a kernel + ssh inside the chroot (one-time):
sudo phase1-chroot/lab-chroot.sh enter vm-seed -- /bin/bash -c '
    apt-get update
    apt-get install -y --no-install-recommends \
        linux-image-amd64 systemd-sysv udev openssh-server \
        ifupdown isc-dhcp-client
    echo "root:lab" | chpasswd
    systemctl enable ssh
'

# Phase 2 turns it into a bootable VM:
sudo phase2-qemu-vm/lab-vm.sh create --config examples/vm-from-chroot-debian.toml
sudo phase2-qemu-vm/lab-vm.sh start  vm-from-chroot-demo
sudo phase2-qemu-vm/lab-vm.sh console vm-from-chroot-demo   # Ctrl-] to detach
```

x86_64 BIOS only in v0.1 — UEFI and aarch64 are future work. For other arches,
extract the chroot's kernel + initrd and use `--backend kernel+initrd`.

### `inspect --json` — live qemu state

Added in commit `00b1fb1`. Schema-versioned, single JSON document, designed to
be diffed and consumed by tooling (Phase 6's TUI lives off this):

```bash
sudo phase2-qemu-vm/lab-vm.sh inspect al1 --json | jq
```

```json
// sample output (truncated)
{
  "schema_version": 1,
  "name": "al1",
  "manifest": {
    "backend": "kernel+initrd", "distro": "alpine", "suite": "latest",
    "arch": "x86_64", "memory": "256M", "cpus": 1,
    "microvm": true, "accel": "kvm", "ssh_port": 2222
  },
  "process": { "running": true, "pid": 24817, "rss_bytes": 178311168, "threads": 4 },
  "files": {
    "disk":   { "path": ".../al1/disk.qcow2", "exists": true,
                "size_bytes": 524288000, "virtual_size_bytes": 536870912000 },
    "seed":   { "path": ".../al1/seed.iso",   "exists": true, "size_bytes": 374784 },
    "kernel": { "path": ".../al1/vmlinuz",    "exists": true, "size_bytes": 11534336 },
    "initrd": { "path": ".../al1/initramfs",  "exists": true, "size_bytes": 41943040 }
  },
  "sockets": {
    "serial":  { "exists": true }, "monitor": { "exists": true }, "qmp": { "exists": true }
  },
  "network": { "ssh_port": 2222, "ssh_user": "lab" },
  "foreign_arch": { "host_arch": "x86_64", "vm_arch": "x86_64",
                    "kvm_available": true }
}
```

`virtual_size_bytes` comes from `qemu-img info --output=json` so you can spot
thin-provisioning waste at a glance. Without `--json` you get the same data in
a flat human-readable layout — handy for `grep`-style triage.

### Netboot simulation — boot any kernel+initrd, including HTTP-served ones

The `kernel+initrd` backend isn't just for Alpine microvms — it's the
mechanism that mirrors what real iPXE hardware does: download a kernel
and initrd over HTTP, then hand them straight to QEMU. Two modes:

**1. Direct** (`vm-netboot-direct.toml`) — QEMU `-kernel`/`-initrd` with
explicit file paths. Fastest way to validate that a Phase 1
`export-initrd` output actually boots. Pair with `cloud_init = false`
for bare initrd images that don't include a cloud-init datasource:

```bash
# Direct (fastest validation):
sudo lab-vm.sh create --config examples/vm-netboot-direct.toml
lab-vm.sh start netboot-direct
```

**2. Full iPXE simulation** (`vm-netboot-ipxe.toml`) — boot from
`ipxe.qcow2`. The VM starts, iPXE does DHCP (via QEMU slirp),
then fetches `http://10.0.2.2:8181/boot.ipxe` — the Phase 4 nginx
server running on the host. iPXE downloads the kernel + initrd and
boots them in RAM, exactly as real thin-client hardware would:

```bash
# Full iPXE simulation (after nginx is up):
sudo lab-vm.sh create --config examples/vm-netboot-ipxe.toml
lab-vm.sh start netboot-ipxe
```

The QEMU slirp network gives the guest `10.0.2.2` as a gateway that
reaches the host's localhost — so `http://10.0.2.2:8181/` in the
iPXE script resolves to the Phase 4 Podman container's port 8181.

The same `ipxe.usb` image `dd`'d to a USB stick runs an **identical
boot sequence** on real hardware: iPXE DHCP + HTTP download + kernel
runs in RAM. No disk write needed on the target machine.

### Direct kernel+initrd boot — local iPXE equivalent

`-kernel`/`-initrd` and iPXE perform the same two-step sequence: load the
kernel and initrd into RAM, then jump to the kernel entry point.  The only
difference is where the bytes come from:

| Mechanism | Kernel source | Initrd source | Cmdline source |
|-----------|--------------|---------------|----------------|
| QEMU `-kernel`/`-initrd` | local file path | local file path | `-append` flag |
| iPXE `kernel`/`initrd`/`boot` | HTTP URL | HTTP URL | `kernel` line params |

Because the handoff to the kernel is identical, an initrd that boots correctly
under `-kernel`/`-initrd` will boot correctly under iPXE — validating locally
first saves a full PXE round-trip.

The `append` field in the TOML is the kernel command line, equivalent to the
parameters on the `kernel` line in an iPXE script:

```toml
# TOML (vm-netboot-direct.toml)
append = "console=ttyS0 root=/dev/ram0 rw"
```

```text
# iPXE script equivalent
kernel http://10.0.2.2:8181/kernel console=ttyS0 root=/dev/ram0 rw
initrd http://10.0.2.2:8181/initrd.gz
boot
```

**Busybox variant** (`vm-netboot-direct.toml`) vs **full Debian variant**
(`vm-netboot-full.toml`):

| | `vm-netboot-direct.toml` | `vm-netboot-full.toml` |
|-|--------------------------|------------------------|
| Chroot source | `chroot-netboot-busybox.toml` | `chroot-netboot-full.toml` |
| Memory | 512M | 4G |
| `cloud_init` | absent (busybox has no agent) | `true` (seeds SSH pubkey) |
| PID 1 | busybox sh | systemd |
| Console | busybox prompt, no login | login prompt, SSH available |

**End-to-end recipe for the busybox track:**

```bash
# 1. Build the busybox chroot (~2-3 min, needs root):
sudo phase1-chroot/lab-chroot.sh create \
    --config examples/chroot-netboot-busybox.toml

# 2. Export kernel + initrd (needs root):
sudo phase1-chroot/lab-chroot.sh export-initrd netboot-busybox \
    --kernel ~/netboot/kernel \
    --output ~/netboot/initrd.gz

# 3. Create the VM record and start it (rootless):
phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-direct.toml
phase2-qemu-vm/lab-vm.sh start  netboot-direct
# Press Ctrl-] to detach from the serial console.
```

To serve the same artifacts over HTTP and validate the full iPXE chain, start
the Phase 4 nginx container first:

```bash
# Serve kernel + initrd over HTTP (rootless):
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml
# Then boot via iPXE:
phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-ipxe.toml
phase2-qemu-vm/lab-vm.sh start  netboot-ipxe
```

**iPXE virtual-disk variant** (manual, for UEFI firmware testing): build iPXE
with an embedded chainload script and pass it to QEMU as firmware:

```bash
# Build iPXE EFI binary with embedded script:
make bin-x86_64-efi/ipxe.efi EMBED=script.ipxe

# Pass as BIOS replacement:
qemu-system-x86_64 -bios ipxe.efi <rest-of-flags>
# Or as a UEFI pflash drive:
qemu-system-x86_64 -drive if=pflash,file=ipxe.efi <rest-of-flags>
```

iPXE will DHCP, fetch `boot.ipxe` from the host, download kernel + initrd over
HTTP, and hand them to the kernel — the same sequence `dd`'d to a USB stick
runs on real thin-client hardware.

Cross-references:
- Busybox chroot build: [`examples/chroot-netboot-busybox.toml`](../examples/chroot-netboot-busybox.toml)
- HTTP artifact server: [`examples/podman-netboot-server.toml`](../examples/podman-netboot-server.toml)
- Full iPXE simulation: [`examples/vm-netboot-ipxe.toml`](../examples/vm-netboot-ipxe.toml)
- Full Debian track: [`examples/vm-netboot-full.toml`](../examples/vm-netboot-full.toml)

## Integrations

### ← Phase 1 (turn a chroot into a VM)

The `from-chroot` backend (above) is the headline cross-phase: any tree
`phase1-chroot/lab-chroot.sh` builds — debootstrap, dnf bootstrap, an Alpine
apk install — boots as a Phase 2 VM as long as it has a kernel and initrd
installed. See [`examples/vm-from-chroot-debian.toml`](../examples/vm-from-chroot-debian.toml).

### → Phase 5 (export qcow2 as an LXD VM image)

LXD's own `from-chroot` builder is **container-only**, so the documented bridge
for "I want a VM in LXD that came from a chroot" goes through Phase 2:

```bash
# Phase 2: build the qcow2 from a chroot.
sudo phase2-qemu-vm/lab-vm.sh create --config examples/vm-from-chroot-debian.toml
# (qcow2 lands at ~/.local/state/lab-create/vms/vm-from-chroot-demo/disk.qcow2)

# Phase 5: import it as an LXD VM image, then launch.
sudo phase5-lxd/lab-lxd.sh build \
    --backend from-qcow2 \
    --qcow2 ~/.local/state/lab-create/vms/vm-from-chroot-demo/disk.qcow2 \
    --alias my-vm-image
incus launch local:my-vm-image vmname --vm
```

### → Phase 6 (TUI surfaces all your VMs)

Phase 6's chroot-detail panel calls `lab-vm.sh inspect --json` for live process
+ disk + socket state — that's why the JSON schema is versioned. Same source of
truth, just a friendlier presentation.

## Where next

- Reference walk-through, every flag exercised: [`MANUAL_TESTING.md`](MANUAL_TESTING.md)
- Why it's shaped this way: [`PLAN.md`](../PLAN.md) §Phase 2
- Real configs to copy:
  [`examples/vm-alpine-amd64.toml`](../examples/vm-alpine-amd64.toml),
  [`examples/vm-debian-amd64.toml`](../examples/vm-debian-amd64.toml),
  [`examples/vm-debian-aarch64.toml`](../examples/vm-debian-aarch64.toml),
  [`examples/vm-kali-amd64.toml`](../examples/vm-kali-amd64.toml),
  [`examples/tiny-linux-experiments/microvm-alpine.toml`](../examples/tiny-linux-experiments/microvm-alpine.toml),
  [`examples/tiny-linux-experiments/microvm-alpine-custom-init.toml`](../examples/tiny-linux-experiments/microvm-alpine-custom-init.toml),
  [`examples/vm-from-chroot-debian.toml`](../examples/vm-from-chroot-debian.toml)
- Sibling SHOWCASEs:
  [Phase 1 (chroots)](../phase1-chroot/SHOWCASE.md) ·
  [Phase 3 (docker)](../phase3-docker/SHOWCASE.md) ·
  [Phase 4 (podman)](../phase4-podman/SHOWCASE.md) ·
  [Phase 5 (LXD/Incus)](../phase5-lxd/SHOWCASE.md) ·
  [Phase 6 (TUI)](../phase6-tui/SHOWCASE.md)
