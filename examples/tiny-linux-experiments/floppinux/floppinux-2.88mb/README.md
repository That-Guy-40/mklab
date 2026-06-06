# FLOPPINUX on a 2.88 MB floppy (extended density)

The same FLOPPINUX, written to a **2.88 MB extended-density (ED)** floppy instead
of the standard 1.44 MB — ~6.5× the free space, and it still boots in QEMU. This
is a thin variant of the [parent lab](../README.md): identical kernel + BusyBox,
only the floppy geometry changes. It exists because the size is a one-knob change
(`FLOPPY_KB=2880`) and the extra room is genuinely useful.

## Build & boot

```bash
cd examples/tiny-linux-experiments/floppinux/floppinux-2.88mb
./build-2.88.sh build      # == FLOPPY_KB=2880 ../build-floppinux.sh build
./build-2.88.sh test       # headless serial boot
./build-2.88.sh boot       # faithful graphical boot
```

[`build-2.88.sh`](build-2.88.sh) is a 1-line wrapper that sets `FLOPPY_KB=2880`
and calls the parent `../build-floppinux.sh` — every subcommand
(`build`/`pack`/`boot`/`test`/`clean`) passes through. If you've already run the
parent `build`, just re-pack at the new size without recompiling:

```bash
./build-2.88.sh pack       # re-writes floppinux.img at 2.88 MB from existing bzImage/rootfs
```

> **One image, one size.** There is a single `~/.cache/lab-create/floppinux/floppinux.img`
> shared with the parent lab. Building here **replaces** it with the 2.88 MB
> image (the kernel and initramfs are size-independent, so only the floppy
> changes). Re-run the parent `./build-floppinux.sh pack` to go back to 1.44 MB.

## What's different from 1.44 MB

| | 1.44 MB (default) | **2.88 MB (here)** |
|---|---|---|
| Capacity | 1440 KiB / 2880 sectors | **2880 KiB / 5760 sectors** |
| Geometry | 80 cyl × 18 spt × 2 heads | **80 cyl × 36 spt × 2 heads** |
| FAT | FAT12, 1 sector/cluster | **FAT12, 2 sectors/cluster** |
| Free after install | ~264 KiB | **~1.69 MiB** (1,735,680 bytes) |
| `mkfs.fat -F 12` | auto-detects | **auto-detects** (no special flags) |
| QEMU `-fda` | `fd0 is 1.44M` | **`fd0 is 2.88M AMI BIOS`** |

Everything in the pipeline adapts to the larger size on its own: `mkfs.fat`
recognizes the 5760-sector image and writes the standard ED BPB (36 sectors/
track, 2 sectors/cluster to stay within FAT12's ~4084-cluster limit), `syslinux`
installs normally, `mtools` doesn't care, and QEMU auto-sizes drive A to 2.88 MB
from the image length.

## Fill the room: a full BusyBox (`BUSYBOX_FULL=1`)

The headline use for the extra space — **the whole BusyBox toolbox** instead of
the 1.44 MB build's ~20 curated commands:

```bash
BUSYBOX_FULL=1 ./build-2.88.sh build      # ~400 applets on a 2.88 MB floppy
```

> **Why a flag and not just symlinks?** BusyBox is one binary that dispatches on
> `argv[0]`, but it only contains the applets **compiled into it**. `ln -s
> busybox grep` then running `grep` just prints `grep: applet not found` — the
> code was never built in. `BUSYBOX_FULL=1` switches the build from
> `allnoconfig`+curated to **`make defconfig`** (BusyBox's full standard set),
> and `make install` then creates all ~400 symlinks for you. It's the *config*,
> not the symlinks, that enables an applet.

What you get and what to expect:

| | curated (default) | `BUSYBOX_FULL=1` |
|---|---|---|
| Applets | ~20 | **~400** (grep, sed, awk, find, tar, gzip, less, sort, cut, xargs, …) |
| `busybox` binary | ~206 KB | **~1 MB** (static) |
| Fits 1.44 MB? | yes | **no** — needs this 2.88 MB floppy |
| `tc` applet | n/a | dropped (`tc.c` doesn't build against musl) |

Two honest caveats:

- **Networking applets are inert.** `wget`, `ping`, `ifconfig`, `nc`, `telnet`
  etc. are compiled in, but the FLOPPINUX kernel is built with **no network
  stack** (no NIC, no TCP/IP), so they exist and fail at runtime. The file/text/
  archive/process utilities (grep/sed/awk/find/tar/gzip/ps/…) all work. Wiring up
  networking would mean enabling `CONFIG_NET`/`CONFIG_INET` + a NIC driver in
  `kernel.config-fragment` — out of scope here.
- **The compile is yours to run.** The full `defconfig` build is validated at the
  *config* level (it resolves to ~401 applets, static, `tc` dropped), but the
  actual musl cross-compile happens on your machine (the toolchain fetch is the
  one agent-gated step). If some applet beyond `tc` ever fails to build against
  musl, disable it the same way (`CONFIG_<X>=n`) and rebuild.

## Why bother — and the hardware caveat

The lever the extra ~1.45 MiB buys you:

- **A bigger kernel** — the 1.44 MB build spends 884 K of 1440 K on `bzImage`;
  at 2.88 MB you could enable more drivers/filesystems and still fit.
- **More userspace** — the full ~400-applet BusyBox fits here
  (`BUSYBOX_FULL=1`, see above) instead of the 1.44 MB build's ~20.
- **More `/data`** — the floppy's `data/` dir (mounted at `/home`) has space for
  real payloads.

⚠️ **2.88 MB ED drives and media are rare real hardware** (they existed on some
early-90s machines and NeXT/PS2 systems). In **QEMU/emulation it's rock-solid**,
which is where this lab lives. If you're targeting a *physical* floppy, 1.44 MB
is the safe universal choice. (The third size the parent knob supports, **1.68 MB
DMF**, is the opposite trade: it's a real-hardware `superformat` trick that does
**not** boot under QEMU — see the parent [`README.md`](../README.md) and
[`build-floppinux.sh`](../build-floppinux.sh)'s `FLOPPY_KB` note.)

## See also

- [`MANUAL_TESTING.md`](MANUAL_TESTING.md) — the differential test runbook for this variant.
- [`../README.md`](../README.md) — the full FLOPPINUX lab (build internals, boot mechanic, attribution).
- [`../ARTIFACTS.md`](../ARTIFACTS.md) — artifact map; only the final `floppinux.img` differs at 2.88 MB.
- [`../MANUAL_TESTING.md`](../MANUAL_TESTING.md) — the parent runbook; kernel/BusyBox/initramfs checks are size-independent.
