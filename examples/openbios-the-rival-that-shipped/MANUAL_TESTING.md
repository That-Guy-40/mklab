# MANUAL_TESTING — exact commands + real success signatures

All transcripts below are from the verification host (Ubuntu 24.04,
qemu-system-x86_64/-ppc 8.2.2, KVM available, rootless podman), 2026-07-21.
Raw spike logs live in `~/openbios-lab/` (`drive*.log`, `smoke-*.log`,
`showcase-*.log`, `build-*.log`).

## 1. Build all targets (container)

```console
$ ./build-openbios.sh
==> applying the revival patch (idempotent)
    applied
==> building the build-box image (localhost/openbios-build)
Building OpenBIOS for x86 ... ok.
Building OpenBIOS for ppc amd64 ... ok.
==> artifacts:
/home/sqs/openbios-lab/openbios/obj-amd64/openbios-unix
/home/sqs/openbios-lab/openbios/obj-ppc/openbios-qemu.elf
/home/sqs/openbios-lab/openbios/obj-x86/openbios-builtin.elf
/home/sqs/openbios-lab/openbios/obj-x86/openbios.dict
/home/sqs/openbios-lab/openbios/obj-x86/openbios.multiboot
```

Success signature: five artifact paths listed. ~2 min cold (clones openbios +
fcode-utils, pulls debian:13, builds toke), seconds warm. Re-running prints
`already applied` — the patch step is idempotent (applies, or verifies it
reverses, or errors if the tree diverged).

## 2. Coreboot ROM (cached tree ≈ 1 min)

```console
$ ./build-coreboot-openbios.sh
==> wrote guard /home/sqs/openbios-lab/coreboot-guard.sha
==> isolated config/build (.config-openbios + build-openbios/) — sibling artifacts untouched
Built emulation/qemu-i440fx (QEMU x86 i440fx/piix4)
==> guard check:
.config: OK
build/coreboot.rom: OK
.config-ofw: OK
build-ofw/coreboot.rom: OK
==> /home/sqs/linuxboot-lab/coreboot/build-openbios/coreboot.rom
```

The guard proves BOTH sibling labs' kept coreboot artifacts (linuxboot's
`.config`/`build/coreboot.rom` and the OFW lab's `.config-ofw`/
`build-ofw/coreboot.rom`) survive our isolated third build.

## 3. Smokes — one verdict each

```console
$ ./smoke-openbios.sh multiboot
  - booting multiboot (accel=kvm), driving the 0 > prompt → .../smoke-openbios-multiboot.log
PASS: OpenBIOS (multiboot) answered 7 at the 0 > prompt and listed the device tree

$ ./smoke-openbios.sh coreboot
PASS: OpenBIOS (coreboot) answered 7 at the 0 > prompt and listed the device tree

$ ./smoke-openbios.sh ppc
  - banner: OpenBIOS built on Jul 21 2026 07:09
  - distro blob: built on Apr 22 2026 09:24 — different, so the running firmware is OURS
PASS: our own openbios-ppc (built on Jul 21 2026 07:09) answered 7 at the 0 > prompt
```

Runtime ≈ 15–30 s each. SKIP (77) when the image, qemu, or python3 is absent.

## 4. The showcase — OpenBIOS boots Linux to u-root

```console
$ ./showcase-rival-boots-linux.sh            # multiboot track (default)
  - booting multiboot (accel=kvm), one boot line at the prompt → .../showcase-multiboot.log
PASS: the rival boots Linux: OpenBIOS (multiboot) loaded kernel+initrd and reached u-root

$ ./showcase-rival-boots-linux.sh coreboot   # same one-liner, through coreboot
PASS: the rival boots Linux: OpenBIOS (coreboot) loaded kernel+initrd and reached u-root
```

Key lines inside `showcase-multiboot.log` (the full serial transcript):

```
0 > boot /ide@1/cdrom@0:\vmlinuz console=ttyS0 initrd=/ide@1/cdrom@0:\uroot.img
[x86] Booting file '/ide@1/cdrom@0:\vmlinuz' with parameters 'console=ttyS0 initrd=...'
Found Linux version 6.3.0 ... (protocol 0x20f) (loadflags 0x1) bzImage.
Loading kernel... ok
Loading initrd... ok
Jumping to entry point...
Linux version 6.3.0 (coreboot@reproducible) ...
RAMDISK: [mem 0x1f296000-0x1fd94fff]
Run /init as init process
2026/07/21 07:18:27 Welcome to u-root!
```

Contrast with the OFW lab's showcase: **no** `memmap=`, **no** hand-staged
initrd, **no** zero-page poke — `initrd=` is parsed by the firmware, the
memory map is real, the zero page is built in C. The difference is the whole
point (POC-4). Needs `genisoimage` + a kernel/initrd pair (defaults:
`~/linuxboot-lab/payload-bzImage` + `uroot.cpio`; override `KERNEL=`/
`INITRD=`). ≈ 30–45 s under KVM.

## 5. The firmware as a Unix process (no QEMU)

```console
$ cd ~/openbios-lab/openbios
$ printf '3 4 + .\nbye\n' | obj-amd64/openbios-unix obj-amd64/openbios-unix.dict
0 > 3 4 + . 7  ok
0 > bye
Farewell!
```

The same IEEE 1275 Forth engine, running as your user with no emulator at all
— OpenBIOS's C-hosted design makes this possible; the frozen OFW rival (pure
self-hosting Forth) has no equivalent.

## 6. Interactive & the ppc swap-in

```console
$ ./run-openbios-qemu.sh              # multiboot, 0 > on this terminal (Ctrl-A X quits)
$ ./run-openbios-qemu.sh coreboot     # coreboot → OpenBIOS
$ ./run-openbios-qemu.sh ppc          # OUR openbios-ppc via -bios (-nographic)
0 > 3 4 + . 7  ok
```

## Reproducer notes (the sharp edges)

- **The prompt is `0 > `** (the number is the stack DEPTH), banner "Welcome to
  OpenBIOS". Different anchors than OFW's `ok`.
- **x86 banner goes to the VGA path** on the multiboot track — over serial the
  boot ends at a bare `0 > `. Anchor expects on the prompt, not the banner.
  (The coreboot track *does* echo the banner to serial — anchor on `0 > `
  either way.)
- **ppc console input needs muxed stdio** (`-nographic`), NOT a `-serial
  unix:` socket — use `tools/drive-pty-repl.py` (this lab's extracted tool).
- **Device paths:** `:\file` (backslash) is a filename; `:/file` is a node
  path. `genisoimage -r` lowercases (`VMLINUZ`→`vmlinuz`).
- **Boot line ≤ ~80 chars** — the firmware input buffer drops the tail
  silently (the showcase line is exactly 78).
- **Serial client must gate the guest**: `-serial unix:…,server=on` with wait
  ON, so the banner isn't emitted before the client connects.
- **Slow-send always** (40 ms/byte — both drive tools' default): firmware
  serial has no flow control.
- **Kill QEMU by PID**, never by pattern (house rule; the scripts comply).
- **A triple fault under `-no-reboot` looks like a clean rc=0 exit** — check
  the log for a prompt, don't trust the exit code. KVM's "internal error" is
  the louder failure mode.
- **Timestamped builds**: the banner embeds `__DATE__`/`__TIME__` — that's the
  ppc swap-in's proof (§3), so byte-identical rebuilds are not expected.
