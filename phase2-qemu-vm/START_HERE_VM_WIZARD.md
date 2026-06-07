# Start here — Phase 2: QEMU VM (`lab-vm.sh`)

Phase 2 creates and runs **full virtual machines** using QEMU — from quick
cloud-image VMs to bare-metal-style direct-kernel boots and microvms.
It covers six architectures, automatically picks KVM when available, and gives
every VM a serial console, SSH access, and cloud-init customisation out of the box.

---

## Option A — use the wizard (recommended)

If you have the Phase 6 TUI running:

```bash
cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
python3 -m lab_tui          # or: python3 phase6-tui/main.py
```

Press **`n`** → select **Phase 2 — QEMU VM** → fill in the form → press **Save**.
The wizard writes a TOML file. Then run the create/start commands below.

---

## Option B — three-minute quickstart (no wizard needed)

### 1. Install prerequisites

```bash
sudo apt-get install -y \
    jq yq curl socat genisoimage \
    qemu-system-x86-64 qemu-utils ovmf
sudo usermod -aG kvm "$USER"   # log out and back in for KVM access
```

### 2. Create + boot a Debian VM

```bash
phase2-qemu-vm/lab-vm.sh create \
    --name  deb1 \
    --distro debian --suite bookworm \
    --arch  x86_64 \
    --memory 2G --cpus 2

phase2-qemu-vm/lab-vm.sh start deb1
```

### 3. Connect

```bash
# SSH (waits for cloud-init to finish — ~30 s first boot):
phase2-qemu-vm/lab-vm.sh ssh deb1

# Or watch the boot directly on the serial console (Ctrl-] to detach):
phase2-qemu-vm/lab-vm.sh console deb1
```

### 4. Stop and clean up

```bash
phase2-qemu-vm/lab-vm.sh stop    deb1
phase2-qemu-vm/lab-vm.sh destroy deb1 --force
```

---

## Option C — use a TOML config (from the wizard or an example)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-examples/vm-debian-amd64.toml
phase2-qemu-vm/lab-vm.sh start  deb-amd64
phase2-qemu-vm/lab-vm.sh ssh    deb-amd64
phase2-qemu-vm/lab-vm.sh destroy deb-amd64 --force
```

Ready-to-run examples in `examples/`:

| File | What it builds |
|---|---|
| `vm-examples/vm-debian-amd64.toml` | Debian bookworm, x86_64, KVM, 2 GB |
| `vm-examples/vm-debian-aarch64.toml` | Debian bookworm, aarch64, TCG (slow) |
| `vm-examples/vm-alpine-amd64.toml` | Alpine, tiny + fast |
| `vm-kali-amd64.toml` | Kali Linux (prebuilt `.7z` image) |
| `tiny-linux-experiments/microvm-alpine.toml` | Alpine + `microvm=true` — fastest x86_64 boot path |
| `tiny-linux-experiments/micro-linux-x86_64.toml` | Your own from-source kernel + initrd |
| `tiny-linux-experiments/micro-linux-x86_64-microvm.toml` | From-source kernel on the `microvm` machine |
| `vm-examples/vm-from-chroot-debian.toml` | Boot a Phase-1 chroot as a VM (needs root) |

---

## Anatomy of a config

```toml
[[vm]]
name     = "my-vm"
backend  = "disk-image"     # disk-image | kernel+initrd | from-chroot | pxe-install
distro   = "debian"
suite    = "bookworm"
arch     = "x86_64"
memory   = "2G"
cpus     = 2
ssh_port = 0               # 0 = auto-allocate from port 2222 upward
microvm  = false           # true = minimal fast-boot machine (x86_64: genuine microvm;
                           #        aarch64: minimized virt, no UEFI firmware needed)
```

### Backend quick reference

| Backend | What it does |
|---|---|
| `disk-image` | Downloads a cloud image, wraps it in a qcow2 overlay, injects cloud-init |
| `kernel+initrd` | Direct `-kernel`/`-initrd` boot — no cloud image needed |
| `from-chroot` | Turns a Phase-1 chroot tree into a bootable BIOS+extlinux VM (root, x86_64) |
| `pxe-install` | Blank disk + TFTP-served installer; use with `--pxe-dir` |

---

## What just happened — the "why" under the hood

**Cloud images and qcow2 overlays:** the first `create` downloads a cloud image
(e.g. `debian-12-genericcloud-amd64.qcow2`, ~350 MB) to a shared cache. Every VM
then gets a **qcow2 overlay** — a tiny (~200 KB) file that records only the
differences from the base image. This means ten VMs with the same distro share one
cached download; each overlay's "backing file" pointer points at the cached base.

**cloud-init NoCloud seed:** `lab-vm.sh` generates a small ISO (`seed.iso`)
containing two files: `meta-data` (VM hostname/instance-id) and `user-data`
(creates a `lab` user, injects your SSH pubkey, sets password `lab`). The VM
boots, cloud-init finds the ISO on the virtual CD-ROM, and applies the config —
that's how SSH just worked without any image customisation.

**microvm machine (x86_64):** QEMU's `microvm` machine removes everything a
legacy PC has (PCI bus, BIOS option ROM, ACPI tables) and keeps only virtio-mmio
devices and a tiny qboot BIOS. Boot time drops from ~10 s to under 1 s. The
tradeoff: requires direct `-kernel` boot (no GRUB, no UEFI), and only virtio-mmio
transports work (no PCI). **aarch64 has no QEMU `microvm` machine** — the equivalent
is a stripped `virt` machine with virtio-mmio and direct boot, which is what
`microvm = true` delivers on arm.

**Serial console (`serial.sock`):** QEMU's `-serial unix:…` creates a Unix domain
socket. `socat` wraps it in a raw-TTY session so you get a full interactive
terminal over the socket — the same path `lab-vm.sh console` uses, and the same
path Phase 6 TUI's console-attach feature (`c` key) uses.

---

## Next steps

- **`README.md`** — complete flag reference, firmware matrix, acceleration matrix, v0.2 features
- **`SHOWCASE.md`** — live-verified demos including aarch64, microvm, from-chroot
- **`MANUAL_TESTING.md`** — step-by-step verification walkthrough
- **`examples/`** — all TOML examples above
- **← Phase 1** (`START_HERE_CHROOT_WIZARD.md`) — build a rootfs the `from-chroot` backend can consume
- **→ Phase 6 TUI** — `c` key attaches the serial console while staying in the TUI
