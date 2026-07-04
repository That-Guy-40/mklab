# toybox + mkroot — the *other* multicall binary, and the distro it builds

[**toybox**](https://landley.net/toybox/) is Rob Landley's single BSD-licensed
multicall binary — one ~450 KB executable that *is* `sed`, `grep`, `tar`, `sh`,
`sha256sum`, and ~235 other commands, chosen by the first argument (`toybox sed …`,
or via a `sed → toybox` symlink). It's the same trick BusyBox plays, by the same
person who used to maintain BusyBox — rewritten from scratch under a permissive
licence so Android could ship it (which it does: toybox is in every Android
phone).

What makes it a *lab* and not just a binary is **mkroot** — toybox's built-in
tiny-distro builder (`make root`). Point it at a Linux kernel source tree and it
bakes a **kernel + a toybox `initramfs.cpio.gz` + a `run-qemu.sh` wrapper** into
a complete Linux system that boots to a shell under QEMU. That makes toybox the
direct sibling of this dir's other from-source micro-distros:

| Lab | Userspace | Builder | Boots |
|---|---|---|---|
| [`floppinux/`](../floppinux/) | **BusyBox** (static) | hand-rolled `build-floppinux.sh` | `-fda` floppy |
| [`../micro-linux/`](../../../micro-linux/) | **BusyBox** / u-root | `mlbuild.sh` | `-kernel/-initrd` |
| **`toybox-mkroot/`** (this) | **toybox** (static) | **toybox's own `make root`** | `-kernel/-initrd` |

The teaching point: floppinux and micro-linux *assemble* a userspace around
BusyBox with a script we wrote; toybox **ships the builder itself**. `make root`
is the whole "simplest Linux that compiles itself" idea distilled into one
Makefile target — a lineage that runs straight back to Landley's
[**Aboriginal Linux**](LINEAGE-aboriginal.md) (2007–2016), the subject of the
companion doc.

> **Was it going to compile?** Yes — cleanly. toybox `0.8.13` (Oct 2025) builds
> with zero errors on a 2026 Ubuntu host, and mkroot's x86_64 kernel miniconfig
> built a bootable kernel on Linux 6.1.176 in ~20 s. "Just over a year old" was
> exactly right: recent enough that nothing has bit-rotted. See
> [MANUAL_TESTING.md](MANUAL_TESTING.md) for the verified transcript.

## Quick start

```bash
# just the multicall binary + its applet list (seconds, no kernel, no QEMU):
./build-toybox-mkroot.sh --binary

# a FULLY from-source bootable toybox system for this machine, then boot it:
./build-toybox-mkroot.sh                       # ~30 s on KVM → a toybox shell; 'exit' powers off

# boot a foreign architecture with zero toolchain (the fast lane):
./build-toybox-mkroot.sh --prebuilt aarch64    # or riscv64, s390x, m68k, sh4, … (~22 arches)

# non-interactive smoke check (drives the shell, asserts a marker):
./build-toybox-mkroot.sh --smoke
```

Rootless. Everything lands under `~/toybox-mkroot-build` (override with
`--workdir`), **outside** this repo. Login is just a root shell — no password,
no getty (it's an initramfs, PID 1 is a shell).

## Three build modes (and one gate)

`build-toybox-mkroot.sh` fetches a pinned toybox (`0.8.13`), builds the multicall
binary (`make defconfig && make`), then does one of:

1. **Native, fully from source (default).** `make root LINUX=<kernel-src>` for the
   **host architecture** uses your **own gcc** — no cross-compiler, nothing
   fetched but the kernel tarball. This is the headline and it's **verified here
   end-to-end**: toybox + a kernel *you* compiled, booted in QEMU.
2. **Rootfs-only** (`--rootfs-only`). `make root` with no `LINUX=` builds just the
   toybox `initramfs.cpio.gz` (static toybox, ~240 commands) — boot it on any
   kernel. Good for seeing the userspace without a kernel compile.
3. **Prebuilt, any architecture** (`--prebuilt <arch>`). Landley publishes
   ready-built mkroot images for ~22 CPU families
   ([binaries/mkroot/latest/](https://landley.net/toybox/downloads/binaries/mkroot/latest/)).
   The script downloads one and runs its `run-qemu.sh` — **no toolchain, no
   compile**, boots aarch64 / mips / riscv / s390x / m68k / sh4 / … under TCG.

**The gate:** cross-compiling from source for a *foreign* arch (`--arch <arch>`)
needs a musl-cross **`ccc/`** toolchain, and fetch+exec of a third-party prebuilt
toolchain is **author-run** in this repo (the
[toolchain-fetch gate](../../../CLAUDE.md)) — an *agent* must hand it to you; on
**your** host it's fully turnkey. `--arch <arch>` **auto-fetches** Landley's
prebuilt toolchain into `ccc/`, runs `make root CROSS=<arch> LINUX=…`, and boots
the result under **TCG** (foreign CPU → no KVM, so it's slow but real).
`--no-fetch-toolchain` uses an existing `ccc/` instead; `--prebuilt <arch>`
skips the toolchain entirely. Native host-arch builds (mode 1) never touch the
gate.

### A retro-silicon tour (`--arch <arch>`)

mkroot boots each target on a *real emulated board* — so `--arch` is a museum of
CPUs you've probably used without knowing:

| `--arch` | Chip | mkroot boots it on | You'll recognise it from |
|---|---|---|---|
| `sh4` | Hitachi/Renesas **SuperH-4** | QEMU SH4 `r2d` | the **Sega Dreamcast** |
| `sh4eb` | big-endian SuperH | " (big-endian) | the **Sega Saturn** ran dual big-endian SH-2 |
| `m68k` | Motorola **68040** | QEMU **`-M q800`** | a **Macintosh Quadra 800** (1993); also Genesis/Amiga/Atari ST |
| `mips` | **MIPS** | QEMU `malta` | **PlayStation 1/2, N64, PSP** (and every old router) |
| `or1k` | **OpenRISC 1000** | QEMU `virt` | a *fully open* ISA, years before RISC-V |
| `powerpc` | **PowerPC** | QEMU **`-M g3beige`** | a beige **Power Mac G3** (1997) |
| `s390x` | IBM **Z** | QEMU `s390-ccw` | a **mainframe** — the anti-console |

```bash
./build-toybox-mkroot.sh --arch sh4        # Dreamcast SuperH, from source, booted under TCG
./build-toybox-mkroot.sh --arch m68k       # → QEMU emulates a 1993 Macintosh
./build-toybox-mkroot.sh --arch mips       # needs: apt install qemu-system-mips
```

You need the matching `qemu-system-<arch>` (`qemu-system-sh4`, `-m68k`, `-or1k`
are in `qemu-system-misc`; `mips`/`ppc` in `qemu-system-mips`/`-ppc`). Each build
grabs a ~40–70 MB toolchain once, compiles a target kernel + toybox, and drops
you at a toybox shell running on emulated vintage hardware. `exit` powers it off.

> **✓ Verified: `--arch m68k`** cross-built (Landley's `gcc 15.1`) a 6.1.176
> kernel + toybox and booted on QEMU `q800` — the kernel prints `Apple Macintosh
> Quadra 800` and probes the real Mac silicon (`mac_esp` SCSI, `SONIC` Ethernet,
> `Z85c30 ESCC` serial) before dropping to a toybox root shell. Full transcript in
> [MANUAL_TESTING.md §5](MANUAL_TESTING.md#5-cross-from-source-a-foreign-arch-compiled-and-booted-author-run).

> ### ⚠️ Never pass `-j` to `make root`
> mkroot's `mkroot.sh` does its own parallelism; make's `-j`/`--jobserver-auth`
> flags leak into *its* argument parser and it dies (`source: -j: invalid
> option`). The script deliberately calls `make root` **without** `-j`. This bit
> us once — see [MANUAL_TESTING.md](MANUAL_TESTING.md#gotchas).

## What you get, and how to poke it

```bash
WORK=~/toybox-mkroot-build
$WORK/toybox/toybox                      # list every applet
$WORK/toybox/toybox sed --help           # any applet's help
$WORK/toybox/root/host/run-qemu.sh       # boot the from-source image by hand
$WORK/toybox/root/host/run-qemu.sh -hda root/host/docs/linux-fullconfig  # attach a disk
```

Inside the booted system, `KARGS=quiet ./run-qemu.sh` quiets the kernel; the
`docs/` dir carries the three kernel configs mkroot layers (`linux-miniconfig` →
`linux-microconfig` → `linux-fullconfig`) so you can see exactly what got turned
on.

## Files

| File | What |
|---|---|
| [`build-toybox-mkroot.sh`](build-toybox-mkroot.sh) | The rootless driver — binary / rootfs / full-image / prebuilt / cross modes, `--smoke`. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Preflight → build → boot runbook + the verified transcript + gotchas. |
| [`UPSTREAM.md`](UPSTREAM.md) | Provenance (toybox pin, the prebuilt binaries, the kernel), cite-don't-mirror. |
| [`LINEAGE-aboriginal.md`](LINEAGE-aboriginal.md) | Where `make root` came from — Landley's **Aboriginal Linux** distilled: the "simplest system that compiles itself", its 7-package bootstrap, and the design opinions worth stealing. |

## ⚠️ Security

A **throwaway** in-RAM system: PID 1 is a root shell, no password, no auth,
networking off. Fine under QEMU user-mode NAT; don't bridge it anywhere real.
It exists to be booted and thrown away.
