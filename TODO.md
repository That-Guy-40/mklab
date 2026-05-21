# TODO

## micro-linux: real end-to-end build + boot — ✅ DONE (2026-05-21)

The actual multi-minute *compile → pack → QEMU boot* has now been run on the dev
host for **all three architectures**. Every arch builds and boots:

| Arch    | Kernel | Initramfs            | Boots to                         |
|---------|--------|----------------------|----------------------------------|
| x86_64  | 13M    | 1.2M gz (BusyBox)    | `login:` (root / micro) → `~ #`   |
| aarch64 | 44M    | 1.2M gz (BusyBox)    | `login:` (root / micro) → `~ #`   |
| riscv64 | 21M    | 15M plain cpio (u-root) | `Welcome to u-root!` + `>` shell |

The first verified run surfaced **seven** bugs that only a real build could
expose (none catchable by shellcheck or the unit tests); all are now fixed:

1. BusyBox `CONFIG_STATIC`/`CONFIG_TC` silently dropped — appending a duplicate
   line makes Kconfig "reassign" → keep-first → our value lost. Fixed with
   `set_kconfig` (replace, never append).
2. A unit test ran `clean` against the **real** `out/` and `rm -rf`'d a build.
   `OUT_DIR` is now overridable via `MLBUILD_OUT_DIR`; the test is isolated.
3. `gen_init_cpio` reads its spec from a file arg (`-` = stdin); it was invoked
   with none → empty initramfs. Pass `-` + assert `/init`+`/bin/busybox` present.
4. `summarize` returned 1 on success (missing optional artifact in an `&&`).
5. arm64/riscv `defconfig` need `python3` (kernel header generators, e.g. MSM) —
   added to the builder image.
6. `mlbuild.sh image` never rebuilt a pre-existing tag → stale image. The
   explicit `image` subcommand now force-rebuilds; the auto path stays lazy.
7. u-root must run from its pinned module source tree (`-mod=mod`); `go run
   pkg@ver` from an unrelated dir can't resolve `cmds/core`. GOPATH/GOCACHE +
   the gpg trustdb now live under the gitignored `out/`.

### Reproducible runbook

**Prereqs** (satisfied on the dev host): `podman`,
`qemu-system-{x86_64,aarch64,riscv64}`, OVMF/AAVMF/OpenSBI firmware, `jq`.

```bash
# 1. Build the rootless toolchain image (pinned debian digest + verified Go)
micro-linux/mlbuild.sh image

# 2. Compile + verify + pack — BusyBox track + faithful riscv64/u-root track
micro-linux/mlbuild.sh all --arch x86_64,aarch64,riscv64

# 3. Boot via Phase 2 (Ctrl-A X to quit QEMU)
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-x86_64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64
#   …repeat for -aarch64 and -riscv64.
```

Direct boot smoke-test (no daemonize; auto-kills after the timeout — a live
shell keeps the VM up, so `rc=124` is success):

```bash
timeout --foreground 120 qemu-system-x86_64 -M pc -m 256M \
  -display none -nographic -no-user-config -nodefaults \
  -kernel micro-linux/out/x86_64/kernel \
  -initrd micro-linux/out/x86_64/initramfs.cpio.gz \
  -append "console=ttyS0" -serial mon:stdio </dev/null
# aarch64: qemu-system-aarch64 -M virt -cpu max … console=ttyAMA0
# riscv64: qemu-system-riscv64 -M virt … console=ttyS0 (initramfs.cpio, plain)
```

### Verified (success criteria — all met)

- [x] `mlbuild.sh image` builds — the pinned-Go sha256 check passes.
- [x] kernel `.tar.sign` + busybox `.tar.bz2.sig` pass `gpgv`; the first run
      records sha256s into `micro-linux/versions.lock` (committed).
- [x] busybox links **static** (the build aborts otherwise — and did, until fix 1).
- [x] x86_64 boots to the `login:` prompt (getty); root / micro → a `~ #` shell.
- [x] aarch64 boots the same (slower under TCG).
- [x] riscv64 boots into the u-root shell.
- [x] the initramfs does **not** embed the kernel; `/dev/console` works in-VM.

### Known caveats
- aarch64/riscv64 run under TCG on an x86_64 host — slow but functional.
- The busybox signing key has weaker out-of-band provenance than the kernel
  keys (`micro-linux/keys/README.md`); cross-check `C9E9416F…ACC9965B`
  independently if this graduates beyond throwaway-lab use.
