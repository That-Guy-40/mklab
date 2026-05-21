# TODO

## micro-linux: run the real end-to-end build + boot

The micro-linux lab is **config-complete and unit-tested**, but the actual
multi-minute *compile → pack → QEMU boot* has **not been run yet**. It's out of
CI scope on purpose (it pulls the toolchain image, compiles a kernel, and boots
a VM — see `MICRO_LINUX_LAB_PLAN.md` §9 step 6). Run it once on a real host to
confirm the full path.

**Prereqs** — already satisfied on the dev host: `podman`,
`qemu-system-{x86_64,aarch64,riscv64}`, OVMF/AAVMF/OpenSBI firmware, `jq`.

### Commands

```bash
# 1. Build the rootless toolchain image (pulls the pinned debian digest; minutes)
micro-linux/mlbuild.sh image

# 2. Compile + verify + pack — BusyBox track
micro-linux/mlbuild.sh all --arch x86_64,aarch64

# 3. Boot to a BusyBox shell (Ctrl-A X to quit QEMU)
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-x86_64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-aarch64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-aarch64

# 4. Faithful track — riscv64 + u-root (builds Go in the image, fetches u-root)
micro-linux/mlbuild.sh all --arch riscv64
phase2-qemu-vm/lab-vm.sh create --config examples/micro-linux-riscv64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-riscv64
```

### Verify (success criteria)

- [ ] `mlbuild.sh image` builds — the pinned-Go sha256 check passes.
- [ ] kernel `.tar.sign` and busybox `.tar.bz2.sig` both pass `gpgv`; the first
      run records sha256s into `micro-linux/versions.lock`.
- [ ] busybox links **static** (the build aborts otherwise).
- [ ] x86_64 boots to `Welcome to micro-linux …` and a `/ #` BusyBox prompt.
- [ ] aarch64 boots the same (slower under TCG).
- [ ] riscv64 boots into the u-root shell.
- [ ] the initramfs does **not** embed the kernel; `/dev/console` works in-VM.
- [ ] **commit the generated `micro-linux/versions.lock`** (it pins the verified
      hashes for reproducibility + drift detection).

### Known caveats
- aarch64/riscv64 run under TCG on an x86_64 host — slow but functional.
- The busybox signing key has weaker out-of-band provenance than the kernel
  keys (`micro-linux/keys/README.md`); cross-check `C9E9416F…ACC9965B`
  independently if this graduates beyond throwaway-lab use.
