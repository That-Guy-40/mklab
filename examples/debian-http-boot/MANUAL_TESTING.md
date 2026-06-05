# debian-http-boot — manual testing & end-to-end runbook

The copy-pasteable runbook for building, packing, and **booting** the
[debian-http-boot](./README.md) lab — Kenneth Finnegan's "Booting Linux over
HTTP" on Debian 13 trixie, run entirely from RAM. It tests each piece in
isolation (so you can tell *which* part broke) and then runs the whole thing
end-to-end, with the **actual** output you should see at each stage.

> **Every "Expect" block below is real**, captured on a KVM-capable x86_64 host
> on 2026-06-04 — not a prediction. Your byte counts and timestamps will differ
> slightly; the shape won't.

Budget ~10–15 minutes wall-clock: most of it is `debootstrap` pulling ~200 MB of
trixie packages. The boot itself is ~2 seconds under KVM.

> Run everything from the repo root:
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> ```
> The VM TOML hard-codes `/home/sqs/...` paths (TOML can't expand `~`/`$HOME`) —
> edit [`vm-debian-http-boot.toml`](./vm-debian-http-boot.toml) if your `$HOME`
> differs.

---

## 0. Preflight — can this host do it?

```bash
# Tools (the build needs debootstrap; the boot needs qemu):
command -v debootstrap qemu-system-x86_64 cpio gzip || \
  echo "install: debootstrap qemu-system-x86 cpio gzip"

# debootstrap must know 'trixie' (on Ubuntu hosts it's symlinked to the sid script):
ls -l /usr/share/debootstrap/scripts/trixie || \
  echo "no trixie script — update debootstrap, or: ln -s sid /usr/share/debootstrap/scripts/trixie"

# KVM (optional, ~50x faster than TCG for a full systemd boot):
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM available" || echo "no KVM — boot works under TCG, just slower"

# Space: chroot ~1.2 GB on disk; initrd ~384 MB; VM wants 4 GB RAM free.
df -h /var "$HOME" | sort -u
```

**Expect** — `trixie -> sid`, `KVM available`, and enough free space:

```
lrwxrwxrwx 1 root root 3 ... /usr/share/debootstrap/scripts/trixie -> sid
KVM available
```

> ⚠️ **Do not build this rootfs with `--rootless`.** fakechroot can't run
> trixie's systemd maintainer scripts (the `libsystemd-shared-*.so` loader
> collision) — the build aborts with *no kernel and no config applied*. A
> full-systemd rootfs needs real root. Details in
> [`README.md` → Troubleshooting](./README.md#troubleshooting).

---

## 1. Build the trixie rootfs (real root, ~5–10 min)

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --config examples/debian-http-boot/debian-http-boot.toml
```

**Expect** — debootstrap streams packages (note `base-files 13.8+deb13u5` =
genuinely trixie), then the `post_commands` run and it finishes clean:

```
[info] debootstrap (native): debian/trixie arch=x86_64 → /var/chroots/debian-http-boot
I: Retrieving InRelease
...
I: Base system installed successfully.
[info] post_command[1]: printf 'LANG=C.UTF-8\n' > /etc/default/locale
[info] post_command[2]: echo 'root:lab' | chpasswd
[info] post_command[3]: mkdir -p /etc/systemd/network
[info] post_command[4]: printf '[Match]\nName=en* eth*\n...' > /etc/systemd/network/10-dhcp.network
[info] post_command[5]: systemctl enable systemd-networkd || true
[info] chroot 'debian-http-boot' ready
```

**If it fails** at `dpkg ... cron-daemon-common ... libsystemd-shared`: you ran it
`--rootless`. Re-run as real `sudo` (see §0).

---

## 2. (Optional) Inspect the chroot — confirm it's configured (sudo)

The chroot is root-owned, so these need `sudo`. Skip to §3 if you trust §1.

```bash
sudo ls -l /var/chroots/debian-http-boot/boot/ | grep vmlinuz   # the kernel
sudo readlink /var/chroots/debian-http-boot/sbin/init           # where /sbin/init points
sudo cat /var/chroots/debian-http-boot/etc/systemd/network/10-dhcp.network
```

**Expect** — a kernel is present, `/sbin/init` resolves to systemd, the DHCP unit
is in place:

```
-rw-r--r-- 1 root root ... vmlinuz-6.12.86+deb13-amd64
usr/sbin/init                # (merged-/usr: /sbin -> /usr/sbin -> ../lib/systemd/systemd)
[Match]
Name=en* eth*

[Network]
DHCP=yes
```

---

## 3. Pack kernel + initrd, installing Kenneth's `/init` verbatim (real root)

```bash
sudo phase1-chroot/lab-chroot.sh export-initrd debian-http-boot \
    --init-script "$PWD/examples/debian-http-boot/init" \
    --kernel ~/netboot/kernel-debian-http \
    --output ~/netboot/initrd-debian-http.gz
```

`--init-script` with that **absolute** path is what installs Kenneth's `/init`
verbatim (export only auto-writes a default `/init` when none exists). The tool
`chown`s the outputs back to you, so the rest of this runbook needs no `sudo`.

**Expect** — the `find | cpio -H newc | gzip` packaging (his exact pipeline,
mechanized) and the two artifacts:

```
[info] using custom /init from .../examples/debian-http-boot/init
[info] copying kernel ... → /home/you/netboot/kernel-debian-http
[info] packaging /var/chroots/debian-http-boot → /home/you/netboot/initrd-debian-http.gz
[info] kernel:  /home/you/netboot/kernel-debian-http (12M)
[info] initrd:  /home/you/netboot/initrd-debian-http.gz (384M)
```

Quick sanity on the artifacts:

```bash
ls -lh ~/netboot/kernel-debian-http ~/netboot/initrd-debian-http.gz
file ~/netboot/kernel-debian-http
```

**Expect** — a real trixie bzImage:

```
... kernel-debian-http: Linux kernel x86 boot executable bzImage,
    version 6.12.86+deb13-amd64 ... Debian 6.12.86-1 (2026-05-08) ...
```

---

## 4. Verify the packaged initrd — the payload checks (no sudo)

This is the part worth doing carefully: prove the cpio actually contains
**Kenneth's `/init`** and your config, before you boot. All of this reads the
sqs-owned `initrd-debian-http.gz` — no root needed.

```bash
REPO="$PWD"                       # you're at the repo root (see preamble)
mkdir -p /tmp/dhb && cd /tmp/dhb

# (a) the centerpiece: the packaged /init is byte-identical to the source script
zcat ~/netboot/initrd-debian-http.gz | cpio -idm --quiet init
diff -q init "$REPO/examples/debian-http-boot/init"
echo "rc=$?  (0 = identical)"

# (b) the kernel hands PID 1 to systemd: /sbin -> /usr/sbin -> systemd (merged-/usr)
zcat ~/netboot/initrd-debian-http.gz | cpio -idm --quiet usr/sbin/init
readlink usr/sbin/init                                  # -> ../lib/systemd/systemd

# (c) your DHCP unit, and that systemctl enable took (the wants/ symlink)
zcat ~/netboot/initrd-debian-http.gz | cpio -idm --quiet etc/systemd/network/10-dhcp.network
cat etc/systemd/network/10-dhcp.network
zcat ~/netboot/initrd-debian-http.gz | cpio -t 2>/dev/null | grep wants/systemd-networkd.service

# (d) Kenneth's locale (written through trixie's /etc/default/locale -> ../locale.conf symlink)
zcat ~/netboot/initrd-debian-http.gz | cpio -idm --quiet etc/locale.conf
cat etc/locale.conf
cd - >/dev/null
```

**Expect**:

```
rc=0  (0 = identical)
../lib/systemd/systemd
[Match]
Name=en* eth*

[Network]
DHCP=yes
etc/systemd/system/multi-user.target.wants/systemd-networkd.service
LANG=C.UTF-8
```

> `diff … init` returning **identical** is the proof the lab's whole premise
> rests on: the bytes Kenneth published are the bytes the kernel will run as
> PID 1.

---

## 5. Boot it (QEMU/KVM)

### 5a. The documented way — `lab-vm.sh` (interactive)

```bash
phase2-qemu-vm/lab-vm.sh create  --config examples/debian-http-boot/vm-debian-http-boot.toml
phase2-qemu-vm/lab-vm.sh start    debian-http-boot   # create only provisions — start boots it
phase2-qemu-vm/lab-vm.sh console  debian-http-boot   # attach; Ctrl-] to detach
```

> **Gotcha 1 — `create` ≠ `start`.** `create` only writes the VM record (it says
> `not started`); nothing is running until `start`. The bare-flags form
> `lab-vm.sh create --backend kernel+initrd --kernel … --initrd …` also errors
> with `[error] spec missing required field: name` — that path needs an explicit
> `--name`. Use `--config` (above); the name lives in the spec.
>
> **Gotcha 2 — this lab is console-only; there is no SSH.** On `create`,
> `lab-vm.sh` prints a generic `ssh access after boot: … lab@127.0.0.1 (default
> password 'lab')` hint. **Ignore it here.** The rootfs is deliberately lean (no
> `openssh-server`) and has no `lab` user — only `root`'s password is set, so
> `ssh -p 2222 lab@127.0.0.1` is *refused* (nothing listens on guest `:22`, and
> the hostfwd only exists while the VM runs). Reach it with `lab-vm.sh console`
> and log in `root` / `lab`. (SSH is the heavier `../chroot-netboot-full.toml`
> track, which ships `openssh-server` + a `lab` user.)

On the console you'll watch the `/init` `set -x` trace run, then systemd boot,
then a login prompt. Log in `root` / `lab`. `Ctrl-]` detaches without killing
the VM. (`lab-vm.sh stop debian-http-boot` shuts it down.)

### 5b. Capture the boot non-interactively (direct qemu → file)

This is how the "Expect" output below was captured — handy for CI or just to
grab the full trace from the very first byte:

```bash
timeout 90 qemu-system-x86_64 \
  -enable-kvm -cpu host -machine q35 -m 4G -smp 2 \
  -kernel ~/netboot/kernel-debian-http \
  -initrd ~/netboot/initrd-debian-http.gz \
  -append "console=ttyS0 root=/dev/ram0 rw" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -serial file:/tmp/dhb-console.log -no-reboot
# qemu is killed by `timeout` (rc=124) because it sat at the login prompt — good.
sed -n '/+ \[ -d \/dev \]/,/exec \/sbin\/init/p' /tmp/dhb-console.log   # the /init trace
tail -6 /tmp/dhb-console.log                                            # the login prompt
```

**Expect** — Kenneth's `/init` running as PID 1, ending in the hand-off:

```
+ [ -d /dev ]
+ mkdir -p /var/lock
+ mount -t sysfs -o nodev,noexec,nosuid sysfs /sys
+ mount -t proc -o nodev,noexec,nosuid proc /proc
+ mount -t devtmpfs -o size=10240k,mode=0755 udev /dev
+ mkdir /dev/pts
+ mount -t devpts -o noexec,nosuid,gid=5,mode=0620 devpts /dev/pts
+ mount -t tmpfs -o nosuid,size=20%,mode=0755 tmpfs /run
+ echo 1
+ exec /sbin/init
```

…then systemd, ending at the trixie serial login (≈2 s in under KVM):

```
[  OK  ] Started serial-getty@ttyS0.service - Serial Getty on ttyS0.
[  OK  ] Reached target multi-user.target - Multi-User System.

Debian GNU/Linux 13 debian-http-boot ttyS0
debian-http-boot login:
```

`+ exec /sbin/init` is the last line the **shell** prints; everything after it is
systemd, in the **same PID 1** (no `switch_root`). That's the entire mechanic.

---

## 6. Log in and verify in-VM (`root` / `lab`)

To confirm it's a real, RAM-resident trixie — log in and run:

```bash
head -1 /etc/os-release      # PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
uname -r                      # 6.12.86+deb13-amd64
findmnt -no SOURCE,FSTYPE /   # rootfs rootfs   ← the proof: / IS the initramfs
ip -4 -o addr show scope global   # enp0s2 ... 10.0.2.15/24 ... dynamic
free -h | head -2             # ~3.8Gi total, whole OS resident in RAM
systemctl is-system-running   # running   (no failed units)
```

**Expect** — exactly that. The single most important line is
`findmnt / → rootfs rootfs`: the root filesystem is the kernel's in-RAM
initramfs `tmpfs` itself. There is no disk; nothing was `switch_root`-ed onto.
`10.0.2.15/24` confirms systemd-networkd DHCP'd the slirp NIC on its own.

A clean `poweroff` from inside exits qemu with `rc=0`.

---

## 7. (Optional) Boot it *over HTTP* — faithful to the title

The direct boot proves the `/init`→systemd mechanic; the blog's framing is
fetching those same bytes over HTTP via iPXE. Don't rebuild a server here — reuse
the repo's pipeline:

1. Serve `~/netboot` on `:8181` — [`../podman-netboot-server.toml`](../podman-netboot-server.toml)
   (rename/symlink `kernel-debian-http`/`initrd-debian-http.gz` to whatever your
   `boot.ipxe` names).
2. Build an iPXE that chainloads it — [`../../netboot/build-ipxe.sh`](../../netboot/build-ipxe.sh).
3. Boot the iPXE "hardware" — [`../vm-netboot-ipxe.toml`](../vm-netboot-ipxe.toml).

Full transport-side testing (HTTP/HTTPS/TFTP, watching each fetch) lives in
[`../../netboot/MANUAL_TESTING.md`](../../netboot/MANUAL_TESTING.md) and
[`../pxe-boot-mechanics/`](../pxe-boot-mechanics/).

---

## 8. Cleanup

```bash
phase2-qemu-vm/lab-vm.sh destroy debian-http-boot              # the VM record
sudo phase1-chroot/lab-chroot.sh destroy debian-http-boot      # the root-owned chroot
rm -f ~/netboot/kernel-debian-http ~/netboot/initrd-debian-http.gz   # the artifacts
rm -rf /tmp/dhb /tmp/dhb-console.log                           # scratch from §4/§5
```

---

## 9. Troubleshooting — quick index

The three you're most likely to hit (full table in
[`README.md`](./README.md#troubleshooting)):

| Symptom | Fix |
|---|---|
| `create` dies on `cron-daemon-common` / `libsystemd-shared-*.so` (exit 127) | You used `--rootless`. fakechroot can't build a systemd rootfs — use `sudo` (§1). |
| `lab-vm.sh create` → `spec missing required field: name` | You used the bare-flags form; use `--config` (§5a). |
| `Kernel panic … Attempted to kill init!` right after the `/init` trace | An early `mount` failed and `set -e` aborted before `exec /sbin/init`. Read the last `+ mount …` line in the trace. |
| Boots but OOM-panics while unpacking | VM RAM too low for the ~1 GB rootfs — keep `memory = "4G"`. |
