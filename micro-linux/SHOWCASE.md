# micro-linux — 5-minute tour

**What you get:** a Linux distro you compiled yourself — a fresh kernel plus a
single static BusyBox (or u-root) binary — booting to a shell in QEMU with no
disk, no bootloader, and no distro packages. The entire userspace lives in RAM
and is a few megabytes.

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
Welcome to micro-linux — kernel 6.12.x on x86_64
(BusyBox v1.36.1)  Ctrl-A X to quit QEMU.

/ # uname -a
Linux (none) 6.12.x #1 SMP ... x86_64 GNU/Linux
/ # cat /proc/1/cmdline
/init
/ # ls /bin | head
[ ash awk base64 busybox cat chmod ...
```

`/init` is ~6 lines: mount `/proc /sys /dev`, reattach the console, `exec
setsid cttyhack /bin/sh`. PID 1 is your shell.

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
- **Throwaway, but smaller blast radius than F1.** The shell is passwordless
  root — fine for a diskless RAM VM — but `network = false` by default and there
  is no SSH/login service, so there's no network auth surface at all.
- **Rootless + guarded.** The build runs rootless (`--userns=keep-id`); the
  initramfs is packed without `mknod`; `clean` refuses any `rm -rf` outside
  `out/` (F7).

---

## Where to go next

- Full design + the deltas from the source post: [`../MICRO_LINUX_LAB_PLAN.md`](../MICRO_LINUX_LAB_PLAN.md)
- Manual build steps, prerequisites, key vendoring: [`README.md`](README.md)
- Boot specs: [`../examples/micro-linux-x86_64.toml`](../examples/micro-linux-x86_64.toml) (+ `aarch64`, `riscv64`)
