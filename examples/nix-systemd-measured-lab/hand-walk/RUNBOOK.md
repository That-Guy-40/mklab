# RUNBOOK.md — hand-walking the Nix build

A disposable **Nix-in-a-box** ([`Containerfile`](Containerfile)) so you can build
the DDI by hand and see each piece, rather than trusting the automated flow. This
is the counterpart to the automated [`../vm/nix-measured-deploy.toml`](../vm/nix-measured-deploy.toml)
deploy — here you drive Nix yourself.

> **[YOU-RUN-THIS]** throughout — the container build and every `nix build` fetch
> from `cache.nixos.org` (the repo's toolchain-fetch gate), and the boot steps
> need KVM. The agent authored a clean, reproducible layer; you run it.

## 1. Build + enter the box

```bash
phase4-podman/lab-podman.sh build --tag nix-measured-handwalk \
    --context examples/nix-systemd-measured-lab/hand-walk
podman run --rm -it \
    -v "$PWD/examples/nix-systemd-measured-lab/nix":/lab:ro \
    nix-measured-handwalk
```

You land in `/lab` with the flake bind-mounted read-only.

## 2. Inspect what Nix will compose (no build yet)

```bash
# The systemd version the image will carry — MUST be >= 261.
nix eval .#nixosConfigurations.ddi-a.config.systemd.package.version
# The image version stamp that distinguishes A from B:
nix eval .#nixosConfigurations.ddi-a.config.system.image.version   # "1"
nix eval .#nixosConfigurations.ddi-b.config.system.image.version   # "2"
```

Why it matters: A and B differ **only** in that stamp — the whole point of a
reproducible image factory. If the version assertion fails here (systemd < 261),
fix the pin or apply the overlay in [`../nix/configuration.nix`](../nix/configuration.nix)
before going further.

## 3. Build the DDI

```bash
nix build .#ddi-a
ls -l result*/
#   nixos-measured_1.efi         <- the UKI (kernel+initrd+cmdline fused)
#   nixos-measured_1_root.raw    <- read-only erofs /nix/store (dm-verity DATA)
#   nixos-measured_1_verity.raw  <- dm-verity HASH tree
```

## 4. Prove the three properties by hand

```bash
# (a) It really is dm-verity — the hash partition has a root hash:
veritysetup dump result*/nixos-measured_1_verity.raw | grep 'Root hash'

# (b) The UKI carries the pillar cmdline (lsm=..bpf.. for RestrictFileSystemAccess):
#     objcopy/ukify can dump sections; grep the embedded cmdline:
strings result*/nixos-measured_1.efi | grep -o 'lsm=[^ ]*' | head -1

# (c) Reproducibility (#286969 workaround): build twice, compare bytes:
nix build .#ddi-a --rebuild -o a2 && cmp result/nixos-measured_1_root.raw a2/nixos-measured_1_root.raw && echo REPRO-OK
```

## 5. (Optional, `--privileged`) build the installer + boot it

Building/booting DDIs with loop devices + a TPM needs privileges the default
container lacks:

```bash
# Re-run the container with:  podman run --privileged ...
nix build .#installer
# Then boot the installer UKI with the swtpm harness on the host instead:
../vm/run-measured-vm.sh --disk <a disk you installed to>
```

## Contrast with the automated path

| Hand-walk (here) | Automated ([`../README.md`](../README.md)) |
|---|---|
| You run each `nix build` and inspect verity/UKI | `ipxe/build-boot-rom.sh` + `lab-vm.sh` drive it |
| `--privileged` container for loop/TPM steps | `vm/run-measured-vm.sh` (swtpm) on the KVM host |
| Teaches *what* the image is | Deploys it on-disk + measures + gates |

When you've seen the pieces here, the automated deploy in the parent README reads
as "the same thing, wired end-to-end."
