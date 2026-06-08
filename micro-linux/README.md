# micro-linux — a from-scratch Linux distro (compile → boot in RAM)

Compile a Linux **kernel** and a tiny **userspace** from upstream source, pack
them into an initramfs, and boot to a **console login prompt** in QEMU — no
disk, no bootloader, no distro packages. Two tracks:

| Track | Arches | Userspace | Pack | Matches the post? |
|---|---|---|---|---|
| **BusyBox** (default) | x86_64, aarch64 | static BusyBox | `gen_init_cpio` → gzip | adaptation |
| **Faithful** (§11) | riscv64 | u-root (pure Go) | plain cpio | yes |

Design + rationale: [`../MICRO_LINUX_LAB_PLAN.md`](../MICRO_LINUX_LAB_PLAN.md).
Based on Uros Popovic's [*Making a micro Linux distro*](https://popovicu.com/posts/making-a-micro-linux-distro/),
vendored byte-exact under [`upstream-tutorial/`](upstream-tutorial/) (HTML + CSS +
provenance + `sha256`s). To **walk that post by hand** — kernel → bare `init.c` →
u-root, in a disposable container that reproduces the author's Debian box — see
[`hand-walk/`](hand-walk/) (the learning path; `mlbuild.sh` below is the turnkey one).
Security posture is cross-referenced with [`../AUDIT.md`](../AUDIT.md) (F2 download
integrity, F5 pinned inputs, F7 destructive-op guard).

---

## Prerequisites

**Build host** (runs `mlbuild.sh`): just a container engine — the whole
toolchain lives in the image.

```bash
# podman (rootless, recommended) — or docker
sudo apt-get install -y podman
# optional, to pin the base image by digest (AUDIT F5):
sudo apt-get install -y skopeo
```

**Boot host** (runs Phase 2 `lab-vm.sh`): QEMU + a firmware blob per arch.
`lab-vm.sh` resolves firmware via `firmware_for()` and fails loud with an
install hint if it's missing — install only the arches you'll boot:

```bash
sudo apt-get install -y qemu-system-x86  ovmf               # x86_64
sudo apt-get install -y qemu-system-arm  qemu-efi-aarch64   # aarch64
sudo apt-get install -y qemu-system-misc opensbi            # riscv64  (the new one)
# lab-vm.sh also needs jq + a TOML parser (already required by Phase 2).
```

> On Fedora/Rocky the package names differ (`edk2-ovmf`, `edk2-aarch64`,
> `qemu-system-riscv`, `opensbi`); `lab-vm.sh`'s install hint prints the right
> one for your distro.

---

## One-time setup before the first **real** build (fails closed until done)

The verification is anchored in a vendored signing key, not a fetched checksum
(see [`keys/README.md`](keys/README.md) and plan §6.0). `mlbuild.sh` **refuses
to build** until these are real:

1. **Vendor + pin the signing keys** — produce `keys/kernel.gpg` and
   `keys/busybox.gpg` and paste their verified fingerprints into
   `versions.env` (`KERNEL_FPR`, `BUSYBOX_FPR`). See `keys/README.md`.
2. **(Recommended) pin the base image by digest** in `versions.env`:
   ```bash
   skopeo inspect docker://debian:bookworm-slim --format '{{.Digest}}'
   # → BASE_IMAGE="debian:bookworm-slim@sha256:<digest>"
   ```
3. **(riscv64 track only)** complete the pinned-Go install in the
   `Containerfile` (bookworm's Go is too old for u-root) — see the comment there.

---

## Build & boot

```bash
# 1. Build the toolchain image once (rootless; minutes)
micro-linux/mlbuild.sh image

# 2. Compile kernel + userspace, then pack the initramfs
micro-linux/mlbuild.sh all --arch x86_64,aarch64        # BusyBox track
#   …or the faithful track:
micro-linux/mlbuild.sh all --arch riscv64

# Artifacts land in micro-linux/out/<arch>/{kernel, initramfs.cpio.gz|initramfs.cpio}

# 3. Boot (reuses Phase 2)
phase2-qemu-vm/lab-vm.sh create --config examples/tiny-linux-experiments/micro-linux-x86_64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64
# Log in at the console as root / micro (advertised in /etc/issue).  In the shell,
# 'poweroff' shuts the VM down cleanly, 'exit' logs out (the prompt respawns);
# Ctrl-A X force-quits QEMU.  aarch64/riscv64 twins via their example TOMLs.
# (riscv64 boots into the u-root shell — no getty/login.)
# Change the lab password with: MLBUILD_LAB_PASSWORD=... mlbuild.sh pack --arch ...
```

`mlbuild.sh build` and `pack` are separate subcommands if you want to inspect
between steps; `all` chains them. `--offline` builds from already-cached
tarballs in `out/_cache/` (no network).

### Boot it as a real microvm

The same artifacts also boot on QEMU's **microvm** machine — the minimal,
PCI-less, fast-boot device model (QEMU's answer to Firecracker). Just point
`lab-vm.sh` at the `-microvm` example TOMLs:

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/tiny-linux-experiments/micro-linux-x86_64-microvm.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64-microvm   # log in: root / micro
# arm64 twin (TCG on x86 hosts): examples/tiny-linux-experiments/micro-linux-aarch64-microvm.toml
```

No second build is needed: `mlbuild.sh` bakes `CONFIG_VIRTIO_MMIO` into **every**
micro-linux kernel, so one universal kernel boots on `q35`/`virt` *and* on microvm
(whose virtio rides the mmio bus, not PCI). Two things worth knowing:

- **QEMU's `microvm` machine is x86-only.** On aarch64, `microvm = true` gives you
  the equivalent — a stripped-down `virt` + virtio-mmio booted directly via
  `-kernel` with **no UEFI firmware** (so the arm microvm twin doesn't even need
  `qemu-efi-aarch64`).
- **`network = false`, honestly stated.** No service listens, and the guest never
  configures a NIC — but on the `kernel+initrd` path QEMU does still *attach* a
  virtio-net device. It simply rides the mmio bus now, so enabling DHCP needs no
  extra kernel config: see the opt-in
  [`examples/tiny-linux-experiments/micro_linux_dhcp_lease/`](../examples/tiny-linux-experiments/micro_linux_dhcp_lease/) demo,
  where `/init` runs `udhcpc` and eth0 picks up a lease over virtio-mmio.

### Build variants — smaller initramfs, smaller kernel, single-file boot

Three optional add-on flags produce alternate output files alongside the
defaults, without discarding the originals.  All three can be combined:

```bash
# Build just the default track:
micro-linux/mlbuild.sh all --arch x86_64,aarch64

# Build defaults + all three variants + a side-by-side size table:
micro-linux/mlbuild.sh all --arch x86_64,aarch64 --all-variants

# Individual flags:
micro-linux/mlbuild.sh all --arch x86_64,aarch64 --musl    # musl BusyBox
micro-linux/mlbuild.sh all --arch x86_64,aarch64 --tiny    # tinyconfig kernel
micro-linux/mlbuild.sh all --arch x86_64,aarch64 --baked   # baked-in initramfs
```

| Flag | Output file | What changes |
|---|---|---|
| `--musl` | `out/<arch>/initramfs-musl.cpio.gz` | BusyBox built against **musl libc** instead of glibc — avoids the static-NSS caveat; ~30–40% smaller initramfs |
| `--tiny` | `out/<arch>/kernel-tiny` | Kernel from `make tinyconfig` + only the symbols needed to reach a BusyBox shell via microvm — **3–5× smaller** than defconfig; pairs with `-microvm` TOMLs |
| `--baked` | `out/<arch>/kernel-baked` | Initramfs **embedded** in the kernel (`CONFIG_INITRAMFS_SOURCE`) — boots with only `-kernel`, no `-initrd`; useful for netboot (one fewer TFTP transfer) |

**musl — why it matters.** A glibc-static binary isn't truly self-contained: glibc
still `dlopen()`s its Name Service Switch plugins (`libnss_files.so`,
`libnss_dns.so`, …) at runtime for name resolution. In a libc-free initramfs
those plugins don't exist, causing silent failures for any call that touches NSS.
musl has a self-contained resolver baked in — no runtime plugins, smaller binary.

**tinyconfig — why it's different.** `make defconfig` enables several hundred
drivers to be broadly compatible. `make tinyconfig` enables almost nothing.
The `--tiny` variant adds back only what's needed for our use case:
`BLK_DEV_INITRD`, `RD_GZIP`, `DEVTMPFS`, serial console, and `VIRTIO_MMIO` for
the microvm bus. The result boots only on microvm (no PCI), but it's a
fraction of the size. Boot it via:

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/tiny-linux-experiments/micro-linux-x86_64-tiny.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64-tiny      # --microvm, kernel-tiny
```

**baked — single-file boot.** `CONFIG_INITRAMFS_SOURCE` tells the kernel's own
`usr/` Makefile to pack and embed the initramfs at compile time. The resulting
kernel image contains everything; no `-initrd` flag is needed:

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/tiny-linux-experiments/micro-linux-x86_64-baked.toml
# Or directly:
qemu-system-x86_64 -machine q35,accel=kvm \
    -kernel micro-linux/out/x86_64/kernel-baked \
    -append "console=ttyS0 root=/dev/ram0 rw" \
    -nographic -m 256M
# No -initrd — it's inside kernel-baked.
```

**aarch64 musl.** Unlike x86_64 (where Debian's `musl-tools` provides `musl-gcc`),
Debian Bookworm has no `aarch64-linux-musl-gcc` package. The Containerfile solves
this by cross-compiling musl 1.2.3 from source using the already-present
`gcc-aarch64-linux-gnu`, generating a GCC specs file via musl's own
`tools/musl-gcc.specs.sh`, and creating `aarch64-linux-musl-gcc` as a wrapper.
Both arches produce identical-quality musl-linked BusyBox binaries.

`--compare` (included in `--all-variants`) prints a size table after the build:

```
arch          kernel    initramfs  initramfs   kernel    kernel
              (defcfg)  (glibc)   -musl       -tiny     -baked
──────────────────────────────────────────────────────────────────────
x86_64        8.2M      12.1M     7.8M        1.9M      20.3M
aarch64       9.4M      14.2M     8.6M        2.1M      23.6M
```

*(numbers are approximate — exact sizes depend on kernel version + BusyBox feature set)*

---

### What `mlbuild.sh` does, by hand

If you'd rather run it manually (or audit each step), this is the BusyBox track:

```bash
# fetch + VERIFY (gpgv against the vendored key; kernel signs the *uncompressed* tar)
curl -fLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.{xz,sign}
xz -dc linux-${LINUX_VER}.tar.xz | gpgv --keyring keys/kernel.gpg linux-${LINUX_VER}.tar.sign -
curl -fLO https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2{,.sig}
gpgv --keyring keys/busybox.gpg busybox-${BUSYBOX_VER}.tar.bz2.sig busybox-${BUSYBOX_VER}.tar.bz2

# kernel (x86_64): defconfig → assert must-have symbols → build
make ARCH=x86_64 defconfig && make ARCH=x86_64 olddefconfig && make ARCH=x86_64 -j"$(nproc)"

# busybox: static, with the assert-static gate.  REPLACE the symbol, don't
# append it: a duplicate makes `oldconfig` "reassign" and keep the FIRST value,
# silently dropping your =y (→ a dynamic busybox that can't exec in initramfs).
make defconfig
sed -i -E '/^(# )?CONFIG_STATIC(=.*| is not set)$/d' .config; echo CONFIG_STATIC=y >> .config
sed -i -E '/^(# )?CONFIG_TC(=.*| is not set)$/d'     .config; echo '# CONFIG_TC is not set' >> .config
make oldconfig && make -j"$(nproc)"
file busybox | grep -q 'statically linked'      # MUST be static
make CONFIG_PREFIX=_install install

# login setup: a root account + securetty + an issue banner advertising the creds
#   (mlbuild.sh's stage_etc bakes /etc/{passwd,group,shadow,securetty,issue})

# pack with gen_init_cpio (no kernel embedded; /dev/console baked; uid 0).
# Pass "-" so gen_init_cpio reads the spec from stdin (it wants a file arg).
cc -o gen_init_cpio linux-${LINUX_VER}/usr/gen_init_cpio.c
./gen_init_cpio - <spec> | gzip -9 -n > initramfs.cpio.gz
```

---

## Tests

Network-free unit tests (autotools-style: 77 = skip):

```bash
micro-linux/tests/run-all.sh
```

They cover the arg/arch validation, the **F7** `rm -rf` guard, the
`gen_init_cpio` spec (kernel-not-embedded, `/dev/console` baked, uid 0), the
`versions.lock` drift detection, and the **fail-closed** verification (refuses
an unpinned fingerprint / missing keyring), plus the getty/login `/etc` setup
(the lab password round-trips against the generated shadow hash). The networked
end-to-end build/boot stays out of CI scope (it compiles a kernel and boots a
VM), but has been run and verified on all three arches — x86_64 + aarch64 reach
the login prompt, riscv64 boots the u-root shell.

---

## Files

| File | Purpose |
|---|---|
| `Containerfile` | rootless build toolchain (digest-pinnable base) |
| `mlbuild.sh` | fetch → verify → compile → pack driver; F7-guarded `clean` |
| `versions.env` | version + key-fingerprint + reproducible-build pins (sourced) |
| `versions.lock` | auto-derived, committed sha256 of each verified tarball |
| `keys/` | vendored signing keys (trust anchor) — see `keys/README.md` |
| `init` | the BusyBox-track `/init`: a getty + login mini-init (§6.4) |
| `udhcpc.script` | udhcpc lease handler for the opt-in DHCP demo (§10) |
| `REPRODUCIBLE.md` | bit-reproducibility: deterministic-build knobs + attestable hashes |
| `tests/` | network-free unit tests |

**Variant example TOMLs** (in `../examples/tiny-linux-experiments/`):

| File | Variant |
|---|---|
| `micro-linux-x86_64-tiny.toml` | `kernel-tiny` + default initramfs on microvm |
| `micro-linux-x86_64-baked.toml` | `kernel-baked` (no `-initrd`), q35 or microvm |
