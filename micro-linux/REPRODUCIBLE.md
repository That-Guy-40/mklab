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
| cpio entry **mtimes** | `gen_init_cpio -t $SOURCE_DATE_EPOCH` (it otherwise stamps `time(NULL)`) |
| cpio ownership / order | `uid/gid 0` + `LC_ALL=C`-sorted file list (`emit_cpio_spec`) |
| gzip header (name+mtime) | `gzip -9 -n` |
| Toolchain | `BASE_IMAGE` pinned by digest in `versions.env` |

`SOURCE_DATE_EPOCH`, `KBUILD_BUILD_USER`, and `KBUILD_BUILD_HOST` are pinned in
`versions.env`; bump them freely, just keep them committed so everyone matches.

## Reproduce & attest

```bash
# A clean build is required (the kernel #N counter must reset to #1):
micro-linux/mlbuild.sh clean --arch x86_64,aarch64
micro-linux/mlbuild.sh all   --arch x86_64,aarch64      # --offline if tarballs are cached
micro-linux/mlbuild.sh hashes --arch x86_64,aarch64     # print the artifact sha256
```

Compare your output to the reference set below (and to other people's). A match
means your toolchain + source reproduced the published binaries exactly.

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
```

Each was confirmed by two independent clean builds. If you bump any pin above
(kernel/busybox version, base-image digest, or `SOURCE_DATE_EPOCH`), regenerate
this table with `mlbuild.sh hashes`.

> The riscv64 (u-root, Go) track is not yet covered here — Go builds are largely
> reproducible with `CGO_ENABLED=0`, but the `-trimpath`/`-buildvcs` knobs and a
> deterministic plain-cpio pack are follow-on work.
