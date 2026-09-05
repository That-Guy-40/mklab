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
  **distributed**. A lab ROM that is built and run here is not distribution. (2) the
  ppc firmware's size ceiling — QEMU maps it into a fixed region. (3) whether the
  seam is the firmware at all, or a client program.
- **The three routes, ranked by what they cost and where they can go:**
  - **GRUB 2 shim in OpenBIOS** — most drivers, best-tested code, the cheapest shim;
    lab-only unless the license measurement surprises.
  - **U-Boot's `fs/` in OpenBIOS** — GPLv2-or-later, so *shippable*; ext4 with
    extents, FAT, btrfs, squashfs, erofs — and **no ISO 9660** at all, which is the
    door most of this repo's labs use. Also the survey's "U-Boot has zero coverage".
  - **A client program with FreeBSD's `libsa`** — BSD-licensed, bootloader-shaped
    (its `devread` is nearly the 0.97 interface grubfs already wraps), runs on **OFW
    and OpenBIOS unchanged**, needs no firmware patch; ext2 without extents, FAT,
    ISO 9660, UFS, ZFS. The only route that reaches the frozen firmware.
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
either. The clib lab already runs freestanding C programs that the firmware `load`s
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
| S0 | the three numbers of §1: the header count, the ppc image against its ceiling, the package interface as measured | a morning; no code |
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
| 2 — partition maps (§2.2) | same patch, `partmap/` | `/packages/grub2parts` | `gpt-parts` | `sgdisk`-made image; MBR control |
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

1. **Which OpenBIOS route, once §1(1) is measured:** a GRUB 2 lift as a lab-only
   artifact with the license written into the catalog row, or a U-Boot `fs/` lift
   that could leave the lab — at the price of no ISO 9660 and a second shim shape.
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
4. **Should `grub2fs` replace `grubfs` once it reads everything the old one can?**
   Keeping both keeps the negative control; replacing removes 0.97 code with two
   known defects. The answer is probably *keep, off by default, for the control*.
5. **Is §2.4 worth doing at all**, given §2.3 reaches OFW without touching it? Only
   if *"the frozen firmware's own `load` reads modern disks"* is the sentence
   wanted — which is the sister lab's thesis (fix it live at the prompt), so
   probably yes, but after §2.3 has shown the cheaper route.
