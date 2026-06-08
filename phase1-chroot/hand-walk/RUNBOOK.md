# Hand-walk: *Rootless cross-architecture debootstrap*, by hand, in a box

A step-by-step runbook for following Alex Bradbury's muxup.com post **inside a
disposable container that carries the author's prerequisites** — so you build a
*foreign-architecture* Debian rootfs (riscv64) with **no root**, by hand, and
watch foreign binaries run on your x86_64 box via `qemu-user-static`.

- **The post (byte-exact archive):** [`../upstream-tutorial/`](../upstream-tutorial/) ·
  canonical: <https://muxup.com/2024q4/rootless-cross-architecture-debootstrap>
- **The environment as code:** [`Containerfile`](Containerfile) — Debian +
  `debootstrap`, `fakeroot`, `symlinks`, `qemu-user-static`, `binfmt-support`,
  and `qemu-system-riscv64` for the bootable-VM finale.
- **The repo's automated take on the same technique:**
  [`lab-chroot.sh --rootless`](../lab-chroot.sh) adopts this exact
  `unshare`+`fakeroot`+`qemu-user-static` approach as a Phase-1 feature. This
  hand-walk is the *learning* counterpart — type it yourself to see how it works.

---

## 0. Bring up the box — and the one wrinkle

The foreign second stage runs riscv64 binaries on your x86_64 host. That needs
`qemu-user-static` registered in the kernel's **`binfmt_misc`**. On a bare host
that's just `apt install qemu-user-static` (its installer registers binfmt for
you) — which is why the post never mentions it. **Inside a rootless container two
things differ**, and they're worth understanding because they're the whole reason
this isn't a plain `lab-podman.sh up`:

1. `binfmt_misc` is **namespaced away** — the container starts with an empty one,
   and registering an entry needs `CAP_SYS_ADMIN`.
2. podman **masks parts of `/proc`** by default, and the post's `_enter` does
   `unshare --mount-proc`, which can't remount `/proc` over those locked mounts.

So the Phase-4 `up` path (which deliberately injects **no** privileges) can't run
this. Build the image with the phase tool, then launch it yourself with exactly
the two options that lift those limits — still rootless, still your own podman:

```bash
# from the repo root — build the environment image via the phase tool:
phase4-podman/lab-podman.sh build --tag muxup-handwalk --context phase1-chroot/hand-walk
# launch it with the two capabilities the post's host has for free:
podman run --rm -it --cap-add SYS_ADMIN --security-opt systempaths=unconfined \
    muxup-handwalk bash
```

`--cap-add SYS_ADMIN` grants the cap only **within your user namespace** (no host
root); `systempaths=unconfined` un-masks `/proc`. Now register the interpreter
the way the host's `qemu-user-static` package would have:

```bash
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc   # one-time, in-box
update-binfmts --enable qemu-riscv64
```

Keep the vendored post open
([`../upstream-tutorial/rootless-cross-architecture-debootstrap.html`](../upstream-tutorial/rootless-cross-architecture-debootstrap.html))
for the author's prose.

---

## 1. The rootless foreign bootstrap (the heart of the post)

debootstrap normally wants root (it `chown`s files to `root:root`, makes device
nodes, etc.). The trick is to fake all of that:

```bash
SYSROOT_DIR=sysroot-deb-riscv64-sid
TMP_FAKEROOT_ENV=$(mktemp)

# Stage 1 — unpack the foreign .debs. No foreign code runs yet, so host tools
# (dpkg, ar, tar) do all the work; fakeroot fakes the root-owned file metadata.
fakeroot -s "$TMP_FAKEROOT_ENV" debootstrap \
  --variant=minbase \
  --include=fakeroot,symlinks \
  --arch=riscv64 --foreign \
  sid \
  "$SYSROOT_DIR"
mv "$TMP_FAKEROOT_ENV" "$SYSROOT_DIR/.fakeroot.env"
```

**Why each piece:**
- **`fakeroot -s <env>`** records every `chown`/`mknod` you *pretend* to do into a
  database file (`.fakeroot.env`). Inside the same fakeroot session those fake
  ownerships look real; outside, you're still your unprivileged self. `-s` saves
  the DB so later steps (`-i`) can reload it — the rootfs's "root-owned" state
  persists across separate commands.
- **`--foreign`** splits the bootstrap: stage 1 here (pure unpack, host tools),
  stage 2 later (runs foreign maintainer scripts → needs qemu).
- **`--include=fakeroot,symlinks`** seeds the rootfs with the two tools the next
  steps need *inside* it.

Now bootstrap `fakeroot` *into* the rootfs by hand (its postinst hasn't run yet),
then write the `_enter` wrapper that makes a rootless chroot:

```bash
fakeroot -i "$SYSROOT_DIR/.fakeroot.env" -s "$SYSROOT_DIR/.fakeroot.env" sh <<EOF
ar p "$SYSROOT_DIR"/var/cache/apt/archives/libfakeroot_*.deb 'data.tar.xz' | tar x -J -C "$SYSROOT_DIR"
ar p "$SYSROOT_DIR"/var/cache/apt/archives/fakeroot_*.deb 'data.tar.xz' | tar x -J -C "$SYSROOT_DIR"
ln -s fakeroot-sysv "$SYSROOT_DIR/usr/bin/fakeroot"
EOF

cat > "$SYSROOT_DIR/_enter" <<'EOF'
#!/bin/sh
export PATH=/usr/sbin:$PATH
FAKEROOTDONTTRYCHOWN=1 unshare -fpr --mount-proc -R "$(dirname -- "$0")" \
  fakeroot -i .fakeroot.env -s .fakeroot.env "$@"
EOF
chmod +x "$SYSROOT_DIR/_enter"
```

**Why `_enter` works:** `unshare -fpr` makes new **user** (`-r`, map you→root),
**pid** (`-p`) and (with `-f`) forks so PID 1 is correct; `--mount-proc` gives the
new pid namespace a matching `/proc`; `-R` chroots into the rootfs. Inside, you
*are* root (in the namespace), and any foreign (riscv64) binary the chroot runs is
routed by `binfmt_misc` to `qemu-riscv64`. No `sudo` anywhere.

Run **stage 2** — the foreign half — through it, then tidy the symlinks:

```bash
"$SYSROOT_DIR/_enter" debootstrap/debootstrap --second-stage
"$SYSROOT_DIR/_enter" symlinks -cr .     # absolute → relative symlinks (self-contained)
```

`--second-stage` configures the packages by running their riscv64 maintainer
scripts — i.e. **foreign code executing on your x86_64 box**, transparently, via
qemu. That's the payoff.

---

## 2. Prove it's really a foreign rootfs

```bash
"$SYSROOT_DIR/_enter" uname -m            # -> riscv64   (running a foreign binary!)
"$SYSROOT_DIR/_enter" cat /etc/debian_version
```

`uname -m` printing `riscv64` means the `coreutils` *binary you just unpacked is
riscv64*, and it ran — proof the bootstrap produced a working foreign userspace.

---

## 3. (the post generalises) Every arch, and a real bootable VM

The post wraps §1 into a `rootless-debootstrap-wrapper` script and sweeps **eight**
architectures (`amd64 arm64 armel armhf i386 ppc64el riscv64 s390x`), compiling a
`uname`-printing `hello.c` in each — see the
[vendored post](../upstream-tutorial/rootless-cross-architecture-debootstrap.html)
for that script and the `Hello from <arch>` table. To do another arch by hand,
repeat §1 with a different `--arch=` and `update-binfmts --enable qemu-<arch>`.

It then turns the riscv64 rootfs into a **bootable VM**: bootstrap with
`--include=linux-image-riscv64,zstd,default-dbus-system-bus`, set up
`systemd-networkd` + a `root:root` login, pack with `mkfs.ext4 -d`, and boot:

```bash
fakeroot -i riscv-sid-for-qemu/.fakeroot.env sh <<EOF
ln -L riscv-sid-for-qemu/vmlinuz kernel
ln -L riscv-sid-for-qemu/initrd.img initrd
fallocate -l 8GiB rootfs.img            # (the post uses 30GiB; 8 is plenty for a try)
mkfs.ext4 -d riscv-sid-for-qemu rootfs.img
EOF

qemu-system-riscv64 -machine virt -cpu rv64 -smp 4 -m 4G -nographic \
  -bios /usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin \
  -kernel kernel -initrd initrd \
  -drive file=rootfs.img,if=none,id=hd,format=raw -device virtio-blk-device,drive=hd \
  -netdev user,id=net -device virtio-net-device,netdev=net \
  -append "rw root=/dev/vda console=ttyS0"
# log in root / root; poweroff to exit (or Ctrl-A X)
```

This boots a full systemd riscv64 Debian you built without ever being root.

---

## 4. Cross-check against the repo's automated feature

```bash
# (on the host) the same technique, automated as a Phase-1 backend:
phase1-chroot/lab-chroot.sh --help        # see the --rootless / --arch options
```

`lab-chroot.sh --rootless` folds the rootless `fakechroot`+`fakeroot` idea into a
repeatable builder — but for the **native** architecture only; foreign-arch
rootless (the qemu-user-static half you just did by hand) is explicitly out of
scope there. So this hand-walk isn't just a manual rerun of the feature — it
shows the *foreign-arch* case the automated mode deliberately leaves out.

---

## 5. Tear down & provenance

The rootfs and image live only in the container — `exit` the `--rm` box and
everything's gone. Drop the image too if you like:

```bash
podman rmi muxup-handwalk
```

- **Provenance.** The archived post under [`../upstream-tutorial/`](../upstream-tutorial/)
  is the work of **Alex Bradbury (muxup.com)**; all rights remain with the author.
  It's vendored for offline reference; this runbook only operationalises it.
  Always prefer the [canonical page](https://muxup.com/2024q4/rootless-cross-architecture-debootstrap).
- **Faithful, with container-only additions:** the `--cap-add SYS_ADMIN` +
  `systempaths=unconfined` + in-box `binfmt` registration in §0 replace the bare
  host's `apt install qemu-user-static`; everything in §1–§3 is the author's
  recipe verbatim. Verified end-to-end (riscv64 stage-1 + foreign stage-2 +
  `uname -m → riscv64`).
