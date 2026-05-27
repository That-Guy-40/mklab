# Micro-Linux From-Scratch Lab — Design Plan v2

> **Status**: Draft v2 — *inspired by* popovicu's *"Making a Micro Linux
> Distro"*, deliberately re-targeted onto LAB_CREATE_V2's existing phase
> machinery.
> **Decisions locked (this session):** compile **both** the Linux kernel
> (kernel.org) **and** static BusyBox (busybox.net) from upstream source; run
> the compile inside a **Phase 3/4 container**; target **x86_64 + aarch64**
> (cross-compiled); **plan only** — no lab files created yet.
>
> ✅ **Source reconciled (v2):** the live post was fetched and read. It does
> **not** match the v1 reconstruction (see §1.1 "Fidelity & deltas"): the post
> builds a **riscv64** kernel with a **hand-written C `init` (or u-root)**
> packed as a **plain, un-gzipped cpio**, and uses **no BusyBox**. This plan is
> therefore an *adaptation in the spirit of* the post, not a transcription of
> it. §6 has been re-derived from the authoritative kernel / BusyBox /
> initramfs docs and pinned accordingly.

---

## 1. What we're building

A from-scratch "almost useless" Linux distribution: a freshly-compiled kernel
plus a single static BusyBox binary, packed into an initramfs and booted in
QEMU to a console login prompt (getty + login) — no bootloader, no disk, no
distro packages. The whole userspace lives in RAM.

This contrasts with the repo's two existing boot pipelines:

| Lab | Rootfs source | Kernel source | Boot |
|---|---|---|---|
| `NETBOOT_LAB_PLAN.md` | debootstrap (Debian pkgs) | host/distro kernel | iPXE → HTTP → RAM |
| `ALMALINUX_PXE_LAB_PLAN.md` | Anaconda → disk | AlmaLinux installer kernel | iPXE → install-to-disk |
| **`micro-linux` (this plan)** | **BusyBox, compiled from source** | **Linux, compiled from source** | **QEMU `-kernel`/`-initrd`** |

### 1.1 Fidelity & deltas (read this first)

The cited post — popovicu, *"Making a Micro Linux Distro"* — was fetched and
read for v2. **This plan is not a transcription of it; it is an adaptation into
this repo's machinery, and the deltas are deliberate:**

| Dimension | The post | This plan | Why we diverge |
|---|---|---|---|
| Target arch | **riscv64** (`qemu-system-riscv64 -machine virt`) | **x86_64 + aarch64** | The repo treats x86_64/aarch64 as first-class; riscv64 is offered as a "faithful track" in §11. |
| Userspace / PID 1 | **hand-written C `init` → `little_shell`**, or **u-root** (Go); *no BusyBox* | **static BusyBox** + `/init` shell | BusyBox matches the repo's existing chroot/netboot story and `export-initrd` presets. |
| cpio | **plain, un-gzipped** (`cpio -o -H newc`) | **gzip -9 -n** | The kernel auto-detects gzip (`CONFIG_RD_GZIP`); reuses the existing packer; trivially smaller. |
| Kernel pin | 6.5.2 | 6.12.x LTS | Current LTS. |
| `/dev` handling | **not handled** in the simple version | explicit (see §5 / §6.4) | An empty `/dev` is unreliable for init stdio on q35/virt — §5. |

Net: we keep the *idea* (compile a kernel + a tiny userspace, boot it diskless
in QEMU) and drop the *letter* (riscv64 / C-init / u-root / plain-cpio).
Anywhere this doc says "reuse" it means our phase scripts, not the post; the
v1 "faithful to the post" claims have been removed.

---

## 2. Pipeline & how it maps onto LAB_CREATE_V2

```
 ┌─ Phase 3/4 build container  (micro-linux/Containerfile, base pinned by digest)
 │    toolchain: gcc, make, bc, bison, flex, libelf-dev, libssl-dev,
 │               cpio, gzip, xz-utils, bzip2, gnupg, file, curl, ca-certificates,
 │               gcc-aarch64-linux-gnu + libc6-dev-arm64-cross  (cross target)
 │    run rootless via podman (--userns=keep-id), work dir bind-mounted, artifacts user-owned
 │
 │  micro-linux/mlbuild.sh  (one-shot `podman run`/`docker run`)
 │    1. fetch + ASSERT (sha256 -c + gpgv against vendored keyring) linux-X.Y.tar.xz, busybox-Z.tar.bz2
 │    2. kernel:   x86_64  make defconfig + fragment        → arch/x86/boot/bzImage
 │                 aarch64 make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig + fragment → arch/arm64/boot/Image
 │    3. busybox:  defconfig + CONFIG_STATIC=y, ASSERT static → make install → _install/
 │                 (cross: ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
 └────► out/<arch>/{ kernel, _install/ }            (on the host)
                         │
   Phase 1  pack the initramfs  ◄── §5: gen_init_cpio (recommended) OR lab-chroot.sh export-initrd
        └────► out/<arch>/{ kernel, initramfs.cpio.gz }
                         │
   Phase 2  lab-vm.sh --backend kernel+initrd  ◄── REUSE (direct -kernel/-initrd boot)
     --kernel out/<arch>/kernel --initrd out/<arch>/initramfs.cpio.gz
     --append "console=ttyS0"  (x86_64) | "console=ttyAMA0" (aarch64)   # NO root= — it's a cpio initramfs
        └────► boots to a console login prompt (root / micro), both arches
```

| Tutorial step | mklab component | Status |
|---|---|---|
| Provide a clean build toolchain | Phase 3 `lab-docker.sh` / Phase 4 `lab-podman.sh` (rootless, multi-arch) | **Reuse** (Containerfile + one-shot run) |
| **Compile Linux kernel from source** | — (only iPXE is compiled today) | **New** |
| **Compile static BusyBox from source** | — (`host-copy` only *copies* a host busybox) | **New** |
| Write `/init`, pack cpio + gzip | `gen_init_cpio` (kernel tree) **or** Phase 1 `export-initrd` (§5) | **Reuse / New** |
| Boot `-kernel`/`-initrd` in QEMU | Phase 2 `lab-vm.sh --backend kernel+initrd` (`--append`, all arches; `--microvm` for the minimal machine on x86_64/aarch64) | **Reuse** |

**Why this split works (and stays small):** the only genuinely new code is the
source-compile (steps 1–3) and a small packer. Booting already exists and is
exactly what the netboot quick-start chains together — there is even a
near-identical working precedent in `examples/vm-netboot-direct.toml` +
`examples/chroot-netboot-busybox.toml`. We're swapping a debootstrap rootfs +
host kernel for a compiled BusyBox + compiled kernel.

---

## 3. Build environment (Phase 3/4 container)

**Single x86_64 build image, cross-compiling both targets.** A kernel compile
is far too slow under qemu-user emulation, so we cross-compile aarch64 with
`CROSS_COMPILE=aarch64-linux-gnu-` from a native x86_64 container — the same
technique `netboot/ipxe-build-inner.sh` already uses for iPXE. (We therefore
need **no** `qemu-user`/`binfmt`; emulated native builds and the other four
repo arches are deferred — see §10.)

- **Engine:** Podman (Phase 4, rootless-first) recommended; Docker (Phase 3)
  works identically. The build is a **one-shot job**, not a service topology,
  so `mlbuild.sh` calls
  `podman run --rm -v "$WORK":/work:Z --userns=keep-id -u "$(id -u)" …`
  directly rather than the topology orchestrator — but the `Containerfile` and
  rootless conventions live in and match the Phase 3/4 world.
  - **`--userns=keep-id` is required** for rootless podman to land artifacts
    owned by the *invoking* user on the host. Without it, files come back owned
    by a high subuid (your uid mapped through the user namespace), defeating the
    "user-owned artifacts → rootless downstream" guarantee (§5). Docker maps the
    uid directly and doesn't need it.
  - **`:Z`** relabels the bind mount for **SELinux** hosts (the repo explicitly
    supports Rocky/Fedora); without it the container hits EACCES on `/work`.
    Harmless on non-SELinux hosts.
- **Artifacts user-owned:** run as the invoking UID and bind-mount `out/`, so
  the compiled kernel + `_install` land on the host owned by the user — no root
  needed, which keeps the downstream pack rootless too (§5).
- **`micro-linux/Containerfile`** pins its base by **tag + digest** to close
  audit **F5** (the repo's existing `debian:bookworm` base is unpinned):
  `FROM debian:bookworm-slim@sha256:<digest>`. Packages:
  `build-essential bc bison flex libelf-dev libssl-dev cpio gzip xz-utils
  bzip2 gnupg file curl ca-certificates kmod`
  + cross: `gcc-aarch64-linux-gnu libc6-dev-arm64-cross`.
  - **`bzip2`** — BusyBox ships *only* as `.tar.bz2`; `tar xf` shells out to the
    `bzip2` binary (absent from `build-essential`). Without it §6.3 dies at
    extraction. (`xz-utils` covers the kernel's `.tar.xz`.)
  - **`gnupg`** — required for the PGP verification §6/§8 promise (absent in v1,
    which made that control a silent no-op).
  - **`file`** — used by the "is it actually static?" assertion in §6.3.
  - **`libc6-dev-arm64-cross`** supplies the static arm64 `libc.a` that
    `CONFIG_STATIC=y` BusyBox needs; x86_64 static libs come from `libc6-dev`
    (in `build-essential`).
  - **Faithful track (§11)** additionally needs `gcc-riscv64-linux-gnu` (riscv
    kernel cross) + a pinned **Go** toolchain (for u-root) — optionally a
    separate build stage so the BusyBox image stays lean.

---

## 4. New files summary

All under a new top-level `micro-linux/` lab dir (parallel to `netboot/`, which
is the precedent for a cross-phase orchestrating lab):

| File | Type | Notes |
|---|---|---|
| `micro-linux/Containerfile` | new | Debian build image (base pinned by tag+digest, F5) with the toolchain above |
| `micro-linux/mlbuild.sh` | new | fetch→**verify**→compile→stage→pack→(boot) driver |
| `micro-linux/init` | new | the `/init` script staged into the initramfs (§6.4) |
| `micro-linux/versions.env` | new | pinned `LINUX_VER`/`BUSYBOX_VER` + **PGP key fingerprints** (per-version hashes are auto-derived into `versions.lock`, not hand-pinned) |
| `micro-linux/versions.lock` | new | git-tracked, auto-derived sha256 of each *verified* tarball (à la `uv.lock`); drift alarm on change — §6.0 |
| `micro-linux/keys/` | new | vendored kernel.org + BusyBox release public keys (gpgv keyring; fingerprints pinned in `versions.env`) — F2 |
| `examples/micro-linux-x86_64.toml` | new | Phase 2 `kernel+initrd` VM, `console=ttyS0`, `network=false` |
| `examples/micro-linux-aarch64.toml` | new | Phase 2 `kernel+initrd` VM, `console=ttyAMA0`, `network=false` |
| `examples/micro-linux-riscv64.toml` | new | **faithful track** (§11): riscv64 + u-root, `console=ttyS0`, `network=false` |
| `micro-linux/README.md` | new | quick start + the full manual command walk-through |
| `micro-linux/SHOWCASE.md` | new | 5-minute tour, matching the other phases |
| `micro-linux/tests/` | new | unit tests: builder argv, staging layout, version-pin parse (network-free) |
| `README.md` | edit | add a "micro-distro from source" quick-start entry |
| `.gitignore` | edit | ignore `micro-linux/out/` + downloaded tarballs / extracted source trees (keep the F-praised hygiene) |

Existing phase scripts are **reused** — `export-initrd` may optionally take a
tiny `--exclude` flag (§5 option A); otherwise no edits land in them.

---

## 5. Packing the initramfs

Two viable packers; **the plan recommends (B) `gen_init_cpio`** because it fixes
two real problems (A) inherits. Both run **rootless**.

### (A) Reuse Phase 1 `export-initrd`

`cmd_export_initrd` (`phase1-chroot/lab-chroot.sh`) does the tutorial's packing
and satisfies its contracts by how we stage the tree:

1. **It locates the kernel via `find $target/boot -maxdepth 1 -name 'vmlinuz-*'`**
   and copies it to `--kernel`. So `mlbuild.sh` stages the compiled kernel as
   `boot/vmlinuz-<ver>` inside the tree. (arm64's `Image` is just a file there;
   QEMU `-kernel` accepts it regardless of the `vmlinuz-` name.)
2. **It uses an existing `$target/init` if present**, else auto-writes a busybox
   preset. We stage our own `/init` (§6.4), so it's used verbatim.
3. **It packs** `find … -print0 | cpio --null -H newc -o | gzip -9 -n`, runs
   rootless (no `mknod`/`mount`; best-effort `chown` to the invoker — verified).

Staged tree fed to `export-initrd`:

```
out/<arch>/stage/
├── init                     # our script (0755)
├── bin/  sbin/  usr/        # from busybox `make install` (_install/)
├── boot/vmlinuz-<ver>       # the compiled kernel (so export-initrd finds + copies it)
├── dev/  proc/  sys/        # empty mountpoints
└── etc/                     # optional: passwd/group/hostname
```

```bash
phase1-chroot/lab-chroot.sh export-initrd out/<arch>/stage \
    --kernel out/<arch>/kernel \
    --output out/<arch>/initramfs.cpio.gz
```

**Two costs to know about:**

- ⚠️ **The kernel gets packed *into* the initramfs.** `export-initrd`'s find
  excludes `proc/ sys/ dev/ run/ tmp/` (+ optionally `lib/modules/`) but **not
  `boot/`** — so the ~12 MB `boot/vmlinuz-<ver>` you staged for it to find rides
  *inside* the cpio as dead weight (the kernel is already loaded via `-kernel`).
  For a "micro" distro that's the wrong default. Mitigations: accept + document
  it; add a 3-line `--exclude`/`--no-pack-boot` option to `export-initrd` (a
  small, justified phase-script edit); or use (B).
- ⚠️ **Empty `/dev` → unreliable init stdio** — see "devtmpfs correction" below;
  with (A), `/init` must reattach stdio (§6.4).

### (B) Use the kernel's own `gen_init_cpio` (recommended)

We're already compiling the kernel; its tree ships `usr/gen_init_cpio`, which
builds a cpio from a spec file and **creates device nodes without root**:

```
dir    /dev          0755 0 0
nod    /dev/console  0600 0 0 c 5 1
dir    /proc         0755 0 0
dir    /sys          0755 0 0
file   /init         out/<arch>/init 0755 0 0
# … busybox _install tree (file/dir/slink lines) …
```

```bash
linux-${LINUX_VER}/usr/gen_init_cpio spec | gzip -9 -n > out/<arch>/initramfs.cpio.gz
```

This gives us, for free: **(a)** no kernel inside the initramfs, **(b)** a real
**`/dev/console`** node so init has stdio from instruction one, and **(c)**
`uid/gid 0` ownership → reproducible, "root-owned" images even though we ran
rootless. Trade-off: it doesn't reuse Phase 1 for packing — a deliberate choice,
given the two costs above.

### Why `/dev/console` matters (the devtmpfs correction)

v1 claimed we "rely on `CONFIG_DEVTMPFS_MOUNT=y` to auto-populate `/dev/console`
at boot." **That is wrong for an initramfs.** The `DEVTMPFS_MOUNT` Kconfig help
says verbatim: *"This option does not affect initramfs based booting, here the
devtmpfs mount has to be done manually after the rootfs is mounted."* When the
initramfs supplies `/init`, the kernel skips the normal root-mount path (where
the auto-mount lives) and, just before exec'ing `/init`, tries to
`open("/dev/console")` to wire up fd 0/1/2. With an empty staged `/dev` that
open fails (`Warning: unable to open an initial console`) and `/init` starts
with **no stdout** — output echoes into the void until something re-opens the
console (the §6.4 stdio reattach, then `getty`).

Fix, per packer:

- **(B) bakes a real `/dev/console`** node into the cpio → solved before `/init`
  ever runs.
- **(A) reattaches stdio in `/init`** right after it mounts devtmpfs (§6.4):
  `exec 0<>/dev/console 1>&0 2>&0`.

---

## 6. The build recipe (reconciled with the live post + upstream docs)

Pinned in `micro-linux/versions.env`: `LINUX_VER=6.12.x` (LTS),
`BUSYBOX_VER=1.36.1`, plus the **sha256** of each tarball and the **PGP key
fingerprints** (kernel.org + BusyBox). **Integrity is asserted, not merely
fetched** — closing audit **F2**, whose root cause was a checksum that was
*downloaded but never compared*.

### 6.0 Verify — what actually survives a supply-chain attack

**The trust anchor is a vendored *public key*, not a fetched checksum.** This is
the crux, and it's the direct answer to "can we just auto-fetch and pin the
upstream `SHA256SUMS`?":

> Fetching a checksum from the *same* server as the artifact and trusting it
> proves only that the bytes weren't corrupted in transit — which TLS already
> guarantees. It is **Trust-On-First-Use**, and against a *supply-chain*
> attacker it is **no defense at all**: whoever can swap the tarball can swap
> its `SHA256SUMS` too. So "auto-fetch + pin the upstream checksum, trust the
> source" does **not** meet the "robust to supply chain" bar.

What does meet it: **verify a signature made by a key obtained out-of-band**
(vendored in `micro-linux/keys/`, fingerprint pinned in `versions.env`). The
authenticity comes from the *key*, not the fetch — so a tampered mirror / CDN /
MITM is caught. This is what lets us **auto-fetch the per-version hashes and
never hand-maintain them**, while staying secure:

1. **Pin the *key fingerprint* once** (stable, changes ~never) in
   `versions.env`; vendor the key in `keys/`. ← the only manual trust step.
2. **Auto-fetch the upstream signature** at download time:
   - kernel.org → `linux-${LINUX_VER}.tar.sign` (PGP over the *uncompressed*
     tar — see gotcha below), signed by the stable-release maintainers.
   - busybox.net → `busybox-${BUSYBOX_VER}.tar.bz2.sig` (PGP, release signer).
3. **Verify with `gpgv` against the vendored keyring** — authenticity +
   integrity in one. No `gpg --recv-keys` (that re-introduces TOFU via flaky
   keyservers).
4. **Auto-derive and lock the hash.** On the first *verified* download, record
   the observed sha256 into a git-tracked **`versions.lock`** (the discipline
   `uv.lock` already uses here — AUDIT F5 praises it). Later builds recompute
   and **fail loudly if the hash changes for a pinned version** — drift
   detection that catches a mirror quietly re-serving a different artifact.

So hashes are **auto-fetched / auto-derived and pinned for you** (what you
asked), but trust flows from the **signed** payload + a **vendored key**, never
from "the source is trusted." Honest residual: this defends against
mirror/CDN/MITM compromise, **not** against the upstream's *own signing key*
being stolen — only reproducible builds + independent rebuild attestation (§10)
chip at that.

> **Generalizes to the F2 case (Phase 2 `lab-vm.sh cache_image`).** Cloud images
> and **Kali** publish a *signed* `SHA256SUMS` (`SHA256SUMS` + `SHA256SUMS.gpg`),
> so the same recipe applies — and the repo *already vendors* the trust anchor
> (`kali-archive-keyring`). The correct, supply-chain-resistant way to "trust the
> Kali repo" is: fetch `SHA256SUMS` + its `.gpg`, `gpgv` the signature against
> that keyring, **then** `sha256sum -c` the artifact. (Plain fetch-and-compare,
> which is what F2 found, is the TOFU trap above.)

**Kernel `.sign` gotcha.** kernel.org signs the **uncompressed** tar, so you
must decompress before verifying — you can't check `.sign` against `.tar.xz`:
```bash
xz -dc linux-${LINUX_VER}.tar.xz \
  | gpgv --keyring micro-linux/keys/kernel.gpg linux-${LINUX_VER}.tar.sign -
```

### 6.1 Kernel — x86_64
```bash
curl -fLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.xz
curl -fLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.sign
# verify .sign against vendored key + lock the hash (§6.0), then:
tar xf linux-${LINUX_VER}.tar.xz && cd linux-${LINUX_VER}
make ARCH=x86_64 defconfig
make ARCH=x86_64 olddefconfig          # after merging the fragment below
make ARCH=x86_64 -j"$(nproc)"          # → arch/x86/boot/bzImage
```
Rather than trust `defconfig` across kernel versions, **force the must-haves on
and assert they took** (`=y`, else abort):
`CONFIG_DEVTMPFS`, `CONFIG_DEVTMPFS_MOUNT`, `CONFIG_BLK_DEV_INITRD`,
`CONFIG_RD_GZIP`, `CONFIG_SERIAL_8250_CONSOLE`, `CONFIG_VIRTIO`,
`CONFIG_VIRTIO_PCI`, `CONFIG_VIRTIO_MMIO`. The first set is what lets a plain
`q35` boot cleanly to userspace (the login prompt); `CONFIG_VIRTIO_MMIO` (plus
`CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES`, set but not asserted) makes the **same
kernel** also boot on QEMU's `microvm` machine, whose virtio rides the mmio bus
rather than PCI — see §10's microvm item. `mlbuild.sh` does this with the
`set_kconfig` helper (not `merge_config.sh`): defconfig writes
`# CONFIG_VIRTIO_MMIO is not set`, and a bare append would be silently dropped by
`olddefconfig`'s keep-first reassign (the same trap as BusyBox's `CONFIG_STATIC`).

### 6.2 Kernel — aarch64 (cross)
```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig   # + fragment
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"   # → arch/arm64/boot/Image
```
Same fragment, but the console symbol is `CONFIG_SERIAL_AMBA_PL011_CONSOLE`
(arm64 `virt` uses PL011 → `console=ttyAMA0`).

### 6.3 BusyBox — static (both arches)
```bash
curl -fLO https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2
curl -fLO https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2.sig
# verify .sig against vendored key + lock the hash (§6.0), then:
tar xf busybox-${BUSYBOX_VER}.tar.bz2 && cd busybox-${BUSYBOX_VER}
make defconfig

# Enable static linking ROBUSTLY. Do NOT just append the symbol: defconfig
# already wrote "# CONFIG_STATIC is not set", and a duplicate line makes
# `oldconfig` warn "trying to reassign symbol" and KEEP THE FIRST value — your
# =y is silently dropped (→ a DYNAMIC busybox that dies in the libc-less
# initramfs with a baffling "not found" on exec). Strip any prior definition,
# then write exactly one line (this is what mlbuild.sh's set_kconfig does):
sed -i -E '/^(# )?CONFIG_STATIC(=.*| is not set)$/d' .config
echo 'CONFIG_STATIC=y' >> .config
# tc.c fails to build against kernel >= 6.8 headers (CBQ symbols removed from
# pkt_sched.h). BusyBox 1.37.0 fixes this upstream, so this disable is needed
# ONLY for the 1.36.x pin — same single-definition rule applies:
sed -i -E '/^(# )?CONFIG_TC(=.*| is not set)$/d' .config
echo '# CONFIG_TC is not set' >> .config
make oldconfig
grep -q '^CONFIG_STATIC=y' .config || { echo "FATAL: static config didn't take"; exit 1; }

make -j"$(nproc)"
# THE gate — assert it's actually static before we trust it in a libc-less initramfs:
file busybox | grep -q 'statically linked' || { echo "FATAL: busybox is NOT static"; exit 1; }

make CONFIG_PREFIX=_install install                              # → _install/{bin,sbin,usr}
# aarch64: prefix the make lines with  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
```
The console in §6.4 uses **getty + login** (a real login prompt), so confirm
those applets are enabled after `make defconfig` — all on by default:
`CONFIG_GETTY`, `CONFIG_LOGIN`, and `CONFIG_FEATURE_SHADOWPASSWDS` (login reads
`/etc/shadow`). `CONFIG_HALT` (poweroff/reboot/halt) is likewise on.

> **glibc-static caveat (forward-looking):** a static glibc binary that does NSS
> lookups (DNS, `getpwnam`) warns/fails at runtime. Fine for a pure shell;
> relevant if the §10 `udhcpc` networking demo lands. A **musl** static build
> sidesteps it and is smaller — see §10.

### 6.4 `/init` (`micro-linux/init`) — a getty + login mini-init
A tiny, inittab-free PID 1: mount, trap the shutdown signals BusyBox sends to
PID 1, then present a **respawning login prompt** via `getty` → `login`.
```sh
#!/bin/sh
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev
# The kernel exec'd us before /dev/console existed (empty initramfs /dev), so
# fd 0/1/2 may be closed. devtmpfs is mounted now → grab the console so prompts
# *and* errors are visible. (No-op when packed with gen_init_cpio, which bakes
# the node — §5 option B.)
[ -c /dev/console ] && exec 0<>/dev/console 1>&0 2>&0

# `poweroff`/`reboot`/`halt` (no -f) just signal PID 1 (USR2/TERM/USR1) and
# expect init to act; trap them and issue the real syscall.
trap 'poweroff -f' USR2; trap 'reboot -f' TERM; trap 'halt -f' USR1

# getty opens /dev/console, prints /etc/issue (which advertises the lab creds),
# then exec's `login` for the password check. Run getty in the BACKGROUND and
# block on `wait`, NOT in the foreground: ash defers traps until a foreground
# external command returns, so a foreground getty would swallow `poweroff` until
# logout — `wait` is trap-interruptible. We don't exec getty, so PID 1 stays
# /init: a logout re-shows the prompt instead of panicking the kernel.
while : ; do
    getty -L console 0 vt100 &
    wait "$!"
    sleep 1                  # no inittab respawn-throttle; avoid a hot spin
done
```
**Login files** (baked into the cpio at pack time by `mlbuild.sh`'s `stage_etc`,
not committed): `/etc/passwd` + `/etc/group` (one root account), `/etc/shadow`
(SHA-512 `crypt()` of the lab password — `root` / `micro` by default, override
with `MLBUILD_LAB_PASSWORD`), `/etc/securetty` (lists `console`/`ttyS0`/`ttyAMA0`
— `FEATURE_SECURETTY=y` would otherwise deny root), and `/etc/issue` (the banner,
which advertises the creds for discoverability). `getty` supersedes the old
`cttyhack`: it does its own `setsid` + controlling-tty setup.

### 6.5 Boot (what Phase 2 runs for us)
```bash
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-x86_64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64
# Equivalent bare QEMU (for reference). NOTE: a cpio initramfs needs NO root= —
# do NOT copy the `root=/dev/ram0 rw` from examples/vm-netboot-direct.toml,
# that's older initrd-IMAGE semantics and is wrong here:
#   qemu-system-x86_64 -kernel out/x86_64/kernel -initrd out/x86_64/initramfs.cpio.gz \
#       -nographic -append "console=ttyS0"        # aarch64: console=ttyAMA0
```

---

## 7. Full workflow (the lab's documented happy path)

```bash
# 1. Build the toolchain image once (rootless podman; base pinned by digest)
podman build -t micro-linux-builder micro-linux/

# 2. Compile kernel + BusyBox for both arches, in the container (fetch+verify+assert)
micro-linux/mlbuild.sh build --arch x86_64,aarch64   # → out/<arch>/{kernel,_install/}

# 3. Pack each arch as kernel + initramfs (rootless; packer per §5 —
#    gen_init_cpio recommended, or export-initrd)
micro-linux/mlbuild.sh pack --arch x86_64,aarch64

# 4. Boot it (reuses Phase 2)
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-x86_64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64
# … and the aarch64 twin via examples/micro-linux-aarch64.toml
```

`mlbuild.sh` is a thin orchestrator: steps 2–3 are its subcommands so a single
`mlbuild.sh all --arch x86_64,aarch64` can do the whole build→pack chain, then
hand off to Phase 2. (An `--offline` mode builds from pre-fetched, pinned
tarballs so a cached tarball can drive a network-gated integration test — §10.)

---

## 8. Security notes (cross-referenced with AUDIT.md)

- **Download integrity — *implements* audit F2.** F2's root cause was a checksum
  *fetched but never compared*. This lab anchors trust in a **vendored signing
  key** (fingerprint pinned in `versions.env`), verifies the upstream
  **signature** with `gpgv`, and **auto-derives + locks** the per-version sha256
  into git-tracked `versions.lock` (§6.0). It deliberately does *not* fetch-and-
  trust a checksum from the same source as the tarball — that's TOFU and useless
  against a supply-chain attacker. First lab in the repo to satisfy F2 fully, and
  it demonstrates the signed-`SHA256SUMS` + vendored-keyring pattern the F2
  Kali/cloud-image fix should reuse.
- **Pinned / reproducible inputs — *implements* audit F5.** Versions are pinned
  in `versions.env` (not a floating ref like iPXE's `master`), and the
  `Containerfile` base image is pinned by **tag + digest** (F5 specifically
  flags the repo's unpinned `debian:bookworm`). Toward bit-reproducible
  artifacts: `gzip -9 -n` + `gen_init_cpio` with `uid/gid 0` + a sorted file
  list get most of the way; set `KBUILD_BUILD_TIMESTAMP/USER/HOST` for the
  kernel. (We use no `binfmt`/`--privileged` path — we cross-compile — so that
  slice of F5 doesn't apply.)
- **Throwaway posture — consistent with audit F1, *minus its sharpest edge*.**
  `/init` runs a **console `getty` + `login`** with a deliberately weak,
  *advertised* lab credential (`root` / `micro`, a SHA-512 `crypt()` hash in
  `/etc/shadow`; override via `MLBUILD_LAB_PASSWORD`). The login prompt is for
  ergonomics/learning, not real defense: it adds no protection over a bare shell
  on a single-user RAM VM. Crucially, unlike F1 (network-reachable `lab`/`lab` +
  `ssh_pwauth` + the blank-password dropbear fallback), this VM runs with
  **`network = false` by default and only a *serial-console* login — no SSH or
  any listening service** — so there is **no network auth surface to
  compromise**. F1's "never expose to an untrusted network" banner still applies
  *iff* the §10 networking demo later adds a NIC.
- **Trust boundary — audit F3 largely N/A here.** F3 concerns root
  `post_commands` / arbitrary `/init` host paths in *chroot* configs. This lab's
  inputs (`versions.env`, the pinned URLs/hashes, the in-repo `/init`) are
  trusted repo files, and the whole build runs **rootless** — so even a
  malicious `versions.env` executes unprivileged, strictly better than F3's root
  execution. (Still: `versions.env` is *sourced*, so treat it as code, not data.)
- **Destructive-op guard — applies audit F7.** `mlbuild.sh`'s `clean`/rebuild
  removes `out/<arch>` and the container work dir. Before any `rm -rf` it asserts
  the target's realpath is non-empty, is a subpath of the lab's `out/`, and is
  never `/`, `$HOME`, or a symlink — the same defense-in-depth F7 asks for in
  `destroy`, where a hand-corrupted `target = "/"` would be catastrophic.
- **Rootless by construction.** Container build runs as the invoking UID
  (`--userns=keep-id`) and the pack is rootless (§5) — no `sudo` anywhere,
  unlike the debootstrap-based netboot lab.
- **No host pollution.** The toolchain lives only in the (digest-pinned)
  container image; the host needs just podman/docker + qemu.

---

## 9. Implementation order (dependency-aware)

1. `micro-linux/Containerfile` (base pinned by digest) + `versions.env` +
   **`keys/`** (vendored signing keys) — the toolchain + trust anchors;
   `versions.lock` is generated on the first verified build (§6.0).
2. `mlbuild.sh build` — fetch + **verify (gpgv vs vendored key) + lock the
   hash** + compile, x86_64 first then aarch64 cross, **with the static /
   required-symbol assert gates** (§6); **guard `clean`/rebuild `rm -rf` per F7**
   (§8). Add `--offline` to build from a pinned tarball cache.
3. `micro-linux/init` + `mlbuild.sh pack` — `gen_init_cpio` recommended (§5 B),
   `export-initrd` as the alternative (§5 A).
4. `examples/micro-linux-{x86_64,aarch64}.toml` (Phase 2 boot specs;
   `network=false`, `memory=256M`–`512M`).
5. Docs (`README.md` quick-start, `micro-linux/README.md`, `SHOWCASE.md`) +
   `.gitignore` entry for `out/`.
6. `micro-linux/tests/` (argv/staging/version-pin units; network-free) — and
   **wire them into the CI that audit F6 recommends**. The optional network
   integration test must be skippable (exit 77), matching the repo's test idiom.
7. *(Optional, parallel — the faithful track, §11)* add `gcc-riscv64-linux-gnu`
   + Go to the builder, pin `UROOT_REF`/`GO_VER`, build the riscv kernel (same
   verify/lock as step 2) + u-root cpio, add `examples/micro-linux-riscv64.toml`.
   Independent of steps 2–6; needs host `opensbi` + `qemu-system-misc` to boot.

---

## 10. Open items / future work

- **Faithful "letter of the post" track → now specified in §11:** `--arch
  riscv64` + **u-root** + **plain cpio**, matching the source post. Phase 2
  already drives riscv64 end-to-end (verified), so it's largely free.
- **Truly micro:** a `make tinyconfig` + minimal fragment variant and a size
  comparison against `defconfig` (the post's "almost useless" spirit; defconfig
  kernels are minutes-long and multi-hundred-MB build trees).
- **musl-static BusyBox:** smaller binaries and no glibc static-NSS caveat
  (§6.3) — the idiomatic choice for static busybox.
- **Reproducible builds:** finish the determinism work flagged in §8
  (`KBUILD_BUILD_*`, sorted file list, `uid/gid 0`) and publish verifiable
  hashes. This is also the *only* real mitigation for the §6.0 residual — an
  upstream **signing-key** compromise — via independent rebuild attestation
  (multiple parties reproduce the same hash).
- **microvm boot — DONE (2026-05-27).** Every micro-linux kernel is now built
  with `CONFIG_VIRTIO_MMIO=y` (+`_CMDLINE_DEVICES`), so one universal kernel boots
  on q35/virt *and* on QEMU's microvm machine (§6.1). No separate `--microvm`
  build profile was needed — mmio is nearly free and a single kernel avoids an
  output-dir split; the microvm-ness is a *boot-time* choice (`microvm = true` in
  the spec → see `examples/micro-linux-{x86_64,aarch64}-microvm.toml`). Phase 2
  was also corrected here: QEMU's `microvm` machine is x86-only, so aarch64
  "microvm" is a minimized `virt` + virtio-mmio + firmware-free direct `-kernel`
  boot (the prior code emitted a nonexistent `-machine microvm` for arm).
- **Bake-in variant:** `CONFIG_INITRAMFS_SOURCE=<dir>` to embed the initramfs
  *inside* the kernel image → a single-file boot (no `-initrd`).
- **More arches:** ppc64le / s390x (riscv64 covered by the faithful track) —
  each needs its cross-toolchain in the Containerfile.
- **Networking demo:** enable `udhcpc` (BusyBox) + a virtio NIC for a
  "micro-distro that gets a DHCP lease" follow-up (re-apply F1's
  network-exposure banner once a NIC exists).
- **Phase 6 TUI:** surface the built artifacts + boot specs as one lab once it
  lands.

---

## 11. Faithful track: `--arch riscv64` + u-root (matches the source post)

This is the *letter of the post* — a **riscv64** kernel + a **u-root**
initramfs packed as a **plain (un-gzipped) cpio** — and it's cheap to add
because **Phase 2 already drives riscv64 end-to-end** (verified, not assumed):
`arch_map` gives `machine=virt`, `cpu=rv64`, `firmware-pkg="opensbi …"`
(`lab-vm.sh:111-115`), `firmware_for()` auto-resolves the OpenSBI blob
(`fw_jump.elf` / `fw_dynamic.elf`), and the run path emits
`qemu-system-riscv64 -machine virt -cpu rv64 -bios <opensbi> -kernel … -initrd …`.

### 11.1 Why it's nearly free
- **Boot:** Phase 2 `kernel+initrd` backend, **unchanged** — the validator has
  no arch restriction (only `from-chroot` is x86_64-only).
- **Userspace:** u-root is **pure Go**, so it cross-compiles to riscv64 with a
  single env var (`GOARCH=riscv64`) — **no C cross-toolchain and no static-libc
  dance** (contrast the BusyBox track, §6.3). u-root's own init mounts
  `/proc /sys /dev` and opens the console, so the **`/dev/console` hazard of §5
  doesn't arise** here.
- **cpio:** u-root emits a **plain newc cpio** — exactly what the post does.

### 11.2 Build-env delta (extends §3)
- **Builder image** adds `gcc-riscv64-linux-gnu` (riscv kernel cross) + a pinned
  **Go** toolchain (for u-root); keep it in a separate build stage if you want
  the BusyBox image lean.
- **The host that boots it** (Phase 2) needs `opensbi` + `qemu-system-misc`
  (riscv64). `firmware_for()` already dies with an exact install hint if OpenSBI
  is missing — so this fails loud, not silent.

### 11.3 Recipe
```bash
# Kernel — riscv64 (same verify .sign + lock-the-hash flow as §6.0):
tar xf linux-${LINUX_VER}.tar.xz && cd linux-${LINUX_VER}
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- defconfig      # the post uses plain defconfig
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)"   # → arch/riscv/boot/Image

# Userspace — u-root initramfs (pure-Go cross-compile, plain cpio):
GOARCH=riscv64 GOOS=linux CGO_ENABLED=0 \
  go run github.com/u-root/u-root@${UROOT_REF} -o out/riscv64/initramfs.cpio
# (u-root's init mounts /proc,/sys,/dev and execs its shell — no /init of ours)
```
- **Supply chain (consistent with §6.0):** u-root arrives via Go modules, whose
  integrity is enforced by `go.sum` + the checksum transparency log
  (`sum.golang.org`) — the same "verified, not fetch-and-trust" principle as our
  PGP + lock flow. **Pin `UROOT_REF` and `GO_VER` in `versions.env`, commit
  `go.sum`.**
- riscv `virt` exposes an 8250 UART → **`console=ttyS0`** (add `earlycon` for
  early logs). u-root's init lands at `/init`, so no `rdinit=` is needed.

### 11.4 Boot
`examples/micro-linux-riscv64.toml`: `backend=kernel+initrd`, `arch=riscv64`,
`kernel=out/riscv64/kernel`, `initrd=out/riscv64/initramfs.cpio`,
`append="console=ttyS0"`, `network=false`, `memory="512M"`.
```bash
# Equivalent bare QEMU (matches the post; lab-vm.sh additionally adds -cpu rv64 -bios <opensbi>):
qemu-system-riscv64 -machine virt -nographic \
  -kernel arch/riscv/boot/Image -initrd out/riscv64/initramfs.cpio \
  -append "console=ttyS0"
```

### 11.5 Optional: the post's "simple" C init
The post's most minimal variant is a **static C `init` → `little_shell`** (no
u-root, no BusyBox): `riscv64-linux-gnu-gcc -static -o init init.c`, packed with
`gen_init_cpio` (§5 B) so `/dev/console` exists. Lower priority than u-root, but
it's the smallest "almost useless" image and the closest to the post's opening
example.

---

## Sources

- *Making a Micro Linux Distro* — popovicu.com — **fetched & reconciled (v2):**
  the post targets **riscv64**, uses a **hand-written C `init` → `little_shell`**
  (or **u-root** for the functional variant) and a **plain `cpio -H newc`** (no
  gzip); BusyBox is not used. See §1.1 for the deltas this plan deliberately
  adopts.
- Linux kernel docs: `Documentation/filesystems/ramfs-rootfs-initramfs.rst`
  (initramfs format & `/init` contract); `usr/gen_init_cpio` (non-root device
  nodes); the `DEVTMPFS_MOUNT` Kconfig help ("does not affect initramfs").
- BusyBox FAQ — building a static binary and `make install` layout; the
  `tc`/kernel-6.8 build break (CBQ symbols removed) and its 1.37.0 fix.
- u-root — `github.com/u-root/u-root` — pure-Go initramfs generator used by the
  faithful track (§11); module integrity via `go.sum` + `sum.golang.org`.
- mklab internals: `phase1-chroot/lab-chroot.sh` (`cmd_export_initrd`,
  `_write_init_preset`), `phase2-qemu-vm/lab-vm.sh` (`kernel+initrd` backend,
  arch map), `netboot/ipxe-build-inner.sh` (`CROSS_COMPILE` precedent),
  `examples/vm-netboot-direct.toml` + `chroot-netboot-busybox.toml` (the
  near-identical working precedent).
- `AUDIT.md` — F1 (weak default creds), F2 (unverified downloads), F3 (config
  trust boundary), F5 (unpinned build inputs), F6 (no CI), F7 (unguarded
  `rm -rf`).
