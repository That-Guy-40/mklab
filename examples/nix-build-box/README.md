# nix-build-box — a reusable, pinned Nix build environment in a rootless container

**The mklab repo's first Nix lab.** A disposable OCI box that gives you a working
`nix` (with flakes + the `nix-command` CLI) on a host that has **no Nix installed**
— which describes this repo's host, and most hosts. Build Nix things inside it,
throw the box away after.

It exists as its **own reusable unit** because later work needs it and shouldn't
re-bolt Nix onto every lab: the systemd-261 measured-boot lab
([`../systemd261-nixos-measured-boot/`](../systemd261-nixos-measured-boot/README.md))
and the [`../nixos-ipxe-deploy/`](../nixos-ipxe-deploy/README.md) block build NixOS
**disk images** with `nix build`, and do so *inside this box*. Import it; don't
reinvent it.

> ### 🚫 Don't prune me — I'm the foundation
>
> `localhost/nix-build-box` is the **root of the repo's whole Nix dependency chain**.
> Every Nix artifact — `build-nixos-image.sh`, `stage-netboot.sh`,
> `nixos-ipxe-deploy/stage-deploy.sh` — executes *inside* this image. The host has no
> Nix precisely **because** this box exists.
>
> A `podman image prune -a` (which reaps every image not attached to a running
> container) **will take it**, and then nothing Nix-related builds until it is back.
> That happened on **2026-07-12**. If it's gone, rebuild it **first**:
>
> ```bash
> phase4-podman/lab-podman.sh build --tag nix-build-box \
>     --backend build --context examples/nix-build-box
> ```
>
> It rebuilds in ~1–2 min from the pinned `Containerfile` (nothing is lost — it is,
> after all, a *reproducible* box). But rebuild it **before** you reach for any of the
> scripts above, or they will fail with a confusing "build box not found".

## What's here

| File | What it is |
|---|---|
| [`Containerfile`](Containerfile) | The box as code: `FROM nixos/nix` (pinned), flakes enabled image-wide. |
| [`flake.nix`](flake.nix) | The smallest flake that proves the box works — `nix build .#hello` + a `devShell`. |
| [`flake.lock`](flake.lock) | Pins nixpkgs to a `nixos-26.05` commit, so the smoke test is reproducible. |
| [`nix-build-box.toml`](nix-build-box.toml) | Declarative Phase-4 spec: build + hold the box open, `exec` into it. |
| [`RUNBOOK.md`](RUNBOOK.md) | Step-by-step: build it, use it, use it to build *another* flake, tear down. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | The verification log — every command + its **captured, real** output. |

## Quick start (the interactive path)

A build box is used *by hand*, so the ergonomic path is a one-shot build + an
interactive shell:

```bash
# 1. Build the image (pulls nixos/nix:2.31.2, ~518 MB):
phase4-podman/lab-podman.sh build --tag nix-build-box \
    --backend build --context examples/nix-build-box

# 2. Drop into it with your flake mounted at /work:
podman run --rm -it -v "$PWD/examples/nix-build-box:/work:Z" -w /work nix-build-box

# 3. Inside the box:
nix build .#hello && ./result/bin/hello     # → Hello, world!
nix develop                                 # → an ephemeral dev shell
```

Or the **declarative** path (build + a held-open box you `exec` into):

```bash
phase4-podman/lab-podman.sh up   --config examples/nix-build-box/nix-build-box.toml
phase4-podman/lab-podman.sh exec nix-build-box/box -- sh   # cd /work; nix build .#hello
phase4-podman/lab-podman.sh down --config examples/nix-build-box/nix-build-box.toml
```

## Using it to build *your* flake

The whole point is reuse. Mount any flake directory at `/work`:

```bash
podman run --rm -it -v "/path/to/your/flake:/work:Z" -w /work nix-build-box \
    nix build .#whatever
```

This is exactly how the systemd-261 lab's `build-nixos-image.sh` will call it —
the box is the substrate, the flake is the payload.

## Prerequisites & posture

- **Rootless podman** (this repo's Phase-4 default). No sudo, no daemon on the host.
- **Network at build+run time.** `nix build` fetches prebuilt paths from
  `cache.nixos.org`; the box does not pre-bake a package set.
- **Reproducibility.** The base image is tag-pinned (`ARG NIX_TAG=2.31.2`; swap for
  a `@sha256:` digest for byte-stability) and the smoke flake is `flake.lock`-pinned.
- **Disposable.** State lives in the container's `/nix/store`; `podman rm` forgets it.
  For a persistent store across runs, bind-mount a volume onto `/nix` (see RUNBOOK).

## What's verified vs documented

**Fully verified in this environment** (see [`MANUAL_TESTING.md`](MANUAL_TESTING.md)):
the image builds, `git`/flakes are present, and `nix build .#hello` →
`Hello, world!` — end to end, no author-run caveat. Nix substituter fetches from
`cache.nixos.org` work here; they are **not** blocked by the repo's toolchain-fetch
gate (that gate targets fetch+exec of opaque prebuilt cross-toolchains, not the Nix
daemon). The heavier *NixOS disk-image* builds that consume this box live in the
systemd-261 lab and carry their own verification notes.
