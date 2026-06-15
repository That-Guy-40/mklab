# Phase 5 — system containers AND VMs, one tool

## What it gives you

LXD/Incus is the only manager in this stack that drives **system containers
and full VMs through one CLI** — single TOML, single `up`, instances of
either flavor side by side. Projects and profiles add LXD-native namespace
isolation and reusable config+device templates. And it speaks two engines
transparently: auto-detects `incus` (preferred — actively maintained fork)
or `lxc` (LXD), one binding wraps both.

## 60-second demo

A clean Debian/Ubuntu/Kali host to a mixed lab — two containers + one VM:

```bash
sudo apt-get install -y incus jq yq
sudo usermod -aG incus-admin "$USER" && newgrp incus-admin
sudo incus admin init --auto --storage-backend zfs --storage-create-loop 20
# (or `sudo lxd init --auto …` if you went the LXD route)

cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
phase5-lxd/lab-lxd.sh up   --config examples/lxd-examples/lxd-mixed-topology.toml
phase5-lxd/lab-lxd.sh list --lab demo-mixed
phase5-lxd/lab-lxd.sh exec demo-mixed/web -- cat /etc/os-release
phase5-lxd/lab-lxd.sh down --lab demo-mixed
```

```text
# sample output (list)
LAB          NAME         TYPE        STATE    IPV4         IMAGE
demo-mixed   web          container   RUNNING  10.42.0.83   images:alpine/3.23
demo-mixed   cache        container   RUNNING  10.42.0.117  images:alpine/3.23
demo-mixed   worker-vm    vm          RUNNING  10.42.0.201  images:alpine/3.23
```

A container, another container, and a hypervisor-backed VM — one `up`,
one `--lab` filter, one `down`.

> **First-run gotcha:** fresh installs hit `Failed getting root disk: No
> root device could be found`. The daemon is running but the `default`
> profile has no root-disk device. One-shot: `sudo incus admin init
> --auto` (or `sudo lxd init --auto`). `MANUAL_TESTING.md` §0a covers it.

## Imperative verbs — `run` and `build` (no TOML)

The demos above all go through `up --config <topology.toml>`, the declarative
path. But Phase 5 also exposes two **imperative** verbs that launch or build a
single instance straight from CLI flags — handy for one-offs, scripting, and
poking at a backend before you commit it to a TOML.

### `run` — launch one instance, ad-hoc

`run` is the imperative twin of `up`'s `[[instance]]` table: it launches exactly
one instance, always tagged with the lab labels (a bare `--name` is treated as a
one-row "lab"). Pick **one** image source:

```bash
# upstream image (latest resolved at run time, same resolver as up)
phase5-lxd/lab-lxd.sh run --name a --image images:alpine/latest

# a VM instead of a container
phase5-lxd/lab-lxd.sh run --name v --image images:debian/bookworm --type vm

# from a Phase-1 chroot / tarball, or a Phase-2 qcow2 (cross-phase bridges)
phase5-lxd/lab-lxd.sh run --name worker --chroot /var/chroots/debian --type vm
phase5-lxd/lab-lxd.sh run --name att    --tarball /tmp/kali-amd64.tar.gz
phase5-lxd/lab-lxd.sh run --name vm1    --qcow2 /tmp/kali.qcow2          # implies --type vm
```

| Flag | Purpose |
|---|---|
| `--name N` | short instance name (the instance becomes `lab-<lab>-<name>`) — required |
| `--image I` | upstream image alias (`images:alpine/latest`, `images:debian/bookworm`) |
| `--chroot PATH` | Phase-1 chroot tree (CLI-flag spelling of the `from_chroot` TOML key) |
| `--tarball PATH` | Phase-1 `export-tarball` output (CLI spelling of `from_tarball`) |
| `--qcow2 PATH` | Phase-2 qcow2 disk image (CLI spelling of `from_qcow2`; implies `--type vm`) |
| `--type container\|vm` | instance flavour (default: `container`) |
| `--project P` | LXD project (created if needed) |
| `--storage POOL` | LXD storage pool |
| `--network NET` | attach the instance to an existing LXD network (e.g. `lxdbr0`) |

> **CLI flag vs TOML key:** `--chroot` / `--tarball` / `--qcow2` are the *flag*
> spellings used by `run` and `build`; the declarative `up` path spells the same
> sources as the TOML keys `from_chroot` / `from_tarball` / `from_qcow2`. Same
> backends, two surfaces — don't mix the spellings.

### `build` — bake a reusable local image alias

`build` doesn't launch anything; it imports a source into the **local image
store** under an alias you name, so later `run`/`up` calls can reference it.
Pick the backend explicitly:

```bash
phase5-lxd/lab-lxd.sh build --alias kali-rolling --backend from-chroot --chroot /var/chroots/kali
phase5-lxd/lab-lxd.sh build --alias deb13        --backend upstream    --image images:debian/13
```

| Flag | Purpose |
|---|---|
| `--alias, --tag TAG` | name for the resulting local image alias — required (`--tag` is an alias of `--alias`) |
| `--backend {upstream\|from-chroot\|from-tarball\|from-qcow2}` | which import path to use |
| `--image\|--chroot\|--tarball\|--qcow2 SRC` | the source, matched to the chosen backend |

## Feature tour

### Dual engine (incus preferred, lxc fallback)

At load time the script probes both. A bare `have incus` check isn't
enough — most distros ship the package with the daemon stopped or the
control group restricted, so Phase 5 issues `incus info` (then `lxc info`
on fallback) to confirm the daemon actually answers:

```text
[info] incus binary present but daemon not reachable; using lxc (LXD) instead
```

The seven subcommands used (`launch`, `exec`, `info`, `list`, `config
show`, `image import`, `delete`) are identical between binaries —
`LXC_CMD` binds once at startup, every call after is engine-agnostic.

### Container OR VM, same TOML

`type = "container"` (default) and `type = "vm"` ride the same
`[[instance]]` table; both go through `lxc launch [--vm] <image> <name>`.
VMs need a block-capable storage pool (`zfs`/`btrfs`/`lvm`) — the
dir-pool default hosts containers fine but not VMs, and Phase 5 reports
that cleanly with a `try: incus storage create vmpool zfs` hint.

```toml
# examples/lxd-examples/lxd-mixed-topology.toml — excerpt
[[instance]]
name = "web"
type = "container"
image = "images:alpine/latest"

[[instance]]
name = "worker-vm"
type = "vm"
image = "images:alpine/latest"
config = { "limits.memory" = "512MiB", "security.secureboot" = "false" }
```

### Projects + profiles for namespace isolation

LXD-native, no Phase 3/4 analogue. **Projects** isolate instance lists,
images, networks. **Profiles** are reusable config+device bundles that
instances inherit via `profiles = ["default", "webnode"]`.

```toml
# examples/lxd-examples/lxd-profiles-projects.toml — excerpt
[[project]]
name = "demo-pp"

[[profile]]
name    = "webnode"
project = "demo-pp"
config  = { "security.nesting" = "true", "limits.cpu" = "1" }
devices = { eth0 = { type = "nic", network = "lxdbr0", name = "eth0" } }

[[instance]]
name     = "web1"
project  = "demo-pp"
profiles = ["default", "webnode"]
```

New projects are created with `features.profiles=false features.storage.
volumes=false` so they share the default project's profiles — no need
to re-create `default` in every project before the first `launch`.

### `images:DISTRO/latest` — no version pinning

The `images:` simplestreams remote doesn't actually publish a `latest`
alias — `images:alpine/latest` would fail at the resolver. Phase 5
catches the `latest` convention (and bare `images:alpine`), queries the
remote for the highest stable X.Y, and rewrites at run time:

```text
[info] resolved images:alpine/latest → images:alpine/3.23
```

Versioned aliases (`images:alpine/3.23`) pass through unchanged. **Commit
`df3f936`** taught the resolver to speak Incus's `linuxcontainers.org`
remote, which uses a different alias-prefix layout than snap LXD's
`images.lxd.canonical.com` — both engines now resolve `latest` correctly.

### `from_chroot` / `from_tarball` / `from_qcow2` — cross-phase image bridges

| Backend        | Source                    | type=container | type=vm | Root? |
|----------------|---------------------------|:--------------:|:-------:|:-----:|
| `from_chroot`  | Phase-1 chroot tree       | ✅ rootless    | ✅      | ✅ (VM only) |
| `from_tarball` | Phase-1 `export-tarball`  | ✅ rootless    | ✅      | ✅ (VM only) |
| `from_qcow2`   | Phase-2 (or any) qcow2    | ❌             | ✅ rootless | — |

**Containers (rootless):** `from_chroot` and `from_tarball` rebundle the
rootfs into LXD's unified tarball format (`./metadata.yaml` + `./rootfs/`)
and import with `lxc image import`.

```toml
[[instance]]
name         = "attacker"
type         = "container"
from_tarball = "/tmp/kali-amd64.tar.gz"   # rootless-clean path
```

**VMs (root required):** `from_chroot` and `from_tarball` build a bootable
disk image via `parted` MBR → `mkfs.ext4` → `extlinux` → `qcow2`, then
delegate to `from_qcow2`.  Requires `sudo`, `extlinux`, `syslinux-common`,
`qemu-utils`, `rsync`.  x86_64 BIOS only.

```bash
sudo phase5-lxd/lab-lxd.sh up --config my-vm-from-chroot.toml
```

```toml
[[instance]]
name        = "worker"
type        = "vm"
from_chroot = "/var/chroots/debian"   # kernel (/boot/vmlinuz-*) must exist
```

**Phase 2 bridge (still valid for UEFI / aarch64 / complex cases):**
Phase 2 → qcow2 → `from_qcow2` handles UEFI grub, signed shim, and
aarch64.  `MANUAL_TESTING.md` §5b covers both paths side by side.

### Two export formats

**`--format lxc-yaml` (default) — handoff-grade round-trip:**

```bash
phase5-lxd/lab-lxd.sh export demo-mixed --format lxc-yaml > demo-mixed.yaml
```

Dumps `<engine> config show --expanded` per instance, concatenated with
YAML `---` separators.  Feedable straight back into `incus launch --yaml
< demo-mixed.yaml` to recreate identical instances — same config, same
devices, same `user.lab-create.*` labels.  The LXD equivalent of Phase
4's `podman kube play` handoff.

**`--format compose` — cross-tool portability:**

```bash
phase5-lxd/lab-lxd.sh export demo-mixed --format compose > demo-mixed-compose.yml
docker compose -f demo-mixed-compose.yml config --quiet   # validates
```

Synthesises Compose v3.9 YAML from the stored `spec.toml`: containers
become services with `image`, `container_name`, `ports`, `environment`,
`volumes`, `command`; named volumes get a top-level `volumes:` block.
VMs are skipped (Compose has no VM concept).  LXD-specific fields
(profiles, project, storage) are noted as omitted.  Matches the compose
export surface in Phases 3 and 4.

### `inspect --json` — instances, profiles, and projects

`inspect` resolves in order: **instance → profile → project**.  All three
share `schema_version: 1` with a `kind` discriminator
(`"instance"` / `"profile"` / `"project"`).

```bash
# Profile inspect
phase5-lxd/lab-lxd.sh inspect default --json | jq .kind,.config
# → "profile"
# → { "limits.cpu": "2" }

# Project inspect
phase5-lxd/lab-lxd.sh inspect demo-pp --json | jq .kind,.config
# → "project"
# → { "features.profiles": "false", "features.storage.volumes": "false" }
```

For **instances**, `inspect --json` pulls together more than
any other phase's inspect: identity + labels + instance metadata
(type/arch/project/ephemeral/stateful/profiles/created_at) + image
provenance (os/release/variant/fingerprint from `image.*` + `volatile.
base_image`) + live state (status/pid/memory current+peak+swap) +
per-interface networking + expanded devices (merged from instance +
profiles) + snapshots — all in one query:

```bash
phase5-lxd/lab-lxd.sh inspect demo-mixed/web --json | jq
```

```jsonc
// sample output (truncated; focus on per-interface address spread)
{
  "schema_version": 1, "kind": "instance",
  "name": "lab-demo-mixed-web", "engine": "incus",
  "labels":   { "lab": "demo-mixed", "svc": "web", "tool": "lab-lxd.sh" },
  "instance": { "type": "container", "project": "default", "profiles": ["default"] },
  "image":    { "os": "Alpine", "release": "3.23", "fingerprint": "8b3c9e…" },
  "state":    { "status": "Running", "pid": 24817,
                "memory": { "usage_bytes": 13905920, "usage_peak_bytes": 14155776 } },
  "network":  { "interfaces": [
    { "name": "eth0", "mac_address": "00:16:3e:5a:9b:11", "addresses": [
        { "family": "inet",  "address": "10.42.0.83",       "scope": "global" },
        { "family": "inet6", "address": "fd42:abcd::83/64", "scope": "global" },
        { "family": "inet6", "address": "fe80::216:…/64",   "scope": "link"   } ] } ] }
}
```

Per-interface `addresses[]` carries family + address + netmask + scope —
the full IPv4-and-IPv6 spread per interface in one query. `list` and
`down` use `--all-projects` so cross-project instances are visible
without a `--project` flag; labels (`user.lab-create.{tool,lab,svc}` —
LXD reserves `user.*` for free-form keys) tie it all back to the lab.

## Integrations

### ← Phase 1 (LXD container or VM from a chroot)

**Container (rootless):** tarball rather than raw tree because Phase 1
chroots are root-owned — Phase 1's `export-tarball` produces a
user-readable archive:

```toml
[[instance]]
name = "attacker"
type = "container"
from_tarball = "/tmp/kali-amd64.tar.gz"
```

**VM (root required):** `type = "vm"` + `from_chroot` or `from_tarball`
builds a bootable disk image (MBR + ext4 + extlinux) and imports it as
an LXD VM.  Run with `sudo`; requires `extlinux` + `qemu-utils` + kernel
in the chroot:

```toml
[[instance]]
name        = "worker"
type        = "vm"
from_chroot = "/var/chroots/debian"
```

### ← Phase 2 (LXD VM from a Phase-2 qcow2)

The qcow2 can come from any Phase 2 backend (`disk-image`,
`kernel+initrd`, `from-chroot`) — Phase 5 just wraps and imports:

```toml
[[instance]]
name = "attacker"
type = "vm"
from_qcow2 = "/tmp/kali.qcow2"
```

### ↔ Phases 3 & 4 (mixed-engine TOMLs)

`engine = "lxd"` and `engine = "incus"` are synonymous to the cross-phase
engine-filter. One `lab.toml` carrying docker, podman, AND LXD rows side
by side is honored row-by-row — each phase tool only claims its own:

```bash
phase3-docker/lab-docker.sh up --config examples/lab-unified-demo.toml  # docker rows
phase4-podman/lab-podman.sh up --config examples/lab-unified-demo.toml  # podman rows
phase5-lxd/lab-lxd.sh      up --config examples/lab-unified-demo.toml  # lxd/incus rows
```

### → Phase 6 (TUI surfaces all instances + projects)

The Phase 6 Textual TUI calls `inspect --json` to render the LXD detail
panel — `state.running` drives the live indicator, network interfaces
become an expandable subtree. Cross-project instances (the TUI queries
`--all-projects` too) live alongside containers and VMs of the same
`lab` label as one composite resource.

## Where next

- [`PLAN.md` § Phase 5](../PLAN.md) — design rationale, exit criteria, what's in/out of v0.1
- [`MANUAL_TESTING.md`](MANUAL_TESTING.md) — every verb, every backend, walkthrough form (incl. §0a bootstrap and §10 troubleshooting)
- [`../examples/lxd-examples/`](../examples/lxd-examples/) — `lxd-plain-single.toml`, `lxd-vm-single.toml`, `lxd-mixed-topology.toml`, `lxd-from-chroot.toml`, `lxd-profiles-projects.toml`
- Sibling SHOWCASEs:
  [Phase 1 (chroots)](../phase1-chroot/SHOWCASE.md) ·
  [Phase 2 (VMs)](../phase2-qemu-vm/SHOWCASE.md) ·
  [Phase 3 (docker)](../phase3-docker/SHOWCASE.md) ·
  [Phase 4 (podman)](../phase4-podman/SHOWCASE.md) ·
  [Phase 6 (TUI)](../phase6-tui/SHOWCASE.md)
