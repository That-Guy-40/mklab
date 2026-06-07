# Start here — Phase 4: Podman (`lab-podman.sh`)

Phase 4 is Phase 3's rootless-first counterpart — the same "one TOML, `up`, `down`"
topology idiom but without a daemon, without root, with **first-class pods**
(containers sharing a network namespace), and with **quadlet** (systemd-user units
that survive reboot). No daemon means no `sudo`, no background service to manage,
and a container escape lands you as your own unprivileged user.

---

## Option A — use the wizard (recommended)

If you have the Phase 6 TUI running:

```bash
cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
python3 -m lab_tui          # or: python3 phase6-tui/main.py
```

Press **`n`** → select **Phase 4 — Podman svc** → fill in the form → press **Save**.
The wizard writes a TOML file to `examples/podman-<lab>.toml`.
Then bring it up with the command in Option C.

---

## Option B — three-minute quickstart (no wizard needed)

### 1. Install prerequisites

```bash
sudo apt-get install -y podman jq yq
# No daemon setup needed — podman runs fully rootless as your normal user.
podman info   # should succeed as non-root
```

### 2. Run a single container (plain mode)

```bash
phase4-podman/lab-podman.sh up --config examples/podman-examples/podman-plain-single.toml
# Brings up rootless nginx on port 18080.

curl http://127.0.0.1:18080/
phase4-podman/lab-podman.sh list --lab hello-nginx
phase4-podman/lab-podman.sh down --lab hello-nginx
```

### 3. Or bring up a three-service pod

```bash
phase4-podman/lab-podman.sh up   --config examples/podman-examples/podman-pod-3svc.toml
phase4-podman/lab-podman.sh list --lab tutorial-pod
# All three services share the same POD ID — localhost is shared.

phase4-podman/lab-podman.sh down --lab tutorial-pod
```

---

## Option C — use a TOML config (from the wizard or an example)

Ready-to-run examples in `examples/`:

| File | What it builds |
|---|---|
| `podman-examples/podman-plain-single.toml` | Single rootless nginx, simplest possible topology |
| `podman-examples/podman-pod-3svc.toml` | Web + cache + ping sharing a pod (localhost-shared namespace) |
| `podman-examples/podman-quadlet-service.toml` | nginx as a systemd-user unit that survives reboot |
| `podman-examples/podman-from-chroot.toml` | Import a Phase-1 chroot as a rootless Podman image |
| `podman-examples/podman-multiarch-build.toml` | Build + run a foreign-arch image (e.g. aarch64 on x86_64) |
| `podman-netboot-server.toml` | Rootless nginx serving PXE artifacts from `~/netboot/` |

```bash
phase4-podman/lab-podman.sh up   --config examples/<file>
phase4-podman/lab-podman.sh list --lab <lab-name-from-file>
phase4-podman/lab-podman.sh down --lab <lab-name-from-file>
```

---

## Anatomy of a config

```toml
[lab]
name = "my-lab"

# Optional — shared network namespace for the services below.
[[pod]]
name    = "frontend"
publish = ["8080:80"]     # ports bind at the pod level, not per-container

[[service]]
name    = "web"
image   = "docker.io/library/nginx:alpine"   # always use fully-qualified names
manager = "pod"            # plain | pod | quadlet
pod     = "frontend"       # ties this service to the pod above
```

### Manager quick reference

| Manager | What it does |
|---|---|
| `plain` | `podman run` — rootless, no daemon, simple |
| `pod` | `podman pod create` + `podman run --pod` — containers share localhost |
| `quadlet` | Writes a `.container` unit file → `systemctl --user start` — survives reboot |

### Other useful keys

| Key | Notes |
|---|---|
| `userns` | `keep-id` (default) / `auto-map` / `host` — user namespace mapping |
| `ports` | `["8080:80"]` — binds at pod level for `pod` manager, at container for `plain` |
| `volumes` | `["/host:/container:ro"]` — `:Z` appended automatically on SELinux hosts |
| `environment` | `{ KEY = "val" }` |
| `from_chroot` / `from_tarball` | Import a Phase-1 chroot/tarball as a rootless image |

---

## What just happened — the "why" under the hood

**Rootless containers and user namespaces:** when Podman runs a container without
root, it creates a **user namespace** — a kernel feature that maps a range of your
user's sub-UIDs (from `/etc/subuid`) to UIDs 0–65535 inside the container. Root
inside the container is UID 0 in the namespace but maps to an unprivileged sub-UID
on the host. A container escape gives an attacker only your own unprivileged account,
not system root. `keep-id` (the default) maps your UID to the same UID inside, so
files you bind-mount from `$HOME` are readable/writable without `chown`.

**Pods and shared network namespaces:** a Podman pod creates an "infra container"
(a tiny pause process) that anchors a shared network namespace. Every container
added to the pod joins that namespace — they all share the same loopback interface,
the same IP address, and the same port binding space. From any container in the pod,
`localhost` reaches every other container. This is exactly how Kubernetes pods work;
Podman's model is deliberately identical.

**Quadlet and systemd-user:** `systemd --user` is a per-user instance of systemd
running since login. Writing a `.container` unit file to
`~/.config/containers/systemd/` and running `systemctl --user daemon-reload`
registers it. The container then has a proper service lifecycle: `start`, `stop`,
`restart on-failure`, and (with `loginctl enable-linger`) **survives logout and
reboot**. The `podman run` invocation with all its flags lives in the unit file,
not in a shell history.

**No separate state file:** like Phase 3, ownership is tracked via Podman labels
(`lab-create.tool`, `lab-create.lab`, `lab-create.svc`). State per lab also lives
at `$LAB_STATE_DIR/podman/<lab>/spec.toml` (a copy of the TOML used at `up` time)
so `export --format compose` and the TUI can reconstruct the topology without
querying the live runtime.

---

## Next steps

- **`SHOWCASE.md`** — live-verified demos: pods, quadlet, from-chroot, netboot server
- **`MANUAL_TESTING.md`** — step-by-step verification walkthrough
- **`examples/`** — all TOML examples above
- **← Phase 1** (`START_HERE_CHROOT_WIZARD.md`) — build a rootfs for `from_chroot`
- **← Phase 3** (`START_HERE_DOCKER_WIZARD.md`) — same topology concept with Docker
- **→ Phase 5** (`START_HERE_LXC_WIZARD.md`) — system containers and VMs with LXD/Incus
- **Export to Compose:** `phase4-podman/lab-podman.sh export <lab> --format compose`
- **Export to Kubernetes YAML:** `phase4-podman/lab-podman.sh export <lab> --format kube`
