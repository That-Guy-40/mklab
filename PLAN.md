# LAB_CREATE_V2 — Project Plan

A staged build-out of a lab-environment provisioning toolkit. Each phase ships
as a **self-contained script** (plus its own copy of any shared helpers) so the
repo can be rebased to any prior phase as a known-good checkpoint.

## Guiding constraints

- **Self-containment per phase.** No phase imports from another. Shared
  helpers (logging, arch detection, config parsing, dependency probing) are
  *copied* into each phase script, not symlinked or sourced from a sibling.
  Cost: duplication. Benefit: any single phase script runs standalone after a
  rebase that drops later phases.
- **No mocks.** `schroot` is acceptable as a chroot *manager* but is optional;
  the bare `chroot(8)` path must always work.
- **Multi-arch from day one.** Every backend that *can* host a foreign
  architecture must do so via `qemu-user-static` + `binfmt_misc` (chroots,
  containers) or QEMU system emulation (VMs). Target arch matrix:
  `x86_64, aarch64, armv7l, ppc64le, riscv64, s390x`.
- **CLI + config file.** Every phase exposes the same shape: positional
  subcommand, flags for one-off use, `--config FILE` for declarative use.
  Flags override config keys. **All phases use TOML** (Phases 1–5 via
  `tomlq` / `yq -p toml` / `dasel`; Phase 6 via Python `tomllib`).
- **Implementation languages.**
  - **Phases 1–5: Bash** (`/bin/bash`, `set -euo pipefail`), POSIX tools, and
    targeted use of `awk`/`sed`/`dd` where those are the right tool. One
    self-contained `lab-*.sh` per phase, plus a copy of shared helpers in
    each phase directory. Rationale: tight fit for orchestrating
    `debootstrap`/`dnf`/`qemu-system-*`/`docker`/`lxc`, no runtime to
    install, easy to maintain and extend by hand.
  - **Phase 6 (TUI) and Phase 6b (web UI): Python 3.11+.** Phase 6 uses
    Textual; Phase 6b uses FastAPI + HTMX. Both call into the bash phase
    scripts via `subprocess` and read state from the standardized state
    locations the bash phases write — they never reimplement provisioning
    logic.
- **Idempotent.** Re-running a phase script with the same config converges,
  doesn't duplicate state, and exits 0 if nothing to do.
- **Root vs rootless.** Default is root (simpler, matches debootstrap/dnf).
  Phase 1 includes a `--rootless` mode based on the muxup.com cross-arch
  technique (user namespaces + fakeroot + qemu-user-static) for the chroot
  backends that support it.

## Repo layout

```
LAB_CREATE_V2/
├── PLAN.md                          # this file
├── README.md                        # quickstart + phase index
├── examples/
│   ├── chroot-debian-bookworm.toml
│   ├── chroot-rocky9-vsftpd.toml
│   ├── chroot-host-copy-busybox.toml
│   ├── chroot-nspawn-managed.toml
│   ├── vm-debian-aarch64.yaml
│   └── microvm-alpine.yaml
├── phase1-chroot/
│   ├── lab-chroot.sh                # the script
│   ├── lab-chroot.1                 # man page (optional)
│   ├── tests/
│   │   ├── test-debootstrap-amd64.sh
│   │   ├── test-debootstrap-arm64-foreign.sh
│   │   ├── test-dnf-rocky9.sh
│   │   ├── test-host-copy.sh
│   │   └── test-schroot-integration.sh
│   └── README.md
├── phase2-qemu-vm/
│   ├── lab-vm.sh
│   ├── tests/
│   └── README.md
├── phase3-docker/
│   ├── lab-docker.sh
│   └── ...
├── phase4-podman/
│   └── ...
├── phase5-lxd/
│   └── ...
├── phase6-tui/                      # optional Textual TUI front-end
│   ├── pyproject.toml
│   ├── lab_tui/
│   │   ├── __main__.py              # entry: `python -m lab_tui`
│   │   ├── app.py                   # Textual App
│   │   ├── screens/                 # resource browser, detail, wizards
│   │   ├── backends/                # thin subprocess wrappers per phase
│   │   ├── state.py                 # reads phase state files
│   │   └── topology.py              # lab.toml parsing
│   ├── tests/
│   └── README.md
└── phase6b-web/                     # optional FastAPI + HTMX web UI
    ├── pyproject.toml
    ├── lab_web/
    │   ├── __main__.py              # entry: `python -m lab_web`
    │   ├── app.py                   # FastAPI app
    │   ├── routes/
    │   ├── templates/               # Jinja2 + HTMX partials
    │   ├── static/
    │   └── backends/                # shared shape with phase6-tui
    ├── tests/
    └── README.md
```

Each `phaseN-*/` directory is a complete unit. Deleting `phase3-docker/`
through `phase6b-web/` leaves Phase 1 and Phase 2 fully working. Phase 6
and 6b each ship their own `pyproject.toml`; they may share helper code
across the two by duplication only (per the self-containment rule), not
by importing across directories.

---

## Phase 1 — Chroots (`phase1-chroot/lab-chroot.sh`)

### Goals

Create a chroot of one of four flavors, on any of the listed architectures
(host or foreign), driven by CLI flags or a YAML config file.

### Backends

| Backend ID    | Distros                         | Tool                             | Foreign-arch path                                |
|---------------|---------------------------------|----------------------------------|--------------------------------------------------|
| `debootstrap` | Debian, Ubuntu, Kali            | `debootstrap`                    | `--foreign` first stage + `--second-stage` under qemu-user-static |
| `dnf`         | Rocky Linux (8, 9, 10)          | `dnf --installroot` (yum fallback) | qemu-user-static for non-host arch              |
| `host-copy`   | none — derived from running host| `ldd` walk + `cp`                | host arch only (by definition)                  |

Kali is handled by the `debootstrap` backend with a Kali-specific keyring and
mirror; the script ships `kali-archive-keyring.gpg` lookup logic, not the key
itself.

### CLI

```
lab-chroot.sh create   --backend {debootstrap|dnf|host-copy} \
                       --distro  {debian|ubuntu|kali|rocky} \
                       --suite   <release-codename-or-version> \
                       --arch    {x86_64|aarch64|armv7l|ppc64le|riscv64|s390x} \
                       --target  /path/to/chroot \
                       [--mirror URL] [--include pkg,pkg,...] \
                       [--variant minbase|buildd|fakechroot] \
                       [--manager {none|schroot|nspawn}] \
                       [--rootless] [--keep-cache]

lab-chroot.sh create   --config chroot.toml
lab-chroot.sh enter    /path/to/chroot [-- cmd args...]
lab-chroot.sh destroy  /path/to/chroot [--force]
lab-chroot.sh list                                 # works for schroot or nspawn
lab-chroot.sh verify   /path/to/chroot             # arch, /etc/os-release, basic exec test
```

### Config file (TOML)

```toml
[[chroot]]
name    = "bookworm-amd64"
backend = "debootstrap"
distro  = "debian"
suite   = "bookworm"
arch    = "x86_64"
target  = "/var/chroots/bookworm-amd64"
mirror  = "http://deb.debian.org/debian"
include = ["build-essential", "vim-tiny", "ca-certificates"]
manager = "schroot"

  [chroot.schroot]
  type   = "directory"
  groups = ["sbuild", "sudo"]

[[chroot]]
name    = "bookworm-nspawn"
backend = "debootstrap"
distro  = "debian"
suite   = "bookworm"
arch    = "x86_64"
target  = "/var/lib/machines/bookworm-nspawn"
manager = "nspawn"

  [chroot.nspawn]
  boot         = false              # true → systemd-nspawn -b (full PID1)
  network      = "host"             # host | veth | none
  bind_ro      = ["/etc/resolv.conf"]
  capabilities = ["CAP_NET_ADMIN"]
  register     = true               # register with machinectl

[[chroot]]
name    = "rocky9-vsftpd"
backend = "dnf"
distro  = "rocky"
suite   = "9"
arch    = "x86_64"
target  = "/srv/ftpjail"
groups  = ["core"]                  # dnf groups
include = ["vsftpd", "openssh-clients"]
post = [
  "useradd -R {{target}} ftpuser",
  "chown root:root {{target}}",
  "chmod 755 {{target}}",
]

[[chroot]]
name     = "minimal-busybox"
backend  = "host-copy"
target   = "/var/jails/busybox"
binaries = ["/bin/busybox", "/usr/bin/sftp-server"]
extras   = ["/etc/resolv.conf", "/etc/nsswitch.conf"]
```

### Foreign-arch flow (debootstrap)

1. Verify `qemu-user-static` is installed and `binfmt_misc` is registered for
   the requested arch (probe `/proc/sys/fs/binfmt_misc/qemu-<arch>`). If
   missing, attempt `update-binfmts --enable qemu-<arch>` or instruct the user
   how to enable it (no silent kernel changes).
2. Stage 1: `debootstrap --foreign --arch=<arch> ...`.
3. Copy `qemu-<arch>-static` into `<target>/usr/bin/`.
4. Stage 2: `chroot <target> /debootstrap/debootstrap --second-stage`.
5. Optional: register the chroot with `schroot` and write a profile under
   `/etc/schroot/chroot.d/`.

### Foreign-arch flow (dnf)

`dnf` itself doesn't have a `--foreign` mode. Approach: bind-mount
`qemu-<arch>-static` into a minimal scratch root, then `dnf --installroot
--forcearch=<rpm-arch>` with the appropriate Rocky `releasever`. Validate that
the chosen arch is actually published by Rocky (e.g., armv7l isn't, so the
script must fail loudly with a clear message rather than producing a broken
tree). Mapping table lives in the script:

| Our arch  | RPM arch        | Rocky support? |
|-----------|-----------------|----------------|
| x86_64    | x86_64          | yes            |
| aarch64   | aarch64         | yes            |
| ppc64le   | ppc64le         | yes (SIG)      |
| s390x     | s390x           | yes (SIG)      |
| riscv64   | riscv64         | yes (SIG, 10+) |
| armv7l    | armv7hl         | **no** — error |

### `host-copy` backend

For minimal jails (vsftpd-style, sftp-only, custom service sandboxes). For
each requested binary:

1. `ldd <binary>` → resolved library set.
2. Copy binary + libraries preserving paths.
3. Copy the dynamic loader (`/lib64/ld-linux-x86-64.so.2` etc.) — easy to
   miss; explicit step.
4. Optionally copy a curated set of `/etc` files (`resolv.conf`,
   `nsswitch.conf`, `passwd`, `group`, `localtime`).
5. `mknod` core devices (`null`, `zero`, `random`, `urandom`, `tty`) only if
   running as root and `--devices` is set.
6. Verify by running `chroot <target> <binary> --version` (or a configurable
   smoke command).

### Rootless mode (`--rootless`)

Follows the muxup.com pattern: `unshare -Ur` + `fakechroot` + `fakeroot` +
`qemu-user-static`. Limitations are documented in `phase1-chroot/README.md`
(no `mknod`, no real uid/gid mapping inside the chroot beyond the user's
subuid/subgid range, no binfmt registration — must be pre-registered by an
admin or use `qemu-<arch>-static -execve`-style wrappers).

### Chroot managers (all optional)

The chroot tree itself is always usable with bare `chroot(8)` —
`--manager none` is the default. Two optional managers are supported in
Phase 1; both are detected at runtime and the script errors out cleanly with
an install hint if the requested manager isn't present.

**`--manager schroot`** — after build, write `/etc/schroot/chroot.d/<name>.conf`
with type/directory/users/groups/profile keys derived from the config.
`lab-chroot.sh enter <name>` becomes a wrapper around `schroot -c <name>`.
`destroy` removes the conf file in addition to the tree.

**`--manager nspawn`** — relocate (or symlink, configurable) the tree under
`/var/lib/machines/<name>` so `machinectl` sees it. `enter` becomes
`systemd-nspawn -D <path>` (interactive shell) or `systemd-nspawn -b -D
<path>` if `boot = true`. The `[chroot.nspawn]` section maps to
`systemd-nspawn` flags: `network` → `--network-veth` / `--network-bridge` /
`--private-network`, `bind_ro` → `--bind-ro=`, `capabilities` →
`--capability=`, `register` → `--register=yes|no`. When `boot = true`, the
chroot must contain a working systemd; `host-copy` chroots are explicitly
rejected for `boot = true` and the script errors out before doing anything.

**`--manager none`** — `enter` does the bind-mounts (`/proc`, `/sys`, `/dev`,
`/dev/pts`, `/run`) itself and calls `chroot`. `destroy` unmounts in reverse
order before `rm -rf`. Bind-mount tracking lives in
`<target>/.lab-chroot-mounts` so a crashed `enter` can be cleaned up by
`destroy`.

`lab-chroot.sh list` enumerates from whichever managers are present:
`schroot -l` output and `machinectl list-images` output, plus any
script-managed bare chroots tracked in `~/.local/state/lab-create/chroots/`.

### Dependency probing

On startup the script runs a preflight that checks for the tools each
selected backend and manager needs and prints the exact install command for
the host distro (detected via `/etc/os-release`). It does **not**
auto-install — the user runs the suggested command. Probed tools:

| Need                      | Tool(s)                                  |
|---------------------------|------------------------------------------|
| Always                    | `tar`, `mount`, `chroot`, TOML parser    |
| `--backend debootstrap`   | `debootstrap`, distro keyring package    |
| `--backend dnf`           | `dnf` (or `yum` fallback), `rpm`         |
| `--backend host-copy`     | `ldd`, `cp`                              |
| Foreign arch              | `qemu-user-static`, `binfmt-support` or `systemd-binfmt` |
| `--manager schroot`       | `schroot`                                |
| `--manager nspawn`        | `systemd-nspawn`, `machinectl`           |
| Kali distro               | `kali-archive-keyring` package on host (script refuses to proceed if `/usr/share/keyrings/kali-archive-keyring.gpg` is absent and prints the install command) |

**TOML parser**: prefer `tomlq` (kislyuk/yq) when present; fall back to
`yq` v4+ with `-p toml -o json` (mikefarah/yq); fall back to `dasel`. The
script picks whichever is installed and abstracts the call behind a single
shell function. Preflight errors if none of the three are present.

### Tests

Each test is a script that exits non-zero on failure. CI-friendly. Tests live
in `phase1-chroot/tests/` and assume root (or document the rootless variant).
Coverage:

- Native amd64 Debian bookworm via debootstrap; verify `/etc/os-release`,
  `apt-get update` works inside.
- Foreign aarch64 Debian via two-stage debootstrap; verify `uname -m` inside
  reports `aarch64` (under qemu-user-static).
- Native Rocky 9 via dnf with `core` group; verify `rpm -qa` works.
- `host-copy` of `/bin/busybox`; verify `chroot ... busybox echo ok` works.
- `schroot` registration round-trip: build, register, `schroot -l` shows it,
  `schroot -c <name> -- whoami` returns root, destroy cleans up the conf
  file.
- `nspawn` integration: build a Debian chroot, register under
  `/var/lib/machines/`, `machinectl list-images` shows it, `systemd-nspawn -D
  ... echo ok` works, `boot = true` variant launches systemd PID1 and exits
  cleanly via `machinectl poweroff`.
- `--manager none` is the default-path test: build, `enter -- whoami`,
  `destroy`, with bind-mount cleanup verified by `mount | grep <target>`
  returning empty.
- Kali debootstrap: with the keyring **absent**, the script must error out
  with the install hint and not touch the target directory; with the keyring
  **present**, the build succeeds.

### Phase 1 exit criteria

- All three backends (`debootstrap`, `dnf`, `host-copy`) produce a working
  chroot on x86_64 host.
- All three managers (`none`, `schroot`, `nspawn`) work with at least one
  backend each, and the script behaves correctly when an *unrequested*
  manager is missing from the host (no spurious errors) and when a
  *requested* manager is missing (clear error + install hint, no partial
  state left behind).
- At least one foreign-arch debootstrap (aarch64) succeeds.
- `host-copy` can build a minimal vsftpd jail per the OneUpTime-style
  example.
- `--config` parity with CLI flags is verified by a test that runs the same
  chroot built both ways and diffs the resulting trees (modulo timestamps).
- Kali keyring-missing path errors out cleanly without touching the target.
- Rocky armv7l errors out cleanly with an explanatory message.

---

## Phase 2 — QEMU full VMs + microvms (`phase2-qemu-vm/lab-vm.sh`)

### Goals

Create and run QEMU VMs and microvms across the same arch matrix. Two
machine-class profiles:

- **Full VM** — `q35`/`virt`/`pseries`/`virt-riscv`/`s390-ccw-virtio` machine
  types, full firmware (OVMF/AAVMF/SLOF/opensbi), virtio devices,
  cloud-init-friendly disk images.
- **microvm** — QEMU's `microvm` machine type (x86_64, aarch64) for fast
  boot; falls back to minimal `virt` config on arches where `microvm` is
  unsupported, with a clear warning.

### Backends within the phase

- **`disk-image`** — download/cache an upstream cloud image (Debian, Ubuntu,
  Rocky generic-cloud, Alpine for microvm) and seed via cloud-init NoCloud
  ISO. Image cache lives under `~/.cache/lab-create/images/`.
- **`from-chroot`** — take a Phase 1 chroot directory, package it into a raw
  disk image with a kernel + initramfs (extracted from the chroot's installed
  kernel package, or downloaded for the target arch). This is the bridge
  that makes Phase 1 useful as a VM source without coupling the two scripts.
- **`kernel+initrd`** — direct `-kernel`/`-initrd`/`-append` boot for
  microvm-style fast iteration.

### CLI

```
lab-vm.sh create   --name N --arch A --memory 2G --cpus 2 \
                   --backend {disk-image|from-chroot|kernel+initrd} \
                   --image|--chroot|--kernel ... \
                   [--microvm] [--accel {kvm|hvf|tcg}] \
                   [--net {user|bridge:br0|tap}] \
                   [--ssh-port 2222] [--cloud-init user-data.yaml]
lab-vm.sh start    NAME
lab-vm.sh stop     NAME [--graceful]
lab-vm.sh console  NAME           # attach to serial
lab-vm.sh ssh      NAME [-- cmd]
lab-vm.sh destroy  NAME [--keep-disk]
lab-vm.sh list
```

### Acceleration matrix

- Host arch == guest arch and `/dev/kvm` accessible → `accel=kvm`.
- Otherwise → `accel=tcg` (slow but works for any arch).
- The script never silently falls back; it prints which acceleration it's
  using and why.

### Firmware/loader matrix

| Guest arch | Machine     | Firmware                                    |
|------------|-------------|---------------------------------------------|
| x86_64     | q35/microvm | OVMF (`/usr/share/OVMF/OVMF_CODE.fd`)       |
| aarch64    | virt        | AAVMF (`/usr/share/AAVMF/AAVMF_CODE.fd`)    |
| armv7l     | virt        | u-boot (`/usr/share/u-boot/qemu_arm/`)      |
| ppc64le    | pseries     | SLOF (bundled with QEMU)                    |
| riscv64    | virt        | OpenSBI + u-boot                            |
| s390x      | s390-ccw    | s390-ccw bios (bundled)                     |

State files (per-VM): `~/.local/share/lab-create/vms/<name>/{config.yaml,
disk.qcow2, seed.iso, qemu.pid, qemu.monitor, serial.sock}`.

### Phase 2 exit criteria

- Boot a Debian cloud image as a full VM on x86_64 (KVM) and aarch64 (TCG).
- Boot an Alpine microvm on x86_64 in under 2 s wall time after image
  warm-up.
- `from-chroot` round-trip: build a Debian chroot in Phase 1, package it,
  boot it, ssh in.

### Phase 2: Kali as a guest distro — landed

Phase 1 supports Kali via debootstrap. Phase 2 now supports Kali as a
`disk-image` VM guest via Kali's prebuilt QEMU image (`.7z`-archived
qcow2) published at `https://cdimage.kali.org/kali-<suite>/`.

What shipped:

- `image_url()` `kali)` arm → `kali-linux-<release>-qemu-amd64.7z`
  (x86_64 only — upstream doesn't publish prebuilt arm64 QEMU images).
- `kali_resolve_suite()` maps the rolling aliases `kali-rolling` /
  `rolling` / `current` onto the concrete release tag at
  `https://cdimage.kali.org/current/` by parsing its `SHA256SUMS`
  (stdlib format, `<hash>  <filename>` with two spaces). Pinned tags
  like `"2026.1"` pass through unchanged. This matches Phase 1's
  `suite = kali-rolling` idiom even though the two phases use the
  string for different purposes (apt archive vs. cdimage alias).
- `cache_image()` detects `.7z` URLs, extracts with `7z` / `7za` / `7zz`
  (whichever is in PATH), promotes the inner `.qcow2`, and caches it
  using the RESOLVED release tag — old VMs keep their original backing
  image across a Kali release bump, new creates pick up the new one.
- `create_one()` skips the cloud-init seed ISO when `distro=kali`, since
  the prebuilt image doesn't ship cloud-init. `ssh_user` is set to
  `kali`. Post-create logs walk the user through the one-time manual
  firstboot (console login as `kali/kali`, enable ssh, drop pubkey).
- `examples/vm-kali-amd64.toml` — minimal spec matching Debian/Alpine
  examples, with a header comment documenting the manual firstboot.
- CLI help: `--distro` now lists `kali`, `--suite` examples include
  `kali-rolling`.

Known limitations / future work:

- **No automated SSH pubkey injection.** Without cloud-init, the first
  login still has to be on the serial console. A future improvement
  would use `virt-customize` (libguestfs) to mutate the overlay qcow2
  pre-first-boot: enable sshd, drop the pubkey into
  `/home/kali/.ssh/authorized_keys`. Opt-in if `virt-customize` is
  present, so we don't add a hard dep.
- **arm64** is not supported — Kali doesn't publish a prebuilt QEMU
  image for arm64. If/when they do, extend `image_url()` accordingly.
- **microvm** variant is not meaningful here: Kali's kernel+initrd
  aren't published standalone in a convenient form (the installer ISO
  carries them, but extracting cleanly is a project of its own).
- **Checksum verification** of the downloaded `.7z` is not performed,
  even though we're already fetching `SHA256SUMS` to resolve the
  rolling alias. Verifying the downloaded archive against the hash in
  that same file would be a cheap hardening — worth adding next.

---

## Phase 3 — Docker (`phase3-docker/lab-docker.sh`)

Wrap `docker buildx` for multi-arch builds (uses `qemu-user-static` via
`tonistiigi/binfmt`) plus `docker run`/`docker compose` orchestration of lab
topologies described in YAML.

- Subcommands: `build`, `run`, `up`, `down`, `exec`, `logs`, `list`,
  `destroy`.
- Config schema mirrors a subset of compose, plus a `lab:` block for arch
  matrix builds and per-service capabilities.
- `--from-chroot` builder: take a Phase 1 chroot tree and `docker import` it
  as an image (no Dockerfile needed).
- Exit criteria: build and run an aarch64 image on an x86_64 host; bring up
  a 3-service topology; tear down cleanly.

## Phase 4 — Podman (`phase4-podman/lab-podman.sh`)

### Goals

Rootless-first OCI container orchestration on Linux. Same problem space as
Phase 3 (Docker), different assumptions and different first-class features:
pods (shared-namespace groups), quadlet (systemd-user unit generation),
`--from-chroot` as a rootless-aware bridge to Phase 1, and export to
Kubernetes/Compose YAML for handoff. Spiritually complements Phase 3 rather
than replacing it — either can be rebased away without breaking the other.

Linux-only. `podman machine` and macOS support are explicit non-goals for
this phase (matches Phase 2's KVM assumption).

### Runtime modes (managers)

Three modes, analogous to Phase 1's manager column:

- **`plain`** — ephemeral `podman run` per service, tracked via labels.
- **`pod`** — N services share `podman pod` network/IPC/PID namespace.
- **`quadlet`** — services become systemd-user units written to
  `~/.config/containers/systemd/<name>.{container,pod,network,volume}`;
  `generate` / `enable` / `start` lifecycle.

`podman kube play` is **not** a runtime mode. Users who want it can run
`lab-podman export <name> --format=kube` and feed the YAML to
`podman kube play` themselves — we avoid the doubled-parser error surface.

### Rootless policy

Rootless by default. The script refuses to run as root unless invoked with
`--allow-root` (explicit escape hatch for restricted hosts). Rootful docker
users who want a unified rootless workflow should opt in; users on hosts
without `/etc/subuid` / `/etc/subgid` provisioning will either fix that
(Phase 4 tells them how) or stay on Phase 3.

### CLI

```
lab-podman.sh build    <service> [--from-chroot <name>] [--platform <arch>]
                build    --config FILE
               run      <image> [--manager plain|pod|quadlet] [-- args...]
               up       --config FILE
               down     <lab-name>
               exec     <service> [--pod <pod>] -- <cmd>
               logs     <service> [--follow]     # routes to journalctl for quadlet mode
               status   <service|lab>            # health, userns, ports, uptime
               list
               destroy  <service|lab|pod> [--force]
               export   <lab-name> --format {kube|compose}
               generate <lab-name>               # quadlet units only, no run
               version | help
```

`exec`/`logs`/`status` hide the manager underneath — the user doesn't
need to know whether their service is a plain container or a quadlet unit.

### Config file (TOML)

```toml
[lab]                         # cross-phase grouping metadata (optional)
name        = "web-stack"
description = "Three-tier demo"
tags        = ["demo", "web"]

[[pod]]
name    = "frontend"
publish = ["8080:80"]

[[service]]
name    = "nginx"
engine  = "podman"                            # per-service; defaults to the invoking tool's runtime.
                                              # Lets a future unified lab.toml mix
                                              # docker-backed and podman-backed services in one lab.
image   = "docker.io/library/nginx:alpine"    # fully qualified, no short-name prompts
pod     = "frontend"                          # optional; omit for plain/quadlet
manager = "pod"                               # plain | pod | quadlet
volumes = ["./html:/usr/share/nginx/html:Z"]  # :Z auto-added if SELinux enforcing
healthcheck = { cmd = "curl -f http://localhost/", interval = "30s" }
autoupdate  = "registry"                      # io.containers.autoupdate=registry (quadlet)

[[service]]
name        = "payload-builder"
engine      = "podman"
manager     = "plain"
from_chroot = "kali-rolling"                  # Phase 1 chroot name → rootless image
userns      = "keep-id"                       # keep-id | auto-map | host | "<uidmap-string>"
                                              # keep-id (default): UID N inside == UID N on host; transparent.
                                              # auto-map: chown everything to 0:0 inside (invoker on host).
                                              # host: share userns (requires --allow-root).
                                              # custom: raw --uidmap/--gidmap passthrough for power users.

[[secret]]
name   = "db-password"
source = "file:///run/secrets/db.pw"          # backed by podman secret

[[network]]
name   = "lab-net"
driver = "bridge"                             # rootless bridge via netavark
```

Labels attached to every artifact: `lab-create.tool=lab-podman`,
`lab-create.lab=<name>` (from the optional `[lab]` block),
`lab-create.svc=<name>` (or `.pod=<name>`). Scoped separately from
Phase 3's `lab-create.tool=lab-docker` so `list`/`destroy` in each
phase tool sees only its own artifacts. Phase 6 cross-correlates on
`lab-create.lab=<name>` to paint a single-pane-of-glass view.

### Rootless plumbing

Each of these is a preflight probe + helpful error, not a silent
best-effort. First-time rootless podman users trip on all of them:

- **subuid/subgid** — `/etc/subuid` and `/etc/subgid` must have an entry
  for the invoking user. Missing → print the exact `usermod --add-subuids`
  fix.
- **`net.ipv4.ip_unprivileged_port_start`** — warn when a service maps a
  host port <1024 without this sysctl lowered.
- **`loginctl enable-linger`** — required for quadlet units to survive
  logout. Probed before `up --manager=quadlet`; prompt if missing.
- **SELinux `:Z`/`:z`** — auto-append `:Z` to volume mounts when
  `getenforce` returns `Enforcing`. Private relabeling; use `:z` via
  explicit TOML opt-in if a mount needs to be shared across containers.
- **Rootless networking** — detect pasta vs. slirp4netns (`podman info`);
  log which is in use; don't fail on either.
- **`from-chroot` UID mapping** — Phase 1 builds chroots as UID 0;
  rootless `podman import` maps those to the invoker's UID. The
  `userns` TOML field on a `from_chroot` service picks the strategy:
  - `keep-id` **(default)** — `--userns=keep-id`; UID N inside the
    container maps to UID N on the host. Most transparent.
  - `auto-map` — during import, rewrite ownership so everything is
    `0:0` inside the container (which, rootless, maps to the invoker
    on the host). Most "container-idiomatic", best for images that
    expect to run as root-in-namespace.
  - `host` — share the host's user namespace; requires `--allow-root`
    and is essentially a chroot-with-containerization. Power-user
    only.
  - A raw string (e.g. `"0:1000:1,1:100000:65535"`) — passed
    verbatim to `--uidmap` / `--gidmap` for custom layouts. Gives us
    a pressure relief valve without expanding the DSL every time a
    new rootless mapping pattern emerges.
  Always warn at import time when the chroot contains UID-0-owned
  paths, regardless of strategy chosen — it's the single most common
  source of confused-deputy bugs.
- **Short-name resolution** — require fully qualified image references
  in TOML (validation-fail on bare names) to avoid interactive
  `registries.conf` prompts during non-interactive `up`.

### Dependency probing

- **`podman` ≥ 4.4** — hard gate for `quadlet` mode (quadlet shipped in
  4.4, 2023). Older podman on Rocky 8 / Ubuntu 20.04 works for
  `plain`/`pod` only; `up --manager=quadlet` errors with a version hint.
- **`podman` ≥ 4.0** — minimum for any mode.
- **`qemu-user-static` + `binfmt_misc`** — for `build --platform` on a
  foreign arch, same probe as Phase 3.
- **`systemctl --user`** — required for `quadlet`; error if running in a
  session without a user DBus (containerized shells, some SSH configs).

### State

`$LAB_STATE_DIR/podman/<lab>/{spec.toml, labels, quadlet-links}`:

- `spec.toml` — canonicalized copy of the input TOML. Lets `destroy`,
  `status`, and `export` work without re-parsing the original file.
- `labels` — newline-separated podman object IDs we own, for fast
  lookup without a full `podman ps -a --filter label=...` sweep.
- `quadlet-links/` — symlinks pointing at the real unit files under
  `~/.config/containers/systemd/`, so `destroy` can disable + remove
  without guessing which units came from which lab.

### Tests

`phase4-podman/tests/run-all.sh` + `lib.sh`, mirroring Phase 3. Planned
test files:

- `test-validation.sh` — TOML schema, `engine=podman` requirement,
  bare-image-name rejection, manager values.
- `test-naming.sh` — label scoping, name collision across labs.
- `test-rootless-smoke.sh` — `plain` run as non-root, clean destroy.
- `test-pod-lifecycle.sh` — 3-service pod up/down/exec/logs.
- `test-quadlet-lifecycle.sh` — generate → reload → enable → start →
  stop → destroy; verify unit symlink hygiene.
- `test-from-chroot-import.sh` — Phase 1 chroot → rootless podman
  image → run; verify UID mapping doesn't bite.
- `test-buildx-multiarch.sh` — cross-arch build via qemu-user-static.
- `test-export-kube-roundtrip.sh` — `export --format=kube` produces
  YAML accepted by `podman kube play` without edits.
- `test-allow-root.sh` — root invocation refused without `--allow-root`,
  allowed with it.

Every test self-skips (exit 77) when its preconditions aren't met
(podman missing, subuid unconfigured, quadlet too old, SELinux absent,
etc.) — same discipline as Phases 1 and 3.

### Example TOMLs

- `examples/podman-plain-single.toml` — one service, plain manager.
- `examples/podman-pod-3svc.toml` — web+app+db pod, shared namespace.
- `examples/podman-quadlet-service.toml` — systemd-user managed.
- `examples/podman-from-chroot.toml` — consumes a Phase 1 chroot name.
- `examples/podman-multiarch-build.toml` — cross-arch build matrix.

### Exit criteria

1. Bring up a 3-service pod rootless (pasta or slirp4netns), tear down
   cleanly.
2. Generate + enable + run a quadlet unit from a TOML spec; verify it
   survives a logout (`loginctl enable-linger`).
3. Cross-phase: `lc create` a Kali chroot in Phase 1; `lab-podman build
   --from-chroot <name>` → runnable rootless image, UID mapping sane.
4. `lab-podman export <name> --format=kube` produces YAML that
   `podman kube play` accepts unmodified — handoff-grade roundtrip,
   even though we don't run `kube play` ourselves.

---

## Phase 5 — LXD / Incus (`phase5-lxd/lab-lxd.sh`)

System containers and (optionally) VMs via LXD/Incus. Detects which is
installed and prefers Incus if both are present. Supports:

- Profile and project creation.
- Image import from Phase 1 chroots (`lxc image import` from a tarball the
  script builds out of the chroot tree, with a metadata.yaml).
- Multi-arch via the upstream image server when available; fallback to
  Phase-1-built tarballs.
- VM mode (LXD/Incus VMs use QEMU under the hood) for arches the host can
  emulate.

## Phase 6 (optional) — Textual TUI (`phase6-tui/`)

A Python 3.11+ Textual app that surfaces every resource produced by Phases
1–5 in one keyboard-driven UI. **No new provisioning logic** — every
mutating action shells out to the corresponding `lab-*.sh` script via
`subprocess`; every read pulls from the standardized state locations the
bash phases write (`~/.local/state/lab-create/`, `/var/lib/machines/`,
`schroot -l`, `qemu` monitor sockets, `docker`/`podman`/`lxc` CLIs). If
Phase 6 is removed, nothing in Phases 1–5 breaks.

### Stack

- **Textual** for the TUI (declarative widgets, CSS-like styling, mouse
  support, async event loop). Implicitly gets `Rich` for free.
- **Python `tomllib`** (stdlib, 3.11+) for reading `lab.toml` topologies and
  per-resource configs.
- **`subprocess`** + a thin `BackendRunner` class per phase that knows the
  script's CLI shape and parses its `--json` output where available.
- **`watchfiles`** (small dep) for noticing when state files change without
  hammering the filesystem on a poll loop.
- No DB. State of truth is whatever the bash phases write; the TUI is a
  view layer.

### Layout (`phase6-tui/lab_tui/`)

```
__main__.py        # python -m lab_tui  →  Textual App.run()
app.py             # LabApp(App) — bindings, screens, theming
screens/
  browser.py       # left: tree of resources by backend; right: detail
  detail.py        # config view, log tail, action buttons
  create_chroot.py # modal wizard → emits TOML → calls lab-chroot.sh create
  create_vm.py
  create_container.py  # docker | podman | lxd selectable
  topology.py      # full-lab graph view from lab.toml
  confirm.py       # destructive-action modal
backends/
  base.py          # BackendRunner ABC: list(), inspect(), create(), start(),
                   #   stop(), destroy(), enter_command()
  chroot.py        # wraps phase1-chroot/lab-chroot.sh
  vm.py            # wraps phase2-qemu-vm/lab-vm.sh
  docker.py        # wraps phase3-docker/lab-docker.sh
  podman.py
  lxd.py
state.py           # readers for ~/.local/state/lab-create/, machinectl, etc.
topology.py        # lab.toml parser + dependency resolver
widgets/
  resource_tree.py
  log_tail.py
  status_pill.py   # running / stopped / built / missing / error
```

### Screens

- **Resource browser** — left pane: tree grouped by backend
  (Chroots → schroot/nspawn/bare; VMs → full/microvm; Containers →
  docker/podman/lxd). Each row carries a status pill. Right pane: the
  selected resource's TOML config, recent log tail (tailing the relevant
  log file or `journalctl -u` for nspawn-managed units), and an action bar.
- **Create wizards** — one modal per resource type. Walk the user through
  the required fields (backend, distro, suite, arch, target, manager, …),
  validate live (e.g., reject Rocky armv7l before submission), preview the
  generated TOML, and on confirm dispatch the bash script in a Textual
  `Worker` so the UI stays responsive. Stream stdout/stderr into a log
  panel.
- **Topology view** — read a unified `lab.toml` (may contain
  `[[chroot]]` / `[[vm]]` / `[[service]]` blocks from any mix of
  Phases 1–5, all sharing the same top-level `[lab]` grouping
  metadata) and render a dependency-ordered list (no fancy graph
  drawing in v1; arrows in text). "Bring up" and "Tear down" actions
  iterate in topological order, dispatching each block to its owning
  phase script. Cross-correlation is done via the
  `lab-create.lab=<name>` label / manifest field that every phase tool
  writes when a `[lab]` block is present. Halt on first failure with
  a clear pointer to which resource broke.
- **Confirm modal** — every destructive action (`destroy`, `tear down`,
  `stop --force`) routes through this. Shows exactly the command(s) about
  to run. No keyboard shortcut bypass.
- **Console attach** — for VMs, the action bar's "console" button shells
  out to `lab-vm.sh console <name>` in a foreground sub-shell (Textual
  suspends, returns when the sub-shell exits).

### Live updates

A single `StateWatcher` subscribes (via `watchfiles`) to the directories
the bash phases write to, plus a low-frequency timer (default 5 s,
configurable) that refreshes things that aren't file-backed (`docker ps`,
`qemu-monitor`). All updates funnel through Textual's reactive system so
screens redraw declaratively.

### Phase 6 exit criteria

- Browser lists every resource the underlying bash phases know about, with
  correct status, on a host that has at least one resource of each backend.
- Each create wizard produces the same TOML the user would have written by
  hand, and the bash script accepts it without modification.
- Destroying a resource from the TUI leaves no orphan state (verified by
  re-listing).
- The TUI starts and is usable on a host where some backends are absent
  (e.g., no Docker installed) — those branches show as "unavailable",
  not as errors.
- `textual serve lab_tui` works, giving Phase 6b a fallback path before
  Phase 6b lands.

---

## Phase 6b (optional) — Web UI (`phase6b-web/`)

A FastAPI + HTMX single-process web app that exposes the same surface as
Phase 6 over HTTP, designed for SSH-port-forward use ("ssh -L 8080:localhost:8080
labhost", open in browser). Same self-containment rule: it shells out to the
bash phase scripts and reads from their state files. No DB.

### Stack

- **FastAPI** (HTTP routing, async, automatic OpenAPI for free).
- **Jinja2** templates returning HTML fragments.
- **HTMX** for interactivity (no SPA, no build step, no JS framework).
- **Python `tomllib`** for config.
- **`uvicorn`** as the ASGI server, single-process.
- **No auth in v1** — bound to `127.0.0.1` only by default; instructions in
  the README to put it behind SSH or a reverse proxy with auth if exposed.
  An explicit `--bind 0.0.0.0` flag exists but prints a loud warning and
  refuses to start without `--i-know-what-im-doing` (or similar) and a
  basic-auth credential.

### Layout (`phase6b-web/lab_web/`)

```
__main__.py          # python -m lab_web  →  uvicorn.run(app)
app.py               # FastAPI() instance, lifespan hooks
routes/
  resources.py       # GET /resources, GET /resources/{backend}/{name}
  actions.py         # POST start/stop/destroy/create
  topology.py        # GET/POST /topology
  stream.py          # SSE endpoints for live log/status updates
templates/
  base.html.j2       # HTMX swap targets defined here
  partials/
    resource_row.html.j2
    detail_panel.html.j2
    create_form.html.j2
    log_tail.html.j2
static/
  htmx.min.js        # vendored, version-pinned
  style.css
backends/             # mirrors phase6-tui/lab_tui/backends/ exactly —
                      # duplicated, not imported
```

### Pages

- `/` — resource browser (HTML). Resource rows are HTMX-swappable from
  Server-Sent Events on `/stream/status` so status pills update live
  without polling.
- `/resources/{backend}/{name}` — detail panel returned as an HTML fragment
  (HTMX `hx-get`).
- `/create/{kind}` — form returning a TOML preview before submission.
  Submit POSTs to the action route, which streams the bash script's
  stdout/stderr back as an SSE log fragment.
- `/topology` — read `lab.toml`, render dependency list, "bring up" and
  "tear down" trigger SSE-streamed runs.
- `/api/v1/...` — same surface in JSON, for scripting. FastAPI gives this
  for free via separate routers tagged for OpenAPI; the docs page at
  `/docs` is the lightweight remote API reference.

### Phase 6b exit criteria

- Same behavioral parity tests as Phase 6, run against the HTTP API.
- Loopback-only by default verified by an integration test that confirms
  `--bind 0.0.0.0` without the override flag refuses to start.
- Works in a stock SSH-forward setup: `ssh -L 8080:localhost:8080 host`,
  browse to `http://localhost:8080`, perform a full create→start→destroy
  flow on a chroot or VM.

---

## Cross-phase concerns

### Logging

A small `log()` helper is copied into every phase script:

- `LAB_LOG_LEVEL` env var: `debug|info|warn|error`.
- All output to stderr; stdout reserved for machine-readable results when
  `--json` is passed (Phase 1 and Phase 2 only, where it's useful).

### Config parser

All phases use TOML. Phases 1–5 (bash) probe `tomlq` / `yq -p toml` /
`dasel` in that order and abstract the call behind a single shell function
(copied into each phase script). Phases 6 and 6b (Python) use stdlib
`tomllib`. State files written by the bash phases are also TOML where
structured, so the Python phases can read them directly without
re-parsing through a CLI.

### Caching

`~/.cache/lab-create/` holds:

- `debootstrap/<suite>-<arch>.tar.gz` — `--make-tarball` outputs.
- `dnf/<release>-<arch>/` — dnf metadata cache.
- `images/<distro>-<release>-<arch>.qcow2` — VM base images.

Each phase script uses `--keep-cache` / `--no-cache` flags consistently.

### Architecture identifiers

A canonical-name table is duplicated into every phase script:

```
canonical | debian | rpm    | qemu-system | qemu-user
x86_64    | amd64  | x86_64 | x86_64      | x86_64
aarch64   | arm64  | aarch64| aarch64     | aarch64
armv7l    | armhf  | armv7hl| arm         | arm
ppc64le   | ppc64el| ppc64le| ppc64       | ppc64le
riscv64   | riscv64| riscv64| riscv64     | riscv64
s390x     | s390x  | s390x  | s390x       | s390x
```

### Lab grouping (`[lab]` as a cross-phase concept)

A "lab" is a named, cross-phase grouping of resources. The motivating use
case: a user grabs a recipe from a blog or tutorial that mixes a build
chroot, a victim VM, and a couple of containers, and wants to spin the
whole thing up, tear the whole thing down, and see it as one thing.

**Schema.** Every phase TOML may carry an optional top-level `[lab]`
block:

```toml
[lab]
name        = "ctf-box"
description = "OWASP XSS challenge from blog post"
tags        = ["ctf", "web", "tutorial"]
```

When present, the phase tool:

- Records `lab = "<name>"` in its per-resource state/manifest (Phases
  1/2) or attaches `lab-create.lab=<name>` as an OCI label (Phases
  3/4).
- Accepts `--lab <name>` on `list` / `destroy` to filter by grouping.

Resources without a `[lab]` block are "ungrouped" and show up under a
special `(none)` bucket.

**Per-phase blocks keep their shape.** The cross-phase part is the
metadata; the provisioning blocks stay phase-local:

- Phase 1: `[[chroot]]`
- Phase 2: `[[vm]]`
- Phase 3: `[[service]]` (engine=docker implicit)
- Phase 4: `[[service]]` with per-service `engine = "podman"`, and
  `[[pod]]` for shared-namespace groups

A future unified `lab.toml` MAY combine blocks from multiple phases in
one file; each phase tool reads its own blocks and ignores the rest.
That gives three equivalent workflows:

1. **Per-phase TOMLs, shared lab name** — current status quo, works
   today once `[lab]` is wired into each phase tool.
2. **Unified TOML, invoke each tool with `--config lab.toml`** — each
   tool picks its own blocks out. No new binary needed.
3. **Phase 6 topology view** — reads unified TOML, dispatches to each
   phase script in dependency order, shows them as one lab in the TUI.

**Engine hint lives per-resource, not per-lab.** A lab can mix
docker-backed and podman-backed services; `[[service]] engine =
"podman"` decides which phase tool owns that block. Default: whichever
tool was invoked (`lab-docker.sh` → `docker`, `lab-podman.sh` →
`podman`).

### Security posture

- No phase ever curls a script into a shell.
- Mirror URLs default to upstream HTTPS endpoints and are pinned in the
  script; user can override but the script warns on plain HTTP.
- GPG verification is **on** for debootstrap (default) and dnf
  (`gpgcheck=1`); a `--insecure` flag is the only way to disable it and it
  prints a loud warning.
- Foreign binaries (qemu-user-static) come from the host's package manager,
  never downloaded ad-hoc.

---

## Build order and rebase points

1. Phase 1 lands first and must be green (all tests pass) before Phase 2
   starts. Tag commit: `phase1-complete`. **STATUS: v0.1 landed, smoke +
   validation tests pass.**
2. Phase 2 lands next, tagged `phase2-complete`. From here, any later phase
   can be rebased away by `git reset --hard phase2-complete` (or
   equivalent in this non-git repo: copy the phase dirs out, wipe, restore).
   **STATUS: v0.1 landed, validation + arch-table + Debian-x86_64
   end-to-end-boot tests pass.**
3. Phases 3–5 are independent of each other and can land in any order or in
   parallel branches.  **Phase 3 STATUS: v0.1 landed, validation + naming
   tests pass; docker-dependent tests skip cleanly when no daemon is
   reachable.**
4. Phase 6 lands last and is the only phase that may be deleted without any
   user-visible feature loss.

## Resolved decisions (2026-04-17)

1. **Config format**: TOML across all phases. Bash phases parse via
   `tomlq` / `yq -p toml` / `dasel` (whichever is on the host); Python
   phases use stdlib `tomllib`.
2. **Implementation languages**:
   - Phases 1–5: Bash (`/bin/bash`, `set -euo pipefail`), POSIX tools,
     targeted `awk`/`sed`/`dd`. One self-contained `lab-*.sh` per phase.
   - Phase 6 (TUI): Python 3.11+ with **Textual**.
   - Phase 6b (web): Python 3.11+ with **FastAPI + HTMX + Jinja2**,
     served by `uvicorn`, loopback-only by default.
   - Both Python phases shell out to the bash phase scripts and read from
     standardized state locations; they never reimplement provisioning
     logic.
3. **Chroot managers**: both `schroot` and `systemd-nspawn` are supported in
   Phase 1, both optional, both detected at runtime; bare `chroot(8)`
   (`--manager none`) remains the always-available default.
4. **Kali keyring**: script looks for `/usr/share/keyrings/kali-archive-keyring.gpg`
   on the host and refuses to proceed if missing, with an install hint. No
   embedding, no download.
5. **Rocky armv7l**: script errors out with an explanatory message. No
   workaround attempted.
