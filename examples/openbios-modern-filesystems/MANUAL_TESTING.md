# Manual testing — OpenBIOS modern filesystems

This lab is **scaffolding**: S0 (the two feasibility measurements) is complete and
the shim's specification is vendored; S1 (the `grub2fs` read shim) and the tracks
are not built yet. So what is testable today is the **integrity of the vendored
spec** and the **reproduction of the S0 numbers**. Anything below marked *pending*
is an honest UNKNOWN, not a pass.

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

## 3. Pending (not yet built — UNKNOWN, by name)

- **S1 — the `grub2fs` read shim** (`/packages/grub2fs`): a modern `mke2fs -t ext2`
  image should read `File not found` through the old `grubfs` and the **right bytes**
  through `grub2fs`, in the same boot, byte-for-byte equal to `grub-fstest cp` on the
  host. *Pending.*
- **`fs-combo` / `fs-tiers` / `store-tiers` / `fs-edit-inplace`** tracks. *Pending.*
- Four-arch matrix (x86 / amd64 / ppc / sparc), the ppc row as the byte-order control.
  *Pending.* sun4m/sparc32's ROM ceiling was **not** measured (a sparc ceiling, out of
  scope for the ppc number) — UNCOVERED by name.
