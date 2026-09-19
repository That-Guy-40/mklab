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
├── MANUAL_TESTING.md    — how to run the smoke + the success signature
├── build-grub2fs.sh     — build openbios-unix WITH grub2fs (in a throwaway tree copy;
│                          the shared tree is never touched) -> $WORKDIR/grub2fs/
├── smoke-grub2fs.sh     — one-verdict test: grub2fs reads a modern ext2 grubfs can't
├── upstream-grub/       — GRUB 2.12 fs drivers, vendored byte-exact (the shim's spec)
│   ├── README.md        — provenance + license (GPLv3+, lab-only) + sha256
│   └── ext2.c fat.c iso9660.c fshelp.c
└── grub2fs/             — the shim
    ├── grub2fs_glue.c   — the grub_* environment (grub_disk_read == grubfs devread,
    │                      grub_malloc/error/fs_register/str/mem over OpenBIOS libc)
    ├── grub2fs_fs.c     — the OpenBIOS /packages/grub2fs-files package (open/read/…)
    ├── grub2fs.h        — shared internals (disk priv + inits)
    ├── build.xml        — fs library objects (condition FSYS_GRUB2FS)
    └── grub/*.h         — 13 minimal shim headers (types+byteorder, err, mm, disk,
                           device, file, fs, fshelp, dl, safemath, i18n, misc, symbol)
```

## Status detail — S1 (the shim): POC-1a + POC-1b + POC-2 done

- **POC-1a (done):** GRUB 2.12's unmodified `ext2.c` + `fshelp.c` compile clean against
  the minimal `grub2fs/grub/` shim headers (`gcc -ffreestanding -I grub2fs -c`).
- **POC-1b (done):** the glue (`grub_disk_read`→`seek_io`/`read_io`, `grub_malloc`,
  `grub_error`, `grub_fs_register`, …) + the OpenBIOS package + build wiring;
  **`openbios-unix` builds with `grub2fs` linked** (`nm` shows `grub2fs_init`,
  `grub_disk_read`, `grub_ext2_fs`, `grub_fs_register`), via `build-grub2fs.sh`.
- **POC-2 (done):** `grub2fs` mounts a **modern** `mke2fs` ext2 image (inode size 256,
  `dir_index`/`filetype`) and `load`s a file **byte-for-byte equal to `grub-fstest`**,
  which the shipped 0.97 `grubfs` reads as `File not found` (though `grubfs` still reads
  a classic image). Proven by [`smoke-grub2fs.sh`](smoke-grub2fs.sh) with the negative
  control biting. Run: `./smoke-grub2fs.sh` → `PASS: grub2fs … read /HELLO from a MODERN
  ext2 image … byte-for-byte equal to grub-fstest …`.
- **POC-3 (next):** FAT + ISO 9660 (add the `charset`/`datetime` shim and a real heap —
  those drivers use `grub_realloc`, which the ext2 slice does not). See [`PLAN.md`](PLAN.md).
