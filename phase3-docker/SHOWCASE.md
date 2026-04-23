# Phase 3 — docker, but treated like a lab manager

## What it gives you

`docker run` and `docker compose` think one container at a time, or one
project per directory. Phase 3 lets you describe a whole **lab** —
services, networks, volumes — in a single TOML file, then drive the
result through 13 verbs (`build`, `run`, `up`, `down`, `exec`, `logs`,
`status`, `list`, `inspect`, `destroy`, `export`, `version`, `help`).
Lab membership lives entirely in three docker labels — `lab-create.tool`,
`lab-create.lab`, `lab-create.svc` — so there is no on-disk state file
to drift, and `list`/`down`/`status` work even after a reboot.

## 60-second demo

```bash
cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2

# 1. Bring up nginx + postgres + an idle alpine "client" on a shared bridge.
phase3-docker/lab-docker.sh up --config examples/docker-3svc-topology.toml

# 2. See what just landed.
phase3-docker/lab-docker.sh list --lab demo

# 3. Poke the database from inside the lab.
phase3-docker/lab-docker.sh exec demo/db -- psql -U lab -d lab -c '\l'

# 4. Tear it all down — containers and the bridge network — by label query.
phase3-docker/lab-docker.sh down --lab demo
```

Sample `list --lab demo` output:

```
── lab: demo ──
NAMES             IMAGE                STATUS         PORTS
lab-demo-web      nginx:alpine         Up 12 seconds  0.0.0.0:8088->80/tcp
lab-demo-db       postgres:16-alpine   Up 12 seconds  5432/tcp
lab-demo-client   alpine:latest        Up 12 seconds

[networks]
NAME                  DRIVER    SCOPE
lab-demo-frontend     bridge    local
```

(sample output)

## Feature tour

### Topology as TOML, not docker-compose

The canonical 3-service demo (`examples/docker-3svc-topology.toml`) is
20 lines of declarative TOML — one `[lab]` block, one `[network.*]`,
three `[[service]]` arrays:

```toml
[lab]
name = "demo"

[network.frontend]
driver = "bridge"

[[service]]
name     = "web"
image    = "nginx:alpine"
networks = ["frontend"]
ports    = ["8088:80"]
```

No project directories, no implicit working-directory magic. The lab
name comes from `[lab].name`, container names are deterministically
`lab-<lab>-<svc>`, networks are `lab-<lab>-<net>`. Re-running `up` is
idempotent — existing services warn and stay alive instead of erroring
out on a duplicate-name conflict.

### Multi-architecture builds (buildx + qemu-user-static)

Build an image for foreign-arch from your x86_64 laptop with one flag:

```bash
phase3-docker/lab-docker.sh build \
    --tag myapp:arm64 --backend buildx --context ./app --arch aarch64
```

On first foreign build the script auto-creates a `lab-builder`
(`docker-container` driver — the default `docker` driver can't `--load`
multi-platform results), checks for the qemu-aarch64 binfmt
registration, and emulates under qemu-user-static. You don't have to
remember `docker buildx create --bootstrap` or `--platform linux/arm64`
or `--load`. If binfmt isn't installed, the error tells you the exact
fix command.

Supported arches: `x86_64 aarch64 armv7l ppc64le riscv64 s390x` — same
mapping table the rest of the project uses.

### `from-chroot` / `from-tarball` import (Phase 1 bridge)

Take any chroot you've built with Phase 1 and turn it into a docker
image. The clean rootless path is two commands:

```bash
sudo phase1-chroot/lab-chroot.sh export-tarball mychroot \
    --output /tmp/mychroot.tar.gz

phase3-docker/lab-docker.sh build \
    --tag mychroot --backend from-tarball --tarball /tmp/mychroot.tar.gz
```

`from-chroot` works directly against the tree if every file is readable
by the calling user. If it isn't (the common case — `sudo lab-chroot
create` leaves mode-600 `/etc/shadow`, `/root/*`, etc.), a readability
preflight catches it **before** the import partially completes and
prints the exact `export-tarball` recipe to run instead. No half-written
ghost images in `docker images`.

Either backend produces a single-layer image via `docker import` —
small, traceable, and faithful to the chroot's filesystem snapshot.

### Cross-phase `engine` filter

The same TOML can describe services for Phase 3 (docker), Phase 4
(podman), and Phase 5 (lxd/incus) at the same time. Each phase tool
reads its own rows and silently ignores the rest:

```toml
[[service]]
name = "edge-proxy"
engine = "docker"        # ← lab-docker claims this
image = "nginx:alpine"

[[service]]
name = "scanner-alpine"
engine = "podman"        # ← lab-podman claims this; lab-docker skips
image = "docker.io/library/alpine:latest"
```

`examples/lab-unified-demo.toml` is the canonical cross-phase example —
five containers, three runtimes, one file. `LAB_LOG_LEVEL=debug` will
show you each `skipping service '…' (engine=…, not docker)` line.

### `compose` export — round-trip back out

Hand a topology off to a vanilla compose environment without rewriting
it by hand:

```bash
phase3-docker/lab-docker.sh export \
    --config examples/docker-3svc-topology.toml --format compose \
    > /tmp/compose.yml

docker compose -f /tmp/compose.yml config --quiet   # validates
docker compose -f /tmp/compose.yml up -d            # ships it
```

The emitted YAML is Compose v2 — no obsolete `version:` key (v2 warns on
it), named volumes auto-collected at the top level, the cross-phase
`engine` filter applied so you don't accidentally export podman rows
into docker compose. Services backed by `from_chroot` or `from_tarball`
emit the synthesized image tag plus a `# source:` comment, since
compose can't rebuild them itself.

### `inspect --json` — folded labels + ports + mounts

Added in commit `f1caefc` and consumed by the Phase 6 TUI's docker
detail panel. `docker inspect` emits a deeply nested JSON array; we fold
it in jq into a stable `schema_version: 1` surface:

```bash
phase3-docker/lab-docker.sh inspect demo/web --json | jq
```

Sample output (truncated):

```json
{
  "schema_version": 1,
  "name": "lab-demo-web",
  "labels": {
    "lab": "demo",
    "svc": "web",
    "tool": "lab-docker",
    "_other": { "maintainer": "NGINX Docker Maintainers <docker-maint@nginx.com>" }
  },
  "container": { "id": "8f3c2…", "image": "nginx:alpine", "command": [], "created_at": "2026-04-22T…" },
  "state":     { "status": "running", "running": true, "exit_code": null, "restart_count": 0, "pid": 31418, "health": null },
  "network":   { "ports": [{ "container_port": 80, "protocol": "tcp", "host_ip": "0.0.0.0", "host_port": 8088 }],
                  "networks": ["lab-demo-frontend"], "ip_addresses": { "lab-demo-frontend": "172.20.0.3" } },
  "mounts":    []
}
```

(sample output)

Image-side labels you didn't set (e.g. `maintainer`) get tucked under
`labels._other` instead of polluting the lab/svc/tool top-level
namespace. Drop `--json` for a human-formatted `[labels] / [container]
/ [state] / [network] / [mounts]` rendering of the same data.

### `status` — three call shapes

```bash
phase3-docker/lab-docker.sh status              # docker info summary
phase3-docker/lab-docker.sh status demo         # all containers + networks in lab demo
phase3-docker/lab-docker.sh status demo/web     # one-container detail (also: lab-demo-web)
```

The dispatcher disambiguates `<lab>` vs `<container>` by checking
whether `lab-<arg>` exists as a container; if not, it tries the label
query. So `status web1` and `status demo/web` and `status demo` all do
the right thing.

## Integrations

### ← Phase 1 (turn a chroot into a docker image)

Build any chroot — debootstrap, host-copy, even `nspawn`-managed —
export it to a user-readable tarball, then `--backend from-tarball`
into docker. The readability preflight on `--backend from-chroot`
prevents half-imported ghost images when you point it at a
sudo-built tree.

### ↔ Phases 4 & 5 (mixed-engine TOMLs)

A `[[service]] engine = "podman"` block is silently skipped by
`lab-docker.sh up`; the same row is claimed by `lab-podman.sh up`
against the same file. Phase 5 reads `[[instance]] engine = "lxd"`
the same way. One file, three runtimes. See
`examples/lab-unified-demo.toml`.

### → Phase 6 (TUI surfaces all your containers)

Phase 6's Textual TUI calls `inspect --json` for the docker detail
panel — the `schema_version: 1` contract above is what it depends on.
Containers tagged `lab-create.tool=lab-docker` show up in the unified
topology view alongside chroots, VMs, podman pods, and LXD instances.

## Where next

- [`PLAN.md` §Phase 3](../PLAN.md) — design rationale and exit criteria
- [`MANUAL_TESTING.md`](MANUAL_TESTING.md) — copy-paste verification walkthrough
- [`examples/docker-3svc-topology.toml`](../examples/docker-3svc-topology.toml) — the lab used above
- [`examples/lab-unified-demo.toml`](../examples/lab-unified-demo.toml) — cross-phase example
- Sibling SHOWCASEs:
  [Phase 1 (chroots)](../phase1-chroot/SHOWCASE.md) ·
  [Phase 2 (VMs)](../phase2-qemu-vm/SHOWCASE.md) ·
  [Phase 4 (podman)](../phase4-podman/SHOWCASE.md) ·
  [Phase 5 (LXD/Incus)](../phase5-lxd/SHOWCASE.md) ·
  [Phase 6 (TUI)](../phase6-tui/SHOWCASE.md)
