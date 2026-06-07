# Phase 3 — Manual Testing Walkthrough

A copy-pasteable, step-by-step exercise of `lab-docker.sh`.

> **Set up:**
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> alias ld='phase3-docker/lab-docker.sh'         # no sudo: docker via group
> ```

## 0. Preflight

```bash
sudo apt-get update
sudo apt-get install -y \
    jq tar yq \
    docker.io docker-buildx \
    qemu-user-static binfmt-support
sudo usermod -aG docker "$USER"
# log out and back in (or: newgrp docker)
docker info     # must succeed without sudo
```

> Once you're in the `docker` group, you don't need `sudo` for any of the
> Phase 3 commands. **Inside containers**, `sudo` and `file` are present only
> if the base image ships them (most slim/alpine images don't — install via
> a Dockerfile `RUN` step or use a heavier base).

Verify:

```bash
ld version             # → "lab-docker.sh 0.1.0"
ld help                # → full usage
ld list                # → header + (probably empty)
```

## 1. Validation guardrails (no docker calls)

```bash
ld build                                                         # → usage error
ld run                                                           # → usage error
ld up                                                            # → "config" error
ld down                                                          # → "lab name" error
ld destroy                                                       # → usage error
ld run --name foo                                                # → "need one of: --image..."
ld build --tag t --backend bogus                                 # → "unknown build backend"
```

Mechanise:

```bash
phase3-docker/tests/test-validation.sh
```

## 2. Ad-hoc nginx (single-container `run`)

```bash
ld run --name web1 --image nginx:alpine --ports 8088:80 --detach
ld list                                  # → table including web1
docker ps --filter name=lab-web1         # confirm name prefix and labels
curl -s http://localhost:8088/ | head -3
```

**Expect:** the nginx default index page first lines.

```bash
ld logs web1
ld exec web1 -- nginx -t
ld destroy web1 --force
ld list                                  # → web1 gone
```

## 3. `from-chroot` import (chains with Phase 1)

Build a tiny chroot in Phase 1 first:

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --backend host-copy --target /var/jails/bbox \
    --binaries /bin/busybox \
    --extras /etc/passwd,/etc/group
```

Import as a Docker image and run:

```bash
ld build --tag bbox:lab --backend from-chroot --chroot /var/jails/bbox
docker images bbox:lab                   # confirm the image exists
ld run --name bb --image bbox:lab --rm --tty -- /bin/busybox sh -c 'echo hi from $(uname -m)'
```

**Expect:** `hi from x86_64` (or whatever your host is).

```bash
sudo phase1-chroot/lab-chroot.sh destroy bbox --force
docker rmi bbox:lab
```

## 4. Multi-arch buildx (foreign aarch64 from x86_64)

Verify binfmt registration first; if missing, the script will tell you exactly which command to run.

```bash
ls /proc/sys/fs/binfmt_misc/qemu-aarch64    # must exist
# If not:
sudo update-binfmts --enable qemu-aarch64
# OR (the docker-native way):
docker run --privileged --rm tonistiigi/binfmt --install all
```

Make a tiny build context:

```bash
mkdir /tmp/myapp && cat > /tmp/myapp/Dockerfile <<'EOF'
FROM alpine:latest
RUN apk add --no-cache htop
CMD ["uname", "-m"]
EOF

ld build --tag myapp:arm64 --backend buildx --context /tmp/myapp --arch aarch64
```

**Expect:** the script auto-creates `lab-builder` (driver `docker-container`) on first foreign build, then `--load`s the result. The build runs entirely under qemu-user emulation.

```bash
ld run --name a --image myapp:arm64 --rm --tty
# → aarch64
docker rmi myapp:arm64
rm -rf /tmp/myapp
```

## 5. Three-service topology (`up` / `down`)

```bash
ld up --config examples/docker-examples/docker-3svc-topology.toml
ld list --lab demo
docker network ls --filter label=lab-create.lab=demo
```

**Expect:** three containers (`lab-demo-web`, `lab-demo-db`, `lab-demo-client`) and one network (`lab-demo-frontend`).

Hit the web service:

```bash
curl -s http://localhost:8088/ | head -3
```

Talk to the db:

```bash
ld exec demo/db -- psql -U lab -d lab -c '\l'
```

Tear down (containers first, then networks):

```bash
ld down --lab demo
ld list --lab demo                       # → empty
docker network ls --filter label=lab-create.lab=demo   # → empty
```

If you keep the named pgdata volume around between runs you can re-`up` and the database persists. To wipe it: `docker volume rm lab-demo-pgdata`.

## 6. Idempotency

```bash
ld up --config examples/docker-examples/docker-3svc-topology.toml
ld up --config examples/docker-examples/docker-3svc-topology.toml   # → second run is a no-op for existing services
ld down --lab demo
```

`up` warns once per existing service that it's leaving things alone, rather than crashing on the duplicate-name conflict.

## 7. Mixed labs

You can run multiple labs side by side; the label-based queries keep them
separate.

```bash
cat > /tmp/lab-a.toml <<EOF
[lab]
name = "alpha"
[[service]]
name = "echo1"
image = "alpine:latest"
command = "sleep 3600"
EOF
cat > /tmp/lab-b.toml <<EOF
[lab]
name = "beta"
[[service]]
name = "echo1"
image = "alpine:latest"
command = "sleep 3600"
EOF

ld up --config /tmp/lab-a.toml
ld up --config /tmp/lab-b.toml
ld list                          # → containers under both alpha and beta
ld down --lab alpha
ld list                          # → only beta remaining
ld down --lab beta
rm /tmp/lab-a.toml /tmp/lab-b.toml
```

## 8. Inspect and export (`status` / `export --format compose`)

`status` is the "show me what's there" counterpart to `list`. Three call
shapes, same dispatch rules as `lab-podman status`:

```bash
ld status                          # bare — daemon/host summary (docker info)
ld status alpha                    # lab-scoped — containers + networks tagged lab=alpha
ld status alpha/echo1              # single-container detail
ld status echo1                    # short-name form (resolves to lab-echo1)
```

`export` emits a [Compose v2][compose] YAML reconstruction of a lab
directly from its TOML — handy for handing a topology off to a
compose-only environment, or for feeding `docker compose config`
validation in CI. Phase 3 is stateless (label-first), so unlike
Phase 4's `export`, `--config FILE` is required:

```bash
ld export --config /tmp/lab-a.toml                    # → compose YAML on stdout
ld export --config /tmp/lab-a.toml --format compose \  # same, explicit --format
          > /tmp/alpha-compose.yml
docker compose -f /tmp/alpha-compose.yml config       # validates round-trip
docker compose -f /tmp/alpha-compose.yml up -d        # hands it off to vanilla compose
```

Cross-phase hygiene: any `[[service]] engine = "podman"` block is
skipped — the exported YAML contains only the docker-engine services,
matching what `ld up` would actually start. Named volumes referenced
by services (anything whose source is not an absolute or relative path)
are declared at the top level automatically so the generated YAML
round-trips without manual fixup.

What doesn't round-trip: `from_chroot` / `from_tarball` image sources
emit the synthesized image tag plus a `# source:` comment, but compose
can't rebuild those images itself — you'd need `lab-docker build` (or
the chroot export step) first. This is called out in the generated YAML.

[compose]: https://docs.docker.com/reference/compose-file/

## 9. depends_on / startup ordering

### 9.1 Why this exists

Without `depends_on`, `cmd_up` starts services in the order they appear in the
TOML file.  That's fine until `web` tries to connect to `db` a millisecond after
`db` starts — the TCP listener isn't up yet, the client crashes, and
everything retries or fails silently.

`depends_on` tells the script the start order.  Internally, it runs a
depth-first topological sort over the declared dependency graph before starting
anything.  Cycles are caught at sort time and die loudly.

### 9.2 Basic ordering

Create a three-service topology where `web` depends on `db` and `cache`:

```bash
cat > /tmp/lab-dep.toml <<'EOF'
[lab]
name = "deptest"

[[service]]
name    = "cache"
image   = "alpine:latest"
command = "sleep 3600"

[[service]]
name       = "db"
image      = "alpine:latest"
command    = "sleep 3600"
depends_on = ["cache"]

[[service]]
name       = "web"
image      = "alpine:latest"
command    = "sleep 3600"
depends_on = ["db", "cache"]
EOF

ld up --config /tmp/lab-dep.toml
```

**Watch the log output.**  You must see services starting in
dependency-first order: `cache` before `db`, both before `web`.
The log lines look like:

```
[info] starting service 'cache' as lab-deptest-cache …
[info] starting service 'db'    as lab-deptest-db    …
[info] starting service 'web'   as lab-deptest-web   …
```

`db` would appear before `web` even though it was listed second in the file.

Verify all three are running:

```bash
docker ps --filter label=lab-create.lab=deptest \
          --format 'table {{.Names}}\t{{.Status}}'
```

**Expect:** three containers, all `Up`.

### 9.3 Dependency order survives a reversed TOML listing

The sort is graph-driven, not position-driven.  Reorder the TOML so `web` is
listed first:

```bash
cat > /tmp/lab-dep-reversed.toml <<'EOF'
[lab]
name = "deprev"

[[service]]
name       = "web"
image      = "alpine:latest"
command    = "sleep 3600"
depends_on = ["db"]

[[service]]
name       = "db"
image      = "alpine:latest"
command    = "sleep 3600"
EOF

ld up --config /tmp/lab-dep-reversed.toml
```

**Expect:** `db` starts first in the log, `web` second — despite `web`
appearing first in the file.

```bash
ld down --lab deprev
```

### 9.4 Diamond dependency (two roots)

```bash
cat > /tmp/lab-diamond.toml <<'EOF'
[lab]
name = "diamond"

[[service]]
name    = "a"
image   = "alpine:latest"
command = "sleep 3600"

[[service]]
name    = "b"
image   = "alpine:latest"
command = "sleep 3600"

[[service]]
name       = "c"
image      = "alpine:latest"
command    = "sleep 3600"
depends_on = ["a", "b"]
EOF

ld up --config /tmp/lab-diamond.toml
```

**Expect:** `a` and `b` start (in TOML order) before `c`.
The script doesn't guarantee the order of independent nodes relative to
each other — only that all dependencies precede their dependents.

```bash
ld down --lab diamond
```

### 9.5 Export round-trip: depends_on in compose YAML

```bash
ld export --config /tmp/lab-dep.toml
```

**Expect:** the `db` service block contains:

```yaml
    depends_on:
      cache:
        condition: service_started
```

and the `web` service block contains both `cache` and `db` with
`condition: service_started`.

(The condition is `service_healthy` instead of `service_started` when the
dependency also declares a `[service.healthcheck]` — see §10.)

### 9.6 Cycle detection

```bash
cat > /tmp/lab-cycle.toml <<'EOF'
[lab]
name = "cycleme"

[[service]]
name       = "alpha"
image      = "alpine:latest"
command    = "sleep 60"
depends_on = ["beta"]

[[service]]
name       = "beta"
image      = "alpine:latest"
command    = "sleep 60"
depends_on = ["alpha"]
EOF

ld up --config /tmp/lab-cycle.toml 2>&1 || true
```

**Expect:** an `[error]` line mentioning `cycle detected at service 'alpha'`
(or `beta`) and a non-zero exit.  No containers are created.

```bash
docker ps --filter label=lab-create.lab=cycleme   # → empty
```

### 9.7 Cleanup

```bash
ld down --lab deptest
ld down --lab deprev   2>/dev/null || true
ld down --lab diamond  2>/dev/null || true
rm /tmp/lab-dep.toml /tmp/lab-dep-reversed.toml /tmp/lab-diamond.toml /tmp/lab-cycle.toml
```

---

## 10. Healthchecks

### 10.1 Why this exists

`depends_on` with only `service_started` guarantees start *order*, not
*readiness*.  A database container is "started" the moment its PID 1 runs —
but `pg_isready` might fail for another 5–15 seconds while the process
initialises.

`[service.healthcheck]` wires a readiness probe directly into the container
via `docker run --health-cmd`.  When a service has a healthcheck and another
service depends on it, `up` polls `docker inspect` until the container reaches
`healthy` state before starting the dependent.  The export path emits
`condition: service_healthy` in the compose `depends_on` block.

### 10.2 Add a healthcheck to a service

Use a fast-pass probe (`echo ok`) so the test completes in a few seconds
rather than waiting for a real database:

```bash
cat > /tmp/lab-hc.toml <<'EOF'
[lab]
name = "hctest"

[[service]]
name  = "backend"
image = "alpine:latest"
command = "sleep 3600"

[service.healthcheck]
test         = "echo ok"
interval     = "2s"
timeout      = "1s"
retries      = 3
start_period = "1s"

[[service]]
name       = "frontend"
image      = "alpine:latest"
command    = "sleep 3600"
depends_on = ["backend"]
EOF

ld up --config /tmp/lab-hc.toml
```

**Watch the log.**  After `backend` starts you should see:

```
[info] waiting for 'lab-hctest-backend' to become healthy (max 120s)…
[info] starting service 'frontend' as lab-hctest-frontend …
```

`frontend` only starts after `backend` becomes healthy.

### 10.3 Verify the healthcheck is wired in

```bash
docker inspect lab-hctest-backend \
    --format '{{.State.Health.Status}}   ({{len .State.Health.Log}} log entries)'
```

**Expect:** `healthy   (N log entries)` where N ≥ 1.

```bash
docker inspect lab-hctest-backend \
    --format '{{(index .State.Health.Log 0).Output}}'
```

**Expect:** `ok` (the stdout of `echo ok`).

Check the `--health-*` flags in the container config:

```bash
docker inspect lab-hctest-backend \
    --format '{{.Config.Healthcheck}}'
```

**Expect:** something like `&{[CMD-SHELL echo ok] 2000000000 1000000000 3 ...}`.
The values are nanoseconds: `2000000000` = 2 s interval.

### 10.4 All healthcheck fields

```bash
docker inspect lab-hctest-backend --format \
    'interval={{.Config.Healthcheck.Interval}}  timeout={{.Config.Healthcheck.Timeout}}  retries={{.Config.Healthcheck.Retries}}'
```

**Expect:** `interval=2000000000  timeout=1000000000  retries=3`.

### 10.5 Export: condition: service_healthy

```bash
ld export --config /tmp/lab-hc.toml
```

**Expect:** the `frontend` block contains:

```yaml
    depends_on:
      backend:
        condition: service_healthy
```

and the `backend` block contains the full `healthcheck:` section:

```yaml
    healthcheck:
      test: ["CMD-SHELL", "echo ok"]
      interval: 2s
      timeout: 1s
      retries: 3
      start_period: 1s
```

Save it and validate with `docker compose config` if you have it:

```bash
ld export --config /tmp/lab-hc.toml > /tmp/hc-compose.yml
docker compose -f /tmp/hc-compose.yml config --quiet && echo "compose validated"
```

### 10.6 Optional: healthcheck failure path

> **Note:** this exercises what happens when a container's probe
> consistently fails.  It will cause `up` to die after detecting the
> container as `unhealthy`.  Run this in a scratch lab and clean up
> manually.

```bash
cat > /tmp/lab-hc-fail.toml <<'EOF'
[lab]
name = "hcfail"

[[service]]
name    = "badprobe"
image   = "alpine:latest"
command = "sleep 3600"

[service.healthcheck]
test     = "false"     # deliberately always fails
interval = "2s"
timeout  = "1s"
retries  = 2
EOF

ld up --config /tmp/lab-hc-fail.toml 2>&1 || true
```

**Expect:** `[error] container 'lab-hcfail-badprobe' is unhealthy` and a
non-zero exit once Docker flips the status to `unhealthy` (after
`retries` consecutive failures).

> `retries = 2` means 2 consecutive failures after the start period.  With
> `interval = 2s`, the container will be declared unhealthy within ~8 s.

Clean up:

```bash
docker rm -f lab-hcfail-badprobe 2>/dev/null || true
```

### 10.7 Cleanup

```bash
ld down --lab hctest
rm /tmp/lab-hc.toml /tmp/lab-hc-fail.toml /tmp/hc-compose.yml 2>/dev/null || true
```

---

## 11. Compose YAML interop

### 11.1 Why this exists

Many teams already have `docker-compose.yml` files that describe their
services.  The `--config` flag now accepts `.yml` / `.yaml` files using the
docker-compose v2 schema, with no conversion step required.  Under the hood,
`compose_to_json()` translates the Compose schema to the same internal JSON
that `toml_to_json()` produces, so `up`, `down`, `export`, and `list` all
work identically.

**Prerequisite:** mikefarah/yq must be installed.  Verify:

```bash
yq --version | grep -i mikefarah   # must match; kislyuk/yq is a different tool
# If missing:
sudo apt-get install -y yq          # Ubuntu 22.04+ ships the mikefarah variant
# or: sudo snap install yq
# or: pip3 install yq               # kislyuk — works for YAML but not for --p toml
```

If yq is absent, the script dies early with an actionable error.

### 11.2 Minimal compose file → `up` and `down`

```bash
cat > /tmp/compose-lab.yml <<'EOF'
name: composelab

networks:
  front:
    driver: bridge

services:
  web:
    image: nginx:alpine
    ports:
      - "18081:80"
    networks:
      - front

  client:
    image: alpine:latest
    command: sleep 3600
    networks:
      - front
EOF

ld up --config /tmp/compose-lab.yml
```

**Expect:** same `[info]` log lines as with a TOML config; two containers
start under the `composelab` lab.

```bash
ld list --lab composelab
curl -s http://localhost:18081/ | head -3   # nginx default page
ld exec composelab/client -- wget -qO- http://web/   # container-to-container via network
```

**Expect:** the wget returns the same nginx HTML, confirming the `front`
bridge network connects the two services.

Tear down using the same config file:

```bash
ld down --config /tmp/compose-lab.yml
ld list --lab composelab   # → empty
```

### 11.3 Environment variables: both YAML forms

Compose supports two environment formats.  Both must parse correctly:

```bash
cat > /tmp/compose-env.yml <<'EOF'
name: envtest

services:
  app:
    image: alpine:latest
    command: env
    environment:
      MAP_KEY: map_value
      ANOTHER: "123"

  app2:
    image: alpine:latest
    command: env
    environment:
      - LIST_KEY=list_value
      - WITH_EQUALS=a=b=c
EOF

ld up --config /tmp/compose-env.yml
```

Inspect the environment in both containers:

```bash
docker exec lab-envtest-app  env | grep -E "MAP_KEY|ANOTHER"
docker exec lab-envtest-app2 env | grep -E "LIST_KEY|WITH_EQUALS"
```

**Expect:**
```
MAP_KEY=map_value
ANOTHER=123
LIST_KEY=list_value
WITH_EQUALS=a=b=c
```

`WITH_EQUALS=a=b=c` exercises the split-on-first-`=` parsing (the value
`a=b=c` must not be truncated at the inner `=`).

```bash
ld down --lab envtest
```

### 11.4 depends_on: both YAML forms

Compose supports `depends_on` as a plain list (`["db"]`) or an object with a
`condition` key.  Both map to the same internal `depends_on` array.

```bash
cat > /tmp/compose-dep.yml <<'EOF'
name: deptestcompose

services:
  db:
    image: alpine:latest
    command: sleep 3600

  worker:
    image: alpine:latest
    command: sleep 3600
    depends_on:
      - db

  api:
    image: alpine:latest
    command: sleep 3600
    depends_on:
      db:
        condition: service_started
EOF

ld up --config /tmp/compose-dep.yml
```

**Expect:** `db` starts before both `worker` and `api`.

```bash
ld down --lab deptestcompose
```

### 11.5 Export: compose → compose round-trip

Use the same `.yml` file as input to `export` — the output should be
structurally equivalent (same services, networks, ports):

```bash
ld export --config /tmp/compose-lab.yml
```

**Expect:** valid compose YAML on stdout with `services:`, `web:`, `client:`,
and `networks:` / `front:` blocks.

Save and validate:

```bash
ld export --config /tmp/compose-lab.yml > /tmp/compose-lab-out.yml
docker compose -f /tmp/compose-lab-out.yml config --quiet \
    && echo "round-trip validated"
```

### 11.6 `.yaml` extension works too

```bash
cp /tmp/compose-lab.yml /tmp/compose-lab.yaml
ld up   --config /tmp/compose-lab.yaml
ld down --config /tmp/compose-lab.yaml
```

**Expect:** identical behaviour.

### 11.7 TOML and compose files are interchangeable in all subcommands

| Command | TOML flag | `.yml` flag | Notes |
|---|---|---|---|
| `up`     | ✅ `--config lab.toml` | ✅ `--config compose.yml` | Both start the lab |
| `down`   | ✅ `--config lab.toml` | ✅ `--config compose.yml` | Lab name is read from file |
| `export` | ✅ `--config lab.toml` | ✅ `--config compose.yml` | Both emit compose YAML |

The `down --lab NAME` form (no `--config`) always works regardless of which
format was used for `up`.

### 11.8 Error: yq absent or wrong variant

If kislyuk/yq is installed instead of mikefarah/yq (the two tools share the
binary name but have different interfaces):

```bash
ld up --config /tmp/compose-lab.yml 2>&1 || true
```

**Expect:** `[error] Compose YAML interop requires mikefarah/yq` and a
non-zero exit.  TOML files still work; only `.yml`/`.yaml` needs mikefarah/yq.

### 11.9 Cleanup

```bash
ld down --lab composelab      2>/dev/null || true
ld down --lab envtest         2>/dev/null || true
ld down --lab deptestcompose  2>/dev/null || true
rm /tmp/compose-lab.yml /tmp/compose-lab.yaml /tmp/compose-lab-out.yml \
   /tmp/compose-env.yml /tmp/compose-dep.yml 2>/dev/null || true
```

---

## 12. Run the automated suite

```bash
phase3-docker/tests/run-all.sh
```

Expect (on a docker-equipped host):

- `test-validation.sh` — pass (~1 s)
- `test-naming.sh` — pass (~1 s; checks the `lab-<lab>-<svc>` rule)
- `test-run-and-destroy.sh` — pass (~5 s; skips if `docker rm -f` is blocked by AppArmor)
- `test-from-chroot-import.sh` — pass; skips if Phase 1 isn't usable
- `test-buildx-multiarch.sh` — pass; skips without `qemu-user-static` binfmt
- `test-topology-up-down.sh` — pass (~10 s; skips if `docker rm -f` is blocked); brings up the 3-svc topology and tears it down
- `test-status-export.sh` — pass (~5 s); covers `status` and `export --format compose`
- `test-inspect-json.sh` — pass; skips if `docker stop` is blocked by AppArmor
- `test-push-validation.sh` — pass (~1 s); validates CLI guards for `push`
- `test-depends-on-order.sh` — pass (~1 s); unit-tests the topo-sort helper
- `test-healthcheck-export.sh` — pass (~1 s); validates healthcheck + depends_on in `export`
- `test-compose-interop.sh` — pass; skips if mikefarah/yq is absent

## 13. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `docker: permission denied on /var/run/docker.sock` | User not in `docker` group | `sudo usermod -aG docker $USER && newgrp docker` |
| `binfmt qemu-aarch64 not registered` | Foreign-arch buildx missing emulation | `sudo update-binfmts --enable qemu-aarch64` *or* `docker run --privileged --rm tonistiigi/binfmt --install all` |
| `multiple platforms feature is currently not supported for docker driver` | Default builder doesn't support multi-platform `--load` | The script auto-creates a `docker-container` builder. If it didn't, run: `docker buildx create --name lab-builder --driver docker-container --bootstrap` |
| `container 'lab-foo' already exists` | Duplicate `--name` | `ld destroy foo --force` first |
| `ld up` succeeds but `curl` to a port hangs | Port not actually published, or service still starting | `ld logs <lab/service>`; check `docker port lab-<lab>-<svc>` |
| `ld exec demo/db` "no such container" | Lab/service name mismatch — service short name in topology, not container name | Use `ld list --lab demo` to see the mapping |
| `depends_on cycle detected at service 'X'` | Circular `depends_on` chain | Draw the dependency graph; break the cycle |
| `timed out waiting for 'X' to become healthy` | Healthcheck probe failing or too slow | Check `docker inspect --format '{{.State.Health}}' lab-<lab>-<svc>`; widen `retries` / `start_period`; fix the probe command |
| `Compose YAML interop requires mikefarah/yq` | Only `.yml`/`.yaml` files need mikefarah/yq; `.toml` files don't | `sudo apt-get install -y yq` (Ubuntu 22.04+) or `sudo snap install yq` |
| `ld up --config compose.yml` fails with yq parsing errors | File is valid Compose YAML but uses unsupported features (object-form volumes, `build.context:`, etc.) | Consult README §v0.2 Known gaps; consider using TOML config instead |

`LAB_LOG_LEVEL=debug` shows the underlying `docker run` argv:

```bash
LAB_LOG_LEVEL=debug ld up --config examples/docker-examples/docker-3svc-topology.toml
```
