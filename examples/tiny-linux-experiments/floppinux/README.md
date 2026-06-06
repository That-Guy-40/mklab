# FLOPPINUX — an embedded Linux on a single floppy, the Debian way

A faithful, **rootless**, non-interactive operationalization of Krzysztof
Krystian Jankowski's [FLOPPINUX](https://krzysztofjankowski.com/floppinux/floppinux-2025.html)
(v0.3.1, Dec 2025) — a complete Linux that boots from a 1.44 MB 3.5" floppy on
anything from an i486 up. One script, [`build-floppinux.sh`](build-floppinux.sh),
turns upstream's Arch/Omarchy *menuconfig* walkthrough into a reproducible build
on a **Debian** host: same kernel (6.14.11), same BusyBox (1.36.1), same boot
script, same `qemu-system-i386 -fda` payload.

> All credit for the distro, the boot script, and the splash art is Krzysztof's
> (<https://krzysztofjankowski.com/floppinux/>). This directory is just his
> recipe, automated for Debian and folded into the `tiny-linux-experiments/`
> family. An **exact, offline copy of the original tutorial** is archived under
> [`upstream-tutorial/`](upstream-tutorial/) — read [the canonical
> page](https://krzysztofjankowski.com/floppinux/floppinux-2025.html) for the
> authoritative, maintained version (and to support the author).

## Files

| File | What it is |
|---|---|
| [`build-floppinux.sh`](build-floppinux.sh) | The whole pipeline. Subcommands: `build` (fetch toolchain → kernel → BusyBox → pack initramfs → write floppy), `pack` (re-pack the rootfs + floppy from an already-compiled tree — resume after `build`, no toolchain), `boot` (graphical), `test` (headless serial), `clean`. |
| [`kernel.config-fragment`](kernel.config-fragment) | The non-interactive equivalent of upstream's `menuconfig` walk — merged onto `tinyconfig`. Every symbol is commented with the menu bullet it replaces. |
| [`ARTIFACTS.md`](ARTIFACTS.md) | Guided tour of every build artifact and **how they connect** — the data-flow graph, producer→consumer table, and read-only commands to peek inside each piece. Start here to *understand* the build. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Pass/fail runbook: test each stage and the end-to-end boot, with the **real expected output** captured from a verified run. Start here to *verify* it works. |
| [`upstream-tutorial/`](upstream-tutorial/) | An exact, unmodified offline archive of Krzysztof Jankowski's original tutorial (HTML + CSS), with provenance/attribution and sha256s. Copyright remains the author's. |

## Quick start (Debian / Ubuntu)

```bash
# 1. one-time host deps (the script prints this exact line if anything's missing)
sudo apt-get install -y build-essential bc bison flex libssl-dev libelf-dev \
    wget xz-utils cpio fakeroot dosfstools mtools syslinux qemu-system-x86

# 2. build everything (downloads a ~40 MB i486 toolchain + clones the kernel)
cd examples/tiny-linux-experiments/floppinux
./build-floppinux.sh build

# 3. boot it
./build-floppinux.sh boot      # faithful: graphical VGA, -cpu 486 -m 20M
./build-floppinux.sh test      # headless: serial console, auto-poweroff (no display needed)
```

Artifacts land in `~/.cache/lab-create/floppinux/` (override with
`FLOPPINUX_BUILD_DIR`): `bzImage`, `rootfs.cpio.xz`, and the bootable
`floppinux.img`. To write it to a real floppy, see upstream — `dd` it with
care to the right device.

## What's different from the upstream HOWTO (and why)

The upstream guide is a hand-driven Arch build. Everything below is a deliberate
Debian / automation adaptation — the *output* is identical, the *path* is
scriptable and needs no root.

| Upstream | Here | Why |
|---|---|---|
| `pacman -S …` | `apt-get install …` (and the script only *prints* the line) | Debian, and the repo never auto-installs. |
| Kernel built with **host gcc** | Kernel cross-built with the **i486-musl toolchain** we already fetch for BusyBox | A 64-bit Debian host would otherwise need `gcc-multilib` to emit 32-bit. Reusing the cross toolchain makes the build self-contained. The kernel is freestanding (never links libc), so the musl toolchain builds it fine. |
| `menuconfig` (interactive) | `tinyconfig` + [`kernel.config-fragment`](kernel.config-fragment) + a **post-config grep that aborts** if a symbol didn't stick | Reproducible, and a renamed/cross-version symbol fails *loudly* instead of silently producing a kernel that boots to a blank screen. |
| `sudo mknod dev/console …` | `/dev/console` + `/dev/null` baked into the cpio under **`fakeroot`** | No root. fakeroot fakes the `mknod`; `cpio` records the faked char-dev in the archive. The script then verifies `/dev/console` really is char 5,1 in the packed cpio. |
| `sudo mount -o loop` to fill the floppy | **`mtools`** (`mmd`/`mcopy`) writes straight into the FAT image | No loop device, no root. |

Net: **the entire build runs as your normal user.** That mirrors this repo's
`micro-linux` ethos (which packs its initramfs with `gen_init_cpio` for the same
reason — see `../../../micro-linux/mlbuild.sh`). We use `fakeroot` instead because
it stays closer to upstream's literal `find . | cpio -H newc -o`.

## How it actually boots — the part worth understanding

FLOPPINUX is a great lens on "what is the minimum that boots." The chain:

```
BIOS → syslinux (FAT boot sector) → loads bzImage + rootfs.cpio.xz into RAM
     → kernel unpacks the cpio into a rootfs in a RAM disk (root=/dev/ram)
     → kernel runs rdinit=/etc/init.d/rc  AS PID 1
     → rc: mount /proc /sys, `mdev -s` populates /dev, mount the floppy's FAT
            area, bind /mnt/data onto /home, `cat welcome`, exec a shell
```

A few things here are more subtle than they look:

**1. `rdinit=` makes a shell script PID 1.** The kernel's `init` for an
initramfs is normally `/init`; `rdinit=/etc/init.d/rc` overrides it to point
straight at the rc script. So **PID 1 is `/bin/sh` running `rc`** — there is no
`/sbin/init` in the boot path at all. The `etc/inittab` and BusyBox `init` applet
are shipped (upstream includes them) but *unused at boot* unless you instead boot
with `init=/sbin/init`. This is exactly the "shell as PID 1" design discussed in
this repo's [`../alpine-custom-init.TXT`](../alpine-custom-init.TXT), with the
same gotcha: **`rc` ends with `/bin/sh` (not `exec`), so when you type `exit`,
`rc` falls off its last line, PID 1 dies, and the kernel panics** (`Attempted to
kill init!`). That's not a bug — it's what "PID 1 is a script" means. (To
poweroff cleanly instead, the floppy carries BusyBox `halt`/`poweroff`.)

**2. `mdev -s` is the no-udev `/dev` populator.** The cpio ships only
`/dev/console` (so PID 1 has stdio) and `/dev/null`. Everything else — crucially
`/dev/fd0`, the floppy — is created by `mdev -s`, which walks `/sys` and makes a
node for each device the kernel already knows about. That's why the kernel needs
`CONFIG_BLK_DEV_FD` (so `/dev/fd0` exists in sysfs) *and* `CONFIG_SYSFS` (so mdev
can see it). No systemd, no udev, no devtmpfs — `mdev` is ~one BusyBox applet.

**3. The floppy is its own data disk.** The FAT filesystem that syslinux boots
from *also* holds a `data/` directory. `rc` re-mounts the floppy read-write at
`/mnt` and bind-mounts `/mnt/data` onto `/home`, so anything you save in `/home`
persists on the physical floppy. One 1.44 MB FAT12 image is simultaneously the
bootloader medium, the kernel/initramfs store, and the user's home disk.

**4. `tinyconfig` is aggressive — the console is the trap.** `make tinyconfig`
strips the *entire* VT layer. The faithful `syslinux.cfg` boots with
`console=tty0`, which needs the VGA text console, which needs the whole VT stack
(`CONFIG_VT`/`VT_CONSOLE`/`VGA_CONSOLE`) — none of which tinyconfig leaves on.
Miss them and you get a kernel that builds clean, prints to the (absent) console,
and looks dead. The fragment turns them back on, and `verify_kconfig` asserts
them before the multi-minute compile. (We also compile in the 8250 serial
console, so the same image works over a serial line and `… test` can verify it
headlessly.)

**5. `-cpu 486` + `tsc=unstable`.** A real 486 has no RDTSC; `CONFIG_M486` builds
for that floor, and `tsc=unstable` tells the kernel not to trust the timestamp
counter for timekeeping. That's what lets the image run on the smallest CPU QEMU
will emulate — and on actual retro hardware.

## Honest opinions & ideas

- **This is the clearest "minimum bootable Linux" demo there is.** Unlike the
  `micro-linux` track (which compiles a kernel for the sake of it), FLOPPINUX has
  a *constraint* — 1.44 MB — that forces every byte to justify itself. The
  253 KiB of free space on a finished disk is a real teaching number.
- **The kernel is 99% of the image.** bzImage is ~880 KiB; the entire userspace
  (static BusyBox + scripts) compresses to ~137 KiB. If you want a *smaller*
  FLOPPINUX, the lever is the kernel `.config`, not the rootfs. Good next
  experiment: diff `kernel.config-fragment` against what `olddefconfig` actually
  produced and prune anything you don't boot.
- **It pairs beautifully with the existing labs.** The Alpine microVM here boots
  a *downloaded* rootfs from RAM; the `micro-linux` track *compiles* a BusyBox
  rootfs and packs it with `gen_init_cpio`; FLOPPINUX *compiles* one too but
  targets a **physical FAT floppy + syslinux** instead of QEMU `-initrd`. Three
  takes on "tiny in-RAM Linux," each making a different part explicit.
- **Idea: a 1.68 MB variant.** Upstream notes you can reformat to 1.68 MB
  ("superformat") for more room. The mtools path here makes that a one-line
  change (`mkfs.fat` geometry) if you ever want the headroom for, say, `tcc`.
- **Idea: drive it from a TOML like the rest of the family.** `lab-vm.sh` has no
  `-fda` backend today (only `disk` / `kernel+initrd`), which is why this lab is a
  standalone script like those in [`../reference/`](../reference/). A small
  `floppy` backend in `lab-vm.sh` would let a `floppinux.toml` join the others.

## ⚠️ Security

Throwaway lab, same rules as the rest of `tiny-linux-experiments/`: the booted
system drops **straight to a root shell with no password**, and there is **no
networking** in the build at all. That's perfectly fine for a floppy you boot in
QEMU or on an air-gapped retro box — but it is not, and is not meant to be, a
hardened system. Don't put secrets on the floppy's `/data`.

## What actually ships (the applet set)

BusyBox is built `allnoconfig` + a curated list, so the disk carries only:

```
bin:  ash cat cp df echo ln ls mkdir mount mv rm sh sync umount vi
sbin: halt init mdev          usr/bin: clear test
```

That's it — ~15 commands. `halt` is the clean-shutdown command (`/sbin/halt -f`).
`poweroff`/`reboot` are *separate* BusyBox applets not in this minimal set (so
the inittab's `::ctrlaltdel:/sbin/reboot` is vestigial — harmless, since `rdinit`
bypasses the inittab anyway). Want them? Add `POWEROFF REBOOT` to the applet loop
in `build-floppinux.sh` and rebuild. There is deliberately no `grep`, `sed`,
`find`, or `uname` — that's the 137 KiB-of-userspace point.

## Status — verified end-to-end (2026-06-05)

Built and booted on a Debian host, kernel 6.14.11 + BusyBox 1.36.1. Confirmed
from the real QEMU console (`-cpu 486 -m 20M`):

- **Boots as a 486:** `CPU: Intel 486 DX/4 (family: 0x4 …)`, `tsc: Marking TSC
  unstable due to boot parameter`.
- **The console landmine is clear:** `Console: colour VGA+ 80x25` — so the
  faithful `console=tty0` graphical boot displays (the advisor-flagged
  `VGA_CONSOLE` trap is handled).
- **Both boot paths work:** the direct `-kernel`/`-initrd` path *and* the real
  **syslinux-off-the-floppy** path (`-fda` → SeaBIOS → syslinux → bzImage +
  rootfs.cpio.xz → `Run /etc/init.d/rc as init process`).
- **The floppy is its own data disk:** `/dev/fd0 on /mnt type msdos
  (…codepage=437…)`, bind-mounted onto `/home`, and `cat /home/hello.txt` →
  `Hello, FLOPPINUX user!` straight off the FAT.
- **Size budget met:** bzImage ≈ 880 K, rootfs.cpio.xz ≈ 112 K, **264 KiB free**
  on the 1.44 MB floppy.
- `/dev/console` is verified as char `5,1` in the packed cpio; BusyBox is
  `static-pie linked` (no INTERP, no NEEDED libs — self-contained).

Reproduce: `./build-floppinux.sh build` (the one step that fetches the `musl.cc`
toolchain — your call on your machine, exactly as upstream), then
`./build-floppinux.sh test` for the headless serial boot, or `… boot` for the
faithful graphical one. Both kernel and BusyBox configs are also independently
validated by the script's fail-fast checks before any compile.
