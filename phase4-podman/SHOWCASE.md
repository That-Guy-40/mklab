# Phase 4 — podman, rootless-first, pods + quadlet aware

## What it gives you

Phase 3's whole-lab idiom — one TOML, `up`, `down`, `exec`, `inspect` —
but **rootless** by default and with two things docker can't touch:
**first-class pods** (containers sharing a network/IPC namespace) and
**quadlet** (systemd-user units that survive reboot, drop-in `.container`
files instead of long `--restart` flags). Same six-arch buildx story,
same Phase 1 chroot-import bridge, same readability preflight — just
without the daemon, without root, and with a few tricks of its own.

## 60-second demo

```bash
# Bring up a 3-service pod (web + cache + ping, all sharing localhost):
phase4-podman/lab-podman.sh up --config examples/podman-pod-3svc.toml

# All three rows show the same POD ID; ports publish at the pod, not the svc:
phase4-podman/lab-podman.sh list --lab tutorial-pod

# Drop into the web container; redis is reachable on localhost because pod:
phase4-podman/lab-podman.sh exec tutorial-pod/web -- \
    sh -c 'apk add --no-cache redis >/dev/null 2>&1 && redis-cli -h localhost ping'
# → PONG

# Tear down — pod, infra container, all members, network, in one shot:
phase4-podman/lab-podman.sh down --lab tutorial-pod
```

That's the elevator pitch. The rest of this doc is the things you didn't
get with `docker run`.

## Feature tour

### Rootless-first

Try to run as root and you hit a wall:

```text
[error] lab-podman.sh is rootless-first; refusing to run as root.
        Either rerun as a non-root user (preferred), or pass --allow-root to override.
```

`--allow-root` is the explicit escape hatch (warns, skips
rootless-only preflights). Why this matters: rootless containers run
inside a user namespace, so a break-out lands you as **your
unprivileged user**, not root — the right default for a tool that
runs Kali payloads and untrusted images.

### First-class pods (the docker-killer feature)

A pod is N containers sharing a network namespace + a single
port-binding namespace. `localhost` inside any of them = `localhost`
inside all of them. Docker has nothing equivalent (compose networks
aren't the same — they're shared *bridges*, not shared NS).

In TOML it's a `[[pod]]` block plus services that opt in:

```toml
[[pod]]
name    = "frontend"
publish = ["8080:80"]

[[service]]
name = "web"; image = "docker.io/library/nginx:alpine"
manager = "pod"; pod = "frontend"

[[service]]
name = "cache"; image = "docker.io/library/redis:alpine"
manager = "pod"; pod = "frontend"
```

`lab-podman` creates an implicit **infra container** that anchors the
shared namespace — totally normal podman behaviour, mentioned here only
because `inspect` will report `num_containers = N+1`. That extra one is
the infra pause container. Don't go looking for the bug.

### Quadlet — systemd-user units that survive reboot

`manager = "quadlet"` flips the script into a different mode entirely.
Instead of `podman run`, it writes a **`.container` unit file** under
`$XDG_CONFIG_HOME/containers/systemd/` (typically
`~/.config/containers/systemd/`), then runs:

```bash
systemctl --user daemon-reload
systemctl --user start lab-<lab>-<svc>.service
```

The unit *(sample output, snipped)*:

```ini
[Container]
Image=docker.io/library/nginx:alpine
PublishPort=8081:80
Label=lab-create.lab=persistent-web
HealthCmd=curl -f http://localhost/ || exit 1
[Service]
Restart=on-failure
[Install]
WantedBy=default.target
```

With `loginctl enable-linger $(id -un)` set, **the container survives
logout and reboot** — systemd-user keeps it running. `lab-podman logs
persistent-web/web` quietly routes to `journalctl --user -u …` so the
UX stays the same. Each unit gets a symlink under
`$LAB_STATE_DIR/podman/<lab>/quadlet-links/` so `inspect` and `down`
know it's quadlet-managed.

Generate without running — useful for audit or config-management:

```bash
phase4-podman/lab-podman.sh generate --config examples/podman-quadlet-service.toml
```

### `userns` modes (keep-id / auto-map / host)

| Mode | What it does | When |
|---|---|---|
| `keep-id` *(default)* | UID inside == invoker UID outside | bind-mount `$HOME/foo` and the container can read/write it |
| `auto-map` | Each container gets a fresh non-overlapping subuid range | multi-tenant isolation |
| `host` | Share the host user namespace | debugging — requires `--allow-root` |
| `<raw-map>` | Verbatim `--uidmap`/`--gidmap` string | you know what you're doing |

Set per-service in TOML: `userns = "keep-id"` (or `"auto-map"`, etc.).

### Multi-arch builds + `from-chroot` / `from-tarball`

Same buildx story as Phase 3 — six arches via qemu-user-static
(`x86_64`, `aarch64`, `armv7l`, `ppc64le`, `riscv64`, `s390x`) — except
rootless and via `podman build --platform`:

```bash
phase4-podman/lab-podman.sh build --tag myapp:arm64 --context ./ctx --arch aarch64
```

**Phase 1 bridge** — take a chroot, turn it into a rootless image, no
Containerfile:

```bash
phase4-podman/lab-podman.sh build --tag mykali \
    --backend from-chroot --chroot /var/chroots/kali-amd64 --userns keep-id
```

Same readability preflight as Phase 3: if you can't `tar -c` the chroot
rootless, you get a clear error (with `sudo chown -R …` hint) before
podman ever sees it. `from-tarball` is the equivalent for an existing
rootfs tarball.

### `kube` and `compose` exports

Pod-managed labs round-trip through Kubernetes-style YAML:

```bash
phase4-podman/lab-podman.sh export pwn --format kube > pwn-kube.yaml
podman kube play pwn-kube.yaml         # bring it back from the YAML
kubectl apply  -f pwn-kube.yaml        # or ship it to a real cluster
```

Compose export is best-effort, synthesised from the cached
`spec.toml` (services + ports + env + networks). Useful for handing a
lab to someone running docker-compose:

```bash
phase4-podman/lab-podman.sh export pwn --format compose > pwn-compose.yaml
```

### `inspect --json` — discriminates container vs pod

Added in commit `add0e44`. `schema_version: 1`, top-level `kind` field
is either `"container"` or `"pod"`, and the rest of the schema follows
that discriminator.

**Container kind** — `phase4-podman/lab-podman.sh inspect pwn/attacker --json | jq` *(sample, truncated)*:

```json
{
  "schema_version": 1, "kind": "container",
  "name": "lab-pwn-attacker",
  "labels": { "lab": "pwn", "svc": "attacker", "tool": "lab-podman" },
  "state": { "status": "running", "started_at": "2026-04-22T…" },
  "userns": "keep-id", "pod": "lab-pwn-ctf",
  "quadlet": { "managed": false }
}
```

**Pod kind** — `phase4-podman/lab-podman.sh inspect pwn/ctf --json | jq` *(sample, truncated)*:

```json
{
  "schema_version": 1, "kind": "pod",
  "name": "lab-pwn-ctf-pod",
  "pod": { "status": "Running", "num_containers": 4, "infra_container_id": "8a3c…" },
  "containers": [ { "name": "lab-pwn-attacker", "state": "running" }, … ],
  "network": { "ports": [ { "host_port": 8080, "container_port": 80 } ] }
}
```

The `kind` discriminator is what Phase 6's TUI keys off to render the
right detail panel.

### Rootless HTTP artifact server — serve netboot images without sudo

The netboot pipeline produces its artifacts as root (Phase 1 chroot
access requires `sudo`), but **serving them needs no root at all** —
a rootless Podman nginx container handles that. This makes the
separation of concerns clean: privileged build, unprivileged serve.

The `examples/podman-netboot-server.toml` mounts `~/netboot/` (the
artifact directory) read-only into the container and side-loads
`ipxe-mime.conf` so nginx returns `application/x-ipxe` for `.ipxe`
files — the content-type iPXE firmware requires before executing a
chainboot script.

Full example flow:

```bash
# One-time setup (no root needed — artifacts live in ~/netboot):
netboot/setup-netboot-dir.sh

# Build and export the initrd (root needed for chroot access):
sudo phase1-chroot/lab-chroot.sh create --config examples/chroot-netboot-minimal.toml
sudo phase1-chroot/lab-chroot.sh export-initrd netboot-minimal \
    --kernel ~/netboot/kernel --output ~/netboot/initrd.gz

# Build iPXE (Docker, no root):
netboot/build-ipxe.sh --server http://10.0.2.2:8181

# Serve (rootless!):
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml
curl -s http://localhost:8181/boot.ipxe    # the embedded iPXE chainboot script
curl -I http://localhost:8181/kernel       # the Debian kernel
curl -I http://localhost:8181/initrd.gz    # the cpio.gz initrd
```

Phase 2's `netboot-ipxe` VM boots from `ipxe.qcow2`, receives a DHCP
lease from QEMU slirp, and then hits `http://10.0.2.2:8181/` — that
address resolves to the host's loopback port 8181, which is exactly
this Podman nginx server. The guest downloads kernel + initrd over
HTTP and boots them in RAM, no disk image needed.

## Integrations

### ← Phase 1 (turn a chroot into a podman image)

Same `from-chroot` / `from-tarball` backends as Phase 3, with the same
readability preflight, but the result is rootless. See
`examples/podman-from-chroot.toml`. Pair `userns = "keep-id"` with a
chroot you own and bind-mounts just work.

### ↔ Phases 3 & 5 (mixed-engine TOMLs)

A single TOML can declare services for multiple engines via
`engine = "docker"|"podman"|"lxc"`. `lab-podman up` silently skips any
service whose `engine` field isn't `podman` (`skipped N service(s)
with engine != podman`); Phase 3 and Phase 5 do the symmetric thing.

The label namespace is **separate** —
`lab-create.tool=lab-podman` vs. Phase 3's `lab-create.tool=lab-docker`
— so the two scripts never fight over each other's containers.
`lab-podman list` only shows lab-podman rows. State per lab lives at
`$LAB_STATE_DIR/podman/<lab>/spec.toml` (verbatim TOML copy, used by
`export --format compose` and by the TUI).

### → Phase 6 (TUI surfaces all containers + pods)

Phase 6's Textual TUI walks all five bash phases and surfaces them in
one tree. The `inspect --json` schema above is what feeds the
container-detail and pod-detail panels — `kind` decides which one to
render.

## Where next

- [`PLAN.md`](../PLAN.md) — design rationale and exit criteria
- [`MANUAL_TESTING.md`](MANUAL_TESTING.md) — copy-paste verification walkthrough
- [`../examples/`](../examples/) — every TOML referenced above lives here:
  - [`podman-plain-single.toml`](../examples/podman-plain-single.toml)
  - [`podman-pod-3svc.toml`](../examples/podman-pod-3svc.toml)
  - [`podman-quadlet-service.toml`](../examples/podman-quadlet-service.toml)
  - [`podman-from-chroot.toml`](../examples/podman-from-chroot.toml)
  - [`podman-multiarch-build.toml`](../examples/podman-multiarch-build.toml)
- Sibling SHOWCASEs:
  [Phase 1 (chroots)](../phase1-chroot/SHOWCASE.md) ·
  [Phase 2 (VMs)](../phase2-qemu-vm/SHOWCASE.md) ·
  [Phase 3 (docker)](../phase3-docker/SHOWCASE.md) ·
  [Phase 5 (LXD/Incus)](../phase5-lxd/SHOWCASE.md) ·
  [Phase 6 (TUI)](../phase6-tui/SHOWCASE.md)
