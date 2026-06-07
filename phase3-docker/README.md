# Phase 3 — `lab-docker.sh`

Wrap `docker` for ad-hoc containers, multi-arch image builds (`buildx` + `qemu-user-static`), and multi-service lab topologies described in TOML.

## At a glance

| | |
|---|---|
| **Backends** | `image` (pull/use existing) · `from-chroot` (`docker import` a Phase-1 chroot tree) · `buildx` (multi-arch builds) |
| **Subcommands** | `build`, `run`, `up`, `down`, `exec`, `logs`, `list`, `destroy` |
| **Arches** | `x86_64`, `aarch64`, `armv7l`, `ppc64le`, `riscv64`, `s390x` (mapped to `linux/amd64`, `linux/arm64`, `linux/arm/v7`, `linux/ppc64le`, `linux/riscv64`, `linux/s390x`) |
| **Topologies** | TOML — `[lab]`, `[network.*]`, repeated `[[service]]` tables |
| **Ownership** | tracked via Docker labels (`lab-create.tool`, `lab-create.lab`, `lab-create.svc`) — no separate state file |
| **Config** | CLI flags or TOML (`--config FILE`) |

## Install

Drop `lab-docker.sh` anywhere on `$PATH`.

### Required on the host

| Always | `bash` 4+, `jq`, `tar`, a TOML parser (`yq`/`tomlq`/`dasel`), `docker` (with the daemon reachable) |
| For `--backend buildx` | `docker buildx` plugin |
| For multi-arch (foreign-arch) builds | `qemu-user-static` + `binfmt-support` *or* `docker run --privileged --rm tonistiigi/binfmt --install all` |
| For `from-chroot` | a Phase-1 chroot directory |

The script never auto-runs `docker run --privileged` on your behalf — if the binfmt registration is missing it tells you the exact command to run.

### Quick install on Debian / Ubuntu

```bash
sudo apt-get install -y \
    jq tar docker.io docker-buildx \
    qemu-user-static binfmt-support \
    yq                    # mikefarah/yq for TOML
sudo usermod -aG docker "$USER"
# log out and back in (or: newgrp docker)
docker info               # should succeed without sudo
```

## Usage

```text
lab-docker.sh build    --tag IMG  [--backend buildx|from-chroot] [--context DIR | --chroot PATH] [--arch A]
lab-docker.sh run      --name N   [--image IMG | --chroot PATH | --context DIR] [opts...]
lab-docker.sh up       --config topology.toml
lab-docker.sh down     --lab NAME | --config topology.toml
lab-docker.sh exec     <name|lab/service> [-- cmd args...]
lab-docker.sh logs     <name|lab/service> [--follow]
lab-docker.sh list     [--lab NAME]
lab-docker.sh destroy  <name|lab/service> [--force]
```

`lab-docker.sh help` for the full flag list.

## Quick examples

### Run nginx in detached mode

```bash
lab-docker.sh run --name web1 --image nginx:alpine --ports 8080:80 --detach
curl http://localhost:8080/
lab-docker.sh logs web1
lab-docker.sh exec web1 -- nginx -t
lab-docker.sh destroy web1 --force
```

(The container name on the docker side becomes `lab-web1` to avoid collisions with manually-managed containers.)

### Build a multi-arch image (aarch64 from x86_64 host)

```bash
mkdir /tmp/myapp && cat > /tmp/myapp/Dockerfile <<'EOF'
FROM alpine:latest
RUN apk add --no-cache htop
CMD ["uname", "-a"]
EOF

lab-docker.sh build --tag myapp:arm64 --backend buildx --context /tmp/myapp --arch aarch64
lab-docker.sh run   --name a --image myapp:arm64 --rm --tty
# → Linux ... aarch64 ... GNU/Linux
```

The first foreign-arch build will create a `lab-builder` buildx builder on the `docker-container` driver. The script reuses any existing multi-platform builder if one is already present.

### Import a Phase-1 chroot as an image

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --backend host-copy --target /var/jails/busybox --binaries /bin/busybox

lab-docker.sh build --tag bbox:lab --backend from-chroot --chroot /var/jails/busybox
lab-docker.sh run --name bb --image bbox:lab --rm --tty -- /bin/busybox sh
```

`docker import` produces a single-layer image with no metadata — set the entry command via `--` (or wrap with a `Dockerfile FROM` to add CMD/ENV layers).

### Multi-service topology

```bash
lab-docker.sh up   --config examples/docker-examples/docker-3svc-topology.toml
lab-docker.sh list --lab demo
curl http://localhost:8088/                # web service
lab-docker.sh exec demo/db -- psql -U postgres -c '\l'
lab-docker.sh down --lab demo
```

## Topology config (TOML)

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

[[service]]
name     = "db"
image    = "postgres:16-alpine"
networks = ["frontend"]
environment = { POSTGRES_PASSWORD = "lab", POSTGRES_DB = "lab" }
volumes  = ["pgdata:/var/lib/postgresql/data"]

[[service]]
name     = "client"
image    = "alpine:latest"
networks = ["frontend"]
command  = "sleep infinity"
```

### Per-service keys

| Key | Type | Notes |
|---|---|---|
| `name` | string | required |
| `image` | string | one of `image`/`from_chroot`/`build` is required |
| `from_chroot` | path | `docker import` this tree, then run |
| `build` | path | `docker buildx build` this directory, then run |
| `networks` | array | first one is attached at run time, the rest via `docker network connect` |
| `ports` | array | strings, docker `-p` syntax |
| `environment` | table | key→value, becomes `-e K=V` |
| `volumes` | array | strings, docker `-v` syntax |
| `command` | string | space-split. For complex argv use `cmd = ["a", "b", "c"]` |
| `cmd` | array | preferred argv form |

### Lab-level keys

| Key | Type | Notes |
|---|---|---|
| `lab.name` | string | required; used as the value of the `lab-create.lab` label and the prefix for container/network names |
| `network.<name>.driver` | string | default `bridge` |

## State and labels

No separate state file — everything is on the docker side. Three labels:

| Label | Value |
|---|---|
| `lab-create.tool` | `lab-docker` (always present on resources we created) |
| `lab-create.lab` | the lab name (or `adhoc` for `run`-created containers) |
| `lab-create.svc` | the service name (or the `--name` used in `run`) |

Resource naming:

| Resource | Name |
|---|---|
| Topology container | `lab-<labname>-<service>` |
| Ad-hoc container | `lab-<name>` |
| Topology network | `lab-<labname>-<network>` |
| Auto-built image (topology) | `lab-<labname>-<service>-img` |
| Auto-built image (`run`) | `lab-build-<name>` / `lab-from-chroot-<name>` |

`down` and `destroy` query labels to find what to tear down — they don't depend on a manifest file, so external `docker rm` operations don't desync state.

## Multi-arch notes

- For host-arch builds, the default `docker` driver works and `--load` makes the result available locally.
- For foreign-arch builds, `buildx` requires a builder with `docker-container` (or `kubernetes`) driver. The script auto-creates one called `lab-builder` if no suitable builder exists.
- `binfmt_misc` registration is **not** auto-installed. The script errors with two install-path hints (`apt-get install qemu-user-static` *or* `docker run --privileged --rm tonistiigi/binfmt --install all`).
- Multi-platform manifest lists (single tag, multiple platforms) require `--push` to a registry — single-platform `--load` is what this v1 supports for local-only builds.

## v0.2 additions

- **`push` subcommand** — `lab-docker.sh push <tag>` (or `--tag TAG`) delegates to `docker push`; warns when `--arch` is present that multi-arch manifest lists need `docker manifest push` separately.
- **`depends_on` / startup order** — topology services are started in topological (dependency-first) order. Add `depends_on = ["db"]` to a `[[service]]` and the dependency starts first. Cycles are detected and die loudly.
- **Healthchecks** — `[service.healthcheck]` TOML table (`test`, `interval`, `timeout`, `retries`, `start_period`) wires directly into `docker run --health-*` flags. When a service has a healthcheck, `up` waits for it to become healthy before starting dependents. `export` emits `healthcheck:` blocks in compose output.
- **Compose YAML interop** — `--config` now accepts `.yml` / `.yaml` files (docker-compose v2 format) in addition to `.toml`. Requires mikefarah/yq. The `up`, `down`, and `export` subcommands all honour the extension.

## Known gaps in v0.2

- **Volumes** treat the source as a literal path or volume name — no explicit management (Docker creates named volumes implicitly on first reference).
- **Compose volumes in object form** (`type: volume`, `source:`, `target:`) are not converted by the YAML interop path; use the string form (`"vol:/data"`) instead.
- **Multi-platform manifest lists** require `--push` to a registry; `push` and `build` only support single-platform `--load` for local builds.

## Tests

```bash
phase3-docker/tests/run-all.sh
```

Each test self-skips (exit 77) if its preconditions aren't met. The full suite needs `docker` reachable and (for the buildx test) `qemu-user-static` + binfmt or the tonistiigi/binfmt setup.
