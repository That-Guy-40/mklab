# Hand-walk: *Making a micro Linux distro*, by hand, in a box

A step-by-step runbook for following Uros Popovic's post **inside a disposable
container that already carries the author's environment** — so you type the
recipe yourself and watch each stage boot, instead of running the repo's
automated [`mlbuild.sh`](../mlbuild.sh).

- **The post (byte-exact archive):** [`../upstream-tutorial/`](../upstream-tutorial/) ·
  canonical: <https://popovicu.com/posts/making-a-micro-linux-distro/>
- **The environment as code:** [`Containerfile`](Containerfile) — a Debian box
  (the author's own distro: the post's boot log reads *"riscv64-linux-gnu-gcc
  (Debian 10.2.1-6) … uros-debian-desktop"*) with the riscv64 cross-toolchain
  (compiler **and** `libc6-dev-riscv64-cross`, so the post's hosted C `init`
  links), the kernel build deps, `cpio`/`gzip`, Go (for u-root), **and
  `qemu-system-riscv64`** so you build *and* boot in the same place.
- **Why a container:** a clean, throwaway, reproducible copy of "the author's
  machine." Nuke it and start over any time; nothing touches your host.

> **This is the learning path; [`mlbuild.sh`](../mlbuild.sh) is the production
> path.** The automated builder cross-compiles every arch for you, verifies every
> download against a vendored signing key, and boots on the host via Phase 2.
> Here you do it by hand on **one** arch (riscv64, the post's "faithful track")
> to *understand* the moving parts. When you want the turnkey version, see
> [`../README.md`](../README.md).

---

## 0. Bring up the box

Rootless — no `sudo`, no `/dev/kvm`, no devices. `qemu-system-riscv64` runs under
pure **TCG** emulation (slower than KVM, but it needs no virtualization
privileges, which is exactly why it works in a rootless container).

```bash
# from the repo root:
phase4-podman/lab-podman.sh up   --config micro-linux/hand-walk/handwalk.toml
phase4-podman/lab-podman.sh exec micro-linux-handwalk/sandbox -- bash
# you are now at a shell in /work inside the box; everything below runs there.
```

Keep the vendored post open in another window
([`../upstream-tutorial/making-a-micro-linux-distro.html`](../upstream-tutorial/making-a-micro-linux-distro.html))
— this runbook gives the commands and what to expect; the post gives the prose.

When you are done, tear it down (§7).

---

## 1. Build the kernel from source

The post builds a stock upstream kernel for `riscv64` with a cross-compiler.
We pin **6.12.30** (a 6.12.x LTS, the same release the repo's automated track
verifies). The post itself used 6.5.2 — *any* recent 6.x stable works; pinning a
known-good one keeps your hand-walk reproducible.

```bash
cd /work
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.30.tar.xz
tar xf linux-6.12.30.tar.xz
cd linux-6.12.30

make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- defconfig    # sane riscv64 config
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- menuconfig   # (optional) poke around
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)" Image
```

**Why these flags.** `ARCH=riscv` selects the architecture; `CROSS_COMPILE=`
prefixes every tool (`riscv64-linux-gnu-gcc`, `-ld`, …) so an x86_64 host emits
riscv64 code. `defconfig` is the maintained "reasonable defaults" config for the
arch. The build target `Image` is the raw, uncompressed kernel —
`arch/riscv/boot/Image` — which is what QEMU's `virt` machine loads directly.

You end with:

```
  OBJCOPY arch/riscv/boot/Image
```

---

## 2. Boot it with no rootfs — and watch it panic

```bash
qemu-system-riscv64 -machine virt -nographic -kernel arch/riscv/boot/Image
# quit QEMU: press Ctrl-A, release, then X
```

The kernel boots, brings up the serial console… then:

```
VFS: Cannot open root device "" or unknown-block(0,0): error -6
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

**Why.** A kernel is only half a system. After it initialises hardware it tries
to mount a root filesystem and exec `/init` (or `/sbin/init`). We gave it
neither, so it has nothing to hand control to → panic. That's the whole point of
the next step: the **initramfs**, a tiny in-RAM root filesystem carrying a single
program the kernel runs as PID 1.

---

## 3. The smallest possible userspace: a "hello world" `init`

PID 1 is just *a program the kernel execs*. Prove it with three lines of C,
cross-compiled **static** (no shared libs exist in our initramfs yet):

```bash
cd /work
cat > init.c <<'EOF'
#include <stdio.h>
int main(int argc, char *argv[]) {
  printf("Hello world\n");
  return 0;
}
EOF
riscv64-linux-gnu-gcc -static -o init init.c
file init                       # → ELF ... statically linked   (must say static!)
```

Pack it into a `newc`-format cpio archive — the format the kernel's initramfs
loader understands. The post drives `cpio` from a file list:

```bash
echo init > file_list.txt
cpio -o -H newc < file_list.txt > initramfs.cpio
```

Boot the *same* kernel, now handing it the initramfs:

```bash
qemu-system-riscv64 -machine virt -nographic \
    -kernel linux-6.12.30/arch/riscv/boot/Image \
    -initrd initramfs.cpio
```

```
Run /init as init process
Hello world
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

**Why it still panics.** PID 1 is special: it must **never exit**. Our `init`
printed and `return`ed, the kernel saw PID 1 die, and that is fatal by design.
Lesson learned → an init has to *stick around*.

---

## 4. A real init: fork a shell, keep PID 1 alive

The post now writes an `init` that **forks**: the child `execl()`s a separate
program (`/little_shell`), and the parent loops forever (so PID 1 never exits).
`little_shell` is a tiny Go program that reads a line and echoes it back —
proving you can ship a second binary and that two processes run concurrently.

Grab the exact `init.c` (the forking version) and `little_shell.go` from the
vendored post — [§ "fork"/"little shell" in
`../upstream-tutorial/making-a-micro-linux-distro.html`](../upstream-tutorial/making-a-micro-linux-distro.html)
— then, in `/work`:

```bash
riscv64-linux-gnu-gcc -static -o init init.c          # the forking init
GOOS=linux GOARCH=riscv64 go build little_shell.go     # cross-build the Go shell
printf 'init\nlittle_shell\n' > file_list.txt          # both go in the image
cpio -o -H newc < file_list.txt > initramfs.cpio
qemu-system-riscv64 -machine virt -nographic \
    -kernel linux-6.12.30/arch/riscv/boot/Image -initrd initramfs.cpio
```

You'll see the parent's heartbeat (`Hello from the original init! 1`, `2`, …
every 10s) **interleaved** with the `little_shell` prompt — two live processes,
no panic. That's a (very) minimal working system you wrote end to end.

**Why Go here.** It shows the userspace is just "whatever binaries you put in the
cpio" — C or Go, doesn't matter, as long as they're statically linked for the
target arch (`GOARCH=riscv64`).

---

## 5. A *usable* userspace: u-root

Hand-writing every tool is educational but doesn't scale. **u-root** builds a
complete busybox-like initramfs (shell + coreutils, all in Go) in one command —
this is the repo's "faithful track" userspace too.

```bash
cd /work
git clone --branch v0.14.0 https://github.com/u-root/u-root.git
cd u-root
GOOS=linux GOARCH=riscv64 go run .        # builds → /tmp/initramfs.linux_riscv64.cpio
cd /work
qemu-system-riscv64 -machine virt -nographic \
    -kernel linux-6.12.30/arch/riscv/boot/Image \
    -initrd /tmp/initramfs.linux_riscv64.cpio
```

```
Run /init as init process
Welcome to u-root!
/# ls
bbin  bin  dev  env  etc  go  init  lib  ...
/# echo "Hello world!"
Hello world!
```

You now have an interactive shell in a kernel+initramfs you assembled yourself.

**Why build u-root *from inside its own clone* (the post's method).** u-root's
default is to bundle its `cmds/core/*` command set, and it resolves those package
paths **relative to the current directory's Go module** — so it must run from the
u-root tree. Running an installed `u-root` binary standalone fails with
*"no Go commands match the given patterns"* because there's no u-root module under
your CWD to glob. `go run .` from the clone builds the tool and runs it with the
repo as CWD, so the default commands resolve. *(The post pins no u-root version;
we pin `v0.14.0` to keep the hand-walk reproducible.)*

### 5b. (optional) Give it a network

The post adds a virtio NIC and pulls a DHCP lease with u-root's `dhclient`:

```bash
qemu-system-riscv64 -machine virt -nographic \
    -kernel linux-6.12.30/arch/riscv/boot/Image \
    -initrd /tmp/initramfs.linux_riscv64.cpio \
    -device virtio-net-device,netdev=usernet \
    -netdev user,id=usernet -device virtio-rng-pci
# inside the guest:
/# dhclient -ipv6=false
/# wget http://example.com && cat index.html
```

`-netdev user` is QEMU's userspace NAT (slirp) — works with no host privileges,
which is why it's fine in a rootless container.

---

## 6. Cross-check against the repo's automated build

Same arch, same idea, fully automated and signature-verified — a good way to see
what the production pipeline does *for* you:

```bash
# (on the host, not in the box)
micro-linux/mlbuild.sh all --arch riscv64        # build + pack, verified
ls -la micro-linux/out/riscv64/                  # kernel + initramfs.cpio (u-root)
```

The deltas between this hand-walk and the post are catalogued in
[`../../MICRO_LINUX_LAB_PLAN.md`](../../MICRO_LINUX_LAB_PLAN.md) (§1.1, §11).

---

## 7. Tear down

```bash
# from the repo root:
phase4-podman/lab-podman.sh down --config micro-linux/hand-walk/handwalk.toml
# (optional) drop the image the phase tool built:
podman rmi lab-micro-linux-handwalk-sandbox-img
```

Everything you built lived inside the container's `/work` (ephemeral) — teardown
reclaims it all. Nothing was written to your host.

---

## Notes — faithfulness, provenance, hygiene

- **Faithful, with two pinned deltas:** kernel `6.5.2 → 6.12.30` (LTS, known-good
  in this toolchain) and u-root pinned to `v0.14.0`. Both are documented above
  and chosen only for reproducibility; the recipe is otherwise the author's.
- **TCG is slow.** Pure-emulation riscv64 boots in seconds but compiles slowly;
  the kernel build runs natively on the x86_64 host toolchain (fast) — only the
  *guest* runs emulated.
- **Throwaway by construction.** The box has no secrets and no listening
  services; the guest userspace is whatever you packed. Don't bridge the
  optional-network guest to anything untrusted (it's a toy).
- **Provenance.** The archived post under [`../upstream-tutorial/`](../upstream-tutorial/)
  is the work of **Uros Popovic**; all rights remain with the author. It's
  vendored for offline reference; this runbook only *operationalises* it. Always
  prefer the [canonical page](https://popovicu.com/posts/making-a-micro-linux-distro/).
