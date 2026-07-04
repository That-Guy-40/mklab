# Upstream & provenance — toybox-mkroot

This lab is a **driver** around toybox's own `make root` (mkroot). It follows the
repo's *cite-don't-mirror* rule for upstream code (the same posture as
[`../../kali-vm-builder/`](../../kali-vm-builder/) and
[`../../kali-packer-vagrant/`](../../kali-packer-vagrant/UPSTREAM.md)): nothing
upstream is vendored here — the driver fetches a **pinned** toybox at build time.

## toybox (the tool + the builder)

| | |
|---|---|
| **Project** | toybox — one BSD-licensed multicall binary + its `mkroot` system builder |
| **Author** | Rob Landley (former BusyBox maintainer) |
| **Upstream** | https://landley.net/toybox/ · mirror https://github.com/landley/toybox |
| **Pinned tag** | `0.8.13` (commit `a61f9fe68fafdabf2913b9498ce9ae1a086ed11d`) |
| **Released** | 2025-10 — recent enough to build clean on a 2026 host |
| **Retrieved** | 2026-07-04 |
| **License** | **0BSD** (zero-clause BSD — *"Permission to use, copy, modify, and/or distribute … with or without fee is hereby granted."*), i.e. public-domain-equivalent. `git rm` this lab to remove; nothing is vendored. |
| **Docs** | `make root` / mkroot: https://landley.net/toybox/faq.html#mkroot · about: https://landley.net/toybox/about.html |

We use it **unmodified**: `make defconfig && make` (the multicall binary) and
`make root [LINUX=… ] [CROSS=… ]` (the system builder). No patches — unlike the
retired [kali-packer](../../kali-packer-vagrant/) scripts, toybox is current and
needs none.

## Prebuilt mkroot binaries (the `--prebuilt <arch>` fast lane, dated not vendored)

| | |
|---|---|
| **Source** | https://landley.net/toybox/downloads/binaries/mkroot/latest/ |
| **Built from** | mkroot `0.8.13` + **Linux 6.17.0** (with patches in `linux-patches/`), musl-cross toolchains |
| **Retrieved** | 2026-07-04 |
| **`x86_64.tgz` sha256** | `f0da202e2a531b05192fdae2952495f75585c4e148c6ce28508aa66c9d1c8132` |
| **Arches (~22)** | aarch64 armv4l armv5l armv7l i486 i686 m68k microblaze mips mips64 mipsel or1k powerpc powerpc64 powerpc64le riscv32 riscv64 s390x sh2eb sh4 sh4eb x86_64 |

Each tarball is a self-contained `linux-kernel` + `initramfs.cpio.gz` +
`run-qemu.sh` + `docs/` (the three kernel configs). The driver downloads on
demand; the sha above is the copy verified here.

## Live data resolved at build time (dated, not vendored)

- **Linux kernel source** — fetched from
  `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-<ver>.tar.xz`. Verified
  here: **`linux-6.1.176.tar.xz`**, sha256
  `aa19772dba40e9737356c00d0671cdedbe26cc895eff062868f0a1f688ae44f6`. mkroot
  itself tracks mainline; the pin is just a version that reliably resolves on
  kernel.org in mid-2026 (see the EOL-pruning note in
  [MANUAL_TESTING.md](MANUAL_TESTING.md#gotchas)).
- **musl-cross `ccc/` toolchains** — for `--arch <foreign>`. Fetched **on your
  host** from
  [`toolchains/latest/`](https://landley.net/toybox/downloads/binaries/toolchains/latest/)
  as `<arch>-linux-musl-cross.tar.xz` (Landley's musl-cross-make builds; extract
  to `<arch>-*-cross/bin/<arch>-linux-musl-cc`, which is what `make root
  CROSS=<arch>` looks for under `ccc/`). **Author-run** — fetch+exec of a
  prebuilt toolchain is blocked for an agent by the repo's toolchain-fetch gate
  (empirically confirmed: the in-agent fetch+run of the sh4 toolchain was denied
  by the sandbox classifier). Source for the toolchains themselves:
  https://github.com/richfelker/musl-cross-make.

## Aboriginal Linux (cited as design ancestry, not operationalized)

The companion [LINEAGE-aboriginal.md](LINEAGE-aboriginal.md) draws on Landley's
earlier project. It is **cited, not built** (2015-era uClibc/autoconf bitrot):

| | |
|---|---|
| **Project** | Aboriginal Linux — "the simplest Linux system capable of compiling itself" |
| **Upstream** | https://landley.net/aboriginal/about.html · https://landley.net/aboriginal/FAQ.html · downloads https://landley.net/aboriginal/downloads/ |
| **Last release** | `aboriginal-1.4.5.tar.gz` (the 1.4.x line; active development wound down ~2016) |
| **Retrieved** | 2026-07-04 |
| **License** | GPLv2 (build scripts) wrapping GPL/BSD upstream packages |

Load-bearing quotes are reproduced inline in `LINEAGE-aboriginal.md` so the
lesson survives link-rot; whole doc sites are **not** mirrored.
