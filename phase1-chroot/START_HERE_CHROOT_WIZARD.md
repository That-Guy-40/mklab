# Start here — Phase 1: Chroot (`lab-chroot.sh`)

Phase 1 builds and manages **chroot environments** — isolated filesystem trees
you can enter, run commands inside, and throw away. They're the building blocks
that every other phase can consume: Phase 2 can boot one as a VM, Phase 3/4 can
import one as a container image, Phase 5 can turn one into an LXD instance.

---

## Option A — use the wizard (recommended)

If you have the Phase 6 TUI running:

```bash
cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
python3 -m lab_tui          # or: python3 phase6-tui/main.py
```

Press **`n`** → select **Phase 1 — Chroot** → fill in the form → press **Save**.
The wizard writes a TOML file to `examples/chroot-<lab>.toml`.
Then come back here and run the create command below.

---

## Option B — three-minute quickstart (no wizard needed)

### 1. Install prerequisites

```bash
sudo apt-get install -y bash jq debootstrap debian-archive-keyring yq
```

### 2. Create a Debian bookworm chroot

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --backend debootstrap \
    --distro  debian \
    --suite   bookworm \
    --arch    x86_64 \
    --target  /var/chroots/bookworm
```

### 3. Enter it

```bash
sudo phase1-chroot/lab-chroot.sh enter bookworm
# You are now inside the chroot — a fresh Debian root filesystem.
cat /etc/os-release
exit
```

### 4. Tear it down

```bash
sudo phase1-chroot/lab-chroot.sh destroy bookworm --force
```

---

## Option C — use a TOML config (from the wizard or an example)

```bash
# The simplest example — a schroot-managed Debian bookworm chroot:
sudo phase1-chroot/lab-chroot.sh create --config examples/chroot-examples/chroot-debian-bookworm.toml
sudo phase1-chroot/lab-chroot.sh enter  bookworm-amd64
sudo phase1-chroot/lab-chroot.sh destroy bookworm-amd64 --force
```

Other ready-to-run examples in `examples/`:

| File | What it builds |
|---|---|
| `chroot-examples/chroot-debian-bookworm.toml` | Debian bookworm, schroot-managed, with build tools |
| `chroot-examples/chroot-rocky9-vsftpd.toml` | Rocky 9 via `dnf` backend, vsftpd installed |
| `chroot-examples/chroot-host-copy-busybox.toml` | Minimal jail from host binaries (`host-copy` backend) |
| `chroot-examples/chroot-nspawn-managed.toml` | Debian, `systemd-nspawn`-managed, full PID 1 inside |
| `chroot-examples/chroot-write-files-demo.toml` | Shows `write_files` — inject config files at build time |

---

## Anatomy of a config

```toml
[[chroot]]
name    = "my-chroot"      # used by list/enter/destroy
backend = "debootstrap"   # debootstrap | dnf | host-copy
distro  = "debian"
suite   = "bookworm"       # Debian/Ubuntu release name; Rocky: "9"
arch    = "x86_64"         # or aarch64, armv7l, ppc64le, riscv64, s390x
target  = "/var/chroots/my-chroot"
include = ["curl", "vim-tiny"]   # extra packages to install
manager = "none"           # none | schroot | nspawn
```

Foreign-arch works too — the script sets up `qemu-user-static` + `binfmt_misc`
automatically if the host is x86_64 and the target arch is aarch64 (or any other
supported arch).

---

## What just happened — the "why" under the hood

A **chroot** changes the apparent root directory for a process.
`debootstrap` bootstraps a minimal Debian root filesystem in two stages:

1. **Stage 1** (runs on the host): downloads and unpacks the base packages
   to `$target` using the host architecture.
2. **Stage 2** (runs inside the chroot): runs the package install scripts
   with the guest libc and interpreter. For foreign arches, `qemu-user-static`
   provides the binary translator so aarch64 ELF binaries run on x86_64.

The `target` directory IS the chroot — there's no VM, no namespace, no image
file. `/proc`, `/sys`, `/dev` are bind-mounted in during `enter` (and unmounted
on exit / recorded in `.lab-chroot-mounts` so `destroy` can clean them up even
after a crash).

`manager = "schroot"` registers the chroot with `schroot`'s config system so
unprivileged users in the right group can `schroot -c my-chroot` without `sudo`.
`manager = "nspawn"` hands it to `systemd-nspawn`, which adds proper namespacing
(PID, network, IPC) on top of the bare chroot.

---

## Next steps

- **`README.md`** — complete flag reference, backends, managers, rootless mode
- **`SHOWCASE.md`** — live-verified demos for every backend
- **`MANUAL_TESTING.md`** — step-by-step verification walkthrough
- **`examples/`** — every TOML above, plus netboot-builder and write-files variants
- **Phase 2** (`START_HERE_VM_WIZARD.md`) — boot this chroot as a VM
- **Phase 3** (`START_HERE_DOCKER_WIZARD.md`) — import this chroot as a Docker image
- **Phase 4** (`START_HERE_PODMAN_WIZARD.md`) — import this chroot rootlessly
- **Phase 5** (`START_HERE_LXC_WIZARD.md`) — launch this chroot as an LXD instance
