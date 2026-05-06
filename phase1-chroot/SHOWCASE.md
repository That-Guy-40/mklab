# Phase 1 — chroots, the lab-create way

## What it gives you

`debootstrap` and a shell wrapper get you a Debian tree. `lab-chroot.sh`
gets you **a managed inventory** — three backends, three managers, six
architectures, declarative TOML on equal footing with CLI flags, and a
machine-readable `inspect --json` surface. One self-contained bash script
with no hidden state — destroy what it built, get the bytes back.

## 60-second demo

Paste this into a fresh Debian/Ubuntu shell. It does not install anything
unless you ask it to:

```bash
cd /path/to/LAB_CREATE_V2
alias lc='sudo phase1-chroot/lab-chroot.sh'

# 1. Build a Debian bookworm chroot, schroot-managed, named "demo":
sudo phase1-chroot/lab-chroot.sh create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch x86_64 --target /var/chroots/demo \
    --manager schroot --name demo

# 2. Confirm it's real:
sudo phase1-chroot/lab-chroot.sh enter demo -- cat /etc/os-release
# → PRETTY_NAME="Debian GNU/Linux 12 (bookworm)" ...

# 3. See it in your inventory (and in schroot's view of the world):
phase1-chroot/lab-chroot.sh list

# 4. Grab a structured snapshot for your scripts/TUI:
phase1-chroot/lab-chroot.sh inspect demo --json | jq .os_release

# 5. Hand the tree off to Phase 3/4/5 as a tarball:
sudo phase1-chroot/lab-chroot.sh export-tarball demo --output /tmp/demo.tar.gz
```

Five commands, one chroot, one tarball, one introspection feed.

## Feature tour

### 3 backends

| Backend | Distros | What it does |
|---|---|---|
| `debootstrap` | Debian, Ubuntu, Kali | Native + foreign-arch two-stage; fetches the right keyring per distro |
| `dnf` | Rocky (RHEL-family) | Bootstraps with `rocky-release`/`rocky-repos`/`rocky-gpg-keys` seed; chroot ships with `dnf` and `rpm` so it's self-extensible |
| `host-copy` | (none — slim) | Walks `ldd` for the binaries you name, copies them + every shared lib + the dynamic loader; ideal for vsftpd/sftp jails or a busybox-only sandbox |

```bash
# Slim: one binary plus its libs, nothing else (sub-second build, no network):
sudo phase1-chroot/lab-chroot.sh create \
    --backend host-copy --target /var/jails/sftp-only \
    --binaries /usr/lib/openssh/sftp-server \
    --extras /etc/passwd,/etc/group
```

### 3 managers (bare → schroot → nspawn upgrade story)

A chroot is just a directory. What you do with it is the manager's job:

| Manager | What you get | When to pick it |
|---|---|---|
| `none` (default) | Bare `chroot(8)` + tracked bind-mounts so cleanup works | Throwaway exploration, scripted use |
| `schroot` | sbuild-style isolation, `/etc/schroot/chroot.d/<name>.conf` written for you | Reproducible builds, `schroot -c <name>` from anywhere |
| `nspawn` | Registered with `machinectl`, optionally `boot = true` for full PID 1 | Real PID namespace, networking, `machinectl shell`/`poweroff` |

The upgrade story: the on-disk tree is the same regardless of manager —
only the registration layer differs, and `destroy` reverses whichever
layer was added.

```bash
sudo phase1-chroot/lab-chroot.sh create --config examples/chroot-nspawn-managed.toml
sudo systemd-nspawn -b -M bookworm-nspawn   # actually boot it
```

### Foreign architectures

x86_64, aarch64, armv7l, ppc64le, riscv64, s390x — pick with `--arch`. On
a foreign arch the script verifies `qemu-<arch>-static` is on the host
(refuses cleanly if not), checks `binfmt_misc` is registered, then runs
the canonical two-stage flow: `--foreign` first stage on host, then
`/debootstrap/debootstrap --second-stage` under transparent emulation.

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch aarch64 --target /var/chroots/bookworm-arm64 \
    --variant minbase

sudo chroot /var/chroots/bookworm-arm64 /usr/bin/uname -m   # → aarch64
sudo chroot /var/chroots/bookworm-arm64 /usr/bin/file /bin/ls   # → ARM aarch64
```

Every binary in the tree is genuinely the foreign arch, executed under
qemu-user. Rocky/dnf foreign-arch also works (via `--forcearch`), though
heavy install scriptlets under qemu-user are sometimes flaky — native dnf
is the recommended path.

### Declarative TOML

Every CLI flag has a TOML key with the same name. Build identical chroots
either way — `test-cli-vs-config-parity.sh` compares the resulting trees
byte-for-byte. A single config can carry many `[[chroot]]` blocks.

```toml
# examples/chroot-debian-bookworm.toml
[[chroot]]
name    = "bookworm-amd64"
backend = "debootstrap"
distro  = "debian"
suite   = "bookworm"
arch    = "x86_64"
target  = "/var/chroots/bookworm-amd64"
variant = "minbase"
include = ["build-essential", "vim-tiny", "ca-certificates"]
manager = "schroot"

  [chroot.schroot]
  type   = "directory"
  groups = ["sbuild", "sudo"]
```

Reference configs to crib from: `examples/chroot-debian-bookworm.toml`
(schroot-managed, sbuild-ready), `examples/chroot-rocky9-vsftpd.toml`
(Rocky 9 + vsftpd jail), `examples/chroot-host-copy-busybox.toml`
(host-copy, busybox + a few `/etc` files), `examples/chroot-nspawn-managed.toml`
(`boot = true` + `register = true`, bootable under `systemd-nspawn -b`).

### `inspect --json` — live state

Added in commit `6f2119e`. Pairs the saved manifest with cheap live probes
— target dir size/owner, parsed `/etc/os-release` (awk-parsed, never
sourced — the chroot's environment is untrusted), dpkg/rpm package count,
manager registration state, and foreign-arch interpreter availability.
Schema is versioned (`schema_version: 1`).

```bash
phase1-chroot/lab-chroot.sh inspect demo --json | jq
```

```jsonc
// sample output (truncated)
{
  "schema_version": 1,
  "name": "demo",
  "manifest": { "backend": "debootstrap", "distro": "debian",
                "suite": "bookworm", "arch": "x86_64", "manager": "schroot" },
  "target":    { "exists": true, "size_bytes": 312983552, "owner": "root:root" },
  "os_release":  { "id": "debian", "version_codename": "bookworm",
                   "pretty_name": "Debian GNU/Linux 12 (bookworm)" },
  "packages":    { "manager": "dpkg", "count": 91 },
  "manager_state": { "kind": "schroot", "registered": true, "active_state": null },
  "foreign_arch":  null
}
```

Drop `--json` for the same data rendered as `[manifest]` and `[live]`
sections — readable at a glance, useful for `grep`. The Phase 6 TUI's
chroot detail panel renders straight from the JSON form.

### `export-initrd` — package any chroot as an HTTP-netboot initrd

The new `export-initrd` verb converts a Phase 1 chroot into a kernel +
cpio.gz initrd pair that iPXE (or QEMU `-kernel`/`-initrd`) can boot
directly over HTTP — no disk image, no bootloader, no installer.

**`init_script` TOML field** controls what runs as PID 1:

| Value | What ships | Size |
|---|---|---|
| `"busybox"` | BusyBox `init` + minimal `/etc/inittab` | ~150 MB initrd |
| `"systemd"` | Full systemd init inside the chroot | ~400 MB initrd |
| `/host/path` | Copies the named file to `/init` verbatim | your call |

If `init_script` is unset and `/init` doesn't already exist in the
chroot, the verb auto-detects: prefers systemd if `systemd` is
installed, otherwise busybox.

**`--strip-modules`** drops `/lib/modules` from the cpio archive —
useful when you're booting with the host kernel's modules or want to
shave ~50–100 MB from the initrd.

```bash
sudo lab-chroot.sh create --config examples/chroot-netboot-minimal.toml
sudo lab-chroot.sh export-initrd netboot-minimal \
    --kernel /srv/netboot/kernel \
    --output /srv/netboot/initrd.gz
# → /srv/netboot/kernel + /srv/netboot/initrd.gz, both readable by non-root
```

The two initrd tracks:

- **Minimal** (`chroot-netboot-minimal.toml`): busybox init, ~150 MB
  initrd, boots in seconds — ideal for network rescue, PXE testing, or
  a live-boot scratchpad.
- **Full Debian** (`chroot-netboot-full.toml`): systemd PID 1, full
  Debian userland (Kenneth's approach), ~400 MB initrd — same boot
  experience as a real Debian install, served entirely over HTTP.

Boot it with Phase 2 (`vm-netboot-direct.toml`) or serve it via
Phase 4 (`podman-netboot-server.toml`).

### `export-tarball` — the cross-phase bridge

The clean, rootless-friendly handoff to Phase 3/4/5. Tarballs the chroot
(excluding `/proc`, `/sys`, `/dev`, `/run`, `/tmp`), preserves numeric
ownership so `podman import` interprets it honestly, and `chown`s the
output back to the invoking user so unprivileged podman/incus can read it.

```bash
sudo phase1-chroot/lab-chroot.sh export-tarball demo --output /tmp/demo.tar.gz
# [info] exporting /var/chroots/demo → /tmp/demo.tar.gz
# [info] wrote /tmp/demo.tar.gz (98M)
```

Marquee use case: **build Kali via debootstrap once, then ship it
everywhere.** One tarball is ready to `podman import`, `lxc image import
--filename`, or feed a Phase 2 `from-chroot` VM — one source of truth for
the "Kali userland" across container, instance, and VM.

## Integrations

The `[lab]` block at the top of any chroot/VM/container/instance config
groups sibling resources under a shared lab tag — `phase1-chroot/lab-chroot.sh
list --lab <name>` and the Phase 6 TUI both filter on it, treating an entire
lab as one unit.

### → Phase 2 (VMs from your chroot)

Phase 2's `from-chroot` backend takes a Phase 1 tree (with a kernel and
initrd installed inside it) and packs it into a bootable BIOS+MBR+ext4
qcow2. The chroot is the source of truth for the userland; Phase 2
supplies the disk geometry, bootloader, and machine config. See
`examples/vm-from-chroot-debian.toml`.

Phase 2 also supports the `export-initrd` → kernel+initrd boot path:
pass the kernel and initrd produced by `export-initrd` directly to
`vm-netboot-direct.toml` (QEMU `-kernel`/`-initrd`) and skip the disk
image entirely. See [Phase 2 (VMs)](../phase2-qemu-vm/SHOWCASE.md) for
the full iPXE simulation walkthrough.

```toml
[[vm]]
name    = "vm-from-chroot-demo"
backend = "from-chroot"
chroot  = "/var/chroots/vm-seed"
arch    = "x86_64"
memory  = "1G"
```

### → Phase 3/4 (containers from your chroot)

Both Phase 3 (Docker) and Phase 4 (rootless Podman) accept Phase 1 chroots
either as `from_chroot = "/path/to/chroot"` (direct) or `from_tarball =
"/path/to/foo.tar.gz"` (the `export-tarball` output — rootless-clean, no
`sudo` on the import side).

```toml
# examples/podman-from-chroot.toml
[[service]]
name        = "payload-builder"
from_chroot = "/var/chroots/kali-amd64"
userns      = "keep-id"           # UID N inside == UID N on host
command     = "sleep infinity"
```

### → Phase 5 (LXD/Incus instances from your chroot)

For containers, point at the tarball (Phase 1 chroots are root-owned, so
the tarball path is the readable one for unprivileged Incus). For LXD/Incus
VMs, take the two-hop route: chroot → Phase 2 `from-chroot` qcow2 → Phase 5
`from_qcow2` instance.

```toml
# examples/lxd-from-chroot.toml
[[instance]]
name         = "attacker"
type         = "container"
from_tarball = "/tmp/kali-amd64.tar.gz"
```

### → Phase 6 (TUI surfaces all your chroots)

The Phase 6 Textual TUI calls `inspect --json` to render the chroot
detail panel — every field above shows up in the side pane, with
`manager_state.active` as a live indicator and `foreign_arch.qemu_user_static_available`
as a green/red dot. Chroots with a `lab` tag appear in the topology view
alongside the VMs/containers/instances of the same lab as one composite resource.

## Where next

- [`PLAN.md` § Phase 1](../PLAN.md#phase-1--chroots-phase1-chrootlab-chrootsh) — design rationale, exit criteria, what's in/out of v0.1
- [`MANUAL_TESTING.md`](MANUAL_TESTING.md) — every verb, every backend, every manager, walkthrough form
- [`README.md`](README.md) — reference docs, install matrix, TOML schema
- [`../examples/`](../examples/) — every TOML referenced here, plus the cross-phase ones
- Sibling SHOWCASEs:
  [Phase 2 (VMs)](../phase2-qemu-vm/SHOWCASE.md) ·
  [Phase 3 (docker)](../phase3-docker/SHOWCASE.md) ·
  [Phase 4 (podman)](../phase4-podman/SHOWCASE.md) ·
  [Phase 5 (LXD/Incus)](../phase5-lxd/SHOWCASE.md) ·
  [Phase 6 (TUI)](../phase6-tui/SHOWCASE.md)
