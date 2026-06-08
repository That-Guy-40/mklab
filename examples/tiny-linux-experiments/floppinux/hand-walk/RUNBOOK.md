# Hand-walk: *FLOPPINUX (2025 edition)*, by hand, in a box

Follow Krzysztof Jankowski's post **inside an Arch container that carries the build
deps** — cross-build a kernel + BusyBox with a musl toolchain and write a whole
bootable Linux onto a single **1.44 MB floppy**, by hand.

- **The post (byte-exact archive):** [`../upstream-tutorial/`](../upstream-tutorial/) ·
  canonical: <https://krzysztofjankowski.com/floppinux/floppinux-2025.html>
- **The environment as code:** [`Containerfile`](Containerfile) — Arch (the
  author's distro) + the `pacman` build deps.
- **The repo's automated counterpart:** [`../build-floppinux.sh`](../build-floppinux.sh)
  (rootless; cross-builds + packs + writes the floppy) with
  [`../MANUAL_TESTING.md`](../MANUAL_TESTING.md) and
  [`../QUALITY_OF_LIFE.md`](../QUALITY_OF_LIFE.md). This hand-walk is the by-hand
  version of the same recipe.

> ### Two steps you run yourself (flagged honestly)
> - **§2 — the musl toolchain.** The post `wget`s a *prebuilt* cross-toolchain
>   from musl.cc and compiles with it. Fetching + executing a third-party prebuilt
>   toolchain is your machine's call to trust — and this repo's agent runner
>   blocks it — so the fetch + the kernel/BusyBox compile are **yours to run**.
> - **§5 — the floppy.** `mknod` (for `/dev/console`, `/dev/null`) and
>   `mount -o loop` need real device access; this build sandbox denies them even
>   with `--privileged`. On **your** host (launch the box `--privileged`) they
>   work. *(The repo's `build-floppinux.sh` sidesteps `mknod` with `fakeroot` and
>   the loop-mount with `mtools`, if you want the rootless route.)*
>
> Everything else — deps, kconfig, packing, booting — runs in the box.

---

## 0. Bring up the box (on your host)

```bash
phase4-podman/lab-podman.sh build --tag floppinux-handwalk \
    --context examples/tiny-linux-experiments/floppinux/hand-walk
podman run --rm -it --privileged floppinux-handwalk bash    # --privileged for §5
```

The post's `pacman -S ncurses bc flex bison syslinux cpio` (+ `qemu-full`) is
already baked into the image — you start with the tools ready.

---

## 1. Fetch the kernel + BusyBox sources

```bash
cd /work
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.14.11.tar.xz && tar xf linux-6.14.11.tar.xz
wget https://github.com/mirror/busybox/archive/refs/tags/1_36_1.tar.gz && tar xf 1_36_1.tar.gz
```

(Versions per the repo's pinned lab — the post tracks current stable; any recent
kernel 6.x + BusyBox 1.36.x works.)

---

## 2. The musl toolchain + the cross-compile  ⚠️ *you run this*

```bash
wget https://musl.cc/i486-linux-musl-cross.tgz && tar xf i486-linux-musl-cross.tgz
export PATH="$PWD/i486-linux-musl-cross/bin:$PATH"
export CROSS_COMPILE=i486-linux-musl-

# kernel: start tiny, add what a floppy needs, build the bzImage
cd /work/linux-6.14.11
make ARCH=x86 tinyconfig
make ARCH=x86 menuconfig          # enable: initramfs, devtmpfs, ELF, /proc, console…
make ARCH=x86 CROSS_COMPILE=$CROSS_COMPILE bzImage -j"$(nproc)"

# BusyBox: minimal static userspace
cd /work/busybox-1_36_1
make ARCH=x86 allnoconfig
make ARCH=x86 menuconfig           # enable: a shell + the applets you want; STATIC
make ARCH=x86 CROSS_COMPILE=$CROSS_COMPILE -j"$(nproc)" && make ARCH=x86 install
```

**Why musl + static.** A floppy has ~1.4 MB; glibc won't fit. A musl-linked,
fully **static** BusyBox is a single small binary that needs no libraries on the
floppy. (This is exactly the gate-split documented in
[`../README.md`](../README.md): host can do everything *except* the musl fetch +
this compile.)

---

## 3. Assemble + pack the initramfs

```bash
cd /work/busybox-1_36_1/_install
mkdir -p dev proc sys
sudo mknod dev/console c 5 1        # ⚠️ mknod — works on your host (see §5 note)
sudo mknod dev/null    c 1 3
# add an /init (the post provides one; the repo's lab ships a tested init too)
find . | cpio -H newc -o | xz --check=crc32 --lzma2=dict=512KiB -e > ../rootfs.cpio.xz
```

---

## 4. Bootloader config

```bash
cd /work
cat > syslinux.cfg <<'EOF'
DEFAULT floppinux
LABEL floppinux
  KERNEL bzImage
  INITRD rootfs.cpio.xz
  APPEND quiet
EOF
```

---

## 5. Write the 1.44 MB floppy  ⚠️ *you run this (`mount -o loop`)*

```bash
dd if=/dev/zero of=floppinux.img bs=1k count=1440
mkfs.fat -n FLOPPINUX floppinux.img
syslinux --install floppinux.img
mkdir -p /mnt/floppy && mount -o loop floppinux.img /mnt/floppy     # ⚠️ loop mount
cp linux-6.14.11/arch/x86/boot/bzImage /mnt/floppy/bzImage
cp busybox-1_36_1/rootfs.cpio.xz /mnt/floppy/
cp syslinux.cfg /mnt/floppy/
umount /mnt/floppy
# to a real floppy:  sudo dd if=floppinux.img of=/dev/sdX bs=512 conv=notrunc,sync
```

---

## 6. Boot it

```bash
qemu-system-i386 -fda floppinux.img -cpu 486 -nographic
```

You boot a complete Linux — kernel + a BusyBox shell — off a single floppy. ⚠️
throwaway: it boots to a passwordless root shell, no networking.

---

## 7. Tear down & provenance

`exit` the `--rm` box. `podman rmi floppinux-handwalk`.

- **Provenance.** The archived post under [`../upstream-tutorial/`](../upstream-tutorial/)
  is the work of **Krzysztof Krystian Jankowski**; all rights remain with the
  author. Vendored for offline reference; this runbook only operationalises it.
  Prefer the [canonical page](https://krzysztofjankowski.com/floppinux/floppinux-2025.html).
- **Status:** the Arch **environment** (build deps) is verified in this box; **§2
  (musl.cc toolchain + compile) and §5 (`mknod`/loop-mount) are author-only here**
  (toolchain-fetch gate + the sandbox's device block) — both work on your own
  host (launch `--privileged`). For the rootless, automated route that avoids
  `mknod`/loop with `fakeroot`+`mtools`, see [`../build-floppinux.sh`](../build-floppinux.sh).
- **Related:** TODO #1 (crack the `LOGIN=1` `$1$` hash) is a follow-on exercise on
  this very lab — see the repo [`TODO.md`](../../../../TODO.md).
