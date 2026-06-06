# FLOPPINUX — manual testing runbook

Test every stage of the build and the end-to-end boot, with the **real expected
output** captured from a verified run (Debian host, 2026-06-05, kernel 6.14.11 +
BusyBox 1.36.1). Each step says what to run and what "pass" looks like. To
*understand* the artifacts rather than test them, read
[`ARTIFACTS.md`](ARTIFACTS.md); to *use* the lab, read [`README.md`](README.md).

```bash
O=~/.cache/lab-create/floppinux        # build dir, used throughout
cd examples/tiny-linux-experiments/floppinux
```

> **One step is yours to run.** `build` downloads and executes a prebuilt
> cross-toolchain from `musl.cc` (exactly as the upstream HOWTO does). Every
> *other* step here — inspection, packing, booting — is local and needs no
> toolchain.

---

## §0 — Preflight (host deps)

```bash
sudo apt-get install -y build-essential bc bison flex wget xz-utils cpio \
    fakeroot dosfstools mtools syslinux qemu-system-x86
```

**Pass:** all install. `build-floppinux.sh` re-checks and prints the exact
missing line if anything's absent (it never auto-installs). `bison`/`flex` are
needed for the kernel's kconfig; `libssl-dev`/`libelf-dev` are *not* needed for
this no-module tinyconfig build (install them only if `make bzImage` ever
complains about `<openssl/*.h>` / `<libelf.h>`).

## §1 — Build end-to-end

```bash
./build-floppinux.sh build
```

This fetches the toolchain (~105 MB), clones the kernel (~260 MB), and compiles
both kernel and BusyBox. **Pass** = it ends with (sizes ≈):

```text
[floppinux] kernel .config verified (console + initrd + floppy + FAT symbols all set)
[floppinux] kernel: 884K → /home/.../bzImage
[floppinux] busybox: 204K self-contained, boot applets present
[floppinux] rootfs: 112K (/dev/console verified as char 5,1)
[floppinux] floppy ready: /home/.../floppinux.img
[floppinux] DONE. Boot it:  ./build-floppinux.sh boot     (graphical)
```

If it aborts, it aborts *early and loudly* (see §9) — by design, before the long
compile. Two harmless build warnings are expected: `reboot.S: … shift count out
of range` (32-bit realmode assembler quirk) and `usage.c: … ignoring return
value of 'write'` (a BusyBox `-Wunused-result`).

## §2 — Verify the kernel

```bash
file "$O"/bzImage
grep -c '=y' "$O"/linux/.config
```

**Pass:**

```text
…/bzImage: Linux kernel x86 boot executable bzImage, version 6.14.11 (…), RO-rootFS, Normal VGA
436
```

`version 6.14.11` and **`Normal VGA`** (the `console=tty0` console is compiled
in). The whole kernel is 436 enabled symbols. Spot-check the load-bearing ones:

```bash
grep -E '^CONFIG_(M486|VGA_CONSOLE|RD_XZ|BLK_DEV_FD|MSDOS_FS|BINFMT_SCRIPT|SERIAL_8250_CONSOLE)=y' "$O"/linux/.config
```

**Pass:** all seven print `=y`. (If any is missing, the build would already have
aborted at `verify_kconfig` — this is just confirming.)

## §3 — Verify BusyBox + the initramfs

```bash
file "$O"/busybox-1_36_1/_install/bin/busybox
xz -dc "$O"/rootfs.cpio.xz | cpio -itv 2>/dev/null | grep -E 'dev/(console|null)$'
```

**Pass:**

```text
…/busybox: ELF 32-bit LSB pie executable, Intel 80386, static-pie linked, stripped
crw-rw-r--   1 root root  1,  3 … dev/null
crw-rw-r--   1 root root  5,  1 … dev/console
```

`static-pie linked` (self-contained — runs with no libraries in the initramfs)
and `dev/console` is a char device **5,1** (PID 1's stdio). Confirm the curated
applet set:

```bash
ls "$O"/busybox-1_36_1/_install/bin "$O"/busybox-1_36_1/_install/sbin "$O"/busybox-1_36_1/_install/usr/bin
```

**Pass:** `bin:` ash cat cp df echo ln ls mkdir mount mv rm sh sync umount vi ·
`sbin:` halt init mdev · `usr/bin:` clear test. (No `grep`/`sed`/`uname` — that's
the point. `halt` is the clean-shutdown command.)

## §4 — Verify the floppy image

```bash
file "$O"/floppinux.img
mdir -i "$O"/floppinux.img ::
```

**Pass:**

```text
…/floppinux.img: DOS/MBR boot sector … OEM-ID "SYSLINUX" … sectors 2880 … FAT (12 bit) … label "FLOPPINUX"

 data         <DIR>
 BZIMAGE         901632   bzImage
 ROOTFS~1 XZ     111384   rootfs.cpio.xz
 syslinux cfg       180
         264 192 bytes free
```

`OEM-ID "SYSLINUX"` = the boot sector was installed; the three boot files are
present; `data/` holds the user disk; **264,192 bytes free** (upstream quotes
~253 KiB). `ROOTFS~1.XZ` is just the 8.3 short name — the long name
`rootfs.cpio.xz` is what `syslinux.cfg` references and what VFAT serves.

**Other floppy sizes — `FLOPPY_KB`.** The size is a one-knob change (only
`make_floppy` cares; bzImage/rootfs are size-independent). There is one shared
`floppinux.img`; a new size replaces it.

```bash
FLOPPY_KB=2880 ./build-floppinux.sh pack   # 2.88 MB ED → sectors 5760, 36 spt, ~1.7 MiB free, BOOTS
FLOPPY_KB=1680 ./build-floppinux.sh pack   # 1.68 MB DMF → sectors 3360, 21 spt; valid media, does NOT boot in QEMU (warns)
FLOPPY_KB=9999 ./build-floppinux.sh pack   # → dies: "FLOPPY_KB must be 1440, 1680, or 2880"
./build-floppinux.sh pack                  # back to the 1.44 MB default
```

**Pass:** each prints `building floppinux.img — <size> …`; `file "$O"/floppinux.img`
shows the matching `sectors` count; `1680` emits the 3-line "does NOT boot under
QEMU" warning. The 2.88 MB variant has its own runbook in
[`floppinux-2.88mb/MANUAL_TESTING.md`](floppinux-2.88mb/MANUAL_TESTING.md).

## §5 — Boot it (headless serial)

The quick way — interactive, you watch it boot and get a shell:

```bash
./build-floppinux.sh test         # serial console, -nographic. Quit: Ctrl-A then X
```

**Pass** = the kernel boots as a 486 and lands on the FLOPPINUX shell. Key lines
from a real run:

```text
Kernel command line: root=/dev/ram rdinit=/etc/init.d/rc console=ttyS0 tsc=unstable
tsc: Marking TSC unstable due to boot parameter
Console: colour VGA+ 80x25
printk: legacy console [ttyS0] enabled
CPU: Intel 486 DX/4 (family: 0x4, model: 0x8, stepping: 0x0)
Floppy drive(s): fd0 is 1.44M
Trying to unpack rootfs image as initramfs...
Freeing initrd memory: 112K
Run /etc/init.d/rc as init process
        … FLOPPINUX 0.3.1 splash …
BusyBox v1.36.1 (…) built-in shell (ash)
#
```

`Intel 486 DX/4`, `Console: colour VGA+ 80x25`, `Floppy … fd0 is 1.44M`, and
`Run /etc/init.d/rc as init process` are the four lines that prove the kernel
config, the boot mechanic, and the floppy hardware all came together.

> **Non-interactive capture** (optional, for CI / a saved transcript). Drives the
> shell with scripted input and powers off. It's a long line — save it as a
> scratch script rather than pasting:
> ```bash
> ( sleep 5; printf 'mount\ncat /home/hello.txt\n/sbin/halt -f\n' ) \
>   | timeout 90 qemu-system-i386 -kernel "$O"/bzImage -initrd "$O"/rootfs.cpio.xz \
>       -fda "$O"/floppinux.img -m 20M -cpu 486 -nographic -no-reboot \
>       -append 'root=/dev/ram rdinit=/etc/init.d/rc console=ttyS0 tsc=unstable'
> ```

The **faithful graphical** boot (needs a display) is the upstream command:

```bash
./build-floppinux.sh boot         # -fda, VGA, -cpu 486 -m 20M
```

## §6 — In-VM verification (at the `#` prompt)

Type these at the FLOPPINUX shell (from `test` or `boot`):

```sh
mount
cat /home/hello.txt
/sbin/halt -f
```

**Pass:**

```text
rootfs on / type rootfs (rw)
none on /proc type proc (rw,relatime)
none on /sys type sysfs (rw,relatime)
/dev/fd0 on /mnt type msdos (rw,relatime,fmask=0022,dmask=0022,codepage=437,errors=remount-ro)
/dev/fd0 on /home type msdos (rw,…)
Hello, FLOPPINUX user!
reboot: System halted
```

- `rootfs on / type rootfs` — root **is** the in-RAM initramfs (no disk).
- `/dev/fd0 on /mnt type msdos (…codepage=437…)` — `mdev` made `/dev/fd0` and the
  floppy's FAT mounted.
- `/dev/fd0 on /home` — the bind-mount; `cat /home/hello.txt` reads real data off
  the physical medium.
- `reboot: System halted` — `halt` halts the CPU (QEMU stays up). **Shutting
  down:** the QoL build makes `poweroff`/`reboot` shell functions that `sync` +
  unmount the floppy, then force — so bare **`poweroff`** powers off + exits QEMU
  (`BUSYBOX_FULL` only — applet + APM) and **`reboot`** resets → exits under
  `-no-reboot`. On a non-QoL build use `poweroff -f`/`reboot -f` (the bare forms
  no-op — init can't be signaled; see §9). Or press **`Ctrl-A` then `X`**.

Write something to `/home`, halt, and re-`test` — it persists, because `/home` is
the floppy.

## §7 — Both boot paths

Two independent ways the kernel can start; testing both isolates a kernel/rootfs
problem from a bootloader problem.

| Path | Command | Proves |
|---|---|---|
| **syslinux off the floppy** (faithful) | `./build-floppinux.sh boot` (or `test` for a serial variant — swap `console=tty0`→`ttyS0` in a copy of the image's `syslinux.cfg`) | BIOS → boot sector → `ldlinux.sys` → `syslinux.cfg` → kernel. |
| **direct kernel load** | the §5 capture command (`-kernel`/`-initrd`, no `-fda` needed for boot) | the kernel + initramfs + rc alone, bypassing the bootloader. |

Both were verified: SeaBIOS → syslinux → `Run /etc/init.d/rc as init process`,
and the direct path to the same shell.

## §8 — Resume & clean

```bash
./build-floppinux.sh pack      # re-pack rootfs + floppy from compiled artifacts (no toolchain, fast)
./build-floppinux.sh clean     # rm -rf the whole build dir
```

`pack` is the resume point: after a successful `build`, edit `rc`/`welcome`/the
applet list and re-`pack` (or rebuild BusyBox then `pack`) without re-fetching
the toolchain or recompiling the kernel. **Pass:** `pack` re-emits the
`rootfs: … (/dev/console verified …)` and `floppy ready` lines in seconds.

## §9 — Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `build` denied / `Permission … musl.cc` | An automated agent (not you) tried to fetch+exec the toolchain. | Run `./build-floppinux.sh build` yourself — it's your machine's call. |
| `kernel .config is missing required symbols: …` | A fragment symbol didn't stick (renamed in your kernel version). | The error names it; `make -C "$O"/linux ARCH=x86 menuconfig` to find the new name, update `kernel.config-fragment`. |
| `BusyBox applet 'X' missing from _install` | An applet was dropped at `oldconfig` (unmet dep). | Check `CONFIG_X`'s dependency: `make -C "$O"/busybox-1_36_1 menuconfig`. |
| `make bzImage` errors on `<openssl/*.h>`/`<libelf.h>` | Missing optional kernel build deps. | `sudo apt-get install libssl-dev libelf-dev`. |
| 32-bit kernel won't compile on amd64 | You dropped the cross toolchain and used host gcc. | Keep `CROSS_COMPILE` (the script's default), or `apt-get install gcc-multilib`. |
| Boots but blank screen on the **graphical** path | VGA console missing — only happens if you edited the fragment. | Ensure `CONFIG_VT`/`VT_CONSOLE`/`VGA_CONSOLE=y` (§2). |
| `poweroff: not found` / `uname: not found` at the shell | Not in the curated applet set (they're in `BUSYBOX_FULL`). | Use `/sbin/halt -f`; or add `POWEROFF REBOOT UNAME …` to the applet loop + rebuild. |
| Bare `poweroff` / `reboot` do nothing (prompt just returns) | The non-`-f` forms `kill(1, SIGUSR2/SIGTERM)` to ask BusyBox init to shut down, but init (PID 1) installs no handler for them and the kernel won't deliver `SIG_DFL` *fatal* signals to init — the signal queues (`/proc/1/status` `ShdPnd`) but is never dispatched. (`SIGCHLD` works → respawn works, because its default action is *ignore*.) | The QoL build replaces them with `poweroff()`/`reboot()` **functions** that `sync`+unmount the floppy then `-f`. On non-QoL builds use `poweroff -f`/`reboot -f`. Full diagnosis in `QUALITY_OF_LIFE.md`. |
| `poweroff -f` *still* halts (`Power off not available: halting system`) | APM (merged from `kernel-apm.config-fragment` for `BUSYBOX_FULL`) didn't engage — BIOS/APM detection. | `reboot -f` and `Ctrl-A X` always work. To debug APM, boot with the kernel cmdline `apm=power-off` (or `apm=on`); or swap APM for `CONFIG_ACPI=y` (bigger, QEMU-native). |
| `poweroff: not found` on a *curated* build | The curated set has no `poweroff` applet, and its kernel has no APM (kept faithful at 20 MB). | Use `reboot`/`Ctrl-A X`; or build with `BUSYBOX_FULL=1` for the applet + APM. |
| `FAT-fs (fd0): Volume was not properly unmounted` | A prior run was killed mid-mount (e.g. timeout). | Cosmetic; harmless. |
