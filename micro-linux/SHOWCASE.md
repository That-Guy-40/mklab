# micro-linux — 5-minute tour

**What you get:** a Linux distro you compiled yourself — a fresh kernel plus a
single static BusyBox (or u-root) binary — booting to a **console login prompt**
in QEMU with no disk, no bootloader, and no distro packages. The entire
userspace lives in RAM and is a few megabytes.

It's the third boot pipeline in this repo, and the only one built *from source*:

| Lab | Rootfs | Kernel | Boot |
|---|---|---|---|
| netboot | debootstrap (Debian pkgs) | host/distro kernel | iPXE → HTTP → RAM |
| almalinux-pxe | Anaconda → disk | installer kernel | iPXE → install-to-disk |
| **micro-linux** | **BusyBox / u-root, from source** | **Linux, from source** | **QEMU `-kernel`/`-initrd`** |

---

## The whole thing in four commands

```bash
micro-linux/mlbuild.sh image                       # toolchain container (once)
micro-linux/mlbuild.sh all --arch x86_64           # compile + pack → out/x86_64/
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-x86_64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64
```

What the serial console shows:

```
Welcome to micro-linux (Linux 6.12.x x86_64)

Throwaway OFFLINE lab VM.  Log in with:
    login:    root
    password: micro

(none) login: root
Password:
login[56]: root login on 'console'
~ # uname -a
Linux (none) 6.12.x #1 SMP ... x86_64 GNU/Linux
~ # cat /proc/1/cmdline
/init
~ # exit            # logout → the login: prompt comes back (getty respawns)
~ # poweroff        # (or 'poweroff -f') → clean ACPI/PSCI power-off, QEMU exits
```

`/init` is a tiny inittab-free mini-init: it mounts `/proc /sys /dev`, reattaches
the console, traps the shutdown signals BusyBox sends to PID 1, then loops
`getty -L console 0 vt100` in the background (blocking on `wait`). getty prints
`/etc/issue` — which advertises the credentials — and hands off to `login`,
which checks the password (SHA-512 `crypt()` in `/etc/shadow`) and starts the
shell. PID 1 stays `/init`, so a logout just re-shows the prompt and `poweroff`
powers the VM off cleanly instead of panicking the kernel.

---

## Three tracks, one pipeline

```bash
mlbuild.sh all --arch x86_64,aarch64    # static BusyBox, cross-compiled
mlbuild.sh all --arch riscv64           # u-root (Go) + plain cpio — the "faithful track"
```

- **x86_64 / aarch64** — static BusyBox, packed with the kernel's own
  `gen_init_cpio` (so the kernel is *not* re-embedded in the initramfs and
  `/dev/console` is baked in without root).
- **riscv64** — the literal recipe from the source post: a u-root initramfs as
  a plain cpio. u-root is pure Go, so it cross-compiles with one env var and
  needs no C cross-toolchain.

---

## Boot it on QEMU's real microvm machine

Every micro-linux kernel is built with `CONFIG_VIRTIO_MMIO`, so the **same**
kernel that boots on `q35`/`virt` also boots on QEMU's minimal **microvm**
machine (no PCIe, ~kilobyte qboot BIOS, virtio on the mmio bus — the QEMU
analogue of Firecracker). It's a one-line change in the spec:

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-x86_64-microvm.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64-microvm
```

QEMU's `microvm` machine is x86-only; on aarch64 the `-microvm.toml` twin gives
you the equivalent — a stripped-down, firmware-free `virt` + virtio-mmio.

---

## Give it a network: the DHCP demo

The kernel already carries `CONFIG_VIRTIO_MMIO` and the BusyBox ships `udhcpc`, so
the from-source distro can pull a real DHCP lease over its virtio NIC — in RAM,
on the microvm machine:

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/micro_linux_dhcp_lease/micro-linux-x86_64-dhcp.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64-dhcp
```

```
*** NETWORK ENABLED (mllab.net): this throwaway VM has a LIVE NIC ...
udhcpc: eth0 bound to 10.0.2.15 (gw 10.0.2.2, dns 10.0.2.3)
~ # ifconfig eth0 → inet addr:10.0.2.15      ~ # ip route → default via 10.0.2.2
```

It's **opt-in**: `/init` only touches the network when the kernel cmdline carries
the `mllab.net` token (the demo spec sets `append = "... mllab.net=1"`). Every
other spec stays network-down. The riscv64 / u-root track works a bit differently
— it boots to an interactive shell and ships u-root's own `dhclient`, so you run
`dhclient -ipv6=false eth0` yourself. See
[`../examples/micro_linux_dhcp_lease/`](../examples/micro_linux_dhcp_lease/) — and
mind the AUDIT-F1 caveat there (root has a well-known password; don't bridge it to
an untrusted network).

---

## Build variants — three levers for size and deployment shape

The default build (`mlbuild.sh all`) produces one kernel and one initramfs per
arch.  Three optional flags add alternate artifacts *alongside* the defaults —
no choice required, no prior build wasted:

```bash
micro-linux/mlbuild.sh all --arch x86_64,aarch64 --all-variants
```

`--all-variants` is shorthand for `--musl --tiny --baked --compare`.
`--compare` prints this table after the build:

```
arch          kernel    initramfs  initramfs   kernel    kernel
              (defcfg)  (glibc)   -musl       -tiny     -baked
──────────────────────────────────────────────────────────────────────
x86_64        8.2M      12.1M     7.8M        1.9M      20.3M
aarch64       9.4M      14.2M     8.6M        2.1M      23.6M
```

### `--musl` — smaller initramfs, no NSS caveat

BusyBox rebuilt against **musl libc** instead of glibc.  The critical
difference: a glibc-static binary still `dlopen()`s Name Service Switch
plugins at runtime (`libnss_files.so`, `libnss_dns.so`, …).  In a libc-free
initramfs those `.so` files don't exist, which causes silent failures for any
code path that touches host lookups.  musl has its resolver baked in — no
runtime plugins, ~30–40% smaller binary.

x86_64 uses Debian's `musl-gcc` wrapper.  aarch64 uses `aarch64-linux-musl-gcc`,
built inside the container by cross-compiling musl 1.2.3 with the existing
`gcc-aarch64-linux-gnu` toolchain, then generating a GCC specs file via musl's
own `tools/musl-gcc.specs.sh`.

Output: `out/<arch>/initramfs-musl.cpio.gz` — drop-in replacement for the
default initramfs; boot it with any micro-linux kernel via the same TOML, just
pointing `initrd` at the `-musl` file.

### `--tiny` — 3–5× smaller kernel, microvm-only

The default kernel comes from `make defconfig`, which enables several hundred
drivers for broad compatibility.  `make tinyconfig` starts from almost nothing.
`--tiny` adds back only what's needed for our use case:

| Symbol | Why |
|---|---|
| `BLK_DEV_INITRD` + `RD_GZIP` | initramfs support |
| `DEVTMPFS` + `DEVTMPFS_MOUNT` | `/dev` at boot |
| `VIRTIO_MMIO` + `VIRTIO_MMIO_CMDLINE_DEVICES` | virtio on the microvm bus |
| serial console (`SERIAL_8250` or `SERIAL_AMBA_PL011`) | output |
| `TTY` + `PRINTK` | terminal + kernel messages |

No `VIRTIO_PCI` — this kernel **only boots on microvm** (or the aarch64
equivalent minimized `virt`).  Uses an out-of-tree build (`O=build-tiny/`) so
the default defconfig build is untouched.

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-x86_64-tiny.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64-tiny
```

Output: `out/<arch>/kernel-tiny`.

### `--baked` — single-file boot, no `-initrd`

`CONFIG_INITRAMFS_SOURCE` tells the kernel's `usr/` Makefile to pack and embed
the initramfs at compile time, compressing it with gzip.  The final `bzImage`
(or arm64 `Image`) contains everything — no separate initramfs file is needed
at boot.

```bash
# With lab-vm.sh:
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-x86_64-baked.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64-baked

# Or directly with QEMU — note: no -initrd:
qemu-system-x86_64 -machine q35,accel=kvm \
    -kernel micro-linux/out/x86_64/kernel-baked \
    -append "console=ttyS0 root=/dev/ram0 rw" \
    -nographic -m 256M
```

Why this is useful:
- **netboot** — one fewer TFTP/HTTP transfer (kernel-baked + no initrd vs. kernel + initrd.gz)
- **embedded** — some targets require a single binary; `-kernel` without `-initrd` works everywhere
- **distribution** — one file to sign, copy, or attest

Uses an out-of-tree build (`O=build-baked/`) so the default defconfig build
is unaffected.  Output: `out/<arch>/kernel-baked`.

---

## Why it's faithful *and* lazy

Only the source-compile is new. Packing reuses the kernel's `gen_init_cpio`;
booting reuses Phase 2's `kernel+initrd` backend unchanged (it already drives
all the arches, OpenSBI firmware and all). The example TOMLs are nearly
identical to `vm-netboot-direct.toml`.

---

## Security posture (cross-referenced with AUDIT.md)

- **Downloads are *verified*, not just fetched (F2).** Trust is anchored in a
  vendored PGP key (fingerprint pinned in `versions.env`); the upstream
  signature is checked with `gpgv`, and the verified sha256 is locked in
  `versions.lock` with drift detection. A checksum fetched from the same mirror
  as the tarball is *never* trusted — that's the trap F2 found.
- **Pinned inputs (F5).** Versions pinned; base image pinnable by digest.
- **Throwaway, but smaller blast radius than F1.** Console login is `root` with
  a *well-known, advertised* lab password (`micro`) — deliberately weak, and fine
  only because `network = false` by default and there is no SSH/listening
  service, so there's no network auth surface at all. The credential lives in
  `/etc/shadow` (SHA-512 `crypt()`); change it via `MLBUILD_LAB_PASSWORD`. The
  DHCP demo re-enables networking, but only as an explicit, token-gated opt-in
  (and only over QEMU's loopback/NAT slirp) — never by default.
- **Rootless + guarded.** The build runs rootless (`--userns=keep-id`); the
  initramfs is packed without `mknod`; `clean` refuses any `rm -rf` outside
  `out/` (F7).

---

## Where to go next

- Full design + the deltas from the source post: [`../MICRO_LINUX_LAB_PLAN.md`](../MICRO_LINUX_LAB_PLAN.md)
- Manual build steps, prerequisites, key vendoring: [`README.md`](README.md)
- Boot specs: [`../examples/micro-linux-x86_64.toml`](../examples/micro-linux-x86_64.toml) (+ `aarch64`, `riscv64`)
