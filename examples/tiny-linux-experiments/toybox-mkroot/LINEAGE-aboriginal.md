# Lineage: Aboriginal Linux — where `make root` came from

`mkroot` didn't appear from nowhere. Before toybox, the same author (Rob Landley)
spent ~2007–2016 on **[Aboriginal Linux](https://landley.net/aboriginal/about.html)**,
a build system with one deliberately extreme goal:

> **"build the simplest linux system capable of compiling itself."**
> — [about.html](https://landley.net/aboriginal/about.html)

Aboriginal is **cited here, not operationalized** — it's 2015-era uClibc +
autoconf + gcc 4.x, and reproducing it on a 2026 host is an archaeology project,
not a lab. But its *design opinions* are the "why" behind toybox and mkroot, and
they're worth stealing. This doc distills them. (Its last release is
[`aboriginal-1.4.5.tar.gz`](https://landley.net/aboriginal/downloads/); the
philosophy lives at [about.html](https://landley.net/aboriginal/about.html) and
the build mechanics at [FAQ.html](https://landley.net/aboriginal/FAQ.html).)

## The thesis: a system that can rebuild itself, from as little as possible

Aboriginal's boast was that the **entire** self-hosting system needs only
**seven source packages**:

> Linux, BusyBox, uClibc, binutils, GCC, make, and bash.

That's it — kernel, a C library, a toolchain, an implementation of `make`, a
shell, and BusyBox for everything else. From those seven you can boot a machine
that can compile those same seven (and then anything else). The number is the
*point*: it's a hard floor you can audit, and every package you'd add on top has
to justify itself against a system that already demonstrably works without it.

The guiding aesthetic is the project's motto, quoted straight on the about page:

> **"Perfection is achieved, not when there is nothing more to add, but when
> there is nothing left to take away."** *(Antoine de Saint-Exupéry)*

## The gem: cross-compile *only* far enough to stop cross-compiling

The deepest idea in Aboriginal is a reaction against cross-compilation. Landley's
position: **cross-compiling is a crutch that hides your real dependencies** — the
moment your build "works on my machine" because of some host tool you forgot you
relied on, reproducibility is a lie.

So Aboriginal cross-compiles the *minimum*: just enough of a toolchain to stand
up a **native build environment running inside QEMU**, and then does all further
building **natively, under emulation, on the target architecture itself**. The
emulated target compiles its own software. Cross-compilation is used once, to
escape cross-compilation forever. That is what "capable of compiling itself"
literally means — not a marketing line but the architecture.

This is exactly the seam you see in **mkroot** today:

```
make root CROSS=<arch> LINUX=<kernel-src>
#          └── cross-toolchain      └── kernel to build natively-ish for the target
```

`CROSS=` is the "escape cross-compilation" toolchain; `LINUX=` is the target's own
kernel. mkroot compresses Aboriginal's staged pipeline into one Makefile target,
but it's the same two-part shape.

## Orthogonal layers: each stage runs, and is replaceable, on its own

Aboriginal is a set of bash scripts that `build.sh` runs in order — but each is
independently runnable and independently swappable:

| Aboriginal stage | Does | mkroot's equivalent |
|---|---|---|
| `download.sh` | fetch + checksum every source tarball | the driver's `curl` of toybox/kernel |
| `host-tools.sh` | build a controlled set of host tools | (mkroot leans on your host toolchain) |
| `cross-compiler.sh` | build the target cross-compiler | `CROSS=` / the `ccc/` toolchains |
| `root-filesystem.sh` | assemble the target rootfs (BusyBox + uClibc) | `make root` packs the toybox initramfs |
| `system-image.sh` | wrap kernel + rootfs into a bootable image | `make root LINUX=` → `linux-kernel` + `initramfs.cpio.gz` |
| `run-emulator.sh` | boot it under QEMU | the generated `run-qemu.sh` |

> **"The file build.sh calls the rest of these scripts in order (but you can call
> 'em directly too)."** — [FAQ.html](https://landley.net/aboriginal/FAQ.html)

The design value: **readable bash as executable documentation**. You can read one
layer without the others, run it in isolation, or replace it wholesale. mkroot
inherits the spirit — `mkroot/mkroot.sh` is a single readable shell script you can
follow top to bottom.

## The gotcha worth internalizing: control the host, or the host controls you

Aboriginal ships a `host-tools.sh` step that builds a clean set of tools to build
*with*, and the FAQ warns:

> **"Even though host-tools.sh is technically an optional step, your host has to
> be carefully set up to work without it."**

The lesson generalizes far beyond Aboriginal: **an uncontrolled host is an
invisible dependency.** Every "it built fine for me" that fails elsewhere traces
to some host tool, version, or environment variable that was never declared. This
is the same instinct behind this repo's containerized `hand-walk/` sandboxes and
its toolchain-fetch gate — pin and declare what you build *with*, not just what
you build.

## What changed between Aboriginal and toybox/mkroot

| | Aboriginal (2007–2016) | toybox + mkroot (current) |
|---|---|---|
| Userspace | **BusyBox** | **toybox** (Landley's clean-license rewrite) |
| C library | **uClibc** | **musl** (via musl-cross-make `ccc/`) |
| Builder | staged bash scripts (`build.sh` → 6 stages) | one Makefile target (`make root`) |
| License goal | GPL stack | **0BSD** toybox (ships in Android) |
| Status | archived, ~2016 | actively maintained |

Same north star — *the simplest system that can rebuild itself* — thirty years of
Landley refining what "simplest" costs. Booting the toybox system next door
([README.md](README.md)) is booting the great-grandchild of Aboriginal's idea.

## If you want to dig into the original

```bash
# Reading the source is the point — it's documentation. (Fetch only; it won't
# build cleanly on a modern host — uClibc/gcc-4.x bitrot.)
curl -fSLO https://landley.net/aboriginal/downloads/aboriginal-1.4.5.tar.gz
tar tzf aboriginal-1.4.5.tar.gz | grep -E 'sources/(more|toys)/|/build\.sh|host-tools\.sh'
```

Start with `build.sh` (the conductor) and `sources/toys/` (the per-package
recipes). Read it for the opinions, not to run it.
