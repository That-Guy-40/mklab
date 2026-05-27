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
  `/etc/shadow` (SHA-512 `crypt()`); change it via `MLBUILD_LAB_PASSWORD`.
- **Rootless + guarded.** The build runs rootless (`--userns=keep-id`); the
  initramfs is packed without `mknod`; `clean` refuses any `rm -rf` outside
  `out/` (F7).

---

## Where to go next

- Full design + the deltas from the source post: [`../MICRO_LINUX_LAB_PLAN.md`](../MICRO_LINUX_LAB_PLAN.md)
- Manual build steps, prerequisites, key vendoring: [`README.md`](README.md)
- Boot specs: [`../examples/micro-linux-x86_64.toml`](../examples/micro-linux-x86_64.toml) (+ `aarch64`, `riscv64`)
