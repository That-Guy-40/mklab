# WHY NIX — background for the Tier A / Tier B deploy block

A ground-up primer on **Nix** — the *what, why, how, and where* — written against
the two things this directory actually does: **Tier A** ([`modules/installer.nix`](modules/installer.nix))
installs a NixOS system package-by-package onto a disk, and **Tier B**
([`modules/deployer.nix`](modules/deployer.nix)) lays a whole prebuilt image down.
Those two tiers are not really two tools — they are **two ways to move the same
Nix object** (a *closure*) onto a machine. Once you see that, the rest of Nix falls
into place. This doc builds up to that sentence.

> New to the family? The build side is [`../nix-build-box/`](../nix-build-box/README.md);
> the flagship application is [`../systemd261-nixos-measured-boot/`](../systemd261-nixos-measured-boot/README.md).
> None of this requires Nix on your host — it lives in the build box.

---

## 1. The problem, first — because Nix is an answer to a specific pain

Traditional package management mutates **global, shared state** in place:
`/usr/bin`, `/usr/lib`, a distro's package database. Three consequences follow, and
you have felt all three:

- **"Works on my machine."** Your build depends on whatever happened to be in
  `/usr/lib` at the time — a version you never wrote down. Someone else, or you in
  six months, gets a different `/usr/lib` and a different result. The inputs were
  never *captured*, so the output was never *reproducible*.
- **Dependency hell / no atomic upgrades.** Installing package X *upgrades* shared
  library Y in place, silently breaking package Z that needed the old Y. There is
  exactly one Y for the whole system, so two consumers that disagree cannot
  coexist. An upgrade that fails halfway leaves the system in a state that is
  neither old nor new.
- **No honest rollback.** "Undo" means "hope the package manager can reconstruct
  the previous state from a log," which is not the same as *having* the previous
  state.

Every one of these is a symptom of the same root cause: **mutable global state with
uncaptured inputs.** Nix removes that root cause.

## 2. What Nix *is* — the one idea

**Nix is a build system and package manager built on a content-addressed store of
immutable artifacts, produced by pure functions of their fully-declared inputs.**
Unpack that against the pains above:

- **A store, not a mutable prefix.** Everything Nix builds lands in `/nix/store`
  under a path like `/nix/store/3v7kqg55…-systemd-261/`. The hash prefix is derived
  from **every input** that went into building it — source, compiler, flags,
  dependencies, all the way down. Change any input → different hash → **different
  path**. Nothing is ever built "in place."
- **Immutable + content-addressed ⇒ coexistence.** systemd-261 and systemd-260 are
  two different store paths. So are two builds of the *same* version with different
  flags. They sit side by side with no conflict, because nothing claims the single
  global name `/usr/lib/libsystemd.so` — each consumer points at the exact store
  path it was built against. Dependency hell is structurally impossible.
- **Pure functions ⇒ reproducibility.** A Nix build (a *derivation*) is a function:
  given identical inputs it must produce an identical output, run in a sandbox with
  **no network and no access to anything not declared**. That hermeticity is *why*
  the same flake rebuilds bit-for-bit on your laptop and in CI. "Works on my
  machine" becomes "works, because the machine is a value we pinned."
- **Atomic switch + rollback come for free.** A whole system is just one more store
  path (its *closure*, §4). "Activating" it flips a symlink; rolling back flips it
  to the previous path, which was never deleted or mutated. Upgrades are atomic
  because they are a pointer swap, not an in-place edit.

That is the entire model. Store paths, hashed over inputs, built by pure functions.
Flakes, NixOS, `nix build`, and both tiers here are consequences.

## 3. The vocabulary you actually need

| Term | What it is | Where it shows up here |
|---|---|---|
| **`/nix/store` path** | an immutable built artifact, named by a hash of its inputs | every `nix build` result symlink points into it |
| **derivation** (`.drv`) | the pure "recipe": inputs + build steps → outputs | `nix eval …drvPath` prints one; `nix build` realizes it |
| **closure** | a store path **plus every path it transitively needs** | the *thing* both tiers put on disk (§5) |
| **flake** | a pinned, hermetic project unit: typed `inputs` → `outputs`, with a `flake.lock` fixing exact revisions | `../systemd261-nixos-measured-boot/image/flake.nix` |
| **NixOS module** | a composable fragment of system config (`imports`, options, `config`) | `modules/installer.nix`, `modules/deployer.nix` |
| **derivation override** | "rebuild package P with these inputs changed" | `lib.mkIpxeEfi` = `pkgs.ipxe.override { embedScript … }` |

## 4. Closures — the concept that makes Tier A and Tier B the same thing

A **closure** is the transitive dependency set of a store path. The NixOS system
you built isn't "some files in `/`"; it is a store path
`…-nixos-system-…/` whose closure is *every* library, binary, kernel module, and
config it references — nothing implicit, nothing from a global `/usr`. Because the
closure is **complete and self-contained**, you can move it around as a unit:

- **Tier A ships the closure as a *build recipe + local cache* and re-derives the
  filesystem on the target.** `installer.nix` bakes the target system's closure into
  the installer's initrd via `system.extraDependencies`, so on the target
  `nixos-install` is a **local store copy** (no network, no substituter) — it
  reassembles `/nix/store` and writes a bootloader. Package-by-package, but every
  package is exactly the one you pinned.
- **Tier B ships the closure as an *already-assembled disk image*.** The Nix build
  produces a whole-disk raw (GPT + ESP + a dm-verity store, in the measured lab);
  `deployer.nix` just `dd`s those bytes onto the disk and registers an EFI entry.

Same closure, two transport encodings: **"send the recipe + parts" vs "send the
finished appliance."** Tier A is friendlier and disk-layout-flexible; Tier B is
atomic, image-based, and signable end-to-end (which is why the measured/dm-verity
lab uses it as the golden-image path). Neither could be trustworthy without the
property underneath both: the closure is *exactly* and *only* what you declared.

## 5. How it runs *here* — Nix without Nix on your host

You never install Nix on the host. [`../nix-build-box/`](../nix-build-box/) is a
container (`FROM nixos/nix`) with flakes enabled; the repo's Phase-4 podman driver
builds and runs it. Inside it:

```bash
# realize a derivation → a store path, with a result symlink
nix build .#installer-initrd          # Tier A: kernel+initrd with the closure baked in
nix build .#image-verity              # Tier B: the whole-disk golden image
nix build .#ipxe-efi                  # a custom ipxe.efi (see §6)

# ask a question without building (pure evaluation)
nix eval --raw .#nixosConfigurations.target.pkgs.systemd.version   # → 261
```

`flake.lock` pins `nixpkgs` to an exact git revision, so these commands produce the
**same store paths** next week and on the CI runner. The build box is itself the
first payoff of the model: a reproducible toolchain the host doesn't have to carry.

## 6. `lib.mkIpxeEfi` — a two-line lesson in why overrides beat forks

Tier B needs a UEFI `ipxe.efi` with the deploy script *embedded*. The usual route
(`netboot/build-ipxe.sh`) wants a docker daemon; this host is rootless-podman. In
Nix you don't fork iPXE or script a bespoke build — you **override the existing
package's inputs**:

```nix
pkgs.ipxe.override { embedScript = ./deploy.ipxe; }
```

Nix rebuilds iPXE from nixpkgs' own definition with one input changed, and — because
that changes an input — you get a **new store path**, cached and reproducible, that
coexists with the stock `pkgs.ipxe`. The override *is* the customization; there is no
patched fork to maintain. That is the composition half of the thesis in miniature.

## 7. Where Nix fits (and where it doesn't)

**Fits well:**
- **Reproducible build environments** — the build box; dev shells (`nix develop`).
- **CI you can trust** — the pinned inputs make the runner and your laptop agree.
- **Whole-system config as code** — NixOS: the OS *is* a flake output, diffable and
  rollback-able. This lab's measured image is one store path.
- **Image factories** — golden disk/VM/container images built hermetically (Tier B,
  and `../debian-vm-builder/`, `../kali-packer-vagrant/` in spirit).

**Costs, honestly:**
- **A real learning curve.** The Nix *language* (lazy, functional, its own idioms)
  and the module system take time; error messages can be dense.
- **Disk + first-build latency.** `/nix/store` is large; the first build pulls a
  closure from `cache.nixos.org` (substituter fetches from the trusted binary cache
  are fine — that is not the same as fetch-then-exec of an opaque third-party
  toolchain).
- **Impedance with non-Nix software** that hard-codes `/usr/lib` or `/bin/bash`
  paths (NixOS patches or wraps these; occasionally you must too).
- **Not always worth it** for a one-off script or a throwaway box — reach for it
  when *reproducibility, rollback, or composition* is the actual requirement.

## 8. The one-paragraph takeaway

Nix makes a built artifact a **pure function of its declared inputs**, stored
immutably and named by a hash of those inputs. That single move dissolves "works on
my machine," dependency conflicts, and un-rollback-able upgrades — and it gives you
the **closure**, a complete self-contained unit you can pin, sign, and ship. **Tier
A** ships that closure as a recipe reassembled on the target; **Tier B** ships it as
a finished image. Everything else in this block — offline installs, a docker-free
`ipxe.efi`, a byte-reproducible measured OS — is that idea, applied.

---

### Go deeper

- **Official:** [nix.dev](https://nix.dev) (start here), the
  [Nix](https://nixos.org/manual/nix/stable/) / [Nixpkgs](https://nixos.org/manual/nixpkgs/stable/)
  / [NixOS](https://nixos.org/manual/nixos/stable/) manuals — *(retrieved 2026-07-12)*.
- **In this repo:** [`../nix-build-box/RUNBOOK.md`](../nix-build-box/RUNBOOK.md) (the
  build environment), [`RUNBOOK.md`](RUNBOOK.md) (drive both tiers),
  [`../systemd261-nixos-measured-boot/SHOWCASE.md`](../systemd261-nixos-measured-boot/SHOWCASE.md)
  (what the composed result can prove).
