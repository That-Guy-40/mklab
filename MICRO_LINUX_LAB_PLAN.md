# Micro-Linux From-Scratch Lab — Design Plan v1

> **Status**: Draft v1 — adapts popovicu's *"Making a Micro Linux Distro"*
> (section *"Building our almost useless Linux micro distribution"* onward) to
> LAB_CREATE_V2's existing phase machinery.
> **Decisions locked (this session):** compile **both** the Linux kernel
> (kernel.org) **and** static BusyBox (busybox.net) from upstream source; run
> the compile inside a **Phase 3/4 container**; target **x86_64 + aarch64**
> (cross-compiled); **plan only** — no lab files created yet.
>
> ⚠️ **Source-fidelity caveat:** this sandbox's network policy blocks all
> outbound HTTP except the git remote, so the live blog post could not be
> fetched while drafting. The recipe below is reconstructed from the standard
> kernel + BusyBox + initramfs + QEMU flow the post follows. **Reconcile §6
> against the live page before implementation** — version pins and the exact
> `/init` are the most likely deltas.

---

## 1. What we're building

A from-scratch "almost useless" Linux distribution: a freshly-compiled kernel
plus a single static BusyBox binary, packed into an initramfs and booted in
QEMU straight to a shell — no bootloader, no disk, no distro packages. The
whole userspace lives in RAM.

This contrasts with the repo's two existing boot pipelines:

| Lab | Rootfs source | Kernel source | Boot |
|---|---|---|---|
| `NETBOOT_LAB_PLAN.md` | debootstrap (Debian pkgs) | host/distro kernel | iPXE → HTTP → RAM |
| `ALMALINUX_PXE_LAB_PLAN.md` | Anaconda → disk | AlmaLinux installer kernel | iPXE → install-to-disk |
| **`micro-linux` (this plan)** | **BusyBox, compiled from source** | **Linux, compiled from source** | **QEMU `-kernel`/`-initrd`** |

---

## 2. Pipeline & how it maps onto LAB_CREATE_V2

```
 ┌─ Phase 3/4 build container  (micro-linux/Containerfile)
 │    toolchain: gcc, make, bc, bison, flex, libelf-dev, libssl-dev,
 │               cpio, gzip, xz-utils, curl, ca-certificates,
 │               gcc-aarch64-linux-gnu + libc6-dev-arm64-cross  (cross target)
 │    run rootless via podman, work dir bind-mounted, artifacts user-owned
 │
 │  micro-linux/mlbuild.sh  (one-shot `podman run`/`docker run`)
 │    1. fetch + verify (sha256/PGP) linux-X.Y.tar.xz, busybox-Z.tar.bz2
 │    2. kernel:   x86_64  make defconfig            → arch/x86/boot/bzImage
 │                 aarch64 make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig → arch/arm64/boot/Image
 │    3. busybox:  make defconfig + CONFIG_STATIC=y  → make install → _install/
 │                 (cross: ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
 └────► out/<arch>/{ kernel, _install/ }            (on the host)
                         │
   Phase 1  lab-chroot.sh export-initrd  ◄── REUSE (exact cpio newc+gzip + /init logic)
     stage = _install/ + /init + boot/vmlinuz-<ver>(=compiled kernel)
        └────► out/<arch>/{ kernel, initramfs.cpio.gz }
                         │
   Phase 2  lab-vm.sh --backend kernel+initrd  ◄── REUSE (direct -kernel/-initrd boot)
     --kernel out/<arch>/kernel --initrd out/<arch>/initramfs.cpio.gz
     --append "console=ttyS0"  (x86_64) | "console=ttyAMA0" (aarch64)
        └────► boots to a BusyBox shell, both arches
```

| Tutorial step | mklab component | Status |
|---|---|---|
| Provide a clean build toolchain | Phase 3 `lab-docker.sh` / Phase 4 `lab-podman.sh` (rootless, multi-arch) | **Reuse** (Containerfile + one-shot run) |
| **Compile Linux kernel from source** | — (only iPXE is compiled today) | **New** |
| **Compile static BusyBox from source** | — (`host-copy` only *copies* a host busybox) | **New** |
| Write `/init`, pack cpio + gzip | Phase 1 `lab-chroot.sh export-initrd` (`/init` presets, cpio `-H newc`, `gzip -9 -n`, chown-to-invoker) | **Reuse** |
| Boot `-kernel`/`-initrd` in QEMU | Phase 2 `lab-vm.sh --backend kernel+initrd` (`--append`, microvm-capable, all arches) | **Reuse** |

**Why this split is faithful *and* lazy:** the only genuinely new code is the
source-compile (steps 1–3). Packing and booting already exist and are exactly
what the netboot quick-start in `README.md` chains together — we're swapping a
debootstrap rootfs + host kernel for a compiled BusyBox + compiled kernel.

---

## 3. Build environment (Phase 3/4 container)

**Single x86_64 build image, cross-compiling both targets.** A kernel compile
is far too slow under qemu-user emulation, so we cross-compile aarch64 with
`CROSS_COMPILE=aarch64-linux-gnu-` from a native x86_64 container — the same
technique `netboot/ipxe-build-inner.sh:109` already uses for iPXE. (Emulated
native builds and the other four repo arches are deferred — see §10.)

- **Engine:** Podman (Phase 4, rootless-first) recommended; Docker (Phase 3)
  works identically. The build is a **one-shot job**, not a service topology,
  so `mlbuild.sh` calls `podman run --rm -v $WORK:/work -u $(id -u)` directly
  rather than the topology orchestrator — but the `Containerfile` and rootless
  conventions live in and match the Phase 3/4 world.
- **Artifacts user-owned:** run as the invoking UID and bind-mount `out/`, so
  the compiled kernel + `_install` land on the host owned by the user — no root
  needed, which keeps the downstream `export-initrd` rootless too (§5).
- **`micro-linux/Containerfile` packages:** `build-essential bc bison flex
  libelf-dev libssl-dev cpio gzip xz-utils curl ca-certificates kmod`
  + cross: `gcc-aarch64-linux-gnu libc6-dev-arm64-cross` (the latter supplies
  the static arm64 `libc.a` that `CONFIG_STATIC=y` BusyBox needs; x86_64 static
  libs come from `libc6-dev`).

---

## 4. New files summary

All under a new top-level `micro-linux/` lab dir (parallel to `netboot/`, which
is the precedent for a cross-phase orchestrating lab):

| File | Type | Notes |
|---|---|---|
| `micro-linux/Containerfile` | new | Debian build image with the toolchain above |
| `micro-linux/mlbuild.sh` | new | fetch→verify→compile→stage→export-initrd→(boot) driver |
| `micro-linux/init` | new | the `/init` script staged into the initramfs (§6.4) |
| `micro-linux/versions.env` | new | pinned `LINUX_VER`/`BUSYBOX_VER` + sha256/PGP keys |
| `examples/micro-linux-x86_64.toml` | new | Phase 2 `kernel+initrd` VM, `console=ttyS0` |
| `examples/micro-linux-aarch64.toml` | new | Phase 2 `kernel+initrd` VM, `console=ttyAMA0` |
| `micro-linux/README.md` | new | quick start + the full manual command walk-through |
| `micro-linux/SHOWCASE.md` | new | 5-minute tour, matching the other phases |
| `micro-linux/tests/` | new | unit tests: builder argv, staging layout, version-pin parse |
| `README.md` | edit | add a "micro-distro from source" quick-start entry |

Existing scripts (`lab-chroot.sh`, `lab-vm.sh`, `lab-podman.sh`) are **reused
unmodified** — no edits expected to land in the phase scripts.

---

## 5. Reusing Phase 1 `export-initrd` for the cpio step

`export-initrd` (`phase1-chroot/lab-chroot.sh:1267`) does exactly the
tutorial's packing — but it has two contracts we satisfy by how we stage the
tree:

1. **It locates the kernel via `find $target/boot -name 'vmlinuz-*'`** and
   copies it to `--kernel` (`lab-chroot.sh:1288`). So `mlbuild.sh` stages the
   compiled kernel as `boot/vmlinuz-<ver>` inside the tree. This works for
   aarch64 too: the arm64 `Image` is just a file there; QEMU `-kernel` accepts
   it regardless of the `vmlinuz-` name.
2. **It uses an existing `$target/init` if present** (`lab-chroot.sh:1295`),
   else auto-writes a busybox preset. We stage our own `/init` (§6.4), so it's
   used verbatim.

Staged tree layout fed to `export-initrd`:

```
out/<arch>/stage/
├── init                     # our script (0755)
├── bin/  sbin/  usr/        # from busybox `make install` (_install/)
├── boot/vmlinuz-<ver>       # the compiled kernel (so export-initrd finds + copies it)
├── dev/  proc/  sys/        # empty mountpoints
└── etc/                     # optional: passwd/group/hostname
```

Then:

```bash
phase1-chroot/lab-chroot.sh export-initrd out/<arch>/stage \
    --kernel out/<arch>/kernel \
    --output out/<arch>/initramfs.cpio.gz
```

This reuses the exact `find … -print0 | cpio --null -H newc -o | gzip -9 -n`
pipeline and the proc/sys/dev exclusions (`lab-chroot.sh:1326-1342`).

- **Runs rootless here.** Because the staged tree is user-owned (built in a
  rootless container, §3) and we rely on `CONFIG_DEVTMPFS_MOUNT=y` (in
  defconfig) to auto-populate `/dev/console` at boot, no root-only `mknod` is
  needed — `export-initrd` packs a user-owned tree without `sudo`.

---

## 6. The build recipe (reconstructed — reconcile with live post)

Pinned in `micro-linux/versions.env`, e.g. `LINUX_VER=6.12.x` (LTS),
`BUSYBOX_VER=1.36.1`. **Every download is sha256-verified** (kernel
additionally PGP-verified) to address audit finding **F2**.

### 6.1 Kernel — x86_64
```bash
curl -fLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.xz
# verify sha256 + PGP, then:
tar xf linux-${LINUX_VER}.tar.xz && cd linux-${LINUX_VER}
make ARCH=x86_64 defconfig
make ARCH=x86_64 -j"$(nproc)"          # → arch/x86/boot/bzImage
```

### 6.2 Kernel — aarch64 (cross)
```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"   # → arch/arm64/boot/Image
```
`defconfig` already enables virtio (`-pci`), the 8250 (x86) / PL011 (arm64)
serial consoles, initramfs/initrd, and `DEVTMPFS_MOUNT` — enough to boot the
standard QEMU `q35`/`virt` machine straight to a shell, matching the post's
plain `qemu-system-*` invocation.

### 6.3 BusyBox — static (both arches)
```bash
curl -fLO https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2
# verify sha256, then:
tar xf busybox-${BUSYBOX_VER}.tar.bz2 && cd busybox-${BUSYBOX_VER}
make defconfig
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config   # static link
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config          # known build break on recent kernels
make -j"$(nproc)"
make CONFIG_PREFIX=_install install                              # → _install/{bin,sbin,usr}
# aarch64: prefix the make lines with  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
```

### 6.4 `/init` (`micro-linux/init`)
```sh
#!/bin/sh
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev 2>/dev/null
echo
echo "Welcome to micro-linux — kernel $(uname -r) on $(uname -m)"
echo "(BusyBox $(busybox | head -1 | awk '{print $2}'))  Ctrl-A X to quit QEMU."
echo
# cttyhack gives /bin/sh a controlling tty on the serial console (job control)
exec setsid cttyhack /bin/sh
```

### 6.5 Boot (what Phase 2 runs for us)
```bash
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-x86_64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64
# equivalent bare QEMU (for reference, matches the post):
#   qemu-system-x86_64 -kernel out/x86_64/kernel -initrd out/x86_64/initramfs.cpio.gz \
#       -nographic -append "console=ttyS0"
```

---

## 7. Full workflow (the lab's documented happy path)

```bash
# 1. Build the toolchain image once (rootless podman)
podman build -t micro-linux-builder micro-linux/

# 2. Compile kernel + BusyBox for both arches, in the container
micro-linux/mlbuild.sh --arch x86_64,aarch64        # → out/<arch>/{kernel,_install/}

# 3. Pack each arch as kernel + initramfs (reuses Phase 1; rootless)
micro-linux/mlbuild.sh pack --arch x86_64,aarch64   # wraps lab-chroot.sh export-initrd

# 4. Boot it (reuses Phase 2)
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-x86_64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64
# … and the aarch64 twin via examples/micro-linux-aarch64.toml
```

`mlbuild.sh` is a thin orchestrator: steps 2–3 are its subcommands so a single
`mlbuild.sh all --arch x86_64,aarch64` can do the whole build→pack chain, then
hand off to Phase 2.

---

## 8. Security notes (cross-referenced with AUDIT.md)

- **Download integrity (audit F2).** Both tarballs are sha256-verified; the
  kernel is additionally PGP-verified against the kernel.org release keys.
  Versions are pinned in `versions.env`, not floating "latest" URLs.
- **Throwaway posture (audit F1).** `/init` execs a root BusyBox shell with no
  password — acceptable because this is a disposable, diskless RAM VM with no
  network service. The lab docs will state **never expose it to an untrusted
  network**; networking is off by default (the hello-shell needs no NIC).
- **Rootless by construction.** Container build runs as the invoking UID and
  the initramfs pack is rootless (§5), so the whole pipeline avoids `sudo` —
  unlike the debootstrap-based netboot lab.
- **No host pollution.** The toolchain lives only in the container image; the
  host needs just podman/docker + qemu.

---

## 9. Implementation order (dependency-aware)

1. `micro-linux/Containerfile` + `versions.env` — the toolchain everything else
   runs in; nothing compiles without it.
2. `mlbuild.sh build` (fetch+verify+compile, x86_64 first, then aarch64 cross).
3. `micro-linux/init` + `mlbuild.sh pack` (stage tree → reuse `export-initrd`).
4. `examples/micro-linux-{x86_64,aarch64}.toml` (Phase 2 boot specs).
5. Docs (`README.md` quick-start, `micro-linux/README.md`, `SHOWCASE.md`).
6. `micro-linux/tests/` (argv/staging/version-pin units; no network in CI).

---

## 10. Open items / future work

- **Truly micro:** add a `make tinyconfig` + minimal fragment variant and a
  size comparison against `defconfig` (the post's "almost useless" spirit).
- **microvm boot:** Phase 2 supports microvm on x86_64/aarch64, but it needs a
  `CONFIG_VIRTIO_MMIO`(+`_CMDLINE`) kernel fragment since defconfig is
  virtio-pci. Offer a `--microvm` build profile.
- **Bake-in variant:** `CONFIG_INITRAMFS_SOURCE=<dir>` to embed the initramfs
  *inside* the kernel image → a single-file boot (no `-initrd`).
- **More arches:** riscv64 / ppc64le / s390x — the repo already maps all six in
  Phase 2; each needs its cross-toolchain in the Containerfile.
- **Networking demo:** enable `udhcpc` (BusyBox) + a virtio NIC for a
  "micro-distro that gets a DHCP lease" follow-up.
- **Phase 6 TUI:** surface the built artifacts + boot specs as one lab once it
  lands.

---

## Sources

- *Making a Micro Linux Distro* — popovicu.com — section *"Building our almost
  useless Linux micro distribution"* (could not be fetched in-sandbox; **verify
  recipe + version pins against the live page**).
- Linux kernel docs: `Documentation/filesystems/ramfs-rootfs-initramfs.rst`
  (initramfs format & `/init` contract).
- BusyBox FAQ — building a static binary and `make install` layout.
- mklab internals: `phase1-chroot/lab-chroot.sh` (`export-initrd`,
  `_write_init_preset`), `phase2-qemu-vm/lab-vm.sh` (`kernel+initrd` backend),
  `netboot/ipxe-build-inner.sh` (`CROSS_COMPILE` precedent).
