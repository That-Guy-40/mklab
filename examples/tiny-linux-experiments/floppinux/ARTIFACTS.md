# FLOPPINUX — artifact map & guided exploration

`build-floppinux.sh` is a small **pipeline of transformations**: a few inputs
you can edit, a couple of compilers, and a chain of intermediate files that ends
in one bootable `floppinux.img`. This doc is a hands-on tour of every artifact
and **how each one connects to the next** — all commands are read-only, so poke
freely. (To *verify* the lab works, see [`MANUAL_TESTING.md`](MANUAL_TESTING.md);
this doc is about *understanding the pieces*.)

Everything lives under the build dir (override with `FLOPPINUX_BUILD_DIR`):

```bash
O=~/.cache/lab-create/floppinux      # used throughout this doc
```

## The data-flow graph

```
 INPUTS you edit            COMPILE / CONFIG              OUTPUTS
 ───────────────            ───────────────              ───────
 kernel.config-fragment ─┐
 linux/  (source) ────────┼─► linux/.config ──► bzImage ────────────────┐
 i486-musl toolchain ─────┘   (tinyconfig+merge)  (884K)                 │
                                                                         │
 busybox source ─────────┐                                              ├──► floppinux.img
 i486-musl toolchain ─────┼─► busybox .config ─► _install/ ─┐            │    (1.44 MB FAT12
 (curated applet list)    ┘   (allnoconfig+set)             │            │     + syslinux)
                                                            ▼            │
 rc + inittab + welcome ──────────────────────────────► filesystem/ ──► rootfs.cpio.xz
 (heredocs in the script)                                   ▲            │   (112K, xz)
 /dev/console + /dev/null ───────────────────────────────────┘          │
 (fakeroot mknod)                                                        │
 syslinux.cfg + hello.txt (heredocs) ───────────────────────────────────┘
```

Two compilers run, both the **i486-musl cross toolchain**: one makes the kernel
(`bzImage`), one makes the userspace (`busybox`). Everything else is packing:
`cpio | xz` builds the initramfs, and `mkdosfs → syslinux → mtools` builds the
floppy. Then at boot the floppy is taken apart in the reverse order (see the last
section).

## Who produces / consumes what

| Artifact | Produced by | Consumed by | Peek inside with |
|---|---|---|---|
| `i486-linux-musl-cross/` | downloaded (musl.cc) | kernel + busybox compiles | `"$O"/i486-linux-musl-cross/bin/i486-linux-musl-gcc --version` |
| `linux/.config` | `tinyconfig` + `kernel.config-fragment` merge | `make bzImage` | `grep -c '=y' "$O"/linux/.config` |
| `bzImage` | `make ARCH=x86 … bzImage` | the floppy (`mcopy`) + the kernel-load at boot | `file "$O"/bzImage` |
| `busybox-1_36_1/_install/` | `make install` | `assemble_rootfs` (`cp -a` → `filesystem/`) | `ls -R "$O"/busybox-1_36_1/_install` |
| `filesystem/` | `_install` + heredocs + fakeroot mknod | `rootfs.cpio.xz` (`cpio`) | `ls -la "$O"/filesystem` |
| `rootfs.cpio.xz` | `find \| cpio -H newc \| xz` (fakeroot) | the floppy + the initramfs-unpack at boot | `xz -dc "$O"/rootfs.cpio.xz \| cpio -itv` |
| `syslinux.cfg` | heredoc | syslinux at boot | `cat "$O"/syslinux.cfg` |
| `hello.txt` | heredoc | the floppy's `::/data` (→ `/home` at boot) | `cat "$O"/hello.txt` |
| `floppinux.img` | `mkdosfs`+`syslinux`+`mtools` | QEMU `-fda` / a real floppy | `mdir -i "$O"/floppinux.img ::` |

The build tree is big; the *outputs* are tiny — that contrast is the point:

```text
2.0G  linux/                 ← kernel source (throwaway after bzImage)
282M  i486-linux-musl-cross/ ← the cross compiler (gcc 11.2.1)
 33M  busybox-1_36_1/        ← userspace source
 884K bzImage                ← the kernel        ┐
 112K rootfs.cpio.xz         ← the userspace     ├─ the only three that matter
 180B syslinux.cfg           ← the boot config   ┘
 1.5M floppinux.img          ← all of the above, on a floppy
```

---

## 1. The cross toolchain — `i486-linux-musl-cross/`

One compiler builds *both* the kernel and BusyBox. It targets 32-bit i486 and
links against musl, which is why the userspace comes out so small.

```bash
"$O"/i486-linux-musl-cross/bin/i486-linux-musl-gcc --version | head -1
#  i486-linux-musl-gcc (GCC) 11.2.1 20211120
```

**Connects to:** nothing downstream directly — it's the tool, not a part. Note
the kernel is freestanding (never links libc), so a musl toolchain builds it
fine; reusing it for the kernel is what lets the whole build skip `gcc-multilib`.

## 2. The kernel config — `linux/.config`

This is where [`kernel.config-fragment`](kernel.config-fragment) lands. The
script runs `make tinyconfig` (a near-empty config), merges the fragment on top,
then `olddefconfig` to resolve dependencies.

```bash
grep -c '=y' "$O"/linux/.config
#  436                          ← a whole kernel in 436 enabled symbols

# the load-bearing ones the fragment forced on:
grep -E '^CONFIG_(M486|VGA_CONSOLE|RD_XZ|BLK_DEV_FD|MSDOS_FS|BINFMT_SCRIPT)=y' "$O"/linux/.config
#  CONFIG_BINFMT_SCRIPT=y   ← run rc (a #! script) as init
#  CONFIG_BLK_DEV_FD=y      ← /dev/fd0 exists for mdev to find
#  CONFIG_M486=y            ← 486DX floor
#  CONFIG_MSDOS_FS=y        ← mount the floppy's FAT
#  CONFIG_RD_XZ=y           ← unpack the xz initramfs
#  CONFIG_VGA_CONSOLE=y     ← console=tty0 has somewhere to draw
```

**Connects:** `kernel.config-fragment` (+ `tinyconfig`) → `.config` → `bzImage`.
Each `=y` here is a feature the next stage's `bzImage` will or won't have.

## 3. The kernel — `bzImage`

```bash
file "$O"/bzImage
#  Linux kernel x86 boot executable bzImage, version 6.14.11 (sqs@…),
#  RO-rootFS, Normal VGA
```

`file` reads the bzImage header back to you: **version 6.14.11**, **Normal VGA**
(that's `CONFIG_VGA_CONSOLE` from §2 showing up in the binary). 884 K — ~87% of
the finished floppy. If you ever want a *smaller* FLOPPINUX, this is the lever,
not the rootfs.

**Connects:** `linux/.config` → `bzImage` → copied onto the floppy as `::bzImage`
and loaded into RAM by syslinux at boot.

## 4. The userspace — `busybox-1_36_1/_install/`

One ~200 K static binary *is* every command, reached through symlinks.

```bash
file "$O"/busybox-1_36_1/_install/bin/busybox
#  ELF 32-bit LSB pie executable, Intel 80386, static-pie linked, stripped

ls "$O"/busybox-1_36_1/_install/bin "$O"/busybox-1_36_1/_install/sbin \
   "$O"/busybox-1_36_1/_install/usr/bin
#  bin:  ash cat cp df echo ln ls mkdir mount mv rm sh sync umount vi
#  sbin: halt init mdev
#  usr/bin: clear test
```

`static-pie linked` means **no shared libraries** — it runs in the initramfs
where no `.so` exists. Every name in those dirs is a symlink to the one
`busybox`; BusyBox dispatches on `argv[0]`.

**Connects:** busybox source + toolchain + curated applet list → `_install/` →
copied wholesale into `filesystem/`.

## 5. The staging rootfs — `filesystem/`

`assemble_rootfs` copies `_install/` here, then adds the parts BusyBox can't
provide: the boot scripts, the splash, and two device nodes.

```bash
ls -la "$O"/filesystem
#  bin/ sbin/ usr/ … plus: dev/ etc/ home/ mnt/ proc/ sys/ tmp/ welcome

cat "$O"/filesystem/etc/init.d/rc        # PID 1 at boot (see §8)
cat "$O"/filesystem/etc/inittab          # busybox-init job list (vestigial — see below)
```

The three hand-written files and their jobs:

| File | Bytes | Role |
|---|---|---|
| `etc/init.d/rc` | 235 | The boot script the kernel runs as PID 1 (`rdinit=`). |
| `etc/inittab` | 120 | A BusyBox-`init` job list — **unused at boot** (rdinit runs `rc` directly, not `/sbin/init`). |
| `welcome` | 548 | The ASCII splash `rc` `cat`s at the end. |

**Connects:** `_install/` + heredocs → `filesystem/` → `rootfs.cpio.xz`. The
device nodes (`dev/console`, `dev/null`) are made here under `fakeroot` so the
next step can record them — see §6.

## 6. The initramfs — `rootfs.cpio.xz`

`filesystem/` packed as a `newc` cpio, xz-compressed. This is Kenneth-Finnegan-
style "the rootfs IS the initramfs": there is no disk install.

```bash
xz -l "$O"/rootfs.cpio.xz
#  Compressed  Uncompressed  Ratio  Check
#   108.8 KiB     207.5 KiB  0.524  CRC32

xz -dc "$O"/rootfs.cpio.xz | cpio -itv | grep -E 'console|null|rc$|busybox$'
#  -rwxrwxr-x  root root    235 … etc/init.d/rc
#  -rwxr-xr-x  root root 206472 … bin/busybox
#  crw-rw-r--  root root  1,  3 … dev/null      ← char device, baked by fakeroot
#  crw-rw-r--  root root  5,  1 … dev/console   ← THIS is init's stdio at boot
```

That `dev/console` as char **5,1** is load-bearing: it's how PID 1 gets a
stdin/stdout before anything is mounted. Make it wrong and the VM boots to
"nothing." `fakeroot` is what let a non-root build record a char device.

**Connects:** `filesystem/` → `rootfs.cpio.xz` → copied onto the floppy as
`::rootfs.cpio.xz` and unpacked into a RAM disk by the kernel at boot.

## 7. The floppy — `floppinux.img`

A 1.44 MB FAT12 image that is **three things at once**: a bootloader medium, the
kernel/initramfs store, and a writable data disk. (Size is the one part that
varies — `FLOPPY_KB=2880` makes it a 2.88 MB ED image instead; see
[`floppinux-2.88mb/`](floppinux-2.88mb/). Everything below is size-independent.)

```bash
file "$O"/floppinux.img
#  DOS/MBR boot sector … OEM-ID "SYSLINUX" … sectors 2880 … FAT (12 bit) … label "FLOPPINUX"

mdir -i "$O"/floppinux.img ::
#  data         <DIR>
#  BZIMAGE         901632   bzImage
#  ROOTFS~1 XZ     111384   rootfs.cpio.xz       (8.3 short name; LFN is rootfs.cpio.xz)
#  syslinux cfg       180
#          264 192 bytes free                     ← matches upstream's "253 KiB free"

mdir -i "$O"/floppinux.img ::data
#  hello    txt        23                          ← becomes /home/hello.txt at boot

xxd -l 16 "$O"/floppinux.img | head -1
#  00000000: eb58 9053 5953 4c49 4e55 5800 …   .X.SYSLINUX…   ← jmp + "SYSLINUX" boot sector
```

The boot sector (`eb 58 90` = a jump, then `SYSLINUX`) is what `syslinux
--install` wrote; `ldlinux.sys` (a hidden system file) is the second-stage
loader. Notice the floppy holds **both** the boot payload (`bzImage`,
`rootfs.cpio.xz`, `syslinux.cfg`) **and** a `data/` directory — the same medium
the kernel boots from is the one `rc` later remounts as `/home`.

**Connects (inputs):** `bzImage` + `rootfs.cpio.xz` + `syslinux.cfg` +
`hello.txt` → `floppinux.img`. **Connects (output):** QEMU `-fda` or `dd` to a
real floppy.

---

## 8. The boot — how the artifacts re-connect at runtime

Building stacks the artifacts up; booting takes them apart in reverse. The glue
is one line — `syslinux.cfg`'s `APPEND`:

```
APPEND root=/dev/ram rdinit=/etc/init.d/rc console=tty0 tsc=unstable
```

```
floppinux.img
   │  BIOS reads the boot sector → ldlinux.sys (syslinux)
   ▼
syslinux  reads syslinux.cfg  →  loads ::bzImage + ::rootfs.cpio.xz into RAM
   ▼
bzImage   unpacks rootfs.cpio.xz into a RAM disk   (root=/dev/ram)
   ▼
kernel    runs rdinit=/etc/init.d/rc  AS PID 1     ← PID 1 is a shell SCRIPT
   ├─ mount -t proc /proc ; mount -t sysfs /sys
   ├─ mdev -s                         → scans /sys, creates /dev/fd0  (needs CONFIG_BLK_DEV_FD)
   ├─ mount -t msdos /dev/fd0 /mnt    → the floppy's OWN FAT area     (needs CONFIG_MSDOS_FS)
   ├─ mount --bind /mnt/data /home    → floppy data disk → /home
   ├─ cat welcome
   └─ /bin/sh                         → interactive ash
```

Each kernel `CONFIG` from §2 reappears here as a capability: `BINFMT_SCRIPT` runs
the `#!/bin/sh` rc, `RD_XZ` unpacks the cpio, `BLK_DEV_FD`+`MSDOS_FS` mount the
floppy, `VGA_CONSOLE` draws `console=tty0`. The real boot log shows it
(`Run /etc/init.d/rc as init process`, `Console: colour VGA+ 80x25`,
`/dev/fd0 on /mnt type msdos`) — captured in [`MANUAL_TESTING.md`](MANUAL_TESTING.md) §5.

> **Why exiting the shell panics.** `rc` ends with `/bin/sh`, *not* `exec
> /bin/sh`, so the shell is a child of PID 1 (`rc`). Type `exit` and `rc` runs
> off its last line, PID 1 dies, and the kernel panics (`Attempted to kill
> init!`). To leave cleanly, `/sbin/halt -f` instead. This is the same "shell as
> PID 1" lesson as [`../alpine-custom-init.TXT`](../alpine-custom-init.TXT).

## 9. Follow one byte end-to-end

Pick `hello.txt` and trace it through the whole pipeline:

1. **Born:** `make_floppy` writes `printf 'Hello, FLOPPINUX user!\n' > "$O"/hello.txt`.
2. **Onto the floppy:** `mcopy … "$O"/hello.txt ::data/hello.txt` → it's in the
   FAT `data/` dir (`mdir … ::data` shows `hello txt 23`).
3. **At boot:** `rc` runs `mount -t msdos /dev/fd0 /mnt` then `mount --bind
   /mnt/data /home`, so `/home/hello.txt` *is* `::data/hello.txt` on the physical
   medium.
4. **Read back:** in the booted VM, `cat /home/hello.txt` → `Hello, FLOPPINUX
   user!` (MANUAL_TESTING §6) — and because `/home` is the real floppy, anything
   you write there survives a reboot.

Do the same with `etc/init.d/rc` (heredoc → `filesystem/` → `cpio` → unpacked to
RAM → run as PID 1) and you've traced both halves of the graph.
