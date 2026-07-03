# minimal-arm-linux-qemu — manual testing runbook

Every stage with the **real expected output**, captured from a verified run
(2026-07-02). The verification is an honest split:

- **Build** (kernel + init + initramfs) was proven **rootless in a Debian
  bullseye container** — that's where the `arm-linux-gnueabi` toolchain installs
  without touching your host. GCC 10.2.
- **Boot** was proven on the **host** with **qemu-system-arm 8.2.2**.

Both halves also run fine directly on a Debian host once the toolchain is
installed; the container is only how *this* environment builds without `sudo`.

```bash
cd examples/tiny-linux-experiments/minimal-arm-linux-qemu
O=~/.cache/lab-create/minimal-arm-linux      # build dir, used throughout
```

---

## §0 — Preflight (host deps)

```bash
sudo apt-get install -y gcc-arm-linux-gnueabi libc6-dev-armel-cross \
    build-essential bc bison flex libssl-dev libelf-dev git cpio fakeroot \
    qemu-system-arm
```

**Pass:** all install. `build-minimal-arm.sh` re-checks and prints the exact
missing line if anything's absent (it never auto-installs). `build`/`pack` need
the toolchain; `test`/`boot` need only `qemu-system-arm`.

## §1 — Build end-to-end

```bash
./build-minimal-arm.sh build
```

Shallow-clones `linux` `v6.1.176` (~250 MB) and cross-compiles it — several
minutes. **Pass** = it ends roughly with:

```text
[minimal-arm] kernel: 2.8M → .../build/arch/arm/boot/zImage
[minimal-arm] compiling static ARM /init (armv5te / xscale)
[minimal-arm] packing initramfs (newc cpio, with /dev/console via fakeroot)
[minimal-arm] initramfs: 520K → .../initramfs
[minimal-arm] flash: two 32 MiB banks (...)
[minimal-arm] done. Boot it: ./build-minimal-arm.sh test
```

**Spot-check the config assertions actually held** (the script aborts if not):

```bash
grep -E 'CONFIG_(AEABI|OABI_COMPAT|BLK_DEV_INITRD)\b' "$O/build/.config"
```
```text
CONFIG_BLK_DEV_INITRD=y
CONFIG_AEABI=y
# CONFIG_OABI_COMPAT is not set
```

**Spot-check `/init` is a static ARM EABI binary:**

```bash
file "$O/init"
```
```text
.../init: ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), statically linked, ... for GNU/Linux 3.2.0, not stripped
```

## §2 — Boot & verify (the payoff)

```bash
./build-minimal-arm.sh test          # headless, asserts the marker
```

**Pass:**

```text
[minimal-arm] headless boot, up to 60s, expecting 'Tiny init ...'
[minimal-arm] PASS — 'Tiny init ...' printed (full serial: .../serial-test.log)
```

The tail of that serial log is the whole point:

```text
XScale iWMMXt coprocessor detected.
Freeing unused kernel image (initmem) memory: 204K
Run /init as init process
Tiny init ...
```

For the human view (watch it boot, then hang in `while(1)`):

```bash
./build-minimal-arm.sh boot          # Ctrl-A x to quit QEMU
```

---

## Gotchas this lab hit (so you don't have to)

Each was a real failure during bring-up; the fix is baked into the script.

| Symptom (verbatim) | Cause | Fix baked in |
|---|---|---|
| `qemu-system-arm: device requires 33554432 bytes, block backend provides 67108864 bytes` | The tutorial's 64 MiB flash; modern QEMU's mainstone wants **32 MiB** each | `make_flash` writes 32768 KiB banks |
| Boot reaches init, then `Kernel panic … Attempted to kill init! exitcode=0x0000000b` (on **qemu 5.2**) | The PXA270 model trapped an **iWMMXt** instruction (`MCRR p0`) in glibc's XScale-tuned static startup | Use a **modern QEMU** (verified 8.2.2); 5.2 is too old |
| `mknod: /…/dev/console: Operation not permitted` (rootless) | A real device node needs `CAP_MKNOD` | node baked under **`fakeroot`** |
| (silent) `/init` runs but prints nothing | line-buffered `printf` + no console to flush to | ship **`/dev/console`** in the initramfs |
| `wget https://cdn.kernel.org/…/linux-*.tar.xz` → **404** | kernel.org CDN refused these paths from this network | fetch via **shallow `git clone`** from `git.kernel.org` |
| `/init` won't run at all / immediate fault | kernel built **OABI** but toolchain is **EABI** | assert **`CONFIG_AEABI=y`** post-config |

## Clean up

```bash
./build-minimal-arm.sh clean         # rm -rf ~/.cache/lab-create/minimal-arm-linux
```
