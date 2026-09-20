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

## Status — S1 read shim DONE (POC-1..5); the `fs-edit-inplace` endgame is next

The `grub2fs` read shim is built and graded (POC-1..4), and its **tier table** is
derived and provenance-bound (POC-5, §"Status detail" below). What is done and measured:

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

**The shim (S1, DONE):** a `/packages/grub2fs` that translates OpenBIOS's method set
(`open`/`read`/`seek`/`dir`) onto GRUB 2's `grub_fs` API over the parent device node,
graded byte-for-byte against `grub-fstest cp` (GRUB's own shim as the oracle), with the
old `grubfs` package as the negative control (a modern image reads `File not found`
through it and the right bytes through `grub2fs` in the same boot). See the plan §2.1, §3.

## The tracks the plan defines

`fs-combo`/`fs-tiers` are **DONE** (Tier 1 — POC-5, [`fs-tiers.toml`](fs-tiers.toml));
`store-tiers` and the `fs-edit-inplace` endgame are pending.

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
│                          (GRUB2FS_ONLY=1 -> a grub2fs-only firmware for POC-5 attribution)
├── smoke-grub2fs.sh     — one-verdict test: grub2fs reads a modern ext2 grubfs can't
├── build-grub2fs-arch.sh — POC-4: build grub2fs into the real ppc/x86 firmware
├── smoke-grub2fs-arches.sh — POC-4: the ppc big-endian byte-order control (== grub-fstest)
├── fixtures/fs-corpus/  — POC-5: build-fs-corpus.sh (one image per edge, foreign-validated)
├── smoke-fs-tiers.sh    — POC-5: derive + verify the per-format probe order (fs-combo/fs-tiers)
├── fs-tiers.toml        — POC-5: the DERIVED tier table (regenerate: smoke-fs-tiers.sh --emit)
├── upstream-grub/       — GRUB 2.12 fs drivers, vendored byte-exact (the shim's spec)
│   ├── README.md        — provenance + license (GPLv3+, lab-only) + sha256
│   └── ext2.c fat.c iso9660.c fshelp.c
└── grub2fs/             — the shim
    ├── grub2fs_glue.c   — the grub_* environment (grub_disk_read == grubfs devread,
    │                      grub_malloc/error/fs_register/str/mem over OpenBIOS libc)
    ├── grub2fs_fs.c     — the OpenBIOS /packages/grub2fs-files package (open/read/…)
    ├── grub2fs.h        — shared internals (disk priv + inits)
    ├── build.xml        — fs library objects (condition FSYS_GRUB2FS)
    └── grub/*.h         — minimal shim headers: `types.h`+byteorder, `err.h`, `mm.h`,
                           `disk.h`, `device.h`, `file.h`, `fs.h`, `fshelp.h`, `dl.h`,
                           `safemath.h`, `i18n.h`, `misc.h`, `symbol.h`, and (POC-3)
                           `charset.h` + `datetime.h` (copied `grub_utf16_to_utf8` /
                           `grub_datetime2unixtime` inlines)
```

## Status detail — S1: POC-1a + POC-1b + POC-2 + POC-3 + POC-4 (ppc byte-order control) + POC-5 (fs-tiers) done

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
- **POC-3 (done):** FAT + ISO 9660. grub2fs now owns a **real heap** (a first-fit
  free-list over a 1 MiB static arena — OpenBIOS has no `realloc` and `free()` is a
  no-op over a 128 KiB bump, which FAT/ISO cannot tolerate), plus `grub_utf16_to_utf8`
  / `grub_datetime2unixtime` inlines and the `grub/fat.h`+`grub/exfat.h` on-disk-struct
  headers (vendored verbatim). `grub2fs` reads a **FAT** and an **ISO 9660** image
  byte-for-byte equal to `grub-fstest`, alongside the modern-ext2 read — proven by
  [`smoke-grub2fs.sh`](smoke-grub2fs.sh) (build determinism 5/5). Run: `./smoke-grub2fs.sh`.
- **POC-4 (ppc byte-order control, done):** grub2fs built into the **real ppc firmware**
  ([`build-grub2fs-arch.sh`](build-grub2fs-arch.sh) `ppc` → `openbios-qemu.elf`) and
  driven in **`qemu-system-ppc` (big-endian)**: it reads a modern little-endian ext2
  image, `/HELLO` byte-for-byte == `grub-fstest`, the inode size **and** data correct
  through `grub_le_to_cpu*` (which SWAP on ppc). Before POC-4 everything ran little-endian
  (amd64), exercising only the identity path; this is the assertion that the typed
  accessors were used, not the CPU's native order. Proven by
  [`smoke-grub2fs-arches.sh`](smoke-grub2fs-arches.sh). Finding: the 1 MiB **static-BSS
  heap overflowed the ppc ROM** (the S0 1 MiB ceiling — `.bss VMA wraps`); the heap is now
  **claimed from RAM at first use** (`alloc-mem`), which fits any ROM (hosted LE re-verified,
  no regression). **UNCOVERED-by-name:** FAT/ISO on ppc (a device-path quirk, not byteorder —
  the shared `grub_le_to_cpu` is proven by the ext2 row); x86 real-firmware; sparc (no
  cross-toolchain in the build container).
- **POC-5 (fs-combo/fs-tiers, done — Tier 1):** one **corpus of edge images**
  ([`fixtures/fs-corpus/`](fixtures/fs-corpus/build-fs-corpus.sh): ext2 classic/modern,
  FAT 16/32/vfat-long, ISO plain/Rock Ridge) read through **both** readers this lab has —
  grubfs (0.97) and grub2fs — via **single-reader firmwares** (a `GRUB2FS_ONLY=1` build,
  so attribution needs no probe-order guess), each read graded byte-equal to a **foreign**
  oracle (debugfs/mcopy/isoinfo). The per-format order is **derived, not opined**:
  **ext2 → grub2fs first** (grubfs *partial*: `File not found` on the modern decider),
  **iso9660 → both eligible, tie UNBROKEN** (needs Tier 2 cost), **fat → grub2fs sole
  reader here**. Written to [`fs-tiers.toml`](fs-tiers.toml), **bound to the corpus by an
  anchor sha** (stale → refused). Controls A (reversed ext2 order = LIED), B (stale anchor
  refused), C (byte-changed payload read back as the new bytes) all bite. Proven by
  [`smoke-fs-tiers.sh`](smoke-fs-tiers.sh). **UNCOVERED-by-name:** Tier 2 cost
  (`info blockstats` — hosted firmware has no counted block device); U-Boot + `libsa`
  readers (§2.1a/b, not built — a two-reader table).
- **Next:** the `fs-edit-inplace` endgame (same-length in-place file write on a real block
  filesystem). See [`PLAN.md`](PLAN.md).
