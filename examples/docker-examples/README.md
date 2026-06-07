# Docker example labs — Phase 3

Ready-to-run [`phase3-docker/lab-docker.sh`](../../phase3-docker/) TOML specs:
declarative container topologies (services, networks, volumes, published ports)
brought up rootful with the Docker engine. Point the tool at one with
`--config examples/docker-examples/<file>` (paths below are from the repo root,
where you run `lab-docker.sh`).

> Grouped into this subdir so the flat [`examples/`](../) directory stays
> scannable — these were previously top-level `examples/docker-*.toml`. For the
> full walkthrough see the phase docs:
> [`START_HERE_DOCKER_WIZARD.md`](../../phase3-docker/START_HERE_DOCKER_WIZARD.md) ·
> [`SHOWCASE.md`](../../phase3-docker/SHOWCASE.md) ·
> [`MANUAL_TESTING.md`](../../phase3-docker/MANUAL_TESTING.md).

## The specs

| File | What you get |
|---|---|
| [`docker-3svc-topology.toml`](docker-3svc-topology.toml) | The Phase 3 showcase: `nginx` + `postgres` + an idle `alpine` client on one shared bridge network — exercises services, a named volume, env vars, and a published port in a single `up`. |
| [`docker-netboot-server.toml`](docker-netboot-server.toml) | Rootful Docker variant of the netboot artifact server: `nginx:alpine` bind-mounting `~/netboot` and serving kernel + `initrd.gz` + kickstarts over HTTP on **:8181**. (The rootless Podman equivalent is [`../podman-netboot-server.toml`](../podman-netboot-server.toml), preferred when you only need to serve.) |

> `docker-netboot-server.toml` is a cross-phase netboot building block, so in the
> catalog it's listed under the **netboot** section of [`../00-INDEX.md`](../00-INDEX.md),
> not the Docker-topologies section — it's grouped here by *engine*, catalogued
> there by *role*.

## Quick start — the 3-service topology

```bash
phase3-docker/lab-docker.sh up   --config examples/docker-examples/docker-3svc-topology.toml
phase3-docker/lab-docker.sh list --lab demo
curl -s http://localhost:8088/ | head -3        # nginx
phase3-docker/lab-docker.sh exec demo/db -- psql -U lab -d lab -c '\l'   # postgres
phase3-docker/lab-docker.sh down --lab demo
```

The named `lab-demo-pgdata` volume persists across `down`/`up` so the database
survives a teardown; wipe it with `docker volume rm lab-demo-pgdata`.

## The netboot artifact server

This spec only *serves* pre-built artifacts — build them with Phase 1 first, then
boot them with Phase 2 (or real hardware). The full chain:

```bash
# 1. Build the rootfs + kernel with Phase 1 (needs sudo):
sudo phase1-chroot/lab-chroot.sh create --config examples/chroot-netboot-minimal.toml
sudo phase1-chroot/lab-chroot.sh export-initrd netboot-minimal \
    --kernel ~/netboot/kernel --output ~/netboot/initrd.gz

# 2. Serve them (rootful Docker):
phase3-docker/lab-docker.sh up --config examples/docker-examples/docker-netboot-server.toml
curl -I http://localhost:8181/kernel
curl -I http://localhost:8181/initrd.gz

# 3. Boot a VM against it (or point a real iPXE client at http://<host-ip>:8181/):
sudo phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-direct.toml
sudo phase2-qemu-vm/lab-vm.sh start netboot-direct
```

Two caveats baked into the spec:

- **Port 8181, not 8080** — this host runs SABnzbd on 8080, so the netboot server
  deliberately uses 8181. If you re-point it, check what already owns the port.
- **`/home/sqs/netboot` is a literal path** — TOML has no shell expansion, so the
  `volumes` line hardcodes the home directory. Edit it to your own `$HOME` before
  `up`.

See [`NETBOOT_LAB_PLAN.md`](../../NETBOOT_LAB_PLAN.md) and
[`netboot/SHOWCASE.md`](../../netboot/SHOWCASE.md) for the end-to-end netboot
design.

## Prerequisites

- **Docker engine** running and your user able to reach it (rootful — `docker
  info` should succeed, via the `docker` group or `sudo`). For a rootless flow,
  use the Phase 4 Podman specs instead.
- **`docker-netboot-server.toml`**: a populated `~/netboot` directory (step 1
  above) and the `:8181` port free on the host.

## Security posture

These are throwaway lab environments. `docker-3svc-topology.toml` sets the Postgres
super-user password to the throwaway `lab`, and `docker-netboot-server.toml` serves
whatever is in `~/netboot` (kernels, initrds, and any kickstarts — which may embed
lab credentials) over plain HTTP. Fine for a local lab; **never expose either on an
untrusted network**.

## Testing

The Docker engine, the 3-service topology, and idempotent re-`up` are all walked
through (with host-side checks) in
[`../../phase3-docker/MANUAL_TESTING.md`](../../phase3-docker/MANUAL_TESTING.md) —
that's the authoritative verification path for these specs, so it isn't duplicated
here. The netboot server's boot-verify chain lives in the netboot docs above.

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog across all
phases.
