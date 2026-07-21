# MANUAL_TESTING — exact commands + real success signatures

All transcripts below are from the verification host (Ubuntu 24.04,
qemu-system-x86_64 8.2.2, KVM available, rootless podman), 2026-07-21. Raw
spike logs live in `~/ofw-lab/` (`drive*.log`, `smoke-ofw-*.log`,
`showcase.log`).

## 1. Build both flavors (container)

```console
$ ./build-ofw.sh
==> building the build-box image (localhost/ofw-build)
==> configuring emu flavor: serial console ON, virtual-mode OFF
--- Saving as emuofw.rom - Binary ROM image format for emulator
==> /home/sqs/ofw-lab/openfirmware/cpu/x86/pc/emu/build/emuofw.rom
==> configuring biosload flavor for coreboot payload
--- Saving as ofwlb.elf - Coreboot payload format
==> /home/sqs/ofw-lab/openfirmware/cpu/x86/pc/biosload/build/ofwlb.elf
```

Success signature: both `Saving as …` lines. ~40 s cold, seconds warm. The
ROM/ELF sha256 changes every rebuild (build timestamp in the banner) — the
signature is the build log, not the hash. First run clones the tree
(github.com/openbios/openfirmware, ~29 MB) and pulls `docker.io/debian:13`.

## 2. Coreboot ROM (cached tree ≈ 1 min)

```console
$ ./build-coreboot-ofw.sh
==> isolated config/build (.config-ofw + build-ofw/) — default .config and build/ untouched
Built emulation/qemu-i440fx (QEMU x86 i440fx/piix4)
==> /home/sqs/linuxboot-lab/coreboot/build-ofw/coreboot.rom
```

Guard proof (the linuxboot lab's artifacts must survive):

```console
$ cd ~/linuxboot-lab/coreboot && sha256sum -c ~/ofw-lab/linuxboot-guard.sha
.config: OK
build/coreboot.rom: OK
```

## 3. Smokes — one verdict each

```console
$ ./smoke-ofw.sh emu
  - booting emu ROM (accel=kvm), driving the ok prompt → /home/sqs/ofw-lab/smoke-ofw-emu.log
PASS: OFW (emu) answered 7 at the ok prompt and listed the device tree

$ ./smoke-ofw.sh coreboot
  - booting coreboot ROM (accel=kvm), driving the ok prompt → /home/sqs/ofw-lab/smoke-ofw-coreboot.log
PASS: OFW (coreboot) answered 7 at the ok prompt and listed the device tree
```

Runtime ≈ 15–25 s each (the emu flavor spends ~10 s failing its default
netboot before prompting). SKIP (77) when the ROM, qemu, or python3 is absent.

## 4. The showcase — OFW boots Linux to u-root

```console
$ ./showcase-forth-to-boot.sh
  - booting emuofw.rom (accel=kvm), initrd=0xafedfc bytes → /home/sqs/ofw-lab/showcase.log
PASS: Forth to boot: OFW hand-staged the initrd and booted Linux to u-root
```

Key lines inside `showcase.log` (the full serial transcript):

```
ok load /pci/pci-ide@1,1/ide@1/cdrom@0:\uroot.img
ok loaded dup to /ramdisk h# 3d000000 swap move
ok h# 3d000000 to ramdisk-adr
ok boot /pci/pci-ide@1,1/ide@1/cdrom@0:\vmlinuz console=ttyS0 memmap=1023M@1M
Linux version 6.3.0 ...
RAMDISK: [mem 0x3d000000-0x3dafefff]
Run /init as init process
Welcome to u-root!
```

Needs `genisoimage` + a kernel/initrd pair (defaults:
`~/linuxboot-lab/urootcfg-bzImage` + `uroot.cpio`; override `KERNEL=`
`INITRD=`). ≈ 45 s under KVM.

## 5. Coreboot track: Linux by hand (the POC-3 recipe)

Stage a FAT16 disk, then type (or drive) at the coreboot-OFW prompt:

```console
$ truncate -s 64M ~/ofw-lab/disk.img && mkfs.vfat -F16 ~/ofw-lab/disk.img
$ mcopy -i ~/ofw-lab/disk.img ~/linuxboot-lab/payload-bzImage ::/VMLINUZ2
$ mcopy -i ~/ofw-lab/disk.img ~/linuxboot-lab/uroot.cpio ::/UROOT.IMG
$ ./run-ofw-qemu.sh coreboot
```

```
ok : my-dma h# 1000 mem-claim ;
ok ' my-dma to allocate-dma
ok 0 value ih
ok " /isa/ide@i1f0/disk@0:\uroot.img" open-dev to ih
ok h# 3d000000 h# afedfc " read" ih $call-method .
ok ih close-dev
ok : fix-zp h# ff h# 90210 c! h# 3d000000 h# 90218 l! h# afedfc h# 9021c l! ;
ok ' fix-zp to linux-hook
ok boot /isa/ide@i1f0/disk@0:\vmlinuz2 console=ttyS0 memmap=1023M@1M
```

Success signature (verified end-to-end, `~/ofw-lab/drive36.log`):

```
RAMDISK: [mem 0x3d000000-0x3dafefff]
Unpacking initramfs...
Run /init as init process
Welcome to u-root!
```

(`h# afedfc` = the byte size of *this* cpio — substitute `printf '%x\n'
$(stat -c %s <initrd>)`. Why each line exists: [POC-3](POC-3-COREBOOT-PAYLOAD.md).)

## 6. OpenBIOS teaser (zero build)

```console
$ qemu-system-ppc -nographic -vga none
>> OpenBIOS 1.1 [Apr 22 2026 09:24]
...
No valid state has been set by load or init-program

0 > 3 4 + . 7  ok
```

Ctrl-A X quits. Verified via a real pty (the pager lab's `drive-pager.py`).
This is now a full lab of its own:
[`../openbios-the-rival-that-shipped/`](../openbios-the-rival-that-shipped/README.md).

## Reproducer notes (the sharp edges, so you don't re-cut yourself)

- **The ok prompt is hex.** `5 6 * .` prints `1e`. Scripted checks must be
  base-agnostic (`3 4 + .` → `7`) or force `d#`/`decimal`.
- **Serial client must gate the guest**: launch QEMU with
  `-serial unix:…,server=on` and *leave wait on* — with `wait=off` the banner
  is emitted before the client connects and can never be matched.
- **Coreboot flavor eats the first post-prompt keystrokes** — send a bare
  `\r` settle first (baked into `smoke-ofw.sh`).
- **Slow-send always** (40 ms/byte — `tools/drive-serial-repl.py` default):
  firmware serial has no flow control.
- **Kill QEMU by PID**, never by pattern (house rule; the scripts comply).
- **`load` can overwrite the firmware itself** on the coreboot track
  (`load-base` 16 MB + big file reaches OFW's home at 25.5 MB; KVM dies with
  EIP inside overwritten firmware). Use small files with `load`, or the
  direct `open-dev`/`read`-to-address idiom from §5.
- **Timestamped builds**: `emuofw.rom` embeds the build time — byte-identical
  rebuilds are not expected.
- **OpenBIOS input quirk**: on `qemu-system-ppc`, console input works via the
  muxed stdio (`-nographic`) but not via a bare `-serial unix:` socket.
