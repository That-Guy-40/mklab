# Phase 4 — Manual Testing Walkthrough

Copy-pasteable exercise of `lab-podman.sh`. Run top to bottom on a Linux
host with rootless podman already working. Each step says what to expect
and how to recognise breakage.

> **Set up a working dir:**
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> alias lp='phase4-podman/lab-podman.sh'
> ```

## 0. Preflight

```bash
sudo apt-get install -y podman jq           # Debian/Ubuntu/Kali
# or:  sudo dnf install -y podman jq        # Rocky/Fedora/Alma

# Rootless prerequisites — MUST be configured for your user:
getent passwd $(id -un)                     # confirm user exists
grep "^$(id -un):" /etc/subuid              # → <user>:100000:65536 (or similar)
grep "^$(id -un):" /etc/subgid              # ditto

# Missing?  Fix with:
#   sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)
#   podman system migrate

# Optional but recommended for quadlet § 5:
loginctl enable-linger $(id -un)

# Confirm podman version:
podman version --format '{{.Client.Version}}'    # need 4.0+; 4.4+ for quadlet

# A TOML parser is required (Phase 3 inherits this):
lp help >/dev/null || sudo apt-get install -y yq
```

Smoke-test:

```bash
lp version                                  # → "lab-podman.sh 0.1.0"
lp help | head -5                           # → usage block
lp list                                     # → empty table, no errors
lp status                                   # → podman info summary
```

## 1. Plain mode: single service

Run one nginx container and hit it from the host.

```bash
lp up --config examples/podman-examples/podman-plain-single.toml
```

**Expect:**
- `[info] rootless network backend: pasta` (or `slirp4netns` on older podman)
- `[info] starting (plain) service 'web' as lab-hello-nginx-web (image=docker.io/library/nginx:alpine)`
- `[info] ── lab 'hello-nginx' up ──`

**Verify:**

```bash
lp list --lab hello-nginx
curl -s http://127.0.0.1:18080/ | head -5     # → nginx welcome page
lp exec hello-nginx/web -- nginx -v          # → nginx version banner
lp logs hello-nginx/web | head -3            # → nginx startup log
```

**Tear down:**

```bash
lp down --lab hello-nginx
lp list                                      # → no hello-nginx rows
```

## 2. Pod mode: 3-service pod

Exercises the `pod` manager — N containers sharing network/IPC/PID.

```bash
lp up --config examples/podman-examples/podman-pod-3svc.toml
```

**Expect:** creates `lab-tutorial-pod-pod-frontend` pod plus
`lab-tutorial-pod-web`, `-cache`, `-ping` containers inside it.

**Verify pod membership:**

```bash
podman pod ps                                # → frontend pod, 3 containers
podman ps --pod                              # → all three rows show same POD ID
lp list --lab tutorial-pod
```

**Verify shared namespace:**

```bash
# Cache is reachable on localhost from inside the web container:
lp exec tutorial-pod/web -- sh -c 'apk add redis >/dev/null 2>&1 && redis-cli -h localhost ping'
# → PONG
```

**Tear down:**

```bash
lp down --lab tutorial-pod
```

This is PLAN.md **exit criterion #1** — 3-service pod rootless, clean
teardown.

## 3. Quadlet mode (requires podman ≥ 4.4)

Generates systemd-user units; they survive reboots when linger is on.

```bash
podman version --format '{{.Client.Version}}'     # must be >= 4.4
loginctl show-user $(id -un) -p Linger            # want Linger=yes
```

**Generate units without running:**

```bash
lp generate --config examples/podman-examples/podman-quadlet-service.toml
ls ~/.config/containers/systemd/                  # → lab-persistent-web-web.container
cat ~/.config/containers/systemd/lab-persistent-web-web.container
```

**Expect:** a `[Container]` section with `Image=`, `PublishPort=`,
`Label=`, `HealthCmd=`, `[Service] Restart=on-failure`, `[Install]
WantedBy=default.target`.

**Bring up for real:**

```bash
lp up --config examples/podman-examples/podman-quadlet-service.toml
systemctl --user status lab-persistent-web-web.service   # → active (running)
curl -s http://127.0.0.1:8081/ | head -3                 # → nginx default
```

**Logs route transparently to journalctl for quadlet units:**

```bash
lp logs persistent-web/web | head -5
# equivalent to:  journalctl --user -u lab-persistent-web-web.service
```

**Survive-a-restart test** (optional, manual):

```bash
systemctl --user restart lab-persistent-web-web.service
curl -s http://127.0.0.1:8081/ | head -1                 # → still responds
```

**Tear down:** lab-podman stops + removes the unit files.

```bash
lp down --lab persistent-web
ls ~/.config/containers/systemd/lab-persistent-web-web.container 2>&1  # → No such file
```

This is PLAN.md **exit criterion #2**.

## 4. From-chroot import (cross-phase)

Prereq: build a Phase 1 chroot first. Kali is a good target because it
exercises the keyring handling:

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --backend debootstrap --distro kali --suite kali-rolling \
    --arch x86_64 --target /var/chroots/kali-amd64 --variant minbase
```

(Skips this step if you don't have `kali-archive-keyring` on the host —
see `phase1-chroot/INSTALL-KALI-KEYRING.md`.)

```bash
lp up --config examples/podman-examples/podman-from-chroot.toml
lp exec chroot-kali/payload-builder -- cat /etc/os-release | head -3
# → PRETTY_NAME="Kali Linux Rolling"
lp exec chroot-kali/payload-builder -- id
# → uid=0(root) gid=0(root)  (inside the namespace)
lp exec chroot-kali/payload-builder -- apt --version
```

**Inspect the userns mapping:**

```bash
podman inspect lab-chroot-kali-payload-builder | jq '.[0].HostConfig.IDMappings'
# → shows the keep-id mapping
```

**Try other userns modes** (destroy + re-up each time):

```bash
lp down --lab chroot-kali
# Edit examples/podman-examples/podman-from-chroot.toml, change userns to "auto-map"
lp up --config examples/podman-examples/podman-from-chroot.toml
lp exec chroot-kali/payload-builder -- stat -c '%u %U' /etc/os-release
# → "0 root" (auto-map forced 0:0 ownership during import)
```

**Tear down:**

```bash
lp down --lab chroot-kali
```

This is PLAN.md **exit criterion #3**.

## 5. Export to Kubernetes YAML

```bash
lp up --config examples/podman-examples/podman-pod-3svc.toml
lp export tutorial-pod --format kube > /tmp/tutorial-pod.yaml
head -30 /tmp/tutorial-pod.yaml         # → apiVersion: v1, kind: Pod
```

**Roundtrip check:** the YAML should be acceptable to `podman kube play`
without modification:

```bash
lp down --lab tutorial-pod
podman kube play /tmp/tutorial-pod.yaml
podman pod ps                           # → tutorial-pod pod is back
podman kube down /tmp/tutorial-pod.yaml
```

This is PLAN.md **exit criterion #4**.

**Compose export (best-effort, uses stored spec.toml):**

```bash
lp up --config examples/podman-examples/podman-pod-3svc.toml
lp export tutorial-pod --format compose > /tmp/tutorial-pod.compose.yaml
cat /tmp/tutorial-pod.compose.yaml
lp down --lab tutorial-pod
```

## 6. The rootless-first gate

```bash
sudo env PATH="$PATH" lp up --config examples/podman-examples/podman-plain-single.toml
# → [error] lab-podman.sh is rootless-first; refusing to run as root.
```

Override:

```bash
sudo env PATH="$PATH" lp --allow-root list
# → runs (with a warning that preflights will be skipped)
```

## 7. Ad-hoc run (not from TOML)

```bash
lp run --name quicktest --image docker.io/library/alpine:latest \
    --tty --rm -- /bin/sh -c 'echo hi from $(uname -n)'
# → "hi from <short-hash>"
```

## 8. Validation guardrails

These should fail fast, before any podman call:

```bash
lp build                                         # → [error] usage: ... build --tag
lp run                                           # → [error] usage: ... run --name
lp up                                            # → [error] usage: ... up --config
lp down                                          # → [error] need a lab name
lp destroy                                       # → [error] usage: ... destroy
lp exec                                          # → [error] usage: ... exec
lp logs                                          # → [error] usage: ... logs
lp frobnicate                                    # → [error] unknown subcommand: frobnicate
lp build --tag t --backend bogus                 # → [error] unknown build backend
lp build --tag t --backend from-chroot           # → [error] requires --chroot
lp run --name x                                  # → [error] need one of: --image | --chroot | --context
```

## 9. Rootless plumbing probes

These fire during normal operations, not as a standalone command. To
confirm they're working:

```bash
# subuid/subgid check (tested by running anything):
sudo -u nobody lp list 2>&1 | grep -i subuid     # should see the fix-it hint

# SELinux :Z auto-append (only on enforcing systems):
getenforce                                       # → Enforcing
# Create a lab with a bind-mount and check the resulting container:
#   volumes = [ "./foo:/foo" ]
# → podman inspect should show /foo mounted with :Z (label=private)

# Port-below-1024 warning:
# Edit a lab to use a port like 80:80, run up, expect a warning line.

# pasta vs slirp4netns detection:
lp status | grep -i network
# → "network:  netavark / rootless=pasta" (or slirp4netns)
```

## 10. Cleanup

```bash
lp list                                          # anything left?
# down each by name
lp down --lab hello-nginx
lp down --lab tutorial-pod
lp down --lab persistent-web
lp down --lab chroot-kali
# nuke state dir if you want a clean slate:
rm -rf ~/.local/state/lab-create/podman
```

## 11. Run the automated suite

```bash
phase4-podman/tests/run-all.sh
```

Each test self-skips (exit 77) if preconditions aren't met (podman
missing, subuid unconfigured, quadlet too old, etc.).

## When something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `[error] podman >= 4.0 required` | Host ships an older podman | Upgrade or use Phase 3 (docker) |
| `[error] quadlet mode requires podman >= 4.4` | Same, but only for quadlet | Use `--manager=plain\|pod`, or upgrade |
| `newuidmap: write to uid_map failed` | Missing/empty subuid/subgid | `sudo usermod --add-subuids 100000-165535 ...` then `podman system migrate` |
| Short-name prompt hangs in `up` | Image not fully qualified | Prefix with `docker.io/library/` (or similar) |
| Volume mounts denied on Fedora/Rocky | SELinux enforcing, missing `:Z` | `lab-podman` adds `:Z` automatically if `getenforce` = Enforcing; otherwise add manually |
| Quadlet unit fails to start | Systemd-user issues | `systemctl --user status <unit>`; `journalctl --user -u <unit>` |
| Pod-mode service can't reach peer on localhost | Not in the pod | Check `pod = "<name>"` is set in the TOML; `podman ps --pod` to confirm |

Reach for `LAB_LOG_LEVEL=debug` to see every podman invocation:

```bash
LAB_LOG_LEVEL=debug lp up --config ...
```
