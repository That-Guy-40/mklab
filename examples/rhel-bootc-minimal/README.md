# rhel-image-mode-minimal — build a custom *minimal* bootc base image, then boot it

A faithful, by-hand reproduction of Red Hat's
**[*Chapter 9. Creating bootc images from scratch*](upstream-tutorial/)**
(*Using image mode for RHEL*, RHEL 9) — the chapter whose page slug is
*"Generating a custom minimal base image."* You take a full bootc base image, use
its built-in `bootc-base-imagectl` to compose a **minimal root filesystem**
(*just bootc, systemd, the kernel, and dnf*), `COPY` that into a `FROM scratch`
image, add only the packages you actually need, and end up with a bootable
container image roughly **half the size** of the stock base. Then — going one step
past the page, like the [kdump lab](../kdump-kexec-lab/) does — you install that
image to a disk with **`bootc install`** and **boot it as a real OS** in a Phase-2
QEMU VM.

**The whole point is the *image-is-the-OS* idea** end to end: the same OCI image
you'd `podman run` is the thing that boots on the metal. The build **and** the boot
were run and verified on CentOS Stream 9 — including a captured serial-console
login showing a real ostree boot (see [`MANUAL_TESTING.md`](MANUAL_TESTING.md)).

## image mode / bootc in three sentences

**Image mode for RHEL** ships the operating system as a *bootable container image*
(`bootc`): you build and version your OS with a `Containerfile` and `podman build`,
exactly like an app image. **`bootc`** (with an ostree backend) knows how to
*install* and *transactionally update* a machine from that image — the kernel
lives in the image at `/usr/lib/modules/$kver/vmlinuz`, not in `/boot`. A
**"from scratch" minimal base** uses `bootc-base-imagectl build-rootfs
--manifest=minimal` to strip the base down to bootc + systemd + kernel + dnf, so
your final image carries only what you add on top.

> **Why a container build *and* a VM.** Generating the image is pure `podman build`
> — a container job. But the payoff of image mode is that the image *boots*, and
> you can't boot a container (it shares the host kernel). So Phase 4's build feeds
> Phase 2: `build-minimal.sh` → `make-disk.sh` (`bootc install`) → `lab-vm.sh`.
> One image, two lives.

## Faithful (RHEL) vs runnable (CentOS) — the matrix

The upstream chapter uses `registry.redhat.io/rhel9/rhel-bootc`, which needs a
Red Hat subscription. This repo's house style (cf. the Rocky/AlmaLinux labs) is to
keep the **faithful** artifact *and* a **runnable** one side by side:

| | `Containerfile.rhel` (faithful) | `Containerfile.centos` (runnable, **verified**) |
|---|---|---|
| Base image | `registry.redhat.io/rhel9/rhel-bootc:latest` | `quay.io/centos-bootc/centos-bootc:stream9` |
| Needs | RH subscription + `podman login`; builder with heredoc support (podman ≥ 5) | nothing — freely pullable, runs on podman 4.x |
| Customization step | `RUN <<EORUN … EORUN` (verbatim §9.4) | same §9.4 packages via an `&&`-chain (heredoc-free) |
| To make it *bootable* | (left to you) | also adds `bubblewrap` + a throwaway `root:lab` — see below |
| Otherwise | **identical** procedure, flags, labels, and manifest | **identical** procedure, flags, labels, and manifest |

CentOS Stream 9 *is* RHEL 9's upstream and ships the very same
`/usr/libexec/bootc-base-imagectl` with the same `minimal`/`standard` manifests —
so the runnable path is faithful in every way that matters. It differs only by the
registry it pulls from, one heredoc accommodation for older podman, and two
**boot-enabler** additions (`bubblewrap` + a throwaway login) that any minimal
image needs to actually install + boot — which the §9.4 page, being about image
*generation*, never adds.

## Quick start (runnable / CentOS path)

```bash
cd examples/rhel-image-mode-minimal

# 1. Build the minimal image (needs the §9.3 build privileges; ~3 min, pulls ~2 GB once)
./build-minimal.sh --base centos                 # → localhost/bootc-minimal:centos

# 2. Install it to a bootable qcow2 with `bootc install` (run as YOUR user, NOT sudo;
#    it self-elevates).  → output/disk.qcow2
./make-disk.sh

# 3. Boot it (vm-bootc-minimal.toml already points image= at output/disk.qcow2)
../../phase2-qemu-vm/lab-vm.sh create  --config vm-bootc-minimal.toml
../../phase2-qemu-vm/lab-vm.sh start   bootc-minimal
../../phase2-qemu-vm/lab-vm.sh console bootc-minimal      # serial login: root / lab
```

> Run `make-disk.sh` as **your user, not `sudo`**: it ships your rootless-built
> image into **root** container storage (`podman save | sudo podman load`, since
> `bootc install` runs as root), then self-elevates for the install. Running the
> whole script under sudo would re-install a *stale* root-storage image — see
> [`RUNBOOK.md`](RUNBOOK.md) "Boot it" and `MANUAL_TESTING.md` "Boot gotchas".

Follow [`RUNBOOK.md`](RUNBOOK.md) for the full faithful walk in the chapter's
order (§9.1 → §9.5), with the *why* at each step and the verified output.

## What's here

| File | What it is |
|---|---|
| [`README.md`](README.md) | This file — the concept + quick start. |
| [`RUNBOOK.md`](RUNBOOK.md) | The faithful by-hand walk in the chapter's order: minimal manifest → from-scratch Containerfile → build privileges → build → verify → **boot it** → rechunk. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Verified pass/fail with **real captured output** (1.98 GB base → 812 MB minimal; `bootc container lint` pass; the full ostree-boot serial transcript) + the heredoc/EPEL **and** four boot gotchas. |
| [`Containerfile.rhel`](Containerfile.rhel) | **Byte-faithful** to upstream §9.4 (`registry.redhat.io/rhel9/rhel-bootc`, `RUN <<EORUN` heredoc). |
| [`Containerfile.centos`](Containerfile.centos) | **Runnable, verified** equivalent on CentOS Stream 9 bootc (adds `bubblewrap` + a throwaway `root:lab` to make it directly bootable). |
| [`Containerfile.cowsay`](Containerfile.cowsay) | The EPEL/`cowsay` variant (§9.2), **layered on top** of `:centos` to show "minimal as a base for multi-stage builds"; greets you with a cow at login. |
| [`cowsay-login.sh`](cowsay-login.sh) | `/etc/profile.d` snippet the cowsay variant installs — moos at interactive login. |
| [`build-minimal.sh`](build-minimal.sh) | Wraps `podman build` with the tutorial's §9.3 privileges; verifies size + lint. `--base centos\|rhel\|cowsay`. |
| [`make-disk.sh`](make-disk.sh) | Image → bootable qcow2 via `bootc install to-disk` (handles the rootless→root storage copy + `sudo`). |
| [`vm-bootc-minimal.toml`](vm-bootc-minimal.toml) | Phase-2 VM spec to boot the installed qcow2 (UEFI, no cloud-init). |
| [`upstream-tutorial/`](upstream-tutorial/) | Byte-exact archive of the RHEL 9 chapter + provenance. |

## What you'll learn

- **The minimal manifest** — what "just bootc, systemd, kernel, dnf" really
  contains, and why SSH/networking are *not* in it (you add them, per §9.4).
- **Multi-stage `FROM scratch`** — a builder stage composes a root filesystem;
  the final stage is built from nothing and gets only that rootfs `COPY`d in.
- **Why the build needs privileges** (§9.3) — `build-rootfs` runs `rpm-ostree`
  under `bwrap`, which needs nested mount namespaces + `/dev/fuse`; rootless
  `podman build` blocks both by default. This lab shows the exact failure modes.
- **What "minimal" *really* omits** — beyond SSH/networking, it strips
  `bubblewrap` (which `bootc install` needs to chroot during bootloader install)
  and leaves root locked. `MANUAL_TESTING.md` "Boot gotchas" surfaces each.
- **The kernel lives in the image** — `/usr/lib/modules/$kver/vmlinuz`, and
  `bootc`/`bootupd` put it on `/boot` at install time. The booted VM's
  `/proc/cmdline` (`ostree=…`, `vmlinuz-5.14.0-…`) proves it.

## Honesty / scope

- The faithful source is RHEL; the **verified** path is CentOS Stream 9 — see the
  matrix above. The two differ by registry, one heredoc accommodation, and the
  boot-enabler additions (`bubblewrap` + a throwaway `root:lab`) the runnable
  variant needs and which §9.4 omits.
- **Both** the build and the `bootc install` → QEMU boot are **verified end to
  end** in `MANUAL_TESTING.md` (with the captured serial transcript). The build
  needs the §9.3 privileges; the install needs `sudo` + a few GB of scratch.
- We use `bootc install to-disk` rather than `bootc-image-builder`; bib is a
  wrapper over the same install path and remains a documented alternative.
