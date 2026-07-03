# minimal-arm-linux-qemu — cross-build a tiny ARM Linux, boot it on QEMU's Mainstone

Operationalizes David Corvoysier's 2016 how-to
**[*Build and boot a minimal Linux system with qemu*](upstream-tutorial/README.md)**
([kaizou.org](https://www.kaizou.org/2016/09/boot-minimal-linux-qemu.html), CC
BY-NC-SA 3.0) on a modern Debian host: it **cross-compiles a Linux kernel from
source**, hand-writes a **static C `/init`** that prints one line, packs it into
an **initramfs**, and boots the whole thing with
`qemu-system-arm -M mainstone` (Intel PXA270). One
[`build-minimal-arm.sh`](build-minimal-arm.sh) does it all, rootless.

It's the **ARM cross-compile** cousin of the tiny-Linux family: where
[`micro-linux-*`](../README.md) builds an x86/riscv BusyBox userspace and
[`floppinux/`](../floppinux/) squeezes an i386 system onto a floppy, this one is
the smallest possible thing — **a from-scratch kernel booting a single static
binary you wrote as PID 1** — on an *emulated ARM board*. No BusyBox, no shell,
no disk, no network: just proof that the kernel you compiled will run the init
*you* compiled.

```bash
cd examples/tiny-linux-experiments/minimal-arm-linux-qemu
sudo apt-get install -y gcc-arm-linux-gnueabi libc6-dev-armel-cross \
    build-essential bc bison flex libssl-dev libelf-dev git cpio fakeroot \
    qemu-system-arm                 # host deps (the script only PRINTS this line)
./build-minimal-arm.sh build       # shallow-clone linux 6.1, cross-compile, pack initramfs
./build-minimal-arm.sh test        # headless boot, assert "Tiny init ..." (verification)
./build-minimal-arm.sh boot        # interactive boot (serial on your terminal; Ctrl-A x quits)
```

Expected finale on the serial console:

```text
Freeing unused kernel image (initmem) memory: 204K
Run /init as init process
Tiny init ...
```

…and then it spins forever — the tutorial's `/init` is literally
`printf("Tiny init ...\n"); while(1);`. Quit QEMU with **Ctrl-A x**.

## What the build produces (under `~/.cache/lab-create/minimal-arm-linux/`)

| Artifact | What it is |
|---|---|
| `linux/` | shallow git checkout of `v6.1.176` (the kernel source) |
| `build/arch/arm/boot/zImage` | the cross-compiled ARM kernel (~2.8 MB) |
| `init` | the static ARM `/init` — `file` says *statically linked, ARM, EABI5* |
| `initramfs` | newc cpio: `/init` + `/dev/console` |
| `mainstone-flash{0,1}.img` | two empty 32 MiB flash banks QEMU's board demands |

## Deliberate adaptations (the tutorial is from 2016)

Each is a faithful modernization, not a shortcut — and most were *forced* by a
concrete failure this lab hit and documents (see
[MANUAL_TESTING.md](MANUAL_TESTING.md) for the receipts):

- **Kernel 6.1.x LTS, not the post's 4.7.5.** 6.1 is the **last** kernel that
  still ships `arch/arm/mach-pxa/mainstone.c` + `mainstone_defconfig` — PXA board
  files were removed in 6.2–6.6 when PXA went device-tree-only, which would leave
  QEMU's hardcoded `-M mainstone` with no board to match. 6.1 keeps the tutorial's
  *exact board* while building cleanly with a current GCC. (The 4.7.5 tarball is
  also long gone from `cdn.kernel.org`.)
- **Debian's `arm-linux-gnueabi` cross toolchain**, not a from-scratch
  crosstool-NG uClibc build. Debian's `armel` port targets **ARMv5TE soft-float
  EABI** — a natural fit for PXA270/XScale. One `apt` line replaces the post's
  `./configure && make && sudo make install` of crosstool-NG.
- **`menuconfig` → a scripted `scripts/config` pass** enabling `BLK_DEV_INITRD`
  (so `-initrd` works) and **`AEABI`** — with a grep-assert that aborts if either
  didn't stick. **AEABI is load-bearing:** `mainstone_defconfig` is an OABI-era
  config, but our toolchain emits EABI; a mismatch means `/init` never runs.
- **`/dev/console` baked into the initramfs via `fakeroot mknod`** (rootless: a
  real `mknod` needs `CAP_MKNOD`). Without a console the kernel wires `/init`'s
  stdout to nothing and the line-buffered `printf` never flushes. The post's bare
  `echo init | cpio` gets away without one only because `mainstone_defconfig`
  auto-mounts `devtmpfs`; we provide the node explicitly so output never depends
  on that.
- **Two 32 MiB flash images, not the post's 64 MiB.** Modern QEMU's `mainstone`
  rejects any other size outright: *"device requires 33554432 bytes."*

## `build-minimal-arm.sh` verbs

| Command | Does |
|---|---|
| `build` (default) | clone + configure + cross-compile the kernel, build `/init`, pack initramfs, make flash |
| `pack` | rebuild `/init` + initramfs + flash from the already-compiled kernel (resume; no recompile) |
| `test` | headless boot, exit 0 iff `Tiny init ...` reaches the serial log (kills QEMU by PID) |
| `boot` | interactive boot, serial on your terminal (`Ctrl-A x` to quit) |
| `clean` | remove the build tree |

Env knobs: `KERNEL_VER` (6.1.176), `MINIMAL_ARM_BUILD_DIR`, `CROSS`
(`arm-linux-gnueabi-`), `JOBS`, `TEST_TIMEOUT`.

## Requirements & verification

Needs the Debian `arm-linux-gnueabi` cross toolchain (build) and
`qemu-system-arm` (boot). **Verified** end-to-end (2026-07-02): the kernel +
initramfs build rootless (Debian bullseye, GCC 10), and the boot prints
`Tiny init ...` on **qemu-system-arm 8.2.2**. Note a *very old* QEMU (5.2)
instead **panics** here — its PXA270 model traps an iWMMXt instruction that
glibc's XScale-tuned static startup emits (`Attempted to kill init`); a modern
QEMU emulates it. See [MANUAL_TESTING.md](MANUAL_TESTING.md).

## The second boot mode (tutorial extension, not wired here)

The post also boots a root filesystem off an emulated **SD card** (an `ext2`
image on `/dev/mmcblk0`, needing `MMC`, `MMC_PXA`, `DMADEVICES`, `PXA_DMA` in the
kernel). Its `sudo mount -o loop` step has a clean **rootless** replacement —
`mke2fs -d <dir>` populates the filesystem from a directory with no mount, and
`fakeroot` supplies the `/dev/console` node — but this lab ships only the
initramfs path (the classic "tiny Linux in RAM"). Wiring up the SD mode is left
as an exercise; the recipe above is the whole trick.

## ⚠️ Security

A **throwaway** demo: PID 1 is one static binary that prints a line and spins.
There is no shell, no login, no networking, nothing to authenticate — it cannot
be "logged into." Fine as a QEMU toy; not a system.
