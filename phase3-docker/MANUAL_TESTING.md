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
ld up --config examples/docker-3svc-topology.toml
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
ld up --config examples/docker-3svc-topology.toml
ld up --config examples/docker-3svc-topology.toml   # → second run is a no-op for existing services
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

## 7b. Inspect and export (`status` / `export --format compose`)

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

## 8. Run the automated suite

```bash
phase3-docker/tests/run-all.sh
```

Expect (on a docker-equipped host):

- `test-validation.sh` — pass (~1 s)
- `test-naming.sh` — pass (~1 s; checks the `lab-<lab>-<svc>` rule)
- `test-run-and-destroy.sh` — pass (~5 s) — pulls `alpine:latest` if not cached
- `test-from-chroot-import.sh` — pass; skips if Phase 1 isn't usable
- `test-buildx-multiarch.sh` — pass; skips without `qemu-user-static` binfmt
- `test-topology-up-down.sh` — pass (~10 s); brings up the 3-svc topology and tears it down
- `test-status-export.sh` — pass (~5 s); covers `status` (no-arg / lab / container) and `export --format compose`, validates the emitted YAML via `docker compose config` when available

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `docker: permission denied on /var/run/docker.sock` | User not in `docker` group | `sudo usermod -aG docker $USER && newgrp docker` |
| `binfmt qemu-aarch64 not registered` | Foreign-arch buildx missing emulation | `sudo update-binfmts --enable qemu-aarch64` *or* `docker run --privileged --rm tonistiigi/binfmt --install all` |
| `multiple platforms feature is currently not supported for docker driver` | Default builder doesn't support multi-platform `--load` | The script auto-creates a `docker-container` builder. If it didn't, run: `docker buildx create --name lab-builder --driver docker-container --bootstrap` |
| `container 'lab-foo' already exists` | Duplicate `--name` | `ld destroy foo --force` first |
| `ld up` succeeds but `curl` to a port hangs | Port not actually published, or service still starting | `ld logs <lab/service>`; check `docker port lab-<lab>-<svc>` |
| `ld exec demo/db` "no such container" | Lab/service name mismatch — service short name in topology, not container name | Use `ld list --lab demo` to see the mapping |

`LAB_LOG_LEVEL=debug` shows the underlying `docker run` argv:

```bash
LAB_LOG_LEVEL=debug ld up --config examples/docker-3svc-topology.toml
```
