# Modern Filesystems for a Frozen Firmware — Design Notes

*Discussion draft, 2026-09-05. Not a lab plan yet: the question was whether the
filesystem drivers in GRUB 2 could be lifted into OpenBIOS, into OFW, or both.
Tracked as
[`TODO.md` §23](TODO.md#23-modern-filesystems-for-a-frozen-firmware--lift-transliterate-or-bring-your-own-2026-09-05);
sibling of
[`DESIGN-NOTES-the-firmware-edits-the-boot-it-makes.md`](DESIGN-NOTES-the-firmware-edits-the-boot-it-makes.md)
(same shape: measure first, seams as build items, grade by outcome), and the
downstream of two findings the labs already paid for — revival bug 5 and the clib
lab's [POC-7](examples/openbios-clib-hello-to-emacs/POC-7-DISK-BOOT.md).*

---

## 0. The question, and the answer in one paragraph each

**The premise, corrected.** Only **OpenBIOS** carries GRUB code. Its `fs/grubfs/`
is the filesystem tree of **GRUB 0.97** — the pre-GRUB-2 "legacy" line — behind a
glue file that presents it as a `/packages` filesystem package. **OFW** has no GRUB
in it and no C in it: its filesystems are Forth packages Firmworks wrote
(`fat-file-system`, `iso9660-file-system`, an ext2 reader —
[POC-2](examples/open-firmware-forth-to-boot/POC-2-OK-PROMPT.md),
[POC-3](examples/open-firmware-forth-to-boot/POC-3-COREBOOT-PAYLOAD.md)). So "lift
GRUB 2's drivers" is, literally, an OpenBIOS question; OFW gets a different answer.

**OpenBIOS: feasible, with precedent, and the work is a shim.** GRUB 2's drivers in
`grub-core/fs/` are freestanding C over a small kernel API, and two things prove
they compile outside GRUB's own boot environment: GRUB's hosted tools `grub-fstest`
and `grub-mount` build them against an emulation layer, and the **efifs** project
wraps the same drivers behind UEFI's file protocol with a few hundred lines of glue.
The shim sits where the legacy glue already sits (§1a) and exposes the same
`open`/`read`/`seek`/`tell`/`dir` methods, so `load` and `dir` would not know the
difference. The blockers are a **license** measurement and a **size** measurement
(§1), not code.

**OFW: no lift is possible; two honest routes remain.** There is nowhere to link C
into a self-hosting Forth image assembled by its own Forth assembler. Either
**transliterate** — GRUB 2's ext4 reader as the *specification* for a Forth package
(§2.4) — or **bring the filesystems in a client program**, which the clib lab's
model already licenses: FreeBSD's boot loader runs as an Open Firmware client, does
its disk I/O through the client interface, and carries a BSD-licensed filesystem
library (§2.3). That route works on OpenBIOS too, with no firmware change at all.

**The seams are the build list** — §2's four each end in a *Build:* line, §4
collects them. §0a is the digest.

## 0a. In brief — what gets built, what it buys, and what decides between the routes

- **What it buys, measured rather than hoped:** an ext2/ext4 image made by a
  *modern* `mke2fs` — the one POC-7 found the 0.97 driver mounts and then cannot
  read (`File not found` on 256-byte inodes, `dir_index`, `ext_attr`); FAT without a
  rebuild and without the *silent* failure POC-7 recorded (`state-valid` stays 0, no
  error); ISO 9660 **with Rock Ridge and Joliet**, so file names stop being
  `STRUCT.FTH;1`; **GPT**, which OpenBIOS's partition packages do not read; exFAT,
  XFS, F2FS, HFS+ on the same shim. And two drivers that are *already this repo's
  subjects*: GRUB 2 reads **CBFS** and **cpio/newc** as filesystems, so the ROM Act I
  walks and the initrd the handoff notes append become things `dir` can list — and
  a **second foreign oracle** for `dsl/cbfs.fth`.
- **What decides the route:** (1) OpenBIOS's license — its `COPYING` is **GPLv2**
  (the clib lab's [`clib/README.md`](examples/openbios-clib-hello-to-emacs/clib/README.md)
  records it), GRUB 2 is GPLv3-or-later, and whether the source headers say *"version
  2"* or *"version 2 or later"* decides whether a combined ROM may ever be
  **distributed**. **Measured 2026-09-07 (§1(1)): the project's licensing page says
  "V2" with no "or later", and `packages/` and `libopenbios/` say "version 2"
  explicitly — so GRUB 2 is lab-only, and the shippable combination is U-Boot +
  `libsa` (§2.1c).** A lab ROM that is built and run here is not distribution.
  (2) the ppc firmware's size ceiling — QEMU maps it into a fixed region. (3) whether
  the seam is the firmware at all, or a client program.
- **The three routes, ranked by what they cost and where they can go:**
  - **GRUB 2 shim in OpenBIOS** — most drivers, best-tested code, the cheapest shim;
    lab-only unless the license measurement surprises.
  - **U-Boot's `fs/` in OpenBIOS** (§2.1a) — GPLv2-or-later, so *shippable*; ext4
    with extents, FAT, btrfs, squashfs, erofs, and its own CBFS reader — and **no
    ISO 9660** at all, which is the door most of this repo's labs use. A path-based
    file API and per-mount globals make its shim a slightly worse fit than GRUB 2's,
    not a smaller one. Also the survey's "U-Boot has zero coverage".
  - **FreeBSD's `libsa`, two ways.** As a **client program** (§2.3) — runs on **OFW
    and OpenBIOS**, needs no firmware patch, the only route that reaches the frozen
    firmware. And **linked into OpenBIOS** as a package (§2.1b) — the best license of
    the three (BSD), the best fit (handle-based, a `devread` twin), the weakest
    coverage: ext2 *without* extents, FAT, UFS, and ISO 9660 with Rock Ridge.
  - **The combination** (§2.1c): the sources are not rivals. In the expected
    license outcome the ROM that may leave the lab is **U-Boot for ext4 + `libsa`
    for ISO and FAT**, and GRUB 2 stays as a lab-only patch for the widest coverage
    and the CBFS/cpio oracles. §2.1c is the decision table, keyed to §1(1).
  - **The chosen plan** (§2.1d, 2026-09-09): **keep 0.97 on** (it is the only reader
    for XFS v4, JFS, ReiserFS, UFS, Minix, AFFS), add U-Boot and `libsa`, and make the
    dispatcher safe with one rule — **a mount must be decisive**: probe by capability
    (U-Boot, `libsa`, then 0.97), and a mount that cannot list `/` unmounts and falls
    through by name. That reads everything this repo's labs make; exFAT, NTFS, UDF,
    XFS v5 and F2FS stay GRUB 2-only, and no lab here makes one.
  - **The overlaps are tiered by measurement** (§2.1e): FAT, ISO, classic ext2 and
    UFS each have two or three readers, so their probe order is *derived* — correctness
    on a per-edge corpus first (byte-equal to host oracles; a partial reader never
    first; a wrong reader disqualified by name), then cost measured from outside the
    firmware as QEMU's `info blockstats` sector-read deltas, never wall time. The
    result is `fs-tiers.toml` with provenance hashes; the dispatcher's table is
    generated from it and a checker refuses a stale one.
- **The testing story is unusually clean:** the drivers are upstream's; **the only
  new code is the shim.** So the shim's oracle is `grub-fstest` reading the same
  image through GRUB's *own* shim, byte for byte; the driver's oracle is the kernel
  mounting the image; and the four-door matrix grades byte order for free — a
  big-endian ppc reading a little-endian ext4 is the CBFS reader's ppc row again.

## 1. The measurements that come first

**Not code — three numbers, each of which can end the discussion.**

1. **The license headers, not the `COPYING`.** `COPYING` says GPLv2; what matters
   is the per-file wording under `fs/`, `packages/`, `libopenbios/` and `arch/`:
   *"version 2 of the License"* forecloses linking GPLv3-or-later code into a
   ROM that leaves the lab; *"or (at your option) any later version"* does not. One
   `git grep -c 'any later version'` against the pinned clone, and the count of
   files without it, decides the *shipping* question. It does **not** decide the
   *lab* question: the GPL conditions distribution, and this repo distributes
   patches and builds ROMs in CI; it publishes no ROM. Whichever way it falls, the
   answer is written into the patch catalog's `kind` column (a `DIVERGENCE`
   carried for a stated reason) rather than left to be rediscovered.

   **MEASURED 2026-09-07 — a sample of seven files, not yet the full grep, and it is
   the "v2 only / mixed" row of §2.1c.** The project's licensing page
   (<https://www.openfirmware.info/GPLv2.html>, retrieved 2026-09-07) says *"OpenBIOS is
   covered by the General Public License V2"* and then reproduces the GPLv2 text —
   **no "or later"** anywhere outside the GPL's own §9. `COPYING` in the tree is the
   bare GPLv2 text with no project preamble. Per file, at upstream `master`:

   | file | wording | class |
   |---|---|---|
   | `libopenbios/load.c` | *"under the terms of the GNU General Public License version 2"* | **v2 only, explicit** |
   | `packages/disk-label.c` | *"under the terms of the GNU General Public License version 2"* | **v2 only, explicit** |
   | `kernel/forth.c` | *"See the file COPYING"* | v2 by reference (COPYING is the v2 text; the wiki says V2) |
   | `arch/x86/openbios.c` | *"See the file COPYING"* | v2 by reference |
   | `fs/iso9660/iso9660_open.c` | *"copied from EMILE"*, a copyright line, **no license wording at all** | inherits EMILE's (GPL) — a provenance gap in its own right |
   | `fs/grubfs/fsys_ext2fs.c` | *"either version 2 of the License, or (at your option) any later version"* | **v2 or later** — it is GRUB's own header, verbatim |

   Two of these decide it: the directories the new shim would sit **beside** —
   `packages/` and `libopenbios/`, which the package interface lives in — carry the
   explicit *"version 2"* wording. So a ROM linking GPLv3-or-later code into them
   cannot be distributed, and **§2.1c's "v2 only" row is the one selected**: GRUB 2
   is a lab-only source; U-Boot and `libsa` are the shippable ones. Two things worth
   keeping from the sample: the *legacy* GRUB files already in the tree are
   **v2-or-later** (GRUB's own notice, untouched), which is why 0.97 has always sat
   there without question and why the question is specific to GRUB **2**; and
   `fs/iso9660/` carries **no license line at all**, only *"copied from EMILE"* — the
   native ISO driver's provenance is a copyright line and a URL, which is the
   cite-don't-mirror tier's failure mode and worth a catalog note of its own. The
   full `git grep` over the pinned clone is still owed (a count, so the sample cannot
   be an unlucky seven), but it can only move the answer *toward* "mixed", never to
   "v2 or later throughout" — the two explicit files are enough to foreclose that.
2. **The ppc image against its ceiling.** QEMU loads the ppc firmware into a
   fixed region (1 MiB on the Mac machines; sun4m's is smaller — measure both). The
   drivers are compiled C in the ROM, not dictionary, so the toolkit's dictionary
   budget does not apply — but the ROM does. Today's `openbios-qemu.elf` size, and
   the size of `ext2.c` + `fat.c` + `iso9660.c` + `fshelp.c` compiled for ppc with
   `-Os`, are two numbers a `size` call produces. **x86 and amd64 have no such
   ceiling** (a coreboot ROM has 4 MiB of CBFS), so a ppc that does not fit
   partitions the matrix rather than blocking it — said by name.
3. **What the package interface actually requires** (§1a) — read out of
   `fs/grubfs/`'s glue and out of revival bug 5, not assumed.

## 1a. The seam that already exists: `/packages` and the 0.97 glue

OpenBIOS mounts a filesystem by **interposing** a package from `/packages` between
the device node and the caller (`Located filesystem`, `INTERPOSE!` in POC-7's
trace). Each filesystem package implements a fixed method set, and the C side of
`fs/grubfs/` is exactly a translation between that set and GRUB 0.97's:

| the package method | what 0.97 gives it | what GRUB 2 gives it |
|---|---|---|
| `open` (mount + path lookup) | `fsys_table[]` probe: each driver's `mount()` over a global `devread()`, then `dir()` with the path | `grub_fs_list` probe: each `fs->fs_open (file, name)` over `grub_disk_read` — the same shape, per-file state instead of globals |
| `read` | `read()` from the global `filepos` | `fs->fs_read (file, buf, len)` from `file->offset` |
| `seek` / `tell` | `filepos` — **bug 5:** no `tell` at all, negative seeks clamped to 0, so `file_size()` returned garbage and every loader sized files at ~4 GB | `file->offset` and `file->size`, both real fields — bug 5's whole class disappears |
| `dir` | `dir()` with `print_possibilities` | `fs->fs_dir (device, path, hook, hook_data)` — a callback per entry |
| `load` | reads whole file to `load-base` | unchanged; sits above `read` |

The **device side** is the same on both: the package reads sectors from its parent
(the IDE, ATAPI, or unix block node) through the parent's own `seek`/`read`. That
is `devread()` in 0.97 and `grub_disk_read (disk, sector, offset, size, buf)` in
GRUB 2, and the 512-byte-sector, offset-within-sector contract is the same.

So the shim is a **second glue file beside the first**, not a replacement of
anything: a `/packages/grub2fs` package whose `open` walks `grub_fs_list`. The 0.97
package stays until the new one has read every image the old one can, on every
door — and then it is the *negative control* (modern `mke2fs` image: old package
`File not found`, new package the bytes).

## 2. Four seams, ordered by how much they change

### 2.1 Seam 1 — the GRUB 2 shim in OpenBIOS

**What the drivers ask of the environment**, read from `grub-core/fs/*.c` and
`include/grub/`, and what each maps to:

| the drivers call | what it is | the shim provides |
|---|---|---|
| `grub_disk_read`, `grub_disk_get_size`, `disk->log_sector_size` | sector I/O, 512-byte units, partial reads | the parent node's `seek` + `read`, exactly what `devread()` does now |
| `grub_file_t` (`data`, `size`, `offset`, `read_hook`) and `grub_fs_t` (`name`, `fs_dir`, `fs_open`, `fs_read`, `fs_close`, `fs_label`, `fs_uuid`, `fs_mtime`) | the interfaces | the structs, verbatim from `include/grub/file.h` and `fs.h` |
| `grub_fs_register`, `GRUB_MOD_INIT`/`GRUB_MOD_FINI`, `grub_dl_ref`/`unref` | module registration | a static list and empty macros — the drivers are linked, not loaded |
| `grub_fshelp_find_file`, `grub_fshelp_read_file` | the generic directory walk and symlink resolution nearly every driver routes through | **`fshelp.c` comes along as-is** |
| `grub_malloc`/`zalloc`/`realloc`/`free` | allocation | OpenBIOS's own `malloc` |
| `grub_memcpy`/`memset`/`strcmp`/`strncmp`/`strlen`/`strchr`/`strrchr`/`strdup`/`strtoul` | libc subset | OpenBIOS's `libc/` |
| `grub_error (GRUB_ERR_…, …)`, `grub_errno`, `grub_dprintf` | the error channel | a global and `printk`; the package's `open` maps a set `grub_errno` to *refusal by name* |
| `grub_le_to_cpu16/32/64`, `grub_be_to_cpu…`, `grub_cpu_to_…` | byte order | header-only (`byteorder.h`) — **the reason a big-endian ppc reads ext4** |
| `grub_divmod64`, `grub_unixtime2datetime` | 64-bit math, mtime | small, from `kern/misc.c` and `lib/datetime.c` |
| `grub_utf16_to_utf8`, `grub_utf8_to_utf16` | long names (FAT, exFAT, HFS+, NTFS, UDF) | header-only inlines in `charset.h` |

**Tier the drivers by what they drag in**, so the first patch is small and the
matrix has a subject on every door:

| tier | drivers | extra dependencies |
|---|---|---|
| **1 — the core shim only** | `ext2.c` (ext2/3/4, extents, inline data), `fat.c` (FAT12/16/32 + exFAT), `iso9660.c` (Rock Ridge, Joliet), `xfs.c`, `hfsplus.c`, `ufs.c`, `f2fs.c`, `udf.c` | none beyond the table above |
| **1a — the repo's own subjects** | `cbfs.c`, `newc.c`/`cpio.c`/`tar.c` (`archivefs`) | none; **a second foreign oracle for `dsl/cbfs.fth`** and `dir` over an initrd |
| **2 — decompressors** | `squash4.c`, `btrfs.c` | `lib/minilzo`, `lib/zstd`, `io/gzio` — thousands of lines, and btrfs also wants `grub_crypto` for checksums |
| **out** | `zfs/` | `grub_crypto`, ~10 k lines; the ZFS lab reaches ZFS a different way |

**Build:** a numbered patch, `FEATURE`, scope *shared* (`fs/` is compiled on every
arch): `fs/grub2fs/{glue.c, shim.h}` + the tier-1 drivers + `fshelp.c`, behind
`CONFIG_FSYS_GRUB2` per arch; the `/packages/grub2fs` registration; one track,
`grub2fs`, that reads **the same image through both packages** and asserts the
modern-`mke2fs` row diverges the right way. The **license decision** is recorded in
the patch catalog row, whichever way §1(1) fell.

### 2.1a Seam 1, the other source — U-Boot's `fs/` in OpenBIOS

The same seam, a different tree: U-Boot's `fs/` is **GPL-2.0-or-later**, so a
combined ROM can leave the lab whatever §1(1) finds in OpenBIOS's headers. It is the
mainstream embedded loader's filesystem layer, in production on every ARM board that
boots from an SD card, and it reads what this repo's disks actually carry: **ext4
with extents** (`fs/ext4/`, read *and* write — the write half is not wanted here),
FAT12/16/32 (`fs/fat/`, read and write), btrfs, squashfs, erofs, ubifs, cramfs,
jffs2, a ZFS reader, and **`fs/cbfs/`** — so, like GRUB 2, a second foreign reader
of the ROM Act I walks.

**What it does not have is ISO 9660.** U-Boot's CD support stops at El Torito
partition discovery; there is no `fs/iso9660`. That is not a footnote: the ISO door
is the one **every** track in the rival lab and both habitats use, and the native
`fs/iso9660` in OpenBIOS is the driver with the two path-syntax defects the toolkit
plan measured (no comma, no `;1` strip). A U-Boot lift therefore leaves ISO where it
is, or pairs with GRUB 2's `iso9660.c` — which reintroduces the license question for
that one file.

**What the drivers ask of the environment**, read from `fs/fs.c` and
`include/fs.h`, `include/blk.h`:

| the drivers call | what it is | the shim provides |
|---|---|---|
| `blk_dread (desc, start, blkcnt, buf)` / `blk_dwrite` (unused) | whole-block I/O on a `struct blk_desc` (`blksz`, `lba`, `log2blksz`) | the parent node's `seek` + `read`, **block-granular** — the shim buffers the partial reads GRUB's interface handled itself |
| `fs_set_blk_dev` / `fs_set_blk_dev_with_part` | select device + partition; probes each `fstype_info` `probe` in turn | the mount step of the package's `open`; the partition comes from OpenBIOS's own partition packages (§2.2 does not apply — U-Boot's `disk/part_efi.c` reads GPT and could, at the same price) |
| `fs_size`, `fs_read (name, addr, offset, len, &actread)`, `fs_ls`, `fs_exists` | the file API, **path-in, bytes-out**, no open handle | `open` resolves and caches the path, `read`/`seek`/`tell` are `fs_read` at an offset, `dir` is `fs_ls` — a slightly worse fit than GRUB 2's per-file handle, since every `read` re-walks the path unless the shim caches |
| `malloc`/`free`, `memcpy`/`strcmp`…, `printf`/`debug` | libc subset | OpenBIOS's `libc/`, `printk` |
| `le32_to_cpu`, `be32_to_cpu`, `__le32` types, `get_unaligned_le32` | byte order | header-only (`asm/byteorder.h`, `linux/unaligned`) — the ppc row's control again |
| `CONFIG_*` and the `fstype_info` table in `fs.c` | the Kconfig surface | a hand-written table for the drivers linked; U-Boot's `fs.c` is the dispatcher and comes along trimmed |
| `env_get`, `hash` (`fs.c`'s `do_load` uses them for `filesize` and the `fsload` command) | U-Boot-isms in the dispatcher | stubbed — the package never runs a U-Boot command |

Two divergences from the GRUB 2 shim worth stating up front: U-Boot's file API is
**path-based, not handle-based**, so a file opened once and read in pieces (which
is what `load` and every loader do) costs a path walk per read unless the shim
keeps the resolved inode — a cache that has to be invalidated on `close`; and its
ext4 driver keeps **global state** per mounted filesystem (`ext4fs_root`,
`ext4fs_file`), so two filesystems open at once — the CD and the disk in the same
boot, which the amd64-linux track does — need the shim to re-mount on switch. The
0.97 driver had the same globals; that is the bug-5 family.

**Tiering** is flatter than GRUB 2's: `ext4`, `fat`, `cbfs` need only the table
above; `btrfs`, `squashfs`, `erofs` bring their decompressors (`lib/zlib`, `lib/lzo`,
`lib/zstd`); `zfs` brings its own and is out for the same reason as §2.1's.

**Build:** the same patch shape as §2.1, `fs/ubootfs/{glue.c, shim.h}` + `fs/ext4/`
+ `fs/fat/` + `fs/cbfs/` + a trimmed `fs.c`, behind `CONFIG_FSYS_UBOOT`;
`/packages/ubootfs`; the same `grub2fs` track re-aimed (S1–S2 with U-Boot's
`ext4ls`/`ext4load` in the **sandbox** build — `u-boot` for the host, `host bind`
onto the image — as the shim's byte-for-byte oracle, the way `grub-fstest` is for
§2.1). **The decision between §2.1 and §2.1a is §6 question 1**, and it is a
license-and-ISO decision, not a code one: both shims are the same size.

### 2.1b Seam 1, the third source — FreeBSD's `libsa` **in** OpenBIOS, not only beside it

§2.3 uses FreeBSD's filesystem library in a **client program**, because that is the
only way it reaches OFW. But OpenBIOS is C, so the same library can be **linked into
the firmware** behind the same `/packages` seam as §2.1 and §2.1a — a third source
for seam 1, and on two of the three axes the best of them:

- **License: BSD-2-Clause.** No distribution question at all — the only source of
  the three for which §1(1)'s measurement is irrelevant.
- **Fit: the closest of the three.** Its device interface is
  `strategy (devdata, rw, dblk, size, buf, &rsize)` — GRUB 0.97's `devread()` with
  the arguments reordered, so the shim is a near-copy of the glue that already
  exists. Its file API is **handle-based** (`struct open_file` with `f_fsdata` per
  open file, `fs_ops { open, close, read, write, seek, stat, readdir }`), which
  avoids both of §2.1a's divergences: no path walk per `read`, no per-mount globals.
- **Coverage: the weakest.** `ext2fs.c` is **ext2 without extents** — it reads the
  classic layout the 0.97 driver reads. Whether it reads a modern `mke2fs -t ext2`
  image (256-byte inodes, `dir_index`, `resize_inode`, `ext_attr` — compatibility
  flags a linear-scan reader can ignore, plus a dynamic-revision inode size it must
  honour) is a **measurement**, not a known; a modern **ext4** image it does not
  read. It has `dosfs` (FAT12/16/32), `ufs`, and **`cd9660` with Rock Ridge** — the
  ISO door, which U-Boot lacks; no XFS, no btrfs, and its `zfs` reader is CDDL and
  large. `nfs`/`tftp` are left to the netboot labs (§5).

| the drivers call | what it is | the shim provides |
|---|---|---|
| `(*devsw->dv_strategy) (devdata, F_READ, dblk, size, buf, &rsize)` | block I/O; `dblk` in 512-byte units | the parent node's `seek` + `read` — the 0.97 `devread()` glue, arguments reordered |
| `struct open_file { f_flags, f_dev, f_devdata, f_ops, f_fsdata, f_offset }` | the handle | one per package instance; `f_fsdata` is where the driver keeps its state, so two filesystems open at once (the CD and the disk in one boot) simply work |
| `fs_ops` table, `file_system[]` list | probe order | a static list of the drivers linked; `open()` tries each `fo_open` — the mount step |
| `open`/`read`/`lseek`/`close`/`stat`/`readdir` (`stand.h`) | the file API | `open` → package `open`; `read`/`lseek` → `read`/`seek`/`tell` (**`lseek` with `SEEK_END` gives bug 5's `tell` for free**); `readdir` → `dir` |
| `alloc`/`free`, `bcopy`/`bzero`/`strcmp`…, `printf`, `twiddle` | libsa's libc | OpenBIOS's `libc/`; `twiddle` (the spinning cursor) stubbed |
| `errno`, `EIO`/`ENOENT`/`EINVAL` | the error channel | mapped to refusal by name in the package's `open` |
| `le32toh`/`be32toh` (`sys/endian.h`), `__packed` | byte order | header-only — the ppc row's control again |

**Build:** the same patch shape, `fs/libsafs/{glue.c, shim.h}` + `ext2fs.c` +
`dosfs.c` + `cd9660.c` (+ `ufs.c`), vendored byte-exact from a pinned FreeBSD
commit under a provenance README; `/packages/libsafs`; behind `CONFIG_FSYS_LIBSA`.
The oracle is FreeBSD's own `loader` in its **userboot** form reading the same
image, or simply the kernel's mount — there is no `grub-fstest` equivalent, so
the shim's oracle is one step weaker and the track says so. The measurement that
decides whether this source is worth its own patch: **S1's modern `mke2fs -t ext2`
image through `libsafs`**, before anything else.

### 2.1c The combination — which driver from which source, decided by §1(1)

The three sources are not rivals; they are three answers to *"what does the license
measurement allow, and what does the ISO door need"*, and the honest plan is a
**combination keyed to that measurement**. One shim shape per source is a cost
worth paying only for the drivers that source alone provides. So, per outcome of
§1(1):

| §1(1) finds | what may ship in a ROM that leaves the lab | ext4 with extents from | ISO 9660 + Rock Ridge from | FAT from | GPT from | what stays lab-only |
|---|---|---|---|---|---|---|
| OpenBIOS is **"v2 or later"** throughout | everything: GPLv3+ combines | **GRUB 2** (§2.1) — one shim covers ext4, ISO, FAT, XFS, HFS+, CBFS, cpio and GPT | GRUB 2 | GRUB 2 | GRUB 2 | nothing; U-Boot and `libsa` are not needed |
| OpenBIOS is **"v2 only"** — **THE MEASURED CASE (§1(1), 2026-09-07)** | GPLv2+ and BSD only | **U-Boot** (§2.1a) | **`libsa`** (§2.1b) — U-Boot has none, GRUB 2's cannot ship | `libsa` (handle-based, the better fit) or U-Boot — pick one, `libsa` | U-Boot's `disk/part_efi.c` | **GRUB 2 as a whole**, kept for the lab as the widest reader and the CBFS/cpio oracles, with its catalog row saying why it cannot leave |
| headers are **mixed** (some files v2-only) | depends on *which* files: `fs/` and `packages/` v2-only forecloses linking GPLv3 there regardless of the rest | as the v2-only row | as the v2-only row | as the v2-only row | as the v2-only row | as the v2-only row; the measurement is recorded per file, not per repo |

Two consequences worth stating:

- **In the expected case the shippable ROM is two sources, not one** — U-Boot for
  ext4, `libsa` for ISO (and FAT). That is two shim files behind two config
  switches, each the size of the 0.97 glue, and both handle-based enough to coexist
  (the `libsa` handle carries its state; the U-Boot shim caches its resolved inode
  and re-mounts on device switch, §2.1a). The **probe order** is then a decision:
  `libsa` first (cheap, refuses non-ISO/FAT/ext2 quickly), U-Boot second, 0.97
  last and off by default as the negative control.
- **The selected row, as of 2026-09-07:** the second. `packages/` and `libopenbios/`
  say *"version 2"* explicitly (§1(1)), so the ROM that may leave the lab is
  **U-Boot for ext4 + `libsa` for ISO and FAT**, and the GRUB 2 shim is a
  `DIVERGENCE`-kind patch whose catalog row says *"lab-only: GPLv3+ into v2-only
  `packages/`"*. The row moves only if the full grep finds the two explicit files to
  be the exception rather than the rule — and even then the wiki's *"V2"* would need
  a maintainer's word to read as *"or later"*.
- **The lab does not have to choose at all.** The GRUB 2 shim can exist as a
  `DIVERGENCE`-kind patch that is never in a distributed ROM, exactly as the catalog
  already carries deliberate local divergences, and its value in the lab — every
  format on one shim, the CBFS and cpio readers as foreign oracles for the toolkit's
  own — is not diminished by the restriction. What the restriction forbids is a
  *sentence* ("this ROM may be handed to someone"), and writing that sentence into
  the catalog row is the whole compliance story.

**Build:** nothing beyond §2.1/§2.1a/§2.1b — this section is the *decision table*
those three patches are selected from. Its own deliverable is one line in the patch
catalog per source: the §1(1) result, the row of this table it selected, and the
date.

### 2.1d The chosen plan — keep 0.97, add U-Boot and `libsa`; the decisive-mount rule

*Decided in discussion 2026-09-09, on the strength of §1(1)'s measurement.* Three
in-firmware packages behind one seam, all three shippable together (0.97 is GRUB's own
*"version 2 or later"*; U-Boot is GPL-2.0-or-later; `libsa` is BSD), and GRUB 2 stays
where §1(1) put it — a lab-only patch, and the only source for the formats the plan
does not reach.

**Keep the 0.97 drivers, and keep them on.** They are not only ext2: the tree carries
`fsys_fat`, `fsys_iso9660`, `fsys_xfs` (version 4), `fsys_jfs`, `fsys_reiserfs`,
`fsys_ufs`/`ufs2`, `fsys_minix`, `fsys_affs`, `fsys_ffs`, `fsys_vstafs`. On the classic
images they read today they keep reading, and for four of those formats they are the
**only** reader in the plan. They also remain the negative control §3 asks for — the
modern image must fail through them and succeed through the new package *in the same
boot* — which is a stronger control when they are on than when they are off.

**The design rule that makes three packages safe: a mount must be decisive.** POC-7
measured the failure this combination invites: the 0.97 ext2 driver recognises a
modern image by its superblock magic, reports it *mounted* (`Located filesystem`,
`INTERPOSE!`), and then fails at the directory lookup (`File not found`). If that
package probes first, nothing falls through to the one that could read it. Two fixes,
both in the dispatcher, both small:

1. **Probe order by capability, not by age** — and, for the formats with more than
   one reader, **by measured tier** (§2.1e), never by this paragraph. The shape as
   reasoned: U-Boot first for the ext2 family — its `ext4` reader handles ext2, ext3
   and ext4 uniformly, so there is no ext2 image it reads worse than 0.97 does; `libsa`
   next, for ISO and FAT; 0.97 **last**, for the formats only it has. A package never
   sees an image a better one has already claimed. Where two or three readers claim a
   format, the order is whatever `fs-tiers.toml` says on the corpus, and the
   dispatcher's table is generated from it.
2. **A mount reads the root directory, not just the superblock.** Every package's
   `open` completes its mount by listing `/`; a mount that cannot is *unmounted* and
   the next package is tried, and the refusal is printed by name
   (`grubfs: mounted ext2 but cannot read /: <feature> — trying next`). That turns
   "mounted but cannot read" — the LIED rung, a false success that outranks an honest
   failure — into an honest fall-through, and it costs one directory read per probe.

**What "full coverage" reaches with the three, and what it does not:**

| format | read by | note |
|---|---|---|
| ext2 / ext3 / **ext4 with extents** | U-Boot | the image that started the question |
| FAT 12/16/32 | `libsa`, U-Boot, or 0.97 | `libsa` first (handle-based) |
| ISO 9660 with Rock Ridge | `libsa`, or 0.97 | the door every track uses |
| btrfs, squashfs, erofs, ubifs, cramfs | U-Boot | with their decompressors (§2.1a tier 2) |
| XFS **v4**, JFS, ReiserFS, UFS/UFS2, Minix, AFFS, FFS | **0.97 only** | the reason to keep it on |
| HFS, HFS+ | OpenBIOS's native `fs/hfs`, `fs/hfsplus` | unchanged |
| CBFS | U-Boot's `fs/cbfs` | a second foreign reader of the ROM Act I walks |
| ZFS | U-Boot's reader, or `libsa`'s (CDDL) | out of scope (§5), listed for completeness |
| **exFAT, NTFS, UDF, XFS v5, F2FS** | **none of the three** | **GRUB 2 only** — no lab here makes one |

So the plan reads everything this repo's labs actually produce, and the five formats
it does not reach are ones no lab makes. That last row is the whole remaining case for
the GRUB 2 patch, and it is a lab-only case, exactly as §1(1) decided.

**Build:** the two new shims of §2.1a and §2.1b as specified there, plus the
**dispatcher**: a probe-order table in `libopenbios/`'s filesystem-package registration
(the same place `fsys_table[]` is consulted today), the decisive-mount check in each
package's `open` (three lines each: list `/`, on failure unmount and `return` the next
candidate), and one config switch per source (`CONFIG_FSYS_GRUB` stays as it is). One
track, **`fs-combo`**, reads **one image set through every package that claims it**:
the modern ext4 image (U-Boot reads, 0.97 falls through by name, `libsa` refuses by
magic), a classic ext2 image (all three read it, byte-equal to the host), a Rock Ridge
ISO (`libsa` and 0.97 agree), a FAT image (all three), and an XFS v4 image (0.97 only,
the others refuse by magic) — and asserts the **fall-through message** on the modern
image, not merely the eventual success, because the message is what proves the rule
ran rather than the order happening to be right. Negative control: the probe order
reversed (0.97 first) must reproduce POC-7's `File not found` **and be reported as a
LIED rung by the track**, so the rule is known to be load-bearing.

### 2.1e Tiering the overlaps — the probe order is a measurement, not an opinion

§2.1d's probe order was written by reasoning: U-Boot for the ext2 family, `libsa` for
ISO and FAT, 0.97 last. That is the right *shape* and the wrong *source* for a table
the dispatcher will consult on every boot: three of the formats have **two or three
readers each**, and which one goes first is a cached fact about their behaviour on
real images — exactly the kind of fact this repo keeps finding served stale. So the
overlaps get a tier each, and the tier is **derived by a track, bound to the corpus it
was derived from, and refused by name when either side moves.**

**Where the sources overlap:**

| format | 0.97 | U-Boot | `libsa` | what differs between them |
|---|---|---|---|---|
| FAT 12 / 16 / 32 | `fsys_fat` | `fs/fat` | `dosfs` | VFAT long names (0.97: yes; U-Boot: yes; `libsa`: **8.3 only** — a measurement, and the likely decider); FAT12 on a 1.44 MB floppy image (all three claim it); FAT32 with 64 KiB clusters |
| ISO 9660 | `fsys_iso9660` (Rock Ridge) | — | `cd9660` (Rock Ridge) | Joliet (neither, probably); the `;1` version suffix (0.97 strips it — the toolkit plan measured that; `libsa`'s behaviour unmeasured); a multi-extent file > 4 GiB |
| ext2, classic layout | `fsys_ext2fs` | `fs/ext4` | `ext2fs` | 256-byte inodes and `dir_index` (0.97 fails, POC-7; U-Boot reads; `libsa` **unmeasured**); symlinks; a directory with > 1,000 entries |
| ext4 | — | `fs/ext4` | — | no overlap; U-Boot by default |
| UFS / UFS2 | `fsys_ufs`, `fsys_ufs2` | — | `ufs` | UFS2 (0.97's `ufs2` vs `libsa`'s single driver); big-endian UFS from a sparc image on the ppc door |

Every cell marked *unmeasured* is one the track below settles; nothing in the table
is allowed to become a probe-order entry on the strength of this prose.

**Tier 1 — correctness, on a corpus, byte-equal to the host.** A source competes for a
format only if it reads **every** image in that format's corpus byte-equal to the
host's own reader (`mtools`/`mcopy` for FAT, `isoinfo`/`bsdtar` for ISO, `debugfs` for
ext2, the kernel's mount for all of them — foreign oracles, never one of the three
sources). The corpus is authored by a builder in the `elf-gate` shape, one image per
edge, each named for the edge it isolates:

- FAT: 12 / 16 / 32; a VFAT long name; an 8.3-only name with a lower-case flag; a
  file spanning a cluster-chain wrap; a root directory at its 512-entry limit (FAT16).
- ISO: plain; Rock Ridge; Joliet; a name that needs `;1` stripped; a 700 MB image
  whose file sits past the 2 GiB byte offset on the LE arches (the unsigned-compare
  class `vaddr>off` already caught once).
- ext2: classic; modern `mke2fs -t ext2`; a symlink; a 1,200-entry directory.

A source that reads all of a format's corpus is **eligible**; one that reads some is
**partial**, and a partial reader is never first — it is placed *after* every eligible
one, so an image it cannot read falls through to one that can, and the decisive-mount
rule (§2.1d) makes that fall-through honest. A source that reads the bytes *wrong*
on any image (not a refusal — wrong bytes) is **disqualified** for that format, by
name, until the defect is understood; a reader that lies outranks one that refuses,
on this repo's ladder, as the worse outcome.

**Tier 2 — cost, measured from outside the firmware.** Among eligible readers the tie
is broken by cost, and the cost that matters in firmware is **not wall time**: TCG
timing is noisy, KVM is not on every runner, and a read through the parent node is the
same instruction stream on every accelerator. What differs between readers is **how
many sector reads they issue** for the same work, and QEMU counts those exactly:
`info blockstats` (`rd_operations`, `rd_bytes`, `rd_total_time_ns`) on the monitor,
read before and after each operation — the observer *outside* the firmware, the way
`xp` and `pmemsave` are for the other tracks. Three operations per source per format:

| operation | what it exercises | the number |
|---|---|---|
| `load` of a 4 MiB file (the kernel's size) | read granularity, readahead, cluster-chain walking | `rd_operations` per MiB, `rd_bytes` / file size (the over-read ratio) |
| `dir` of the 1,200-entry directory | directory-walk strategy, whether it re-reads the same block | `rd_operations`; a reader that re-reads is visible as *more operations than blocks in the directory* |
| `open` of a file 8 levels deep | path-walk cost — the U-Boot shim's path-based API re-walks per `read` unless it caches (§2.1a), and this row is where that shows | `rd_operations` for one `open` + one 512-byte `read`, twice — the second must not repeat the first's walk |

Wall time is recorded beside the counts, on the hosted door and under KVM where
present, as a *secondary* figure the report labels by accelerator; it is never the
tie-breaker, because it is not reproducible on the runner that matters.

**The tier table is data with provenance, not a constant.** The `fs-tiers` track
emits `fs-tiers.toml`: per format, the ordered readers, each with its corpus verdict
(eligible / partial / disqualified, and which image decided it) and its cost row, plus
the sha256 of the corpus builder's output and the pinned commits of the three sources.
The dispatcher's probe-order table (§2.1d) is **generated from it**, not typed, and a
checker in `tools/tests/` fails the run when the generated table and the toml disagree
— the track-list checker's shape. When the corpus builder changes or a source's pin
moves, the toml's hashes no longer match and the *track* refuses to grade against it
by name until re-derived: the record cannot outlive its subject.

**Two things the measurement is expected to find, written down so the surprise is
legible either way:**

- **The FAT tier is probably not `libsa` first.** The reasoning in §2.1d put `libsa`
  ahead for its handle-based API; if `dosfs` reads 8.3 names only, it is *partial* on
  the FAT corpus and drops behind both 0.97 and U-Boot, and the order becomes
  U-Boot, 0.97, `libsa` — the opposite of the prose. That is the point of the track.
- **0.97 may win a cost row it loses on correctness.** Its `devread()` takes a byte
  range and the glue reads only the sectors covering it; U-Boot's `blk_dread` is
  whole-block and the shim may over-read. If 0.97 posts the fewest `rd_operations` on
  the 4 MiB load, that is a finding about the *U-Boot shim's* granularity to fix, not
  a reason to put a partial reader first.

**Build:** the corpus builder (`fixtures/fs-corpus/build-fs-corpus.sh`, one image per
edge, host oracles named per format); the `fs-tiers` track (all three packages
compiled in, `info blockstats` deltas via the monitor, the toml emitted with its
provenance hashes); the generator from toml to the dispatcher's table; and the
checker that binds them. **Controls:** an image the builder corrupts by one byte in a
directory entry must be *refused* by every eligible reader, not read wrong (the
disqualification path, watched to bite); and a `rd_operations` delta of zero on any
row is a **broken instrument** (the read went to a cache the monitor cannot see, or the
wrong device was measured), reported as such rather than as a free read.

### 2.2 Seam 2 — the partition maps, for the same price

GRUB 2's `partmap/gpt.c` and `partmap/msdos.c` use nothing but `grub_disk_read`
and `grub_partition_map_register`. OpenBIOS's `packages/pc-parts.c`,
`mac-parts.c` and `sun-parts.c` read MBR, Apple and Sun labels; **none reads GPT**,
which is what every disk image the repo's newer labs make carries. Same shim, one
more package (`grub2parts`), and the ZFS-boot and PXE-lab disk images become
`dir`-able at the prompt.

**Build:** the two partmap files under the same `CONFIG_FSYS_GRUB2`; one track,
`gpt-parts`, `dir hd:2,\` on a GPT image whose second partition the host made with
`sgdisk`, with an MBR image as the control (both packages must agree there).

### 2.3 Seam 3 — bring your own filesystems: the loader as a client program

The route that reaches **OFW**, and the one that needs **no firmware change** on
either (on OpenBIOS-ppc the *stock* QEMU blob runs C clients; on OpenBIOS-x86 the
client interface needs the clib lab's revival patch first — a firmware change that
already exists, not a new one). For the same library **linked into** OpenBIOS as a
package, see §2.1b. The clib lab already runs freestanding C programs that the firmware `load`s
and enters, calling back through the IEEE 1275 client interface (`open`, `read`,
`seek`, `claim`). A filesystem reader that does its sector I/O through **that**
interface needs nothing from the firmware but a block device — which is precisely
how FreeBSD's boot loader has run on Open Firmware for two decades:
`stand/libofw` (the client-interface disk strategy) + `stand/libsa` (the filesystem
library: `ufs`, `ext2fs`, `dosfs`, `cd9660`, `nfs`, `tftp`, and a `zfs` reader
under CDDL), BSD-licensed, on ppc/ppc64 today (the sparc64 port was removed in 13).

`libsa`'s interface is worth noticing: `struct fs_ops { open, close, read, write,
seek, stat, readdir }` over a device `strategy (devdata, rw, dblk, size, buf,
rsize)` — **that is GRUB 0.97's `devread()` with the arguments in a different
order**, the same bootloader-shaped seam grubfs already wraps.

What it costs: the client can serve files **to itself** — a loader that then boots
a kernel — but it cannot serve them **to the firmware's `load`**, since a client
program is not a `/packages` node. So this route gives *"boot Linux off a modern
ext4 disk on OFW"* (the loader reads the kernel and initrd and jumps, the way
FreeBSD's `loader` boots FreeBSD) and does **not** give *"`dir hd:\` at the `ok`
prompt lists a modern ext4"*. Both are worth having; they are different deliverables.

**Build:** a client in the clib lab's shape — `libsa` vendored under its own
provenance README, its `strategy` bound to `cif-open`/`cif-read`/`cif-seek` on the
disk ihandle, `main()` = open a path, print its size, read and sha256 it (the
toolkit's `sha256` on the host is the oracle); one track per firmware, `libsa-ofw`
and `libsa-openbios`, same binary. The **UNKNOWN by name**: ext2 in `libsa` predates
extents too — it reads the classic layout, so *modern* ext4 through this route is
FreeBSD's newer `ext2fs` or U-Boot's, and which one the client carries is a
decision, not a given.

### 2.4 Seam 4 — transliteration: a GRUB 2 driver as the specification for Forth

The other route to OFW, and the only one that gives OFW's own `load` a modern
filesystem. OFW's ext2 package is Forth; GRUB 2's `ext2.c` is ~1,100 lines of C of
which the part OFW's package lacks — the **extent tree** (`ext4_extent_header`,
`ext4_extent_idx`, `ext4_extent`, the depth-first walk to a logical block) and the
feature-flag gates (`INCOMPAT_EXTENTS`, `INCOMPAT_64BIT`, `RO_COMPAT_HUGE_FILE`, and
a refusal by name for the ones it does not implement, `INCOMPAT_INLINE_DATA`,
`INCOMPAT_ENCRYPT`) — is a few hundred lines of logic. That is **authoring, not
lifting**, and the honest name for it is a port with GRUB 2 as the reference
implementation: every structure is a `struct.fth`-style layout (the toolkit's type
layer *is* the tool for this, and it already parses ELF and CBFS the same way).

**Build:** `ext4.fth` — the extent walk as a package method beside OFW's existing
ext2 package, loaded the way the habitats lab loads vocabularies; one track,
`ofw-ext4`, reading a modern `mke2fs -t ext4` image whose one file the host
sha256'd; the control is the same image through OFW's stock package, which must
fail *by name* (unknown incompatible feature), never by reading the wrong blocks.
Scope guard: **read-only**, extents and 64-bit only, no journal replay (a dirty
image is refused, not replayed), no htree lookups (linear directory scan — slow is
honest, wrong is not).

## 3. Grading, per this repo's rules

- **The shim is the only new code, so the shim gets the sharpest oracle.** For
  every image and path in the track, the bytes `load` produces through the new
  package **equal the bytes `grub-fstest cp` produces** from the same image on the
  host — the same driver, GRUB's own shim versus ours. A difference is a shim bug
  by construction, and a *foreign* oracle (the kernel's mount, `debugfs`, `mtools`,
  `isoinfo`) then says which of the two is right.
- **The old package is the negative control, not deleted.** A modern-`mke2fs` image
  must read as `File not found` through `grubfs` and as the right bytes through
  `grub2fs`, in the same boot; a classic image must read identically through both.
  A track where the old package cannot be made to fail is not proving what the new
  one fixed.
- **Every door, every driver.** The four-arch matrix is the byte-order control: the
  ppc row reading little-endian ext4 fields through `grub_le_to_cpu32` and
  big-endian HFS+ through `grub_be_to_cpu32` in the same boot is the assertion that
  the accessors were used and not the CPU's order. A driver that passes on x86 only
  is listed as **UNCOVERED on ppc**, by name, not folded into the pass.
- **Silent failure is the enemy on record.** POC-7's FAT-not-compiled-in failed with
  `state-valid` = 0 and no message. The new package's `open` maps every set
  `grub_errno` to a printed refusal, and the track asserts the *message*, then the
  outcome — and the habitats' rule holds: gate on `load-size`, never on the ` ok`.
- **Refuse before the irreversible step.** A filesystem opened read-only cannot do
  harm, but a *loader* that trusts a size can: `file->size` from the new package
  feeds `file_size()` and thence every loader's allocation — bug 5's blast radius.
  The track reads a file larger than 4 GiB's low word (a sparse image) and requires
  the size to be right, not truncated.
- **Provenance is cite, not mirror**, with one exception: `fshelp.c` and each
  driver land in the patch **byte-exact from a pinned GRUB commit** with the commit
  in the patch header, and `check-patch-hygiene.sh`'s `Arch-tested:` line names
  the doors each driver was read on.

## 4. A sequence, and what to build by seam

| step | the line that must print | needs |
|---|---|---|
| S0 | the three numbers of §1: the header count (**sampled 2026-09-07: v2-only in `packages/` and `libopenbios/`; the full grep still owed**), the ppc image against its ceiling, the package interface as measured | a morning; no code |
| S1 | `dir hd:\` through `grub2fs` lists a **modern `mke2fs`** ext4 image on unix and x86; the same path through `grubfs` says `File not found` in the same boot | the shim + `ext2.c` + `fshelp.c` (§2.1) |
| S2 | the same, plus FAT with a long name and an ISO with Rock Ridge, on all four doors — or UNCOVERED on ppc *by name* if S0's ceiling said so | tier 1 |
| S3 | `dir hd:2,\` on a GPT image; MBR unchanged through both packages | §2.2 |
| S4 | `dir cbfs:\` lists `fallback/payload` in the lab's own `coreboot.rom` — and its entry count equals `dsl/cbfs.fth`'s and `cbfstool`'s | tier 1a |
| S5 | a client program prints the sha256 of a file it read through the client interface on **stock** `openbios-ppc` and on OFW, equal to the host's | §2.3 |
| S6 | OFW's own `load` reads a modern ext4 image through `ext4.fth`; the stock package refuses it by name | §2.4 |

| seam | file / patch | words / methods | track | graded by |
|---|---|---|---|---|
| the measurements (§1) | a note in the patch catalog | — | — | three numbers, written down |
| 1 — GRUB 2 shim (§2.1) | patch N, `fs/grub2fs/`, `CONFIG_FSYS_GRUB2` | `/packages/grub2fs`: `open` `read` `seek` `tell` `dir` `load` | `grub2fs` | `grub-fstest cp` byte-equal; the kernel's mount; old package as control |
| 1a — U-Boot shim (§2.1a) | patch N, `fs/ubootfs/`, `CONFIG_FSYS_UBOOT` | `/packages/ubootfs`, same five methods | `grub2fs` re-aimed | U-Boot sandbox `ext4load` byte-equal; the kernel's mount; old package as control |
| 1b — `libsa` shim (§2.1b) | patch N, `fs/libsafs/`, `CONFIG_FSYS_LIBSA`, `libsa` vendored with provenance | `/packages/libsafs`, same five methods | `grub2fs` re-aimed; **S1 on a modern `mke2fs -t ext2` image first** | the kernel's mount; old package as control (no `grub-fstest` twin — said so) |
| 1c — the combination (§2.1c) | one catalog line per source | — | — | the §1(1) result and the table row it selected, dated |
| 1d — the dispatcher (§2.1d) | the probe-order table (**generated from `fs-tiers.toml`**) + the decisive-mount check in each package's `open` | `open` lists `/` or falls through by name | `fs-combo` | one image set through every package that claims it; the fall-through **message** asserted on the modern image; reversed order reported as LIED |
| 1e — the tiers (§2.1e) | `fixtures/fs-corpus/build-fs-corpus.sh`; `fs-tiers.toml` with provenance hashes; the toml-to-table generator; a `tools/tests/` checker binding them | — | `fs-tiers` | byte-equal to host oracles per format (eligible / partial / disqualified); `info blockstats` deltas per operation; a zero delta is a broken instrument; a one-byte corruption refused, not read wrong |
| 2 — partition maps (§2.2) | same patch, `partmap/` (or U-Boot's `disk/part_efi.c`) | `/packages/grub2parts` | `gpt-parts` | `sgdisk`-made image; MBR control |
| 3 — bring your own (§2.3) | a client under the clib lab, `libsa` vendored | `strategy` over `cif-read` | `libsa-ofw`, `libsa-openbios` | host sha256; stock firmware, no build |
| 4 — transliteration (§2.4) | `ext4.fth` in the OFW lab | the extent walk as a package method | `ofw-ext4` | host sha256; stock package refuses by name |

## 5. What this is NOT (scope guards)

- **Not a write path.** Every route is read-only. `write-file` on unix and the pmem
  seam exist for authoring; a filesystem *writer* in firmware is a different lab
  with a different risk (a wrong write is the `dd`).
- **Not a network stack.** `libsa` carries `nfs` and `tftp`; they are left out here
  on purpose — the netboot labs own that door.
- **Not ZFS.** Neither GRUB 2's nor `libsa`'s ZFS reader comes along; the ZFS-boot
  lab reaches ZFS through ZFSBootMenu, which is where that belongs.
- **Not an upstream submission.** Per the patch catalog's standing decision, nothing
  goes to `openbios/openbios`; this patch is carried like the other 68.

## 6. Open questions — the ones to discuss

1. **Which OpenBIOS sources, once §1(1) is measured** — §2.1c's table answers it
   per outcome; what is left to discuss is whether the expected two-source ROM
   (U-Boot ext4 + `libsa` ISO/FAT) is worth two shims, or whether one source and
   a stated gap (U-Boot alone, no ISO; `libsa` alone, no ext4) is the better lab.
   The recommendation is GRUB 2 for the lab, because ISO is the door every track
   here uses, and to *state* the shipping restriction rather than avoid it.
2. **Does the client route (§2.3) want FreeBSD's `loader` itself, or a small client
   on `libsa`?** The whole loader boots FreeBSD and Linux (via its `kexec`-less
   `bsd` and `elf` loaders) and is a product; a small client is a lab. The clib
   lab's shape says small client; the "boot Linux off ext4 on OFW" payoff says
   loader.
3. **Does the ppc image fit?** §1(2). If not, the honest partition is *tier 1 on
   x86/amd64/unix, UNCOVERED on ppc by name* — or a ppc build with only `ext2.c`
   and `iso9660.c`, which is a per-arch config and not a fork.
4. ~~**Should `grub2fs` replace `grubfs` once it reads everything the old one can?**~~
   **Answered 2026-09-09 (§2.1d): keep 0.97, and keep it ON** — it is the only
   reader in the plan for XFS v4, JFS, ReiserFS, UFS, Minix and AFFS, and an
   on-by-default control is stronger than an off one. What made "on" safe is the
   decisive-mount rule; without it, 0.97 claiming a modern ext4 first is POC-7 again.
5. **Which reader wins FAT?** §2.1e expects the measurement to contradict §2.1d's
   prose: if `libsa`'s `dosfs` is 8.3-only it is *partial* and drops to last, and the
   order is U-Boot, 0.97, `libsa`. The corpus decides; the prose does not.
6. **Is §2.4 worth doing at all**, given §2.3 reaches OFW without touching it? Only
   if *"the frozen firmware's own `load` reads modern disks"* is the sentence
   wanted — which is the sister lab's thesis (fix it live at the prompt), so
   probably yes, but after §2.3 has shown the cheaper route.
