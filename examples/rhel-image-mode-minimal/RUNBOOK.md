# RUNBOOK — Creating a custom minimal bootc base image (and booting it)

A faithful, by-hand walk through Red Hat's **[*Chapter 9. Creating bootc images
from scratch*](upstream-tutorial/)** (RHEL 9 image mode), in the chapter's own
section order (§9.1 → §9.5), with the *why* at each step. Where the upstream uses
`registry.redhat.io/rhel9/rhel-bootc` (subscription-gated), the commands here use
the freely-pullable **CentOS Stream 9 bootc** image — RHEL 9's upstream, shipping
the identical `bootc-base-imagectl`. The byte-faithful RHEL form lives in
[`Containerfile.rhel`](Containerfile.rhel); the verified runnable form in
[`Containerfile.centos`](Containerfile.centos).

> **The source of truth is [`upstream-tutorial/`](upstream-tutorial/).** Read this
> alongside it. Commands you can run as-is are marked **▶ run**; subscription- or
> privilege-gated steps are marked **⚠ needs**.

## Prerequisites

- `podman` (4.x is fine for the runnable path; the upstream heredoc form needs
  podman ≥ 5 — see §9.4), plus `qemu-img` and this repo's `phase2-qemu-vm/lab-vm.sh`
  for the boot.
- ~2 GB to pull the base image once, ~1 GB for the built image, a few GB of
  scratch if you do the boot.
- Network access to `quay.io` (runnable) or a Red Hat subscription +
  `podman login registry.redhat.io` (faithful).

---

## §9.0 — The idea (chapter intro)

`bootc-base-imagectl` lets you build a bootc image **from scratch**, using an
existing bootc base image purely as a *build environment*. The procedure takes
your chosen RPM packages as input — so if the RPMs change, you rebuild. The custom
base derives from the stock base and does **not** auto-track upstream base changes
unless you make that part of a pipeline.

Two manifests ship in the base image. Confirm them yourself:

**▶ run**
```bash
podman run --rm quay.io/centos-bootc/centos-bootc:stream9 \
    /usr/libexec/bootc-base-imagectl list
```
```
minimal: Effectively just bootc, systemd, kernel, and dnf as a starting point.
standard: A relatively full, but still generic base image. Roughly
similar to a headless server installation. ...
```

That `minimal` line is the whole lab in one sentence.

---

## §9.1 — Using pinned content (the standard manifest)

The chapter opens with the **standard** manifest and *pinned content* — for strict
certification/compliance you mirror or snapshot repos and point the build at them,
so you always get the exact same package versions. The shape (faithful, §9.1):

```dockerfile
FROM registry.redhat.io/rhel9/rhel-bootc:latest as builder
RUN rm -rvf /etc/yum.repos.d; mkdir -p /etc/yum.repos.d/
COPY mypinnedcontent.repo /etc/yum.repos.d/
RUN /usr/libexec/bootc-base-imagectl build-rootfs --manifest=standard /target-rootfs
FROM scratch
COPY --from=builder /target-rootfs/ /
RUN <<EORUN
set -xeuo pipefail
dnf -y install NetworkManager emacs
dnf clean all
rm /var/{log,cache,lib}/* -rf
EORUN
LABEL containers.bootc 1
LABEL ostree.bootable 1
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
RUN bootc container lint
```

**Why it matters for us:** this establishes the *multi-stage builder → scratch*
pattern the whole chapter reuses. The only knob that turns "standard" into our
target is `--manifest=minimal`. We skip the pinned-repo lines (they're for
compliance pipelines, not a lab) and move to minimal.

---

## §9.2 — Building a base image up from minimal

The minimal image is **not shipped pre-built** in any registry — you generate it.
It starts from *bootc, kernel, and dnf* only, then you extend it. Upstream's §9.2
example (faithful):

```dockerfile
FROM registry.redhat.io/rhel9/rhel-bootc:latest as builder
RUN dnf repolist && /usr/libexec/bootc-base-imagectl build-rootfs --manifest=minimal /target-rootfs
FROM scratch
COPY --from=builder /target-rootfs/ /
RUN <<EORUN
set -xeuo pipefail
dnf -y install NetworkManager cowsay
dnf clean all
rm /var/{log,cache,lib}/* -rf
EORUN
LABEL containers.bootc 1
LABEL ostree.bootable 1
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
RUN bootc container lint
```

Two things to notice, both real gotchas (see [`MANUAL_TESTING.md`](MANUAL_TESTING.md)):

- **`build-rootfs --manifest=minimal /target-rootfs`** takes the *target* path;
  the *source root* defaults to `/` (the builder's own filesystem). It runs
  `rpm-ostree compose` to assemble the minimal rootfs.
- **`cowsay`** is in **EPEL**, not RHEL/CentOS base repos — so this exact example
  fails with `No match for argument: cowsay` unless EPEL is enabled first. The
  cow is optional; §9.4's `openssh-server` is the package the *boot* actually
  needs. (We keep the cow in spirit — see "An optional cow", below.)

---

## §9.3 — Building required privileges  ⚠ the load-bearing step

Generating a new root filesystem uses container features — **mount namespacing** —
that are **off by default** in most build environments. The inner `build-rootfs`
runs `rpm-ostree` under `bwrap`; without privileges you get, in order:

1. `bwrap: Creating new namespace failed: Operation not permitted`
2. (with caps/seccomp relaxed) `fuse: device not found, try 'modprobe fuse' first`

So provide, **at minimum**, exactly what the chapter says:

```
--cap-add=all --security-opt=label=type:container_runtime_t --device /dev/fuse
```

[`build-minimal.sh`](build-minimal.sh) wraps this. We do **not** route the build
through `lab-podman.sh build` precisely because the phase tool refuses to inject
these privileges — the same "needs a privilege the phase tool won't inject" case
as the muxup/micro-linux hand-walks.

---

## §9.4 — Generating your bootc image from scratch  ▶ the one we build

This is the canonical from-scratch example, and the one this lab builds and boots.
It installs **`NetworkManager openssh-server`** — networking + SSH, which are *not*
in minimal and which you need to log in to the booted VM.

**▶ run** — build the runnable CentOS form (= [`Containerfile.centos`](Containerfile.centos)):
```bash
cd examples/rhel-image-mode-minimal
./build-minimal.sh --base centos
```
which runs, in effect:
```bash
podman build -f Containerfile.centos -t localhost/bootc-minimal:centos \
    --cap-add=all --security-opt=label=type:container_runtime_t --device /dev/fuse .
```

**⚠ needs (faithful RHEL form)** — [`Containerfile.rhel`](Containerfile.rhel),
verbatim §9.4 with the `RUN <<EORUN` heredoc and the registry.redhat.io base:
```bash
subscription-manager register          # or a registry.redhat.io service account
podman login registry.redhat.io
./build-minimal.sh --base rhel         # requires a heredoc-aware builder (podman >= 5)
```

> **podman-version gotcha.** The upstream `RUN <<EORUN … EORUN` heredoc needs
> buildah ≥ 1.34 / podman ≥ 5. On podman 4.9.3 it is mis-parsed line by line
> (`Error: Unknown instruction: "SET"`). `Containerfile.centos` therefore uses an
> `&&`-chain that is byte-for-byte equivalent in effect. Same packages, same
> labels, same lint.

**Verify** (the chapter ends each example with `bootc container lint`):
**▶ run**
```bash
podman run --rm localhost/bootc-minimal:centos bootc container lint
podman images localhost/bootc-minimal:centos      # ~812 MB vs ~1.98 GB base
podman run --rm localhost/bootc-minimal:centos sh -c \
    'command -v bootc dnf sshd; ls /usr/lib/modules/*/vmlinuz'
```

### An optional cow (faithful to §9.2, EPEL caveat made explicit)

To honor §9.2's `cowsay` without a silent failure, enable EPEL in the
customization step (add before the install in `Containerfile.centos`):
```dockerfile
RUN set -xeuo pipefail && \
    dnf -y install epel-release && \
    dnf -y install NetworkManager openssh-server cowsay && \
    dnf clean all && rm -rf /var/log/* /var/cache/* /var/lib/* && \
    bootc container lint
```
Then `podman run --rm localhost/bootc-minimal:centos cowsay 'minimal, but mighty'`.
The cow approves. 🐄

---

## Boot it — beyond the page (build → install → VM)

The chapter stops at *generating* the image. Image mode's payoff is that the image
*boots*, so we continue: install it to a disk with **`bootc install to-disk`**
(run from the image itself), then boot it in Phase 2. This needed two
boot-enabling additions to `Containerfile.centos` that the minimal manifest omits
— `bubblewrap` and a throwaway `root:lab` — plus naming the root filesystem. The
**four boot gotchas** and why each is needed are catalogued in
[`MANUAL_TESTING.md`](MANUAL_TESTING.md) "Boot gotchas".

> **Why `bootc install` and not `bootc-image-builder` (bib)?** bib is a wrapper
> over the same `bootc install` code. Running the image's *own* bootc directly is
> simpler, has no extra moving parts, and is what we verified. bib remains a fine
> alternative on a current podman/host.

**⚠ needs sudo (`--privileged`)** — `bootc install` wipes a block device (here a
loopback file) and runs as root, so it reads **root** container storage.
[`make-disk.sh`](make-disk.sh) bridges your rootless-built image into root storage
(`podman save | sudo podman load`) and runs the install. **Run it as your user,
NOT `sudo`** — under sudo, `podman save` would read root's (possibly stale) image:
```bash
cd examples/rhel-image-mode-minimal
./make-disk.sh                                 # → output/disk.qcow2
```
which is, unrolled:
```bash
podman save localhost/bootc-minimal:centos | sudo podman load   # rootless → root storage
truncate -s 10G output/disk.raw
sudo podman run --rm --privileged --pid=host \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$PWD/output:/output" \
    localhost/bootc-minimal:centos \
    bootc install to-disk --generic-image --via-loopback --wipe \
        --filesystem xfs --karg console=ttyS0 --karg console=tty0 \
        --target-imgref localhost/bootc-minimal:centos /output/disk.raw
qemu-img convert -f raw -O qcow2 output/disk.raw output/disk.qcow2
```
(Tip: `DEBUG=1 ./make-disk.sh` turns on `BOOTC_BOOTLOADER_DEBUG=2` + `RUST_LOG=debug`
— invaluable for diagnosing the bootloader step.)

**▶ run** — boot the disk (`vm-bootc-minimal.toml` already points `image =` at the
absolute `output/disk.qcow2` path):
```bash
../../phase2-qemu-vm/lab-vm.sh create  --config vm-bootc-minimal.toml
../../phase2-qemu-vm/lab-vm.sh start   bootc-minimal
../../phase2-qemu-vm/lab-vm.sh console bootc-minimal          # serial login: root / lab
```
`lab-vm.sh` makes a copy-on-write overlay over the installed qcow2, so
destroy/recreate freely. Inside the guest, prove the image-is-the-OS claim (real
captured output is in `MANUAL_TESTING.md`):
```bash
bootc status                       # booted image: localhost/bootc-minimal:centos + digest
uname -r                           # 5.14.0-710.el9.x86_64 — the kernel from the image
cat /proc/cmdline                  # ostree=/ostree/boot.1/... — a real ostree boot
. /etc/os-release; echo "$PRETTY_NAME"   # CentOS Stream 9
```

---

## §9.5 — Optimizing to a smaller version (rechunk)

A from-scratch build yields **one giant tar layer** — every change (e.g. a kernel
bump) re-pushes the whole thing. `rechunk` splits it into reproducible,
content-grouped layers so registries and clients reuse unchanged layers. Faithful
upstream command (RHEL):
```bash
sudo podman run --rm --privileged -v /var/lib/containers:/var/lib/containers \
    registry.redhat.io/rhel9/rhel-bootc:latest \
    /usr/libexec/bootc-base-imagectl rechunk \
        quay.io/exampleos/rhel-bootc:single \
        quay.io/exampleos/rhel-bootc:chunked
```
Runnable CentOS form — swap the helper image for `quay.io/centos-bootc/centos-bootc:stream9`
and your own `:single` → `:chunked` tags. Compare `podman image inspect` layer
counts before/after to see the win.

---

## Where this fits

- **Concept + quick start:** [`README.md`](README.md)
- **Verified output + gotchas:** [`MANUAL_TESTING.md`](MANUAL_TESTING.md)
- **The source:** [`upstream-tutorial/`](upstream-tutorial/)
- **Sibling by-hand VM lab:** [`../kdump-kexec-lab/`](../kdump-kexec-lab/)
