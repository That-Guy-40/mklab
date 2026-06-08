# debian-http-boot — Booting Debian 13 (trixie) entirely from RAM, over HTTP

A faithful, self-contained clone of Kenneth Finnegan's 2020 write-up
**[“Booting Linux over HTTP”](https://blog.thelifeofkenneth.com/2020/03/booting-linux-over-http.html)**,
updated from Debian *buster* to **Debian 13 “trixie.”** A full Debian system —
systemd and all — is packed into a single gzipped cpio archive and booted
*entirely in RAM*. There is **no disk**: the initramfs **is** the root
filesystem. The star of the show is a hand-rolled `/init` shell script that sets
up a few kernel mounts and then `exec`s the real `/sbin/init` (systemd).

> ### Honest framing first
> This repo *already* does this trick — [`../chroot-netboot-full.toml`](../chroot-netboot-full.toml)
> is literally commented “Kenneth Finnegan's HTTP netboot approach” and cites the
> same blog post. So this directory isn't a brand-new capability. What's new and
> worth having on its own:
> 1. **Debian 13 trixie**, not bookworm.
> 2. **Kenneth's exact `/init`, verbatim** ([`./init`](./init)) — the elaborate
>    Gandi.net version with the `devtmpfs`→`tmpfs` fallback, `/dev/pts`, `/run`,
>    and `dmesg_restrict` — instead of the repo's stripped-down three-line
>    `systemd` init preset.
> 3. **A standalone walkthrough** that explains *why* it works, which is what you
>    actually asked for. The mechanic — not the artifact — is the point.
> 4. **The upstream write-up, vendored** — a byte-exact offline archive of
>    Kenneth's post lives in [`upstream-tutorial/`](upstream-tutorial/) (HTML +
>    CSS + provenance + `sha256`s) so the lab stays reproducible and attributed
>    even if the original moves.
> 5. **A by-hand build sandbox** — [`hand-walk/`](hand-walk/): a disposable
>    container that reproduces Kenneth's *server* environment so you run the
>    `debootstrap` → `cpio` → iPXE steps yourself (artifacts to a bind-mounted
>    `out/`, then boot with the client below). The hands-on counterpart to this
>    lab's automated build.
>
> It's also *leaner* than `chroot-netboot-full.toml` on purpose: no cloud-init,
> no `locales-all`. Neither is in the blog, and dropping them keeps this close to
> the original (and sidesteps the cloud-init/locale build pitfalls documented
> elsewhere in this repo).

---

## TL;DR — the whole pipeline

```bash
# 1. Build the trixie rootfs (root, ~5-10 min)
sudo phase1-chroot/lab-chroot.sh create \
    --config examples/debian-http-boot/debian-http-boot.toml

# 2. Pack it into kernel + initrd, installing Kenneth's /init verbatim (root)
sudo phase1-chroot/lab-chroot.sh export-initrd debian-http-boot \
    --init-script "$PWD/examples/debian-http-boot/init" \
    --kernel ~/netboot/kernel-debian-http \
    --output ~/netboot/initrd-debian-http.gz

# 3. Boot it the short way — QEMU loads kernel+initrd into RAM (no sudo)
phase2-qemu-vm/lab-vm.sh create --config examples/debian-http-boot/vm-debian-http-boot.toml
phase2-qemu-vm/lab-vm.sh start  debian-http-boot          # log in: root / lab
```

Step 3 is the *short* path. The *faithful* path — actually fetching those bytes
over HTTP with iPXE — is in [§ Booting it over HTTP](#booting-it-over-http).

> For a stepped, copy-pasteable runbook that tests **each** piece in isolation
> (with the real expected output at every stage) and then runs the whole thing,
> see [`MANUAL_TESTING.md`](./MANUAL_TESTING.md).

---

## The blog, faithfully retold (buster → trixie)

Kenneth's goal was diskless Dell FX160 thin clients that pull a whole OS into RAM
over the network. His recipe, step by step, with the trixie adaptation alongside:

### 1. Build a Debian root filesystem with debootstrap

His original:

```bash
sudo debootstrap buster /home/kenneth/tmp/rootfs http://ftp.us.debian.org/debian/
LANG=C.UTF-8 sudo chroot /home/kenneth/tmp/rootfs /bin/bash
apt install linux-image-amd64        # inside the chroot
# ...then copy the kernel out of /boot for later
```

Here, [`./debian-http-boot.toml`](./debian-http-boot.toml) does the equivalent
with `suite = "trixie"` — `lab-chroot.sh` runs `debootstrap trixie …`, installs
`linux-image-amd64` plus systemd and a few net tools, and sets `LANG=C.UTF-8`
(Kenneth's exact locale). One nuance: on an Ubuntu host, debootstrap resolves
`trixie` through its `sid` script (they share logic) — harmless.

### 2. The `/init` script — the heart of it

The kernel, when handed an initramfs, runs **`/init`** as PID 1. Kenneth's (in
[`./init`](./init), reproduced **byte-for-byte** including his attribution):

```sh
#!/bin/sh
# Kenneth Finnegan, 2020 ... Huge thanks to Gandi.net for most of this code
set -x
set -e
# create mount points (only if missing) ...
mount -t sysfs -o nodev,noexec,nosuid sysfs /sys
mount -t proc  -o nodev,noexec,nosuid proc  /proc
# devtmpfs for /dev, falling back to a tmpfs + manual mknod if the kernel
# wasn't built with CONFIG_DEVTMPFS:
mount -t devtmpfs -o size=10240k,mode=0755 udev /dev   # (with fallback)
mkdir /dev/pts && mount -t devpts ... devpts /dev/pts
mount -t tmpfs ... tmpfs /run
echo 1 > /proc/sys/kernel/dmesg_restrict
# Replace ourselves with the actual init daemon:
exec /sbin/init
```

### 3. Pack the rootfs into an initramfs

His command, verbatim:

```bash
cd /home/kenneth/tmp/rootfs
sudo find . | sudo cpio -H newc -o | gzip -9 -n >~/www/initrd
```

**This repo mechanizes exactly that line.** `export-initrd`'s core is:

```
( cd "$target" && find . <prune /proc /sys /dev /run /tmp> \
    | cpio --null -H newc -o | gzip -9 -n > "$out" )
```

Same `find | cpio -H newc -o | gzip -9 -n` — it just also drops the virtual
filesystems (you don't want a snapshot of `/proc` in your archive) and copies the
kernel out of `/boot` for you in the same step.

### 4. Boot it over HTTP with iPXE

Kenneth flashed a custom iPXE ROM with an **embedded boot script** onto each
thin client's SSD. His `#!gpxe` script (static IP):

```
#!gpxe
ifopen net0
set net0/ip 192.0.2.100
set net0/netmask 255.255.255.0
set net0/gateway 192.0.2.1
set net0/dns 192.0.2.1
kernel http://example.com/vmlinux1
initrd http://example.com/init1
boot
```

built into a ROM with:

```bash
cd ~/src/ipxe/src
make EMBEDDED_IMAGE=./bootscript bin/ipxe.usb     # then dd to the SSD
```

The repo's netboot pipeline does the modern DHCP equivalent — see
[§ Booting it over HTTP](#booting-it-over-http).

---

## What's *actually* happening (your question, answered)

> *“I THINK it invokes the normal Debian init program?”* — Yes. Exactly that.
> Here's the full chain, because the mechanic is the whole point.

**1. The kernel runs `/init` as PID 1.** When you boot with an initramfs (QEMU's
`-initrd`, or iPXE's `initrd` command), the kernel unpacks that cpio archive into
a `tmpfs` in RAM and executes **`/init`** from its root as process 1. (For a true
initramfs it looks for `/init` specifically; you can override with `rdinit=`.)

**2. Normally `/init` is a stepping-stone — here it's the destination.** On a
stock Debian install, `/init` comes from *initramfs-tools* and its job is: load
storage drivers, find the **real root disk**, mount it, and `switch_root` (a.k.a.
`pivot_root`) onto it — *then* exec the disk's `/sbin/init`. The tiny initramfs
exists only to reach the real root.

In Kenneth's RAM boot **there is no real root disk.** The *entire* Debian system
is already unpacked into the RAM `tmpfs`. So his `/init` does **none** of the
find-and-mount-real-root dance. It only:

- mounts the kernel's virtual filesystems that systemd expects to exist —
  `/proc`, `/sys`, `/dev` (devtmpfs), `/dev/pts`, `/run` — and
- `exec /sbin/init`.

**3. `exec` keeps the *same* PID 1.** `exec` doesn't spawn a child; it *replaces*
the current process image in place. So the `/bin/sh` running `/init` **becomes**
`/sbin/init` — still PID 1, no fork, no `switch_root`. systemd takes over the
exact root filesystem the shell was standing in (the RAM `tmpfs`), and brings up
the rest of userspace — fstab mounts, getty, networking — just like a disk
install. **The initramfs never gets thrown away; it *is* the final root.**

**4. Why systemd boots as a *normal* system (the detail that makes it work).**
Modern systemd checks for **`/etc/initrd-release`** at startup. If that file is
present, systemd assumes it's running *inside* an initramfs and enters “initrd
mode” — it runs `initrd.target` and *expects* something to `switch_root` away
soon. A plain debootstrap rootfs has **no `/etc/initrd-release`** (that file is an
initramfs-tools artifact). So when `exec /sbin/init` fires, systemd sees an
ordinary root and boots normally — `default.target`, the works. *That* is the
quiet reason a full distro rootfs can masquerade as an initramfs, but a distro's
*actual* initramfs image can't just “become” the running system.

So: kernel → `/init` (PID 1, a shell) → sets up vfs mounts → `exec /sbin/init`
(same PID 1, now systemd) → normal Debian boot, all in RAM. No disk, no
`switch_root`.

---

## Build it

```bash
# Build the trixie chroot (needs root, ~5-10 min the first time):
sudo phase1-chroot/lab-chroot.sh create \
    --config examples/debian-http-boot/debian-http-boot.toml
```

Then pack it. The `--init-script "$PWD/examples/debian-http-boot/init"` is how
Kenneth's *file* gets installed verbatim as `/init`: `export-initrd` only
auto-writes a default `/init` when none exists, and `--init-script` with an
**absolute** path overrides it. `$PWD/…` makes that absolute path work no matter
where you cloned the repo.

```bash
sudo phase1-chroot/lab-chroot.sh export-initrd debian-http-boot \
    --init-script "$PWD/examples/debian-http-boot/init" \
    --kernel ~/netboot/kernel-debian-http \
    --output ~/netboot/initrd-debian-http.gz
```

You now have a kernel and a `~1 GB`-in-RAM initrd that contain a complete Debian
13 system.

## Boot it directly (the short path)

```bash
phase2-qemu-vm/lab-vm.sh create  --config examples/debian-http-boot/vm-debian-http-boot.toml
phase2-qemu-vm/lab-vm.sh start    debian-http-boot   # create only provisions — start actually boots it
phase2-qemu-vm/lab-vm.sh console  debian-http-boot   # attach to the serial console; Ctrl-] detaches
```

> **This lab is console-only — there is no SSH.** On `create`, `lab-vm.sh` prints
> a generic `ssh access after boot: … lab@127.0.0.1 (default password 'lab')`
> hint. **Ignore it here:** the rootfs is deliberately lean (no `openssh-server`)
> and has no `lab` user — only `root`'s password is set. `ssh -p 2222 …` will be
> *refused* (nothing listens on guest `:22`, and the forward only exists while the
> VM runs). Get in with `lab-vm.sh console` and log in **`root` / `lab`**. (If you
> *want* SSH, that's the heavier [`../chroot-netboot-full.toml`](../chroot-netboot-full.toml)
> track — it ships `openssh-server` + a `lab` user.)

**Observed** (booted end-to-end under KVM — see [Status](#status)): the `set -x`
trace from `/init` scrolls past first — you literally watch each `mount` run and
then `+ exec /sbin/init` as the very last line the shell prints — then systemd's
boot output, then a `Debian GNU/Linux 13 debian-http-boot login:` prompt in
**~2 seconds**. Log in **`root` / `lab`**. `Ctrl-]` detaches. The first NIC
already has a DHCP lease (systemd-networkd) — `ip addr` shows `10.0.2.15/24` on
the slirp net. The proof it's truly RAM-resident: `findmnt /` reports
**`rootfs rootfs`** (the initramfs tmpfs itself is `/` — no disk, no
`switch_root`), and `systemctl is-system-running` returns `running` (no failed
units).

> If you drive it by hand and hit `[error] spec missing required field: name`,
> you used the bare-flags form of `lab-vm.sh create` — that path needs an
> explicit `--name`. Use `--config …/vm-debian-http-boot.toml` (above) instead;
> the name lives in the spec.

## Booting it over HTTP

The direct boot above proves the `/init`→systemd mechanic. To be faithful to the
title — fetch the same kernel+initrd *over HTTP* via iPXE — reuse the repo's
existing netboot pipeline rather than rebuilding one here:

1. **Serve the artifacts.** Point an nginx container at `~/netboot` on `:8181`:
   [`../podman-netboot-server.toml`](../podman-netboot-server.toml) (rootless) or
   [`../docker-examples/docker-netboot-server.toml`](../docker-examples/docker-netboot-server.toml). (Rename or
   symlink `kernel-debian-http`/`initrd-debian-http.gz` to whatever your
   `boot.ipxe` references.)
2. **Build an iPXE that chainloads it.** [`../../netboot/build-ipxe.sh`](../../netboot/build-ipxe.sh)
   bakes an embedded script that DHCPs and fetches `kernel`+`initrd` over HTTP —
   the modern DHCP equivalent of Kenneth's static-IP `#!gpxe` ROM.
3. **Boot the iPXE “hardware.”** [`../vm-netboot-ipxe.toml`](../vm-netboot-ipxe.toml)
   boots a VM off that iPXE image so it pulls everything over HTTP, simulating a
   real PXE client. The end-to-end HTTP/HTTPS/TFTP transport mechanics (and how
   to *watch* each fetch) are documented under
   [`../pxe-boot-mechanics/`](../pxe-boot-mechanics/) and
   [`../../netboot/MANUAL_TESTING.md`](../../netboot/MANUAL_TESTING.md).

The kernel doesn't care where the bytes came from — local file or HTTP GET, it
unpacks the same initramfs and runs the same `/init`.

---

## Honest opinions & ideas

- **The mechanic is dead simple and worth internalizing.** Strip away HTTP, iPXE,
  and debootstrap and the entire trick is two ideas: *(a)* an initramfs can be a
  complete OS, not just a bootstrap, and *(b)* `exec /sbin/init` hands PID 1 to
  systemd in place. Everything else is plumbing. The `set -x` in `/init` is a gift
  for learning — you *see* the mounts happen.
- **This overlaps `chroot-netboot-full.toml`; that's fine.** I'd keep both: that
  one is the repo's batteries-included VM track (cloud-init, SSH, the “full” tier
  in [`../00-INDEX.md`](../00-INDEX.md)); this one is the *teaching* clone —
  trixie, verbatim init, minimal extras. If you ever want to collapse them, this
  dir is the more faithful base.
- **RAM is the real cost, not CPU.** A full trixie rootfs is ~1 GB unpacked, and
  during boot the kernel holds the compressed initrd *and* the expanding rootfs
  simultaneously. Hence 4 GB for the VM. This is the single biggest difference
  from 2020 (buster was leaner) — and the thing that bites on real hardware with
  little RAM.
- **`set -e` in PID 1 is a loaded gun (kept anyway, for faithfulness).** If any
  early `mount` fails, `set -e` aborts the script *before* `exec /sbin/init`,
  PID 1 exits, and the kernel panics: `Attempted to kill init!`. On a stock
  Debian kernel those mounts succeed, so it's fine — but it's the **first** thing
  to check on a panic. A production version would `||` -guard each mount; Kenneth
  (and we, “to the letter”) don't.
- **Ideas to extend:** drop the rootfs size with `--strip-modules` on
  `export-initrd`; add a `getty` autologin drop-in so the console lands you at a
  root shell without the `root/lab` prompt; or build an aarch64 twin (the repo's
  chroot tooling cross-builds with `arch = "aarch64"`).
- **Faithful HTTP, not just faithful init.** Because the title is “over HTTP,”
  the lab isn't complete until you've done the iPXE path once. The direct QEMU
  boot is the debug loop; the HTTP boot is the demo.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Kernel panic … Attempted to kill init!` right after the `/init` trace | An early `mount` in `/init` failed and `set -e` aborted before `exec /sbin/init`. Check the last `+ mount …` line in the `set -x` trace. Usually a missing `CONFIG_DEVTMPFS` (the script has a tmpfs fallback) or a typo if you edited `/init`. |
| Panic with **out of memory** while unpacking the initrd | The VM has too little RAM for the ~1 GB rootfs. Give it 4 GB (the VM toml does). On real hardware, the box needs ≥2 GB. |
| `debootstrap: unknown suite trixie` | Old debootstrap without a `trixie` script. On this host it's symlinked to `sid` and works. Otherwise update `debootstrap`, or `ln -s sid /usr/share/debootstrap/scripts/trixie`. |
| Boots to systemd but **no login prompt** on serial | Ensure `console=ttyS0` is on the kernel cmdline (it is in the VM toml) — systemd auto-spawns `serial-getty@ttyS0` only when it sees a serial console. |
| Login prompt appears but **`root` won't log in** | A bare debootstrap **locks** root. The chroot's `post_commands` run `echo 'root:lab' | chpasswd` to fix this; if you removed it, root has no valid password. |
| No network after boot | systemd-networkd should DHCP the first NIC automatically (enabled in the chroot). Check `systemctl status systemd-networkd` and `networkctl`. If the NIC name doesn't match `en*`/`eth*`, edit `/etc/systemd/network/10-dhcp.network`. |
| systemd errors about cgroups on boot | Append `systemd.unified_cgroup_hierarchy=0` to `append` in the VM toml (rarely needed on trixie's modern systemd). |
| `create` fails under `--rootless` with `systemd-sysusers: … libsystemd-shared-NNN.so: cannot open shared object file` (exit 127) | **Don't build this rootfs `--rootless`.** fakechroot is an `LD_PRELOAD` shim with no real `chroot()`; trixie's systemd helpers (run by maintainer scripts like `cron-daemon-common`'s) load a private `libsystemd-shared-*.so` via RUNPATH, which the fakechroot jail can't resolve → the second stage aborts and you get *no kernel and no `post_commands`*. A full-systemd rootfs needs **real root** (`sudo`). Rootless is fine for the busybox/minimal netboot tiers, not this one. |

## Status

**Verified end-to-end (2026-06-04).** Built with `sudo lab-chroot.sh create`
(real root — a `--rootless` attempt failed, see Troubleshooting), packed with
`export-initrd --init-script …/init` (Kenneth's `/init` installed verbatim), and
booted under QEMU/KVM with `-kernel`/`-initrd`. Observed: the `/init` `set -x`
trace ending in `exec /sbin/init`, systemd reaching `graphical.target`, a trixie
serial login (`root`/`lab`) in ~2 s, `findmnt /` → `rootfs rootfs` (RAM-resident
root, no `switch_root`), a systemd-networkd DHCP lease (`10.0.2.15/24`), and
`systemctl is-system-running` → `running`. Artifacts:
`~/netboot/kernel-debian-http` (12 MB, Linux 6.12.86) +
`~/netboot/initrd-debian-http.gz` (384 MB).

## ⚠️ Security

A **lab** demo for **authorized, isolated** networks. `root / lab` is a
**throwaway** credential — never ship it, never expose this VM to an untrusted
network. Plain HTTP and TFTP have no authentication; if you want transport
confidentiality see the HTTPS path under
[`../../netboot/MANUAL_TESTING.md`](../../netboot/MANUAL_TESTING.md) (snakeoil
test cert — no real trust).

## Files in this directory

| File | What it is |
|---|---|
| [`init`](./init) | Kenneth Finnegan's `/init`, **verbatim** (Gandi.net-derived). The centerpiece. |
| [`debian-http-boot.toml`](./debian-http-boot.toml) | The trixie debootstrap chroot spec (Phase 1). |
| [`vm-debian-http-boot.toml`](./vm-debian-http-boot.toml) | QEMU `-kernel/-initrd` direct boot (Phase 2). |
| [`MANUAL_TESTING.md`](./MANUAL_TESTING.md) | Step-by-step runbook: test each piece + run it end-to-end, with real captured output. |
| `README.md` | This walkthrough. |
