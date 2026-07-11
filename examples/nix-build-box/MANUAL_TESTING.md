# MANUAL_TESTING — nix-build-box

Verification log. Unlike most build/boot labs in this repo, **this one was verified
end-to-end by the agent** — Nix substituter fetches from `cache.nixos.org` are *not*
blocked by the repo's toolchain-fetch gate (that gate targets fetch+exec of opaque
prebuilt cross-toolchains like musl.cc, not the Nix daemon in a rootless container).

Host: this repo's COLD_STORAGE host (rootless podman). Date: 2026-07-11.

## 1. Base image pulls, tag is valid

```
$ podman pull docker.io/nixos/nix:2.31.2
…
Writing manifest to image destination
a69447ad471e…            # rc=0
```

**Signature:** the pinned tag resolves and pulls (~518 MB final image).

## 2. Image builds; git present; flakes enabled

```
$ podman build -t nix-build-box --build-arg NIX_TAG=2.31.2 examples/nix-build-box
…
STEP: RUN git --version            # → git version 2.50.1
Successfully tagged localhost/nix-build-box:latest      # rc=0

$ podman run --rm localhost/nix-build-box \
      sh -c 'command -v git && git --version; nix flake --help >/dev/null && echo ok'
/root/.nix-profile/bin/git
git version 2.50.1
ok
```

**Signature:** the base ships git 2.50.1 (enough for flakes), the build asserts it,
and the `nix-command`+`flakes` experimental features are live (`nix flake --help` ok).

> **Errata found while building this box** (both fixed in the shipped files):
> 1. `nix profile install nixpkgs#git …` in an early Containerfile **collided** with
>    the base image's pre-installed git-minimal (`error: An existing package already
>    provides …/git-core/git-merge-index`). Worse, a trailing `|| true` swallowed the
>    failure so the image "built" without the intended tools — a silent-failure trap.
>    **Fix:** drop the reinstall; the base already has git. Assert `git --version`.
> 2. The smoke `flake.nix` defined `packages.${system}.hello` and
>    `packages.${system}.default` as two statements → `error: dynamic attribute
>    'x86_64-linux' already defined`. **Fix:** define `packages.${system} = { … }`
>    once.

## 3. Smoke test — `nix build .#hello` end to end

```
$ podman run --rm -v "$PWD/examples/nix-build-box:/work:Z" -w /work \
      localhost/nix-build-box sh -c 'nix build .#hello 2>/dev/null && ./result/bin/hello'
Hello, world!
```

And the dev shell half:

```
$ … nix develop -c which git
nix-build-box devShell ready: nix (Nix) 2.31.2
/nix/store/k3wl6cg7q50zkx47af3msmg1yrg1f203-git-2.54.0/bin/git
```

**Signature:** `Hello, world!` — evaluation (fetched `github:NixOS/nixpkgs/nixos-26.05`
→ commit `8f0500b9`, dated 2026-07-10) **and** realization (fetched/built `hello`)
both succeed; the `devShell` reports Nix 2.31.2 and a store-path `git`.

## 4. Reproducibility pin

```
$ grep -E '"(lastModified|rev)"' examples/nix-build-box/flake.lock
        "lastModified": 1783703440,
        "rev": "8f0500b9660505dc3cb647775fe9a978a74b5283",
```

**Signature:** `flake.lock` pins nixpkgs to a single commit, so the smoke test is
reproducible; the base image is tag-pinned (digest-pinnable) in the Containerfile.

## What is NOT covered here

Building a full **NixOS disk image** (systemd-repart / dm-verity / UKI) inside this
box is the job of the systemd-261 measured-boot lab, and is verified there — some of
its steps need privileges (loop devices, KVM) beyond a rootless container and are
marked author-run in *that* lab's docs. This box only proves the Nix substrate itself.
