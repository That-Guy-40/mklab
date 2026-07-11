# RUNBOOK — nix-build-box

Operator procedure for building and using the Nix build box, with the *why* at
each step. The automated/declarative counterpart is
[`nix-build-box.toml`](nix-build-box.toml); this walks the interactive path.

## 1. Build the image

```bash
phase4-podman/lab-podman.sh build --tag nix-build-box \
    --backend build --context examples/nix-build-box
```

*Why:* the Phase-4 driver's `build` backend is just `podman build --platform` over
a context dir containing a `Containerfile` (`phase4-podman/lab-podman.sh:490`). Going
through the driver (rather than a bare `podman build`) keeps this box lifecycle-
consistent with every other lab and gets the repo's SELinux `:Z`/arch handling.

The `FROM nixos/nix:2.31.2` pull is ~518 MB. The one `RUN` step just asserts
`git --version` — the base image already ships git-minimal (2.50.1), which flakes
require, so we deliberately **do not** reinstall it (doing so collides on
`git-core` helper paths and aborts the profile operation).

## 2. Enter the box

```bash
podman run --rm -it -v "$PWD/examples/nix-build-box:/work:Z" -w /work nix-build-box
```

*Why:* `-v …:/work:Z` mounts the flake into the box (`:Z` relabels for SELinux);
`--rm` makes it disposable. You land in `/bin/sh` at `/work`.

## 3. Prove it works

Inside the box:

```sh
nix build .#hello && ./result/bin/hello    # → Hello, world!
nix flake metadata                         # → resolves the pinned nixpkgs input
nix develop -c which git                   # → /nix/store/…-git-2.54.0/bin/git
```

*Why:* `nix build .#hello` exercises evaluation (fetch nixpkgs) **and** realization
(fetch/build the `hello` derivation) — the two halves of "is Nix working." The
`devShell` proves the other build-box mode, ephemeral toolchains via `nix develop`.

## 4. Use it to build another flake

```bash
podman run --rm -it -v "/path/to/your/flake:/work:Z" -w /work nix-build-box \
    nix build .#yourOutput
```

*Why:* the box is substrate, not payload. This is the call shape the systemd-261
lab's image builder uses to turn a NixOS flake into a bootable disk image without
installing Nix on the mklab host.

## 5. (Optional) persist the Nix store between runs

```bash
podman volume create nixstore
podman run --rm -it -v nixstore:/nix -v "$PWD/examples/nix-build-box:/work:Z" \
    -w /work nix-build-box
```

*Why:* by default `/nix/store` dies with the container, so every run re-fetches.
A named volume on `/nix` caches downloads across runs — worth it once you are
iterating on real image builds.

## 6. Tear down

Interactive `--rm` runs clean themselves up. For the declarative spec:

```bash
phase4-podman/lab-podman.sh down --config examples/nix-build-box/nix-build-box.toml
```

To reclaim the image and any store volume:

```bash
podman image rm localhost/nix-build-box
podman volume rm nixstore     # only if you created one in step 5
```

(Per house convention, destructive removal is yours to run — this RUNBOOK lists
the commands; it does not fire them for you.)
