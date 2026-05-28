# Reproducible builds & attestation

micro-linux artifacts are **bit-for-bit reproducible**: given the pinned source
(`versions.env` + `versions.lock`) and the digest-pinned toolchain image, two
independent builders produce byte-identical `kernel` and `initramfs.cpio.gz`.

## Why this matters (the §6.0 / §8 residual)

The build verifies every download against a *vendored* signing key (not a fetched
checksum), which defeats a malicious mirror. The residual it can't defeat alone is
an **upstream signing-key compromise** — if kernel.org's or BusyBox's key signed a
backdoored tarball, `gpgv` would still pass. The only real mitigation is
**independent rebuild attestation**: many parties build from the pinned source and
publish the artifact hashes; a divergence (or a hash that doesn't match a widely
reproduced one) is the signal. Reproducibility is what makes that comparison
meaningful — it reduces "do you trust my binary?" to "do we agree on the source?".

## What makes it deterministic

| Source of non-determinism | How it's pinned |
|---|---|
| Kernel build identity (`compile.h`: `user@host`, build date) | `KBUILD_BUILD_USER`/`HOST` + `KBUILD_BUILD_TIMESTAMP` (derived from `SOURCE_DATE_EPOCH`), exported by `export_repro_env` |
| Kernel `#N` build counter | reset to `#1` by a **clean** build (fresh source tree → no `.version`) |
| BusyBox banner build date | `SOURCE_DATE_EPOCH` (BusyBox honors it natively) |
| cpio entry **mtimes** (BusyBox track) | `gen_init_cpio -t $SOURCE_DATE_EPOCH` (it otherwise stamps `time(NULL)`) |
| cpio ownership / order (BusyBox track) | `uid/gid 0` + `LC_ALL=C`-sorted file list (`emit_cpio_spec`) |
| gzip header (name+mtime) | `gzip -9 -n` |
| u-root cpio (riscv64 track) | u-root's `mkuimage` applies `cpio.MakeReproducible` (zeroes mtime/uid/gid/ino) natively; the Go binaries are deterministic given the pinned Go + the fixed in-container build path |
| Toolchain | `BASE_IMAGE` pinned by digest in `versions.env` |

`SOURCE_DATE_EPOCH`, `KBUILD_BUILD_USER`, and `KBUILD_BUILD_HOST` are pinned in
`versions.env`; bump them freely, just keep them committed so everyone matches.

## Reproduce & attest

```bash
# A clean build is required (the kernel #N counter must reset to #1):
micro-linux/mlbuild.sh clean --arch x86_64,aarch64,riscv64
micro-linux/mlbuild.sh all   --arch x86_64,aarch64,riscv64   # --offline if tarballs are cached
micro-linux/mlbuild.sh hashes --arch x86_64,aarch64,riscv64  # print the artifact sha256
```

Compare your output to the reference set below (and to other people's). A match
means your toolchain + source reproduced the published binaries exactly.

## Variants produce distinct, reproducible hashes

The `--musl`, `--tiny`, and `--baked` variant builds are **also reproducible**
— the same pins + toolchain produce byte-identical variant artifacts — but they
produce *different hashes* from the defaults (different binary content, obviously).
The reference hashes below cover only the default track (`initramfs.cpio.gz` /
`kernel`).  For variants, generate your own reference set and commit it:

```bash
micro-linux/mlbuild.sh clean --all
micro-linux/mlbuild.sh all --arch x86_64,aarch64 --all-variants
micro-linux/mlbuild.sh hashes --arch x86_64,aarch64   # prints all present artifacts
```

`print_hashes` / `hashes` now covers `kernel-tiny`, `kernel-baked`, and
`initramfs-musl.cpio.gz` alongside the defaults.

Two things to keep in mind when attesting variant builds:

- **`--baked` kernel hash depends on the initramfs content.**  If you change
  the BusyBox feature set, the credentials (`MLBUILD_LAB_PASSWORD`), or any
  file in `_install/`, the `kernel-baked` hash changes even if the kernel
  source is unchanged.  Treat `kernel-baked` as a joint artifact of both source
  components.
- **`--tiny` uses an out-of-tree build** (`O=build-tiny/`) — the in-tree default
  kernel build is untouched and its hash is stable across `--tiny` runs.

## Reference hashes

Built with, and valid for, exactly these pins:

- `BASE_IMAGE = debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb`
- `LINUX_VER = 6.12.30`, `BUSYBOX_VER = 1.36.1`
- `SOURCE_DATE_EPOCH = 1700000000`, `KBUILD_BUILD_USER = mklab`, `KBUILD_BUILD_HOST = micro-linux`

```
34556542112a9b24f7859db3afe3d36bb8857139d26755530b86d5e7ca13f2b9  x86_64/kernel
07abcdefca1cc71bda6cdcda1fcb5e204981c0ed23fb5dec6e1b0253770dbd80  x86_64/initramfs.cpio.gz
bfba8379497ceeacca90fa5d45accb1ebd68cf37e6d72f03886a20eca44f7a43  aarch64/kernel
bdcb92068defe90e55ae2ab415519af1e37822d2c92f111d608015b0c13aaaf0  aarch64/initramfs.cpio.gz
10561c5f77ed461ad5d32ab082964437a8838eaaeff2c990a8f53afd1be2b2c6  riscv64/kernel
099d34a027d358f26cac708215af76fdd6b8b61ce71b8e0232d5442ae10e9c16  riscv64/initramfs.cpio
```

Each was confirmed by two independent clean builds (riscv64 included — `UROOT_REF
= v0.14.0`, `GO_VER = 1.22.5`). If you bump any pin above (kernel/busybox/u-root
version, Go version, base-image digest, or `SOURCE_DATE_EPOCH`), regenerate this
table with `mlbuild.sh hashes`.

> **riscv64 / u-root note.** The Go track reproduces without any extra flags: the
> kernel goes through the same `KBUILD_BUILD_*` path as the other arches, and
> u-root's `mkuimage` already normalizes the cpio (`cpio.MakeReproducible`). We do
> *not* add `-trimpath`: the build always runs at the fixed in-container path
> (`/work/...`), so embedded paths don't vary between builders, and adding it
> would only change the hashes without improving the container-based attestation.
