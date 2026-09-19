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
| POC-3 — FAT + ISO 9660 ✓ DONE | add `fat.c`+`iso9660.c` to the build; the new surface: a **real heap for grub2fs** (`grub_malloc`/`free`/`realloc`/`calloc` over a static arena — OpenBIOS has no `realloc` and `free()` is a no-op over a 128 KiB bump, which the ext2 slice tolerated but FAT/ISO do not), `grub_utf16_to_utf8` (charset) + `grub_datetime2unixtime` (datetime) as copied inlines, `grub_get_unaligned16` in types.h, and `grub/fat.h`+`grub/exfat.h` **vendored verbatim** (on-disk structs). Register `grub_fat_init`/`grub_iso9660_init` beside ext2. | grub2fs reads FAT + ISO == `grub-fstest` (positive oracle; 0.97 grubfs also reads basic FAT/ISO, so the "old package can't" control is specific to modern-ext, POC-2) |
| POC-4 — four arches | x86 / amd64 / ppc / sparc; ppc is the byte-order control | matrix, UNCOVERED named |
| POC-5 — `fs-combo`/`fs-tiers` | one image set through every package that claims it; emit `fs-tiers.toml` | design notes §2.2 |
| (endgame) `fs-edit-inplace` | `blocks-of` beside `read`; same-length in-place write; `fsck` clean; boot it | design notes §2.6 |

## Where the code lives

- `grub2fs/grub/*.h` — the minimal shim headers (this lab; mirrors how `fs/grubfs/` ships its
  own adapted headers, not GRUB's originals).
- `grub2fs/grub2fs_glue.c` — the `grub_*` environment (disk/mm/err/fs/dl/misc).
- `grub2fs/grub2fs_fs.c` — the OpenBIOS package (`DECLARE_NODE` + methods).
- `grub2fs/{build.xml,Kconfig}` — build integration.
- `build-grub2fs.sh` — stages `grub2fs/` + `upstream-grub/*.c` into the openbios tree's
  `fs/grub2fs/` and builds (sha-guarding sibling labs' artifacts, per the family's pattern).
