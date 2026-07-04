# toybox-mkroot — build + boot runbook

Every mode below was **verified here on KVM (2026-07-04)** — toybox `0.8.13`,
Linux `6.1.176`, QEMU on an x86_64 Ubuntu host. Transcript + gotchas at the
bottom.

> Run from this directory. Artifacts land in `$WORKDIR`
> (default `~/toybox-mkroot-build`) — outside the repo.

## 0. Preflight

```bash
command -v git make gcc curl qemu-system-x86_64 || echo "install: git build-essential curl qemu-system-x86"
# kernel-build prereqs (mkroot compiles a tiny kernel):
for p in flex bison bc libelf-dev libssl-dev; do dpkg -s "$p" >/dev/null 2>&1 && echo "ok $p" || echo "MISS $p (apt install $p)"; done
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM ok" || echo "no KVM — boots fall back to slow TCG"
```

## 1. Just the multicall binary (seconds — verified ✓)

```bash
./build-toybox-mkroot.sh --binary
```

Expect:

```text
[toybox] toybox @ 0.8.13
[toybox] make defconfig && make  (the multicall binary)
[toybox] built 448K multicall binary — 238 applets
  sample: toybox echo works
  sample: 49e2e07c…  -
```

That single 448 KB binary is `sed`, `grep`, `tar`, `sh`, and 234 more. Poke it:

```bash
~/toybox-mkroot-build/toybox/toybox                 # list applets
~/toybox-mkroot-build/toybox/toybox sed --help
```

## 2. A fully from-source bootable system (~30 s on KVM — verified ✓)

```bash
./build-toybox-mkroot.sh                            # or add --smoke for non-interactive
```

This builds the binary, fetches the kernel source, runs `make root LINUX=…` with
your **host gcc** (no cross-compiler), and boots the result. You land at a toybox
shell; type `exit` to power the VM off. `--smoke` instead drives the shell and
asserts a marker:

```text
[toybox] make root LINUX=/home/you/toybox-mkroot-build/linux-6.1.176
[toybox] from-source image: …/root/host  (kernel version 6.1.176)
[toybox] booting: …/root/host/run-qemu.sh  (accel=kvm, 256M) — type 'exit' to power off
Linux version 6.1.176 (you@host) (gcc (Ubuntu 13.3.0…)) #1 …
$ toybox 0.8.13
$ Linux 6.1.176 x86_64
$ TOYBOX_MKROOT_SMOKE_OK
$ commands: 210
[toybox] SMOKE OK — booted to a toybox shell
```

> **Kernel version.** Default is `--kernel 6.1.176` (a current longterm — the
> tarball that reliably resolves on kernel.org today). mkroot itself tracks
> **mainline** (its published binaries used 6.17.0); any recent kernel works —
> pass `--kernel <ver>`. If a version 404s it's been **EOL-pruned** from
> kernel.org; pick a current longterm from
> [kernel.org/releases.json](https://www.kernel.org/releases.json).

## 3. Any architecture, no toolchain (the fast lane — verified x86_64 ✓)

```bash
./build-toybox-mkroot.sh --list-arches              # ~22 CPU families
./build-toybox-mkroot.sh --prebuilt aarch64         # download Landley's image, boot under TCG
./build-toybox-mkroot.sh --prebuilt x86_64 --smoke  # verified here
```

Verified (`--prebuilt x86_64 --smoke`): booted **toybox 0.8.13 on Linux 6.17.0**
(Landley's musl-built kernel), 422 command symlinks, clean shutdown. Foreign
arches boot the same way under TCG — you just need the matching
`qemu-system-<arch>` installed (`apt install qemu-system-arm qemu-system-misc …`).

## 4. Rootfs-only, and cross-from-source

```bash
./build-toybox-mkroot.sh --rootfs-only              # from-source initramfs, no kernel compile
./build-toybox-mkroot.sh --arch sh4                 # cross-from-source (author-run; see below)
```

`--arch <arch>` is **author-run** — it needs the musl-cross-make `ccc/`
toolchains, whose fetch+exec is gated in this repo. The script prints the exact
`make root CROSS=<arch> LINUX=… ` command and where to get the toolchains, or
you can just use `--prebuilt <arch>`.

---

## What was verified here (2026-07-04)

| # | Check | Result |
|---|---|---|
| 1 | `--binary` | toybox `0.8.13`, **238 applets**, 448 KB, builds clean (only `-Wunused-result` warnings) on Ubuntu gcc 13.3 |
| 2 | `make root` (native, no `LINUX=`) | from-source `initramfs.cpio.gz` (963 KB); `usr/bin/toybox` a **static ELF**, 246 command symlinks |
| 3 | that initramfs on the prebuilt kernel | booted to a toybox shell (`FROM_SOURCE_ROOTFS_OK`) |
| 4 | **default: `make root LINUX=6.1.176`** | a **bzImage 6.1.176 I compiled** + toybox initramfs → **booted to a toybox shell**, 210 commands, clean `reboot: Restarting system` |
| 5 | `--prebuilt x86_64 --smoke` | Landley's image booted: toybox `0.8.13` / **Linux 6.17.0**, 422 cmd-links |
| 6 | script plumbing | `bash -n` clean; `--binary`, default `--smoke`, `--prebuilt … --smoke` all green; `--list-arches`/`--help` render; unknown-arg dies cleanly |

The `make root LINUX=` kernel compile took **~20 s** (it's a tiny miniconfig
kernel, not a full distro kernel), so the whole from-source path — clone, build
binary, compile kernel, boot — is well under a minute on KVM.

## Gotchas

- **Never pass `-j` to `make root`.** mkroot self-parallelizes; make's
  `-j32 --jobserver-auth=3,4` leak into `mkroot.sh`'s own arg parser, which
  chokes: `export: --: invalid option` / `source: -j: invalid option` →
  `make: *** [Makefile:94: root] Error 1`. The driver calls `make root` with no
  `-j`. (First thing that bit us.)
- **Kernel tarballs get EOL-pruned.** mkroot's binaries were built on **6.17.0**,
  but by mid-2026 6.17 (and 6.6/6.12/6.18 point releases on some mirrors) 404 on
  kernel.org — only current longterm trees stay published. The default pins a
  longterm (**6.1.176**) that resolves; `--kernel` overrides. mkroot's x86_64
  miniconfig is forward/backward-tolerant enough that 6.1 builds a bootable
  kernel with no edits.
- **First keystroke gets eaten.** Piping commands into the serial console can
  land the *first* line before the shell prints its prompt (`sh: …: No such file
  or directory`). Harmless — the `--smoke` driver sends a sacrificial `# warmup`
  line first. When driving `run-qemu.sh` by hand, just wait for the `$` prompt.
- **`run-qemu.sh` is `-nographic console=ttyS0 -no-reboot`.** The shell *is* the
  serial console; `exit` (or `reboot`/`poweroff`) stops QEMU. Extra args pass
  through to QEMU, `KARGS=…` appends kernel args (`KARGS=quiet`).
- **It's an initramfs, so there's no login.** PID 1 is a shell running as root —
  no getty, no password. That's expected for a mkroot system.
