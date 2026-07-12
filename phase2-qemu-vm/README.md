# Phase 2 — `lab-vm.sh`

Create and run QEMU VMs and microvms across the same arch matrix as Phase 1.

## At a glance

| | |
|---|---|
| **Backends** | `disk-image` (cached cloud images + cloud-init NoCloud seed) · `kernel+initrd` (direct boot, microvm-friendly) · `from-chroot` (Phase-1 tree → bootable BIOS qcow2, x86_64, needs root) · `pxe-install` (boot an installer over PXE/iPXE) |
| **Arches** | `x86_64`, `aarch64`, `armv7l`, `ppc64le`, `riscv64`, `s390x` |
| **Acceleration** | `kvm` if guest arch == host arch and `/dev/kvm` is r+w; otherwise `tcg` (slow but works for any arch) |
| **microvm** | `--microvm` selects QEMU's minimal fast-boot device model: the genuine `microvm` machine + qboot on **x86_64**; a stripped `virt` + virtio-mmio + no UEFI on **aarch64** (QEMU has no arm `microvm` machine); falls back with a warning on other arches. Direct `-kernel` boot only. |
| **Networking** | `--network-mode user` (default: slirp + per-VM SSH hostfwd) · `bridge` (`--bridge`) · `tap` (`--tap`) — bridge/tap attach to host L2 and need root (or a setuid `qemu-bridge-helper` + `/etc/qemu/bridge.conf`) |
| **Snapshots / CPU** | offline qcow2 snapshots (`snapshot create/list/restore/delete`); CPU topology (`--cores`/`--threads`) + host-CPU pinning (`--cpu-pin`, via `taskset`) |
| **Create overrides** | `--image PATH` (use a specific qcow2/.img instead of the cached cloud image) · `--ssh-port N` (pin the host SSH forward instead of auto-allocating from 2222) · `--pubkey PATH` (inject this SSH public key) · `--no-cloud-init` (skip NoCloud seeding, for bare/iPXE disk images) |
| **Console** | serial console exposed as a unix socket; `lab-vm.sh console` attaches via `socat` |
| **Lifecycle** | graceful shutdown via QMP `system_powerdown`; SIGTERM → SIGKILL escalation if it doesn't take |
| **Config** | CLI flags or TOML (`--config FILE`) |

## Install

Drop `lab-vm.sh` anywhere on `$PATH`.

### Required on the host

| Always | `bash` 4+, `jq`, `qemu-img`, `qemu-system-<arch>`, a TOML parser (`yq`/`tomlq`/`dasel`), `socat`, `curl`, `genisoimage` (or `xorriso` / `mkisofs`) |
| For KVM | `/dev/kvm` r+w by your uid (often: `usermod -aG kvm $USER`, log out, log in) |
| For aarch64 / x86_64 UEFI | `qemu-efi-aarch64` / `ovmf` (firmware blobs) |
| For armv7l | `u-boot-qemu` |
| For riscv64 | `opensbi` |
| For ppc64le / s390x | bundled with `qemu-system-*` — nothing extra |

The script's preflight prints the exact install command for whatever's missing.

### Quick install on Debian / Ubuntu

```bash
sudo apt-get install -y \
    jq yq curl socat genisoimage \
    qemu-system qemu-system-arm qemu-system-misc qemu-utils \
    ovmf qemu-efi-aarch64 u-boot-qemu opensbi
sudo usermod -aG kvm "$USER"   # log out and back in for it to take effect
```

## Usage

```text
lab-vm.sh create   --name N [opts...] | --config FILE
lab-vm.sh start    <name>
lab-vm.sh stop     <name> [--force]
lab-vm.sh console  <name>
lab-vm.sh ssh      <name> [-- cmd args...]
lab-vm.sh destroy  <name> [--force] [--keep-disk]
lab-vm.sh list
lab-vm.sh inspect  <name> [--json]
lab-vm.sh publish-netboot <name> [opts...]
```

`inspect` prints a VM's manifest and runtime status (add `--json` for machine-readable
output). `publish-netboot` copies a `kernel+initrd` VM's kernel and initrd into a netboot
directory (and optionally writes a `boot.ipxe`) so Phase 4's nginx container can serve them.

`lab-vm.sh help` for the full flag list.

### Quick examples

Native x86_64 Debian VM:

```bash
lab-vm.sh create --name deb1 --distro debian --suite bookworm --arch x86_64
lab-vm.sh start  deb1
lab-vm.sh ssh    deb1
lab-vm.sh stop   deb1
lab-vm.sh destroy deb1
```

Aarch64 VM on an x86_64 host (TCG, slow):

```bash
lab-vm.sh create --name arm1 --distro debian --suite bookworm --arch aarch64 \
                 --memory 1G --cpus 1
lab-vm.sh start  arm1
lab-vm.sh console arm1   # watch the boot via serial; Ctrl-] to detach
```

Alpine microvm (fastest boot path on x86_64):

```bash
lab-vm.sh create --name alp1 --distro alpine --suite 3.19 --arch x86_64 \
                 --microvm --memory 256M --cpus 1
lab-vm.sh start  alp1
```

Direct kernel boot (you provide `vmlinuz` and `initrd`):

```bash
lab-vm.sh create --name kboot --backend kernel+initrd --arch x86_64 \
                 --kernel /boot/vmlinuz-$(uname -r) \
                 --initrd /boot/initrd.img-$(uname -r) \
                 --append "console=ttyS0 root=/dev/ram0"
```

Same VM from a TOML config:

```bash
lab-vm.sh create --config examples/vm-examples/vm-debian-amd64.toml
```

## Configuration (TOML)

```toml
[[vm]]
name     = "deb1"
backend  = "disk-image"
distro   = "debian"
suite    = "bookworm"
arch     = "x86_64"
memory   = "2G"
cpus     = 2
ssh_port = 0           # 0 = auto-allocate from 2222

[[vm]]
name     = "alp-microvm"
backend  = "disk-image"
distro   = "alpine"
suite    = "3.19"
arch     = "x86_64"
memory   = "256M"
cpus     = 1
microvm  = true
```

A single inline `[vm]` table is also accepted.

## State and locations

| | |
|---|---|
| Per-VM dir | `${LAB_STATE_DIR}/vms/<name>/` |
| Manifest | `<vm-dir>/manifest.toml` |
| Disk (qcow2 overlay over cached base) | `<vm-dir>/disk.qcow2` |
| cloud-init seed | `<vm-dir>/seed.iso` |
| QEMU pidfile | `<vm-dir>/qemu.pid` |
| QEMU monitor (text) | `<vm-dir>/monitor.sock` |
| QMP socket | `<vm-dir>/qmp.sock` |
| Serial console | `<vm-dir>/serial.sock` |
| QEMU stderr/stdout log | `<vm-dir>/qemu.log` |
| UEFI vars (per-VM) | `<vm-dir>/vars.fd` |
| Image cache | `${LAB_CACHE_DIR}/images/` |
| `LAB_STATE_DIR` (root) | `/var/lib/lab-create` |
| `LAB_STATE_DIR` (non-root) | `${XDG_STATE_HOME:-$HOME/.local/state}/lab-create` |

Cloud images are cached; subsequent VMs of the same `distro+suite+arch` reuse the base via qcow2 backing-file overlays (no extra download, ~200 KB on disk per VM until you start writing).

## Default credentials

The cloud-init seed creates a `lab` user with password `lab` and `sudo NOPASSWD`, plus your invoking user's first SSH public key (`~/.ssh/id_ed25519.pub`, `id_rsa.pub`, or `authorized_keys` — whichever exists first). Root login is enabled with password `lab` for emergency console access.

> **This is a lab tool.** The defaults are deliberately permissive. Do not expose these VMs to untrusted networks; user-mode networking is loopback-only by default but check your forwards.

## Acceleration matrix

| Host arch | Guest arch | Result |
|---|---|---|
| x86_64 | x86_64 | KVM (if `/dev/kvm` r+w) |
| x86_64 | aarch64, armv7l, ppc64le, riscv64, s390x | TCG |
| aarch64 | aarch64 | KVM |
| aarch64 | other | TCG |
| (any) | (any other) | TCG |

The script logs the decision and the reason ("no /dev/kvm", "guest != host", etc.). It never silently falls back.

## Firmware matrix

| Guest arch | Loader | Default file lookup |
|---|---|---|
| x86_64 (full VM) | OVMF | `/usr/share/OVMF/OVMF_CODE*.fd` |
| x86_64 (microvm) | qboot (or none under `-kernel`) | `/usr/share/qemu/qboot.rom` |
| aarch64 (full VM) | AAVMF / QEMU_EFI | `/usr/share/AAVMF/AAVMF_CODE.fd`, etc. |
| aarch64 (microvm) | none — minimized `virt`, direct boot | — |
| armv7l | u-boot | `/usr/share/u-boot/qemu_arm/u-boot.bin` |
| riscv64 | OpenSBI | `/usr/share/opensbi/.../fw_jump.elf` |
| ppc64le | SLOF (bundled in QEMU) | — |
| s390x | s390-ccw bios (bundled in QEMU) | — |

Per-VM UEFI variable storage (writable copy of `OVMF_VARS.fd` / `AAVMF_VARS.fd`) lives at `<vm-dir>/vars.fd` so that grub/efibootmgr changes survive across boots.

## Emulated TPM (`tpm = true`)

Set `tpm = true` on a `[[vm]]` to attach an emulated **TPM 2.0** (via
[`swtpm`](https://github.com/stefanberger/swtpm)) — for measured boot, PCR reads,
and TPM2-sealed secrets. A per-VM `swtpm` sidecar (state under `<vm-dir>/tpm`,
control socket `<vm-dir>/swtpm.sock`) is started before QEMU and reaped by PID on
`stop`/`destroy`. The device is `tpm-crb` on x86_64, `tpm-tis-device` on aarch64.
Requires the `swtpm` package; opt-in, so ordinary VMs are unaffected.

> A software TPM is **plumbing, not a trust anchor** — anything that can read its
> userspace can forge PCR state. Use it to develop/test attestation flows, not as
> production assurance (that needs a hardware TPM or a hypervisor-backed vTPM).

## Lifecycle

- `create` provisions but does **not** start the VM. Run `start` to boot.
- `start` is a no-op if the VM is already running.
- `stop` (default) sends `system_powerdown` via QMP, then waits up to 30 s; if the guest doesn't shut down cleanly, falls back to SIGTERM, then SIGKILL.
- `stop --force` skips QMP and goes straight to SIGTERM → SIGKILL.
- `destroy` will stop a running VM first (with `--force`), prompt for confirmation unless `--force`, and remove the per-VM directory. `--keep-disk` moves the qcow2 to `${LAB_STATE_DIR}/orphaned-disks/` before deletion.

## v0.2 additions

- **`from-chroot` backend** — implemented (x86_64): loop-device → `parted` MBR →
  `mkfs.ext4` → `rsync` the tree → `extlinux` → qcow2. Needs root.
- **Snapshots** — `snapshot {create|list|restore|delete} <vm> [name]`, offline
  qcow2 internal snapshots via `qemu-img`. Refuses to mutate a running VM's disk.
- **CPU topology + pinning** — `--cores`/`--threads` build an explicit `-smp`
  topology; `--cpu-pin "0-3"` binds the VM (and its vCPU threads) via `taskset`.
- **Bridge / tap networking** — `--network-mode {user|bridge|tap}` (+ `--bridge`,
  `--tap`). bridge/tap need root or a setuid `qemu-bridge-helper` + an allow entry
  in `/etc/qemu/bridge.conf`.
- **Per-VM cloud-init overrides** — `--packages`, `--runcmd` (repeatable), and
  `--user-data FILE` (verbatim full override). Also `[vm] packages=/runcmd=/user_data=` in TOML.
- **`--refresh-image`** — drop the cached cloud image and re-download.
- **Kali `.7z` integrity** — the prebuilt Kali archive is now verified against the
  release's published `SHA256SUMS` before extraction.

## Known gaps

- **Live migration** — out of scope for a single-host lab tool.
- **SSH-pubkey injection via `virt-customize`** — not implemented; cloud-init
  already injects pubkeys, and the non-cloud-init Kali path documents a one-time
  manual setup (libguestfs would be a heavy dep for little gain).
- **Kali arm64** — upstream publishes no arm64 QEMU prebuilt image; errors out
  until they do.
- **Alpine NoCloud URL** points to a specific release pattern that may need to be revisited as Alpine's image-server layout evolves.

## Tests

```bash
cd phase2-qemu-vm/tests
./run-all.sh
```

Each test self-skips (exit 77) if its preconditions are missing. The full suite needs:

- `qemu-system-x86_64`, `qemu-img`, `socat`, `genisoimage`, `curl`
- ~2 GB free disk (Debian cloud image is ~350 MB; overlays are tiny)
- KVM access for the fast tests
- ~3–5 minutes for the boot-and-ssh test
