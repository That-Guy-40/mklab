# Start here — Phase 3: Docker (`lab-docker.sh`)

Phase 3 wraps Docker for **ad-hoc containers, multi-arch image builds, and
multi-service lab topologies** described in a single TOML file. One `up` command
starts every service; one `down` tears them all down. There's no separate state
file — ownership is tracked via Docker labels.

---

## Option A — use the wizard (recommended)

If you have the Phase 6 TUI running:

```bash
cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
python3 -m lab_tui          # or: python3 phase6-tui/main.py
```

Press **`n`** → select **Phase 3 — Docker svc** → fill in the form → press **Save**.
The wizard writes a TOML file to `examples/docker-<lab>.toml`.
Then bring it up with the command in Option C.

---

## Option B — three-minute quickstart (no wizard needed)

### 1. Install prerequisites

```bash
sudo apt-get install -y jq docker.io docker-buildx yq
sudo usermod -aG docker "$USER"   # log out and back in
docker info                        # should succeed without sudo
```

### 2. Run a single container

```bash
phase3-docker/lab-docker.sh run \
    --name web1 \
    --image nginx:alpine \
    --ports 8080:80 \
    --detach

curl http://localhost:8080/
```

### 3. Inspect, exec, and destroy

```bash
phase3-docker/lab-docker.sh list
phase3-docker/lab-docker.sh exec web1 -- nginx -t
phase3-docker/lab-docker.sh logs web1
phase3-docker/lab-docker.sh destroy web1 --force
```

---

## Option C — use a TOML config (from the wizard or an example)

```bash
# Three-service topology: nginx + postgres + alpine client on a shared network
phase3-docker/lab-docker.sh up   --config examples/docker-3svc-topology.toml
phase3-docker/lab-docker.sh list --lab demo

curl http://localhost:8088/
phase3-docker/lab-docker.sh exec demo/db -- psql -U lab -c '\l'

phase3-docker/lab-docker.sh down --lab demo
```

Ready-to-run examples in `examples/`:

| File | What it builds |
|---|---|
| `docker-3svc-topology.toml` | nginx + postgres + alpine client on a bridge network |
| `docker-netboot-server.toml` | nginx serving PXE artifacts (netboot pipeline) |

---

## Anatomy of a config

```toml
[lab]
name = "my-lab"               # label applied to every container/network we create

[network.frontend]             # creates a docker bridge network "lab-my-lab-frontend"
driver = "bridge"

[[service]]
name     = "web"              # container becomes "lab-my-lab-web"
image    = "nginx:alpine"
networks = ["frontend"]
ports    = ["8080:80"]

[[service]]
name        = "db"
image       = "postgres:16-alpine"
networks    = ["frontend"]
environment = { POSTGRES_PASSWORD = "lab" }
volumes     = ["pgdata:/var/lib/postgresql/data"]
depends_on  = ["web"]         # db starts after web is healthy
```

### Per-service keys (quick reference)

| Key | Notes |
|---|---|
| `image` | pull from a registry |
| `from_chroot` | path to a Phase-1 chroot — imported via `docker import` |
| `build` | path to a Dockerfile context — built via `docker buildx` |
| `ports` | `["host:container"]` — docker `-p` syntax |
| `environment` | `{ KEY = "val" }` |
| `volumes` | `["vol:/path"]` or `["/host:/container"]` |
| `command` | space-split string; use `cmd = ["a","b"]` for complex argv |
| `depends_on` | start this service only after these services are running/healthy |
| `[service.healthcheck]` | `test`, `interval`, `timeout`, `retries`, `start_period` |

---

## What just happened — the "why" under the hood

**Labels as the state file:** Docker lets you attach arbitrary key=value metadata
to any object. Phase 3 stamps every container, network, and volume it creates with:
```
lab-create.tool=lab-docker
lab-create.lab=my-lab
lab-create.svc=web
```
`down` and `destroy` run `docker ps -a --filter label=lab-create.lab=my-lab` to
find their resources — no manifest file to get out of sync. You can `docker rm` a
container manually and Phase 3 won't complain; it just won't find it on the next `list`.

**`depends_on` and topological sort:** `up` builds a dependency graph from `depends_on`
fields and does a depth-first topological sort before starting anything. Services
with no dependencies start first; services that depend on them start after. If a
service has a `healthcheck`, dependents wait until Docker reports it `healthy` (not
just `running`) before they start. Cycles are detected before any container starts.

**Multi-arch builds (`buildx`):** Docker's `buildx` plugin uses `binfmt_misc` +
`qemu-user-static` to run foreign-arch build steps. When you `build --arch aarch64`
on an x86_64 host, the build steps run inside a QEMU-translated arm64 container.
The result is a real `linux/arm64` image, not a cross-compiled binary wrapped in
the wrong-arch image. Phase 3 creates a `docker-container`-driver buildx builder
(`lab-builder`) if one doesn't exist.

---

## Next steps

- **`README.md`** — complete flag reference, Compose YAML interop, v0.2 features
- **`SHOWCASE.md`** — live-verified demos: multi-arch, from-chroot, topology
- **`MANUAL_TESTING.md`** — step-by-step verification walkthrough
- **`examples/`** — all TOML examples above
- **← Phase 1** (`START_HERE_CHROOT_WIZARD.md`) — build a rootfs for `from_chroot`
- **→ Phase 4** (`START_HERE_PODMAN_WIZARD.md`) — same topology concept, rootless, with pods
- **Export to Compose:** `phase3-docker/lab-docker.sh export <lab> --format compose`
