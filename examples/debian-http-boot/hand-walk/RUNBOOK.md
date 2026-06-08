# Hand-walk: *Booting Linux over HTTP*, by hand, in a box

Follow Kenneth Finnegan's post **inside a disposable container that carries the
server-side prerequisites** — build a whole Debian system, pack it into one
gzipped cpio initramfs, and boot it **entirely from RAM** over HTTP, by hand. The
*client* is the repo's existing QEMU lab; this box is the build/serve **server**.

- **The post (byte-exact archive):** [`../upstream-tutorial/`](../upstream-tutorial/) ·
  canonical: <https://blog.thelifeofkenneth.com/2020/03/booting-linux-over-http.html>
- **The environment as code:** [`Containerfile`](Containerfile) — Debian +
  `debootstrap` + `cpio` + an iPXE toolchain + `python3` (HTTP).
- **The client + the automated take:** the repo already operationalises this — see
  [`../README.md`](../README.md) and boot with
  [`../vm-debian-http-boot.toml`](../vm-debian-http-boot.toml). This hand-walk is
  the *by-hand server build* counterpart.

> **Heads-up:** the parent lab already ships a written walkthrough and a verbatim
> [`../init`](../init). This box is what's *not* there: a throwaway environment to
> actually run Kenneth's `debootstrap` → `cpio` → iPXE commands yourself and watch
> the artifacts appear, instead of using the repo's automated pipeline.

---

## 0. Bring up the box

`debootstrap` chroots and mounts `/proc` inside the target, which a rootless
container can't do unprivileged — so (exactly as in the muxup hand-walk) build via
the phase tool, then launch with `--cap-add SYS_ADMIN` + `systempaths=unconfined`.
Bind-mount an `out/` dir (the kernel+initrd land there for the client) and the lab
dir read-only (for Kenneth's verbatim `/init`):

```bash
# from the repo root:
phase4-podman/lab-podman.sh build --tag debhttp-handwalk \
    --context examples/debian-http-boot/hand-walk
mkdir -p out
podman run --rm -it --cap-add SYS_ADMIN --security-opt systempaths=unconfined \
    -v "$PWD/out:/out:Z" -v "$PWD/examples/debian-http-boot:/lab:ro" \
    debhttp-handwalk bash
```

---

## 1. Build the Debian rootfs that *becomes* the initramfs

Kenneth runs `sudo debootstrap` (real root). To stay **rootless** in a container
— and because this build sandbox can't `mknod` — wrap it in `fakeroot`, which
*fakes* the device nodes and root-owned files debootstrap creates. Pull a kernel
in the same pass with `--include` (you'll copy its `vmlinuz` out in §3):

```bash
cd /work
fakeroot -s fakeroot.env debootstrap \
    --include=linux-image-amd64 \
    trixie rootfs http://deb.debian.org/debian/      # Kenneth used buster
```

**Why fakeroot + `-s`.** debootstrap `chown`s files to `root` and `mknod`s a few
device nodes; as a normal user those must be faked. `fakeroot -s <env>` records
the fake ownership/nodes into `fakeroot.env`, and §3 packs the archive under the
*same* env so the nodes come out right. (On a host where you actually have root,
Kenneth's plain `sudo debootstrap` + `sudo chroot rootfs apt install
linux-image-amd64` is the direct equivalent.)

Set a throwaway login (matches the parent lab's `root` / `lab`) without a real
chroot — `unshare -r` maps you to root in a private namespace, which is enough:

```bash
unshare -r fakeroot -i fakeroot.env -s fakeroot.env \
    chroot rootfs /bin/sh -c 'echo root:lab | chpasswd'
```

**Why a kernel inside?** The kernel is passed to QEMU/iPXE *separately*, but
`--include=linux-image-amd64` is the easy way to get a matching `vmlinuz` to copy
out in §3.

---

## 2. Install Kenneth's hand-rolled `/init`

The kernel, given an initramfs, runs `/init` as PID 1. Kenneth's version mounts
the kernel's virtual filesystems (`/proc`, `/sys`, a `devtmpfs`→`tmpfs` fallback
`/dev`, `/dev/pts`, `/run`) and then `exec`s `/sbin/init` (systemd). Use it
verbatim from the repo:

```bash
cp /lab/init rootfs/init && chmod +x rootfs/init
```

(It's the elaborate Gandi.net version — read [`../init`](../init); the post
explains each mount.)

---

## 3. Pack the initramfs + copy the kernel out — Kenneth's exact pipeline

Run the pack **under the same fakeroot env** so the faked device nodes land in
the archive as real cpio device entries:

```bash
cp rootfs/boot/vmlinuz-* /out/kernel-debian-http        # the kernel, out to the client
fakeroot -i fakeroot.env sh -c \
    'cd rootfs && find . | cpio -H newc -o | gzip -9 -n' > /out/initrd-debian-http.gz
ls -lh /out/
```

**Why `find . | cpio -H newc -o | gzip`.** That *is* the initramfs format: a
newc-format cpio of the whole tree, gzipped. The kernel unpacks it into a tmpfs
and runs `/init`. Running it inside `fakeroot -i fakeroot.env` is what makes the
device nodes (and root ownership) come out correct without ever being root. (A
fresh `debootstrap` tree has no populated `/proc` etc., so a plain `find .` is
fine — no excludes needed.)

The kernel + initrd are now in `out/` on your host, ready for the client.

---

## 4. (faithful to the post) Build an iPXE ROM with an embedded boot script

Kenneth flashed each thin client's SSD with a custom iPXE ROM that HTTP-fetches
the kernel + initrd. Build the same ROM:

```bash
cd /work
git clone --depth 1 https://github.com/ipxe/ipxe.git
cd ipxe/src
cat > bootscript.ipxe <<'EOF'
#!ipxe
dhcp
kernel http://10.0.2.2:8181/kernel-debian-http
initrd http://10.0.2.2:8181/initrd-debian-http.gz
boot
EOF
make -j"$(nproc)" EMBED=bootscript.ipxe bin/ipxe.usb
cp bin/ipxe.usb /out/ipxe-debian-http.usb
```

*(Kenneth's 2020 post used the older `EMBEDDED_IMAGE=./bootscript`; current iPXE
spells it `EMBED=`. `10.0.2.2` is QEMU user-net's host alias — where §5 serves.)*

---

## 5. Serve the artifacts over HTTP

```bash
cd /out && python3 -m http.server 8181        # 8181, not 8080 (SABnzbd owns 8080 on this host)
```

Leave it running; this is the "over HTTP" half of the post.

---

## 6. Boot the client (the existing QEMU lab)

Two ways, both using the repo's Phase-2 tool on the **host** (not in the box):

**(a) Simplest — boot the kernel+initrd directly** (what the parent lab does):

```bash
# point the parent lab's spec at the artifacts you just built in out/, then:
phase2-qemu-vm/lab-vm.sh create --config examples/debian-http-boot/vm-debian-http-boot.toml
phase2-qemu-vm/lab-vm.sh start   debian-http-boot      # log in: root / lab
```

**(b) Full Kenneth experience — boot via iPXE over HTTP:** boot a QEMU guest from
the `ipxe-debian-http.usb` you built (§4) with user-net to your `:8181` server;
iPXE pulls the kernel + initrd over HTTP exactly as his thin clients did. See the
repo's netboot pipeline (the [examples index](../../00-INDEX.md), § Netboot &
PXE) for the DHCP-driven modern equivalent.

Either way you land in a full systemd Debian running **entirely from RAM** — no
disk was touched.

---

## 7. Tear down & provenance

`exit` the `--rm` box; the rootfs vanishes. Your `out/` artifacts remain on the
host (delete when done). Drop the image with `podman rmi debhttp-handwalk`.

- **Provenance.** The archived post under [`../upstream-tutorial/`](../upstream-tutorial/)
  is the work of **Kenneth Finnegan** (init also credits Gandi.net); all rights
  remain with the author. Vendored for offline reference; this runbook only
  operationalises it. Prefer the
  [canonical page](https://blog.thelifeofkenneth.com/2020/03/booting-linux-over-http.html).
- **Verified in this box (rootless):** `fakeroot debootstrap --include=linux-image-amd64
  trixie` (exit 0; `vmlinuz-6.12.x` lands — the kernel postinst runs fine under
  fakeroot), the `fakeroot … find | cpio | gzip` pack (→ `initrd.gz`), and the
  iPXE `EMBED=` build (`bin/ipxe.usb`). Only the QEMU boot itself defers to the
  parent lab's already-tested client.
