# Manual testing — OpenBIOS modern filesystems

S0 (the two feasibility measurements) is complete and the shim's spec is vendored;
**S1 — the `grub2fs` read shim — now reads a modern ext2 filesystem** (POC-1b build +
POC-2 read, §3 below). The remaining formats (FAT/ISO) and the tracks are not built
yet. Anything marked *pending* is an honest UNKNOWN, not a pass.

## 1. The vendored spec is byte-exact (integrity)

The four GRUB 2.12 driver files must hash to what
[`upstream-grub/README.md`](upstream-grub/README.md) records:

```console
$ cd examples/openbios-modern-filesystems/upstream-grub
$ sha256sum ext2.c fat.c iso9660.c fshelp.c
1a23a4c0…56233260  ext2.c
5da2eea5…f3bc0817  fat.c
da5dd920…94f1448c  iso9660.c
28423516…ea4b04a6  fshelp.c
```

And they must be exactly the files GRUB 2.12 ships, from a tarball whose own
`sha256` is `f3c97391…7fe0faa` and whose GPG signature verifies against the GRUB
release-manager key (`BE5C…2166`). The success signature: the per-file hashes match,
**and** they are reproduced from a GPG-**Good** tarball (not an error page).

## 2. Reproduce the S0(2) ppc driver-size number (the feasibility measurement)

The claim (plan §1(2)): the four drivers compiled `-Os` for a real
`powerpc-ieee1275` target fit the Mac ROM ceiling with an ~18× margin. To reproduce,
build for that target with the lab's own cross toolchain (the `powerpc-linux-gnu-gcc`
in the `openbios-build` container — the package QEMU's stock openbios-ppc is built
with) and `size` the linked objects:

```console
# GRUB's configure records the real target flags: -Os -m32 -mbig-endian
#   -DGRUB_MACHINE=POWERPC_IEEE1275
$ size ext2.module fat.module iso9660.module fshelp.module   # text+data
#   ext2   4577+55 = 4632
#   fat    4986+55 = 5041
#   iso9660 7329+55 = 7384
#   fshelp 2284+15 = 2299   → 19,356 B total (~18.9 KB)
$ readelf -h ext2.module | grep -E 'Machine|Data'
#   Data: 2's complement, big endian   Machine: PowerPC   (the byte-order control)
```

Against the ROM: `openbios-qemu.elf` is 689,492 B (text+data 663,512 B); the mac99
`-bios` ceiling is exactly 1 MiB (`1048576` accepted, `+1` rejected). Headroom
≈ 351 KB, so 18.9 KB of drivers clears it ~18×. **Verdict: the ppc size ceiling does
not partition the matrix.** `size` reports only ALLOC sections, so `-g` debug info
does not inflate the figure; the objects carry unresolved externals (`grub_disk_read`,
`grub_malloc`) that the shim maps to firmware equivalents (§1a), not new ROM.

## 3. S1 — grub2fs reads a modern ext2 filesystem (POC-1b + POC-2)

Prerequisite: the rival lab's `openbios-unix` exists (it is the negative-control,
grubfs-only firmware) — `openbios-the-rival-that-shipped/build-openbios.sh unix`.

```console
$ cd examples/openbios-modern-filesystems
$ ./build-grub2fs.sh          # builds openbios-unix WITH grub2fs, in a THROWAWAY copy
                              # of the tree (the shared tree is never touched), leaving
                              # $WORKDIR/grub2fs/openbios-unix (+ .dict)
$ ./smoke-grub2fs.sh
  - POSITIVE: grub2fs firmware mounts the modern ext2 image and loads /HELLO
  - grub2fs read /HELLO from the modern image, 65 bytes, byte-equal to grub-fstest
  - CONTROL A: the stock grubfs firmware on the SAME modern image -> expect File not found
  - grubfs on the modern image: File not found (0.97 cannot read its dir_index/256-byte-inode directory)
  - CONTROL B: the stock grubfs firmware reads the CLASSIC image == its grub-fstest oracle
  - grubfs read /HELLO from the classic image, byte-equal to grub-fstest — it works, just not on modern ext2
PASS: grub2fs … read /HELLO from a MODERN ext2 image (inode size 256, dir_index/filetype)
      byte-for-byte equal to grub-fstest, which the shipped 0.97 grubfs could not …
```

**Success signature:** one `PASS:` line, exit 0; the modern-image bytes equal the
`grub-fstest <img> cp /HELLO -` foreign oracle, and the negative control **bites**
(the stock grubfs firmware returns `File not found` on the modern image while reading
the classic one). `smoke-grub2fs.sh` runs `build-grub2fs.sh` itself if the firmware is
absent, and SKIPs by name without podman / grub-fstest / mke2fs / the stock firmware.

**The load-base gotcha (why the drive sets it):** openbios-unix's default `load-base`
is unmapped, so a real read there segfaults (`segmentation violation at 4000000`) — not
a grub2fs bug. The drive sets `load-base` to an `alloc-mem` buffer first
(`100000 alloc-mem value bb  bb (u.) s" load-base" $setenv`), the same pattern the
rescue lab's config act uses. With that, `load hd:\HELLO` reads into the buffer.

**Non-destructive:** `build-grub2fs.sh` builds in a copy under `$WORKDIR/grub2fs-build`
and removes it on exit (even on failure) — the shared `openbios/` tree that the rival
and habitats labs build from is never modified. Re-runnable and idempotent.

## 3a. FAT + ISO 9660 (POC-3) — done, same `./smoke-grub2fs.sh`

`smoke-grub2fs.sh` also authors a FAT image (`mkfs.vfat` + `mcopy`) and an ISO 9660
image (`xorriso`/`genisoimage`), each holding `/HELLO`, and asserts `grub2fs` reads
each **byte-for-byte equal to `grub-fstest`**. Unlike the ext2 arm there is no
"grubfs can't read it" control — 0.97 `grubfs` reads basic FAT/ISO too — so the proof
for these formats is the `grub-fstest` foreign oracle. This exercised the new
**grub2fs heap** (`fat.c`/`iso9660.c` call `grub_realloc`/`grub_calloc`, which OpenBIOS
cannot provide — `free()` is a no-op over a 128 KiB bump); grub2fs supplies a first-fit
free-list over a 1 MiB static arena. Build determinism verified 5/5. Extra SKIP guards
name `mkfs.vfat` / `mcopy` / an ISO tool if absent.

## 3b. Big-endian byte-order control (POC-4) — `./smoke-grub2fs-arches.sh`

Everything above ran little-endian (amd64), exercising only the identity byteorder
path. POC-4 builds grub2fs into the **real ppc firmware** (`build-grub2fs-arch.sh ppc`
→ `openbios-qemu.elf`) and drives it in **`qemu-system-ppc` (big-endian)**:
`load hd:\HELLO` via grub2fs off a modern ext2 disk, and the loaded bytes (printed with
`type` between `DA<`/`>DA` markers — take the *last* pair; the driver echoes the typed
command first) must equal `grub-fstest`. They do: `load-size` = 66 and the data match,
so the ext2 **inode size** (a little-endian on-disk field read through `grub_le_to_cpu`,
which SWAPS on ppc) and the data blocks were both read correctly — the assertion that
the typed accessors were used, not the CPU's native order.

**Finding:** the 1 MiB **static-BSS heap overflowed the ppc ROM** (link died with
`.bss VMA wraps around address space` — the S0 1 MiB mac99 ceiling). Fixed by claiming
the heap from RAM at first use (`alloc-mem` in `g2_init`, post-boot when the memory
system is up), which fits any ROM; the hosted LE path was re-verified (no regression).
**UNCOVERED-by-name:** FAT/ISO on ppc (`smoke-grub2fs-arches.sh` reports 0 bytes — a ppc
`hd:`/`cd:` device-path quirk, not a byteorder failure; the shared `grub_le_to_cpu` is
proven by the ext2 row); the x86 real-firmware row; sparc (no sparc cross-toolchain in
the build container). Run: `./smoke-grub2fs-arches.sh` → `PASS: grub2fs read a MODERN
little-endian ext2 filesystem correctly on a BIG-ENDIAN ppc firmware …`.

## 4. The tier table (POC-5, `fs-combo`/`fs-tiers`) — `./smoke-fs-tiers.sh`

POC-1..4 proved grub2fs *reads* each format. POC-5 asks the §2.1e question: **when
two packages both claim a format, which goes first — and is that a measurement or an
opinion?** It reads **one corpus of edge images through every reader this lab has** and
*derives* the probe order, byte-for-byte against a foreign host oracle.

```
$ ./fixtures/fs-corpus/build-fs-corpus.sh        # one image per edge (ext2/FAT/ISO),
                                                 # each foreign-validated (debugfs/mcopy/isoinfo)
$ ./smoke-fs-tiers.sh                            # derive + verify the table; run the controls
$ ./smoke-fs-tiers.sh --emit                     # regenerate fs-tiers.toml from live measurement
```

Two readers exist here: **grubfs** (GRUB 0.97, the stock firmware) and **grub2fs**
(GRUB 2). For unambiguous attribution each read goes through a **single-reader**
firmware — the stock grubfs-only build, and a **grub2fs-only** build
(`GRUB2FS_ONLY=1 ./build-grub2fs.sh`, grubfs *not* registered) — so no probe-order
guess about which package handled a read. The measured table
([`fs-tiers.toml`](fs-tiers.toml)):

| format | grub2fs | grubfs | order | decided by |
|---|---|---|---|---|
| **ext2** | eligible | **partial** (reads classic; `File not found` on modern) | `grub2fs, grubfs` | **correctness** (decider: `ext2-modern`) |
| **iso9660** | eligible | eligible | `grub2fs, grubfs` *(provisional)* | **tie — UNBROKEN** (needs Tier 2 cost) |
| **fat** | eligible | not-a-reader (`Unknown` — `CONFIG_FSYS_FAT=false` here) | `grub2fs` | sole reader here |

The table is **bound to the corpus by an anchor sha256** (over the corpus *definition*
— manifest + `.expected` payloads + the builder — not the image bytes, which carry
ambient mkfs timestamps); a stale toml is refused by name. Three controls, each watched
to bite: **A (LIED)** reversing the ext2 order (grubfs first) reproduces POC-2's
`File not found`, so the order is load-bearing; **B (STALE)** a mangled anchor is
refused; **C (grader)** a byte-changed payload is read back as the *new* bytes (the
reader follows on-disk content, not a cached value). Verdict:
`PASS: fs-tiers derived from a foreign-graded corpus … controls A, B, C all bit`.

**UNCOVERED-by-name (POC-5):** **Tier 2 cost** (sector-read count via QEMU
`info blockstats`) is **UNMEASURED** — the hosted firmware reads a host file directly
and has no counted block device, so the `iso9660` tie stays unbroken until measured on
a QEMU arch. The **U-Boot** and **`libsa`** readers (design §2.1a/b) are **not built** —
this is honestly a two-reader table. The **dispatcher** (§2.1d, decisive-mount
fall-through in `libopenbios/`) is not built; `fs-tiers.toml` is the *data* a generated
probe-order table would consume.

## 5. Pending (not yet built — UNKNOWN, by name)

- **`store-tiers`** (§2.5) and the **`fs-edit-inplace`** endgame (§2.6, same-length
  in-place write on a real block fs). *Pending.*
- **Tier 2 cost** for `fs-tiers` (above) — needs a QEMU arch's `info blockstats`.
- x86 real-firmware + sparc rows of the four-arch matrix (ppc is DONE — §3b). sparc: no
  cross-toolchain in the build container. sun4m/sparc32's ROM ceiling was **not** measured
  (a sparc ceiling, out of
  scope for the ppc number) — UNCOVERED by name.
