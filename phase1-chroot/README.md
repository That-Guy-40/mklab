# Phase 1 — `lab-chroot.sh`

Create and manage chroots across distros, architectures, and managers.

## At a glance

| | |
|---|---|
| **Backends** | `debootstrap` (Debian, Ubuntu, Kali) · `dnf` (Rocky) · `host-copy` (binaries+libs from running host) |
| **Managers** | `none` (bare `chroot(8)`, default) · `schroot` · `systemd-nspawn` |
| **Arches** | `x86_64`, `aarch64`, `armv7l`, `ppc64le`, `riscv64`, `s390x` (foreign-arch via `qemu-user-static` + `binfmt_misc`) |
| **Config** | CLI flags or TOML (`--config FILE`) — both produce identical results |
| **Scope** | Self-contained single bash script. No imports from sibling phases. |

## Install

Drop `lab-chroot.sh` anywhere on `$PATH` (or invoke it directly). The script auto-detects the host distro for install hints and never auto-installs anything itself.

### Required on the host

| Always | `bash` 4+, `jq`, `tar`, `mount`, `chroot`, one of `tomlq` / mikefarah `yq` (v4+) / `dasel` |
| For `debootstrap` backend | `debootstrap` + the matching keyring package (`debian-archive-keyring`, `ubuntu-keyring`, `kali-archive-keyring`) |
| For `dnf` backend | `dnf` (or `yum` as fallback) **plus `rpm`** (for `rpmkeys`, used to verify RPM GPG signatures — Debian/Ubuntu's `dnf` package alone is not enough) |
| For `host-copy` backend | `ldd` (glibc), `cp` |
| For foreign-arch | `qemu-user-static`, plus `binfmt-support` *or* `systemd-binfmt` |
| For `--manager schroot` | `schroot` |
| For `--manager nspawn` | `systemd-nspawn`, `machinectl` |
| For Kali | `kali-archive-keyring` package present on host (script refuses without it; we will not embed or download the key) |
| For the test suite (optional) | `file` (used by `test-host-copy-static-binary.sh`; falls back to `cc -static` if absent) |

`sudo` is **not** installed by the script and **is not** installed into the
chroots it creates — `sudo` is assumed present on the host (every operation
needs root); inside the chroot, add it explicitly via `--include sudo` (or
the equivalent in your TOML spec) if you want it.

### Install hints by distro

The script's preflight prints the exact `apt-get` / `dnf` command for any tool that's missing — let it tell you, don't guess.

## Usage

```text
lab-chroot.sh create   [--config FILE | --backend B --distro D --suite S --arch A --target PATH ...]
lab-chroot.sh enter    <name|path> [-- cmd args...]
lab-chroot.sh destroy  <name|path> [--force]
lab-chroot.sh list
lab-chroot.sh verify   <name|path>
```

Run `lab-chroot.sh help` for the full flag list.

### Quick examples

Native Debian:

```bash
sudo lab-chroot.sh create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch x86_64 --target /var/chroots/bookworm-amd64
```

Foreign-arch Debian aarch64 (host is x86_64):

```bash
sudo lab-chroot.sh create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch aarch64 --target /var/chroots/bookworm-arm64 \
    --include vim-tiny,ca-certificates
```

Rocky 9 with vsftpd, registered with schroot:

```bash
sudo lab-chroot.sh create --config examples/chroot-rocky9-vsftpd.toml
sudo lab-chroot.sh enter rocky9-vsftpd -- vsftpd --version
```

Minimal `host-copy` jail for sftp:

```bash
sudo lab-chroot.sh create \
    --backend host-copy --target /var/jails/sftp-only \
    --binaries /usr/lib/openssh/sftp-server \
    --extras /etc/passwd,/etc/group
```

Same chroot via TOML config:

```bash
sudo lab-chroot.sh create --config examples/chroot-host-copy-busybox.toml
```

systemd-nspawn-managed (full PID 1 inside, exposed to `machinectl`):

```bash
sudo lab-chroot.sh create --config examples/chroot-nspawn-managed.toml
sudo lab-chroot.sh enter bookworm-nspawn
```

## Configuration (TOML)

A config can carry one chroot inline or many under `[[chroot]]`. CLI flags map 1:1 to the keys below.

```toml
[[chroot]]
name    = "bookworm-amd64"
backend = "debootstrap"
distro  = "debian"
suite   = "bookworm"
arch    = "x86_64"
target  = "/var/chroots/bookworm-amd64"
mirror  = "http://deb.debian.org/debian"        # optional; backend default if omitted
variant = "minbase"                             # optional
include = ["build-essential", "vim-tiny"]
manager = "schroot"

  [chroot.schroot]
  type   = "directory"
  groups = ["sbuild", "sudo"]
  users  = []
```

### Backend-specific keys

- **`debootstrap`** — `distro`, `suite`, `arch`, `mirror?`, `variant?`, `include?`
- **`dnf`** — `distro` (must be `rocky`), `suite` (e.g. `"9"`), `arch`, `include?`, `groups?`. Default seed packages are `rocky-release`, `rocky-repos`, `rocky-gpg-keys`, `rpm`, `dnf` — anything in `include` is added on top. The `rpm` and `dnf` CLIs are included so the chroot is self-introspectable (`rpm -qa`) and self-extensible (`dnf install ...` from inside) out of the box.
- **`host-copy`** — `binaries` (required), `extras?`. `arch` is implicitly the host's.

### Manager-specific keys

- **`[chroot.schroot]`** — `type` (default `directory`), `users`, `groups`
- **`[chroot.nspawn]`** — `boot` (default `false`), `register` (default `true`), `network` (`host`/`veth`/`none`/`<bridge>`), `bind_ro` (array of host paths), `capabilities` (array of `CAP_*`). The advanced keys are persisted in the manifest and applied to `systemd-nspawn` at `enter` time (→ `--network-veth`/`--private-network`/`--network-bridge=`, `--bind-ro=`, `--capability=`).

### `host-copy` notes

- Walks `ldd` output for each requested binary and copies the binary, every shared library it depends on, and the dynamic loader, preserving paths.
- Always copies `linux-vdso` *out* (it's kernel-virtual).
- Statically-linked binaries are detected and copied without a library walk.
- The script creates a minimal skeleton (`/proc /sys /dev /tmp /run /etc`) but does **not** `mknod` device nodes by default — add `--manager nspawn` if you need full namespacing, or extend the spec's `extras` list and bind-mount yourself.

### Foreign-arch notes

- For `debootstrap`, the script runs the canonical two-stage flow: `--foreign` first stage on host, copy `qemu-<arch>-static` into the tree, run `/debootstrap/debootstrap --second-stage` under `chroot`.
- `binfmt_misc` is checked at `/proc/sys/fs/binfmt_misc/qemu-<arch>` and enabled via `update-binfmts --enable` (Debian-style) or `systemctl restart systemd-binfmt` (systemd-style) if absent.
- For `dnf`, foreign-arch uses `--forcearch=<rpm-arch>` plus the same qemu-user-static + binfmt setup. **Considered experimental** — install scriptlets that fork heavily under qemu-user emulation can fail. Native-arch dnf is the recommended path; if you need a foreign Rocky chroot, consider building it on a matching-arch host or VM (Phase 2).
- Rocky armv7l: not published upstream. The script errors out before doing anything.

## State and locations

| | |
|---|---|
| Per-chroot manifest | `${LAB_STATE_DIR}/chroots/<name>.toml` |
| `LAB_STATE_DIR` (root) | `/var/lib/lab-create` |
| `LAB_STATE_DIR` (non-root) | `${XDG_STATE_HOME:-$HOME/.local/state}/lab-create` |
| schroot conf | `/etc/schroot/chroot.d/<name>.conf` |
| nspawn registration | symlink `/var/lib/machines/<name>` → target |
| Bind-mount tracking (manager=none) | `<target>/.lab-chroot-mounts` |

`destroy` removes whatever it created, in reverse order, including the manifest and the chroot tree.

## Idempotency and safety

- `create` refuses to write into a non-empty target directory.
- `create` refuses to overwrite an existing manifest with the same name.
- `destroy` prompts unless `--force` is passed.
- `enter` (manager=none) records all bind-mounts so `destroy` can clean them up even after a crashed `enter`.
- The script never auto-installs host packages and never silently enables `binfmt_misc` without the matching tool being present on the host.

## Rootless mode (`--rootless`)

Create and enter a chroot **without root**, following the muxup.com pattern:
`debootstrap --variant=fakechroot` (or `host-copy`) built and entered under
`fakechroot fakeroot`, so no real uid 0, no `mknod`, and no bind-mounts.

```bash
phase1-chroot/lab-chroot.sh create --rootless \
    --backend debootstrap --distro debian --suite bookworm \
    --arch x86_64 --target ~/chroots/bookworm
phase1-chroot/lab-chroot.sh enter ~/chroots/bookworm        # also rootless
```

Requires `fakechroot` + `fakeroot` on the host (`sudo apt-get install -y
fakechroot fakeroot`). Constraints: **native arch only** (foreign-arch needs root +
qemu-user-static), **`manager=none`** (schroot/nspawn need root), backend
`debootstrap`/`host-copy` (dnf needs root). State lives under `$XDG_STATE_HOME`,
and the rootless flag is recorded in the manifest so `enter`/`destroy` reproduce it.

## Other options

- **`--keep-cache`** — reuse a persistent package download cache across builds
  (debootstrap `--cache-dir`, dnf `cachedir`+`keepcache=1`) under `$LAB_CACHE_DIR`.
- **`--json`** — machine-readable output for `list` (array of managed chroots,
  `schema_version=1`) and `inspect` (single chroot, live probes).
- **`post = [...]`** TOML hooks (and `--post-command`) run inside the chroot after
  the build, in order.

## Known gaps

- **dnf foreign-arch** works in theory but is fragile under heavy scriptlets. Consider it experimental.
- **Rootless is native-arch + debootstrap/host-copy only** — foreign-arch and dnf rootless are out of scope (they need real root / qemu-user-static).

## Tests

```bash
cd phase1-chroot/tests
sudo ./test-host-copy.sh
sudo ./test-debootstrap-amd64.sh
sudo ./test-debootstrap-arm64-foreign.sh
sudo ./test-dnf-rocky9.sh
sudo ./test-schroot-integration.sh
sudo ./test-nspawn-integration.sh
sudo ./test-cli-vs-config-parity.sh
sudo ./test-kali-keyring-missing.sh
sudo ./test-kali-bootstrap.sh
sudo ./test-rocky-armv7l-rejection.sh
```

Each test is independent, exits non-zero on failure, and skips itself (exit 77, autotools convention) if a required tool is missing.

## Phase 1 exit criteria status

See `../PLAN.md` for the full list. v0.1 covers the core paths; rootless and a couple of nice-to-haves are tracked in *Known gaps* above.
