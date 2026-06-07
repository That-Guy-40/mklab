# Podman example labs — Phase 4 (rootless)

Ready-to-run [`phase4-podman/lab-podman.sh`](../../phase4-podman/) TOML specs.
Phase 4 is the **rootless-first** container manager in this stack: everything
below runs as your normal user (no `sudo`, no root daemon) via Podman's userns
machinery. Point the tool at one with `--config examples/podman-examples/<file>`
(paths below are from the repo root, where you run `lab-podman.sh`).

> Grouped into this subdir so the flat [`examples/`](../) directory stays
> scannable — these were previously top-level `examples/podman-*.toml`. Two
> Podman specs **stay flat on purpose** because other labs reuse them:
> `podman-netboot-server.toml` (the netboot artifact server — used by
> `almalinux-pxe-lab/`, `debian-http-boot/`, `pxe-boot-mechanics/`, the
> `netboot/` subsystem, and `phase2-qemu-vm/lab-vm.sh`) and `podman-pxe-dhcp.toml`
> (the ProxyDHCP companion for the PXE labs). For the full walkthrough see the
> phase docs:
> [`START_HERE_PODMAN_WIZARD.md`](../../phase4-podman/START_HERE_PODMAN_WIZARD.md) ·
> [`SHOWCASE.md`](../../phase4-podman/SHOWCASE.md) ·
> [`MANUAL_TESTING.md`](../../phase4-podman/MANUAL_TESTING.md).

## The specs

| File | Manager / mode | What you get |
|---|---|---|
| [`podman-plain-single.toml`](podman-plain-single.toml) | `plain` | The simplest topology: one rootless `nginx` container publishing `127.0.0.1:18080`. The smoke test. |
| [`podman-pod-3svc.toml`](podman-pod-3svc.toml) | `pod` | Three containers (`nginx` + `redis` + an `alpine` health-pinger) sharing **one pod** — a single net/IPC/PID namespace, so they reach each other on `localhost` and ports publish at the pod level (`8080:80`). |
| [`podman-quadlet-service.toml`](podman-quadlet-service.toml) | `quadlet` | Exports a `.container` **quadlet** unit to systemd-user (`~/.config/containers/systemd/`) — the container becomes a real `systemctl --user` service that survives reboots (with linger) and auto-restarts on failure. Publishes `8081:80`. |
| [`podman-multiarch-build.toml`](podman-multiarch-build.toml) | `build` | Builds an image for a **foreign architecture** (e.g. `aarch64` on an x86_64 host) via `qemu-user-static`. An image-*production* step (`build`), not an `up`. |
| [`podman-from-chroot.toml`](podman-from-chroot.toml) | cross-phase | Imports a **Phase-1 chroot** tree as a rootless Podman image (the example uses a Kali `minbase` tree). Also catalogued under *Cross-phase bridges* in [`../00-INDEX.md`](../00-INDEX.md). |

## Quick start — the single-service smoke test

```bash
phase4-podman/lab-podman.sh up   --config examples/podman-examples/podman-plain-single.toml
phase4-podman/lab-podman.sh list --lab hello-nginx
curl -s http://127.0.0.1:18080/ | head -3
phase4-podman/lab-podman.sh down --lab hello-nginx
```

> All images are **fully qualified** (`docker.io/library/...`) on purpose: rootless
> Podman's short-name resolution would otherwise stop and prompt you to pick a
> registry interactively, which breaks unattended `up`.

## The three managers — what actually differs

Phase 4's `manager` key picks *how* a service is run; the three modes are the
heart of these examples:

- **`plain`** — one standalone container per service (`podman run`). Each gets its
  own network namespace; you publish ports per service. Simplest, most isolated.
- **`pod`** — services join a shared **pod**. A pod is a group of containers that
  share the same network, IPC, and PID namespaces (the same model Kubernetes uses
  for a Pod). Inside the pod, containers talk over `localhost`; ports are published
  once, at the pod level (`[[pod]] publish = [...]`), not per container. The
  `pod-3svc` spec's `alpine` pinger `wget`s `http://localhost/` to prove the nginx
  peer is reachable without any inter-container networking config.
- **`quadlet`** — instead of running the container directly, `lab-podman.sh` writes
  a systemd **quadlet** (`.container`) unit and hands lifecycle to systemd-user.
  This is the production-shaped path: `systemctl --user` start/stop/status,
  auto-restart on failure, and (with `loginctl enable-linger`) survival across
  logout/reboot. Use `lab-podman.sh generate --config …` to write the unit
  **without** starting it, so you can inspect it first. Needs Podman ≥ 4.4.

## The build spec (foreign-arch images)

`podman-multiarch-build.toml` documents a `build` flow, which is driven by CLI
flags today (the TOML is reference-only — a future version may accept `--config`):

```bash
# emulation prereqs (Debian/Ubuntu/Kali):
sudo apt-get install -y qemu-user-static binfmt-support && sudo update-binfmts --enable
ls /proc/sys/fs/binfmt_misc/qemu-aarch64        # must exist

# build an aarch64 image on an x86_64 host (./context needs a Containerfile):
phase4-podman/lab-podman.sh build --tag myapp:aarch64 --context ./context --arch aarch64
```

The resulting image can then be referenced from a normal `[[service]]` spec.

## The cross-phase import (`from_chroot`)

`podman-from-chroot.toml` turns a Phase-1 chroot into a runnable rootless image.
Build the chroot first, then `up`:

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --backend debootstrap --distro kali --suite kali-rolling \
    --arch x86_64 --target /var/chroots/kali-amd64 --variant minbase
phase4-podman/lab-podman.sh up   --config examples/podman-examples/podman-from-chroot.toml
phase4-podman/lab-podman.sh exec chroot-kali/payload-builder -- uname -a
phase4-podman/lab-podman.sh down --lab chroot-kali
```

The `userns` key controls how the chroot's UID/GID ownership maps into your
rootless namespace — `keep-id` (UID *N* inside == UID *N* on host, most
transparent), `auto-map` (force `0:0` ownership → root-in-namespace idiomatic),
`host` (`--userns=host`, needs `--allow-root`), or `raw` (a verbatim
`--uidmap`/`--gidmap` string). See PLAN.md Phase 4 "Rootless plumbing".

## Prerequisites

- **Podman** installed and usable rootless (`podman info` succeeds as your user).
- **`podman-quadlet-service.toml`**: Podman ≥ 4.4 (quadlet support); for true
  reboot-survival also `loginctl enable-linger "$(whoami)"`.
- **`podman-multiarch-build.toml`**: `qemu-user-static` + `binfmt-support` (the
  `binfmt_misc` handler for the target arch must be registered).
- **`podman-from-chroot.toml`**: a Phase-1 chroot built first (see above).

## Security posture

These are throwaway lab environments. The `plain`/`pod`/`quadlet` specs publish
their demo ports to **loopback or all interfaces** on the host — fine for a local
lab, but don't expose them on an untrusted network. `podman-from-chroot.toml`
imports a **Kali** rootfs (offensive tooling — use only against systems you are
authorized to test).

## Testing

The Podman engine and these manager modes (including the pod and quadlet
exit-criteria from PLAN.md Phase 4) are walked through with host-side checks in
[`../../phase4-podman/MANUAL_TESTING.md`](../../phase4-podman/MANUAL_TESTING.md) —
that's the authoritative verification path for these specs, so it isn't duplicated
here.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog across all
phases.
