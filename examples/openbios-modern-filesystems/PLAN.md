# S1 — the `grub2fs` read shim: plan & spike ladder

**Goal (design notes §2.1):** a new OpenBIOS `/packages/grub2fs` that reads a filesystem
made by a *current* tool (ext4 from a modern `mke2fs`, FAT, ISO 9660) by running **GRUB 2's
own driver code** behind a thin translation layer — where today's vendored **GRUB 0.97**
`grubfs` reads a modern image as `File not found`. This is a **shim, not a port**: GRUB 2's
`ext2.c`/`fat.c`/`iso9660.c`/`fshelp.c` are compiled unmodified (vendored in
[`upstream-grub/`](upstream-grub/)); the shim supplies the small `grub_*` environment they
call and the OpenBIOS package methods that call *them*.

## The seam, both directions

OpenBIOS mounts a filesystem by interposing a `/packages` package (method set below) between
the device node and the caller. `fs/grubfs/grubfs_fs.c` is the existing translation to GRUB
0.97; `grub2fs` is the same shape to GRUB 2 — and GRUB 2's per-file `grub_file` state
replaces 0.97's `filepos`/`filemax` globals, so revival bug 5's whole class is gone.

| OpenBIOS package method | GRUB 0.97 (`grubfs`, today) | **GRUB 2 (`grub2fs`, this lab)** |
|---|---|---|
| `open` (mount + path lookup) | `fsys_table[]` probe: each `mount_func()` over global `devread`, then `dir_func(path)` | iterate `grub_fs_list`: each `fs->fs_open (file, name)` over `grub_disk_read`; per-file state in `struct grub_file` |
| `read` | `read_func()` from global `filepos` | `fs->fs_read (file, buf, len)` from `file->offset` |
| `seek`/`tell` | `filepos` (bug 5: no real `tell`) | `file->offset`, `file->size` — both real fields |
| `dir` | `dir_func()` + `print_possibilities` | `fs->fs_dir (device, path, hook, hook_data)` — a callback per entry |
| `load` | reads whole file to `load-base` | unchanged; sits above `read` |

## The disk layer maps one-to-one (the reason this is a shim)

GRUB 2's single disk primitive is
`grub_disk_read (disk, sector, offset, size, buf)` — read `size` bytes at
`sector * 512 + offset` (GRUB_DISK_SECTOR_SIZE = 0x200). OpenBIOS's `grubfs` already has the
identical call, `devread (sector, byte_offset, byte_len, buf)`, implemented as
`seek_io (fd, sector*512 + offset); read_io (fd, buf, size)` on the parent device node. So
the shim's `grub_disk_read` **is** `grubfs`'s `devread` with GRUB-2 argument names — the fd
(and any partition `offset`) lives in the `grub_disk`'s `->data`, set at `open`/`probe` from
`open_ih(my_parent())`. No new device code.

## The shim surface (the libgrub subset), scoped for the **ext2 slice** first

The four drivers `#include` twelve `grub/*.h`; ext2 + fshelp need these external symbols
(everything else is internal to the vendored drivers):

- **mm** (`grub/mm.h`): `grub_malloc` `grub_free` `grub_zalloc` `grub_realloc` → OpenBIOS `malloc`/`free`/`realloc` (+ `memset` for `zalloc`).
- **disk** (`grub/disk.h`): `grub_disk_read` + `struct grub_disk`/`grub_device` → `seek_io`/`read_io` (above).
- **err** (`grub/err.h`): `grub_error` `grub_errno` `grub_dprintf` → set errno + return; `dprintf` under `CONFIG_DEBUG_FS`.
- **fs** (`grub/fs.h`): `grub_fs_register`/`grub_fs_unregister` → push/remove on a `grub_fs_list`.
- **dl** (`grub/dl.h`): `grub_dl_ref`/`grub_dl_unref` → **no-ops** (static build, no modules).
- **types** (`grub/types.h`): `grub_le_to_cpu16/32/64`, `grub_be_to_cpu16`, `grub_cpu_to_le*` → header byteorder over OpenBIOS `libc/byteorder.h` (the ppc row's control — these are used explicitly, never the CPU's order).
- **misc** (`grub/misc.h`): `grub_memcpy` `grub_memset` `grub_strcmp` `grub_strcasecmp` `grub_strdup` `grub_strndup` `grub_xasprintf` → OpenBIOS `libc/string.h` + a small `vsnprintf`-backed `xasprintf`.
- **safemath** (`grub/safemath.h`): `grub_add`/`grub_mul`/`grub_sub` → `__builtin_*_overflow` macros.
- **i18n** (`grub/i18n.h`): `_()`/`N_()` → identity.
- **fshelp** (`grub/fshelp.h`): `grub_fshelp_find_file`/`read_file` are **compiled from the vendored `fshelp.c`**, not stubbed.
- **supporting** (no external symbols of their own): `grub/device.h` (the `grub_device` → `grub_disk` indirection the drivers follow as `file->device->disk`) and `grub/symbol.h` (`EXPORT_FUNC`/`EXPORT_VAR` → identity, since a static build has no module symbol table).

FAT and ISO 9660 additionally pull in `charset` (`grub_utf16_to_utf8`), `datetime`
(`grub_datetime2unixtime`) and `exfat`/`fat` headers — added in POC-3, not the ext2 slice.

## Grading (design notes §3 — assert the OUTCOME, and run the negative control)

- **Oracle — GRUB's own shim vs ours.** For every image+path in the track, the bytes `load`
  produces through `grub2fs` **equal** the bytes `grub-fstest cp` produces from the same
  image on the host. A difference is a shim bug by construction; a *foreign* oracle (the
  kernel's mount, `debugfs`, `isoinfo`) then says which side is right.
- **Negative control — the old package must fail.** A **modern** `mke2fs -t ext2` image must
  read `File not found` through `grubfs` **and** the right bytes through `grub2fs`, in the
  same boot; a classic image reads identically through both. A track where the old package
  cannot be made to fail proves nothing about what the new one fixes.
- **Four-arch matrix** is the byte-order control: the ppc row reading little-endian ext4
  fields through `grub_le_to_cpu32` in the same boot is the assertion that the accessors were
  used and not the CPU's order. A driver passing on x86 only is listed **UNCOVERED on ppc**.
- **Silent failure is the enemy on record** (POC-7's FAT-not-compiled-in failed silently):
  every SKIP/UNKNOWN is named.

## Spike ladder

| spike | milestone | verified by |
|---|---|---|
| **POC-1 — build box ✓ DONE** | GRUB 2's `ext2.c` + `fshelp.c` compile against the minimal `grub/` shim headers, then link into `openbios-unix` with the glue + package | `gcc -c` clean; `openbios-unix` built via `build-grub2fs.sh`, `nm` shows `grub2fs_init`/`grub_disk_read`/`grub_ext2_fs`/`grub_fs_register` |
| **POC-2 — ext2 mount + read ✓ DONE** | `grub2fs` mounts a **modern `mke2fs -t ext2`** image (inode 256, `dir_index`/`filetype`) and `load`s a file; bytes == `grub-fstest cp`; the same image reads `File not found` through `grubfs`, which still reads a classic image (neg control bites) | `smoke-grub2fs.sh` → PASS, headless `openbios-unix` drive vs the `grub-fstest` foreign oracle |
| S1 `dir` ✓ DONE | `dir hd:\` through grub2fs **lists** a modern `mke2fs` ext2 directory (design notes §4 S1's literal milestone); grubfs's `dir` is a stub AND it cannot mount a modern-ext2 directory, so it cannot list one. Mechanism: `open` succeeds for a directory path (probes `fs_dir`, mirroring iso9660's opendir-then-open) and stores the path in the instance; the `dir` method drives `fs->fs_dir` with a **buffering** hook (printing from inside the driver's C callback faults; the framework's `dir`-word stack is mismatched, so `dir` uses the mounted instance's own state, not the passed args). Subdirectories marked with a trailing `\`. | `smoke-fs-dir.sh` → PASS (all entries == `debugfs`; grubfs control bites) |
| POC-3 — FAT + ISO 9660 ✓ DONE | add `fat.c`+`iso9660.c` to the build; the new surface: a **real heap for grub2fs** (`grub_malloc`/`free`/`realloc`/`calloc` over a static arena — OpenBIOS has no `realloc` and `free()` is a no-op over a 128 KiB bump, which the ext2 slice tolerated but FAT/ISO do not), `grub_utf16_to_utf8` (charset) + `grub_datetime2unixtime` (datetime) as copied inlines, `grub_get_unaligned16` in types.h, and `grub/fat.h`+`grub/exfat.h` **vendored verbatim** (on-disk structs). Register `grub_fat_init`/`grub_iso9660_init` beside ext2. | grub2fs reads FAT + ISO == `grub-fstest` (positive oracle; 0.97 grubfs also reads basic FAT/ISO, so the "old package can't" control is specific to modern-ext, POC-2) |
| POC-4 — the byte-order control (ppc DONE) | grub2fs built into the REAL ppc firmware (`build-grub2fs-arch.sh ppc` -> `openbios-qemu.elf`) and driven in `qemu-system-ppc` (BIG-ENDIAN): reads a modern little-endian ext2 image, `/HELLO` byte-for-byte == `grub-fstest`, inode size + data both correct through `grub_le_to_cpu*` (which SWAP on ppc). amd64 LE is proven hosted (`smoke-grub2fs.sh`). **x86 real-firmware + sparc are UNCOVERED-by-name** (sparc: no cross-toolchain in the build container). **Finding: the 1 MiB static-BSS heap overflowed the ppc ROM** (`.bss VMA wraps` — the S0 1 MiB ceiling); fixed by claiming the heap from RAM at first use (`alloc-mem` in `g2_init`), which fits any ROM. | `smoke-grub2fs-arches.sh` — ppc `load hd:\HELLO` via grub2fs == `grub-fstest` |
| POC-5 — `fs-combo`/`fs-tiers` ✓ DONE (Tier 1) | one **corpus of edge images** read through every reader this lab has (grubfs 0.97, grub2fs) via **single-reader firmwares** (a `GRUB2FS_ONLY=1` build → attribution needs no probe-order guess); the per-format order **derived** from byte-equal grades against a **foreign** oracle (debugfs/mcopy/isoinfo). Result: **ext2 → grub2fs first** (grubfs *partial*, `File not found` on the modern decider); **iso9660 → both eligible, tie UNBROKEN** (needs Tier 2 cost); **fat → grub2fs sole reader here** (grubfs FAT not compiled). Emitted to `fs-tiers.toml`, **bound to the corpus by an anchor sha** (stale → refused). **Tier 2 cost (info blockstats) UNMEASURED** — hosted firmware has no counted block device; **U-Boot/`libsa` (§2.1a/b) not built** — a two-reader table, named as such. | `smoke-fs-tiers.sh` → PASS; controls **A** (reversed ext2 order = LIED), **B** (stale anchor refused), **C** (byte-changed payload read back as new bytes) all bite |
| (endgame E1) `blocks-of` ✓ DONE | the shim reports a file's **device data-block LBAs** (a `blocks-of` package method: fshelp fires `disk->read_hook` for the FILE-DATA reads only, so a recording hook learns the segments — the glue now honors the hook, ~10 lines, no new driver code). Graded by a **foreign** oracle: the raw device bytes at the reported LBAs **reconstruct the file** byte-for-byte (single- and multi-block) and sum to its exact size, agreeing with `debugfs`; a control (rewrite the bytes on disk → the map follows) bites. | `smoke-fs-blocks.sh` → PASS |
| (endgame E2) same-length in-place write ✓ DONE (hosted) | `write-file` overwrites a file's own DATA blocks in place (the sectors `blocks-of` located) with exactly-its-own-length bytes → **no metadata touched** (`fsck` clean). Path: grub2fs `write-file` → parent `write` (the C deblocker `packages/deblocker.c` does RMW over `write-blocks`), same-length guarded (refuse a length change BY NAME). The hosted disk is made writable in the **throwaway build only** (`ENDGAME_WRITE=1`: `O_RDWR` + `arch/unix/blk.c` `write-blocks` + a `packages/disk-label.c` `parent_write_xt` relay — its `dlabel_write` was a hard `-1` stub). Grade: firmware edits `MODE=die`→`MODE=run`, host reads the fix, size unchanged, **`e2fsck` CLEAN**, and image-wide EXACTLY the 3 edited bytes differ (no metadata moved). Neg control: a length-changing edit refused by name, image byte-identical, fsck clean. | `smoke-fs-edit-inplace.sh` → PASS |
| (endgame E2b) port the write to REAL firmware (qemu-ppc) — **DEFERRED, characterized as a spike below** | the faithful "real writable IDE" version | design notes §2.6; see the spike |
| (endgame E3) boot it | the UKI Spike 11 config act moved to a real root fs: break a config, fix it in place at the prompt, **boot it** | design notes §2.6 |

### Spike (deferred): port the same-length write to real firmware (qemu-ppc)

E2 proves the mechanism on hosted `openbios-unix`. The faithful version — a real
writable IDE on a QEMU arch — is characterized here from the E2 investigation, for a
later attack. **What is reusable, platform-independent:** the whole grub2fs `write-file`
method **and** the `packages/disk-label.c` `parent_write_xt` write relay. Only the arch
disk write-seam and method-reachability differ.

- **Arch = ppc** (`ppc_config.xml` has `DRIVER_IDE=true`; mac99's disk runs through
  `drivers/ide.c`; grub2fs ext2 read is proven on ppc — POC-4).
- **The ATA write already exists, guarded:** `drivers/ide.c` `ob_ide_write_sectors`
  (refuses ATAPI/CHS/out-of-LBA28/range) + `ob_ide_write_ata_lba28` (`WIN_WRITE`) +
  `ob_ide_write_blocks_nr`. `build-grub2fs-arch.sh ENDGAME_WRITE=1` **already stages** an
  `ide.c` `write-blocks` method (mirror of `read-blocks`).
- **Two known obstacles, mapped:**
  1. **`open-dev hd:\file` on ppc returns the disk-label, not grub2fs** — so
     `blocks-of`/`write-file` are not reachable via `open-dev` + `$call-method` (they are
     on hosted). `load hd:\file` works via the fs-package **interpose** framework. The
     port must open grub2fs through that framework (or expose a global word).
  2. The **`packages/disk-label.c` write relay** (E2's hosted patch) applies unchanged;
     the C deblocker already RMWs over `write-blocks`.
- **The crux, UNCONFIRMED — NOT proven dead, just untested:** *does
  `ob_ide_write_sectors` actually persist a `WIN_WRITE` to the qemu mac99 IDE drive?*
  I could not fire it from the ppc prompt (couldn't reach a write-capable word). **The
  decisive experiment:** a global `bind_func` word (e.g. `g2-ata-write ( buf blk -- flag )`
  → `ob_ide_write_blocks_nr(0, blk, buf, 1)`), then check the qemu image changed on the
  host. If it persists → the port is (ide write-blocks, staged) + (disk-label relay, done)
  + (reach `write-file` via the fs framework). If it does **not** persist → the qemu IDE
  write path itself (DMA/PIO write wiring in `ide.c`) needs fixing first.

## Where the code lives

- `grub2fs/grub/*.h` — the minimal shim headers (this lab; mirrors how `fs/grubfs/` ships its
  own adapted headers, not GRUB's originals).
- `grub2fs/grub2fs_glue.c` — the `grub_*` environment (disk/mm/err/fs/dl/misc).
- `grub2fs/grub2fs_fs.c` — the OpenBIOS package (`DECLARE_NODE` + methods).
- `grub2fs/{build.xml,Kconfig}` — build integration.
- `build-grub2fs.sh` — stages `grub2fs/` + `upstream-grub/*.c` into the openbios tree's
  `fs/grub2fs/` and builds (sha-guarding sibling labs' artifacts, per the family's pattern).
  `GRUB2FS_ONLY=1` builds a **grub2fs-only** firmware (grubfs not registered) for POC-5's
  per-reader attribution.
- `fixtures/fs-corpus/build-fs-corpus.sh` — the POC-5 corpus builder: one image per edge
  (ext2 classic/modern, FAT 16/32/vfat-long, ISO plain/Rock Ridge), each foreign-validated
  and byte-reproducible where the tool allows; emits `manifest.tsv` + a definition anchor.
- `smoke-fs-tiers.sh` — the `fs-combo`/`fs-tiers` track (POC-5); emits/verifies `fs-tiers.toml`.
- `fs-tiers.toml` — the DERIVED per-format probe order (do not hand-edit; regenerate with
  `smoke-fs-tiers.sh --emit`).
- `smoke-fs-blocks.sh` — endgame E1: grades grub2fs's `blocks-of` (a file's device data LBAs)
  by reconstructing the file from raw device bytes at those LBAs.
- `smoke-fs-edit-inplace.sh` — the endgame E2: grub2fs `write-file` edits a file in place on a
  real ext2 fs (same-length), host reads the fix, `e2fsck` clean, only the edited bytes change.
  Uses `GRUB2FS_ONLY=1 ENDGAME_WRITE=1 build-grub2fs.sh` (writable firmware, throwaway build only).
- `smoke-fs-dir.sh` — S1's literal milestone: grub2fs `dir hd:\` lists a modern ext2 directory
  (== `debugfs`); the stock grubfs control cannot.

## Backlog — the rest of the design note, prioritized

What the [design notes](../../DESIGN-NOTES-modern-filesystems-for-a-frozen-firmware.md) define
that this lab has **not** built yet, most-valuable/cheapest first. Seam 1 (§2.1) — the GRUB 2
shim — is complete through the endgame; the rest is breadth (other sources, other OFW routes,
the store direction) that the note itself frames as *choices*, plus two finishes to work already
started.

| # | item | §  | effort | what it unlocks / why |
|---|---|---|---|---|
| B1 | **Tier 2 cost for `fs-tiers`** — `info blockstats` sector-read deltas per (reader, op), breaking the `iso9660` eligible-tie POC-5 left open | 2.1e | S–M (a QEMU-arch drive + monitor) | finishes the tier table's second half; the only *measured* way to order two eligible readers |
| B2 | **Endgame E2b — port the same-length write to REAL firmware** (qemu-ppc, real writable IDE) | 2.6 | M | the faithful endgame; **already characterized as a spike above** (ide.c has the ATA write; crux = does a qemu `WIN_WRITE` persist — a `bind_func` test word settles it) |
| B3 | **Endgame E3 — "boot it"** | 2.6 | M | the rescue arc's finale: break a config on a real root fs, fix it in place, then boot — the sentence the whole note exists to reach, end to end |
| B4 | **Seam 2 — partition maps** (`grub2parts`: GPT + MBR via GRUB 2's `partmap/`) | 2.2 | S ("for the same price" — same shim) | `dir hd:2,\` on the GPT images the newer labs make; today none reads GPT |
| B5 | **The decisive-mount dispatcher** (probe order generated from `fs-tiers.toml`, fall-through-by-name) | 2.1d | M | makes 0.97 + grub2fs coexist safely; `fs-tiers.toml` is already the data it consumes |
| B6 | **Seam 1 other sources — U-Boot `fs/` (§2.1a) + `libsa` (§2.1b) shims** → the shippable multi-source ROM | 2.1a/b/c | L | the license-clean shipping story (GRUB 2 is lab-only); makes `fs-tiers` a real >2-reader table |
| B7 | **Seam 3 — the loader as a client program** (`libsa-ofw`/`libsa-openbios`) | 2.3 | M | reaches OFW with no firmware change: "boot Linux off a modern ext4 disk on OFW" |
| B8 | **Seam 4 — transliteration** (`ext4.fth`: GRUB 2's `ext2.c` as the spec for an OFW Forth package) | 2.4 | L (authoring) | OFW's *own* `load` reads modern ext4 — the sister lab's thesis |
| B9 | **`store-tiers`** — one sweep over the persistence tracks (patches 04–10) emitting `store-tiers.toml` | 2.5 | M | the *other* direction (writing durable bytes), tiered by use, with provenance |

Open questions the note leaves to discuss (§6) are mostly answered by the built work: §6 Q4
(keep 0.97 ON) is settled; Q3 (ppc fits) is measured (POC-4); Q1/Q5 wait on B6's second source.
