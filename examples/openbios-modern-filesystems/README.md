# OpenBIOS reads a modern filesystem — the `grub2fs` read shim (and the in-place-write endgame)

OpenBIOS (the IEEE 1275 firmware that ships in QEMU) mounts filesystems through a
**vendored GRUB 0.97** (`fs/grubfs/`). 0.97 predates ext4, so a modern `mke2fs`
image reads as `File not found`. This lab lifts GRUB **2**'s filesystem drivers into
OpenBIOS as a new `/packages/grub2fs`, so the firmware can read ext4 / FAT / ISO 9660
made by a current tool — and then turns the toolkit's existing **same-length in-place
editors** (`cpio-edit.fth`, `pe-edit.fth`) onto a file that lives on a real block
filesystem, modifying it in place at the firmware prompt with no USB stick and no
chroot.

**The full design and rationale live in the plan:**
[`DESIGN-NOTES-modern-filesystems-for-a-frozen-firmware.md`](../../DESIGN-NOTES-modern-filesystems-for-a-frozen-firmware.md).
This lab operationalizes it. It is a sibling of, and composes with, the OpenBIOS
toolkit in [`../openbios-the-rival-that-shipped/`](../openbios-the-rival-that-shipped/)
(the `dsl/` readers and the `cpio-edit.fth` / `pe-edit.fth` editors the endgame reuses).

**The S1 build plan and spike ladder are in [`PLAN.md`](PLAN.md)** — the
package-method ↔ `grub_fs` mapping, the shim surface, and the grading (`grub-fstest cp`
oracle + old `grubfs` negative control).

## Status — scaffolding (S0 complete; S1 is the next build)

This lab is **being built**. What is done and measured:

- **S0(1) — the license question (DONE 2026-09-16).** GRUB 2 is GPL-3.0-or-later;
  OpenBIOS's package interface is GPLv2-only (measured: 0 "or later" files in the
  directories the shim sits beside). So the shim is **lab-only** — the shippable
  combination is U-Boot + `libsa`, with GRUB 2 kept here as the widest reader and the
  CBFS/cpio oracle. See the plan §1(1), §2.1c.
- **S0(2) — the ppc size ceiling (DONE 2026-09-19).** GRUB 2.12's four `fs/` files
  compiled `-Os` for a real `powerpc-ieee1275` target occupy **19,356 B** (ext2 4,632
  / fat 5,041 / iso9660 7,384 / fshelp 2,299), against **~351 KB** of headroom under
  the tightest Mac ROM ceiling (mac99 = exactly 1 MiB; `openbios-qemu.elf` = 689,492 B)
  — an **~18× margin**. The ppc size ceiling does **not** partition the four-arch
  matrix. See the plan §1(2).
- **The specification is vendored.** [`upstream-grub/`](upstream-grub/) holds the four
  GRUB 2.12 driver files byte-exact, with a provenance + license README (GPLv3+,
  lab-only, `sha256` + GPG-verified tarball).

**Next (S1):** the `grub2fs` read shim itself — a `/packages` package that translates
OpenBIOS's method set (`open`/`read`/`seek`/`dir`) onto GRUB 2's `grub_fs` API over
the parent device node, graded byte-for-byte against `grub-fstest cp` (GRUB's own
shim as the oracle), with the old `grubfs` package as the negative control (a modern
image must read `File not found` through it and the right bytes through `grub2fs` in
the same boot). See the plan §2.1, §3.

## The tracks the plan defines (not yet built)

| track | what it proves |
|---|---|
| `fs-combo` | one image set read through **every** package that claims it, on all four arches — the ppc row reading little-endian ext4 through `grub_le_to_cpu32` is the byte-order control |
| `fs-tiers` | emits `fs-tiers.toml` — per format, the ordered readers with each one's corpus verdict + provenance hashes; the dispatcher's table is data, not a constant |
| `store-tiers` | the block-device write seams (IDE sectors, CFI flash, NVDIMM) graded on durability, with the static-buffer P0 row as the broken-instrument control |
| `fs-edit-inplace` | **the endgame** — break a config on an ext4 image, `blocks-of` it through the shim, same-length overwrite through the write seam, `fsck` clean + host reads the fix, then **boot it**: the UKI Spike 11 config act moved from a cpio to a real root filesystem |

## Layout

```
openbios-modern-filesystems/
├── README.md            — this file
├── PLAN.md              — S1 build plan + spike ladder (the mapping, surface, grading)
├── MANUAL_TESTING.md    — how to verify what exists so far
├── upstream-grub/       — GRUB 2.12 fs drivers, vendored byte-exact (the shim's spec)
│   ├── README.md        — provenance + license (GPLv3+, lab-only) + sha256
│   └── ext2.c fat.c iso9660.c fshelp.c
└── grub2fs/             — the shim (POC-1a: the minimal grub/ header adapter)
    └── grub/*.h         — types+byteorder, err, mm, disk, device, file, fs,
                           fshelp, dl, safemath, i18n, misc, symbol
```

## Status detail — S1 (the shim) is under way

- **POC-1a (done):** GRUB 2.12's unmodified `ext2.c` + `fshelp.c` compile clean against
  the minimal `grub2fs/grub/` shim headers (`gcc -ffreestanding -I grub2fs -c`) — the
  proof that the shim approach builds GRUB 2's real driver code with no changes to it.
- **POC-1b (next):** the glue (`grub_disk_read`→`seek_io`/`read_io`, `grub_malloc`,
  `grub_error`, `grub_fs_register`, …) + the OpenBIOS package + build wiring, so
  `openbios-unix` builds with `CONFIG_FSYS_GRUB2FS`.
- **POC-2:** mount + read a modern `mke2fs` image, bytes `==` `grub-fstest cp`, old
  `grubfs` as the negative control. See [`PLAN.md`](PLAN.md).
