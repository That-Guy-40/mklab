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

## 4. Pending (not yet built — UNKNOWN, by name)

- **`fs-combo` / `fs-tiers` / `store-tiers` / `fs-edit-inplace`** tracks. *Pending.*
- Four-arch matrix (x86 / amd64 / ppc / sparc), the ppc row as the byte-order control.
  *Pending.* sun4m/sparc32's ROM ceiling was **not** measured (a sparc ceiling, out of
  scope for the ppc number) — UNCOVERED by name.
