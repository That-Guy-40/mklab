# Kali PXE lab — full install boot-verify (the ~15-min d-i run)

> **⚠️ Boot mechanism updated (this runbook predates it).** The lab now boots via
> QEMU **`pxe-install`** (the NIC's PXE ROM TFTP-chainloads `ipxe.pxe`), **not**
> the two-disk iPXE-ROM-on-a-disk boot-loop described below — that never booted in
> QEMU (SeaBIOS only tries the first hard disk; disk-image x86_64 defaults to OVMF,
> which can't boot a BIOS-MBR disk). The **install + preseed** steps are unchanged
> and still valid; ignore the `vdb` "iPXE ROM disk" / ROM-survival material (there
> is no second disk now). For the current pxe-install boot checks see
> [`../kali-preseed-gallery/MANUAL_TESTING.md`](../kali-preseed-gallery/MANUAL_TESTING.md).

End-to-end, copy-pasteable runbook for actually completing a Kali Linux
zero-touch **Debian-installer (d-i)** PXE install in QEMU — from a blank disk
to an SSH login, hands-off. This is the Kali/d-i analog of
`../rocky-pxe-lab/MANUAL_TESTING.md` (which covers the Anaconda/kickstart side).

Budget ~10–20 minutes wall-clock on a KVM-capable x86_64 host for the **lean**
default install (longer under TCG, much longer with a `kali-linux-*` metapackage).

> Run everything from the repo root:
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> ```
> Edit `examples/kali-pxe-lab/kali-pxe-lab.toml` and replace `/home/sqs` with
> your `$HOME` (TOML does not expand `~`/`$HOME`).

---

## ⚠️ Read this first — the one genuinely install-breaking risk

**d-i wandering onto the iPXE ROM disk.** The whole boot-loop depends on the
installer touching **only** the blank 20 GB target and **never** the small
iPXE ROM disk that chainloaded it. If d-i partitions or installs GRUB onto the
ROM, you get the worst outcome: the ROM is destroyed *and* the real target
stays blank, so the VM either reinstalls on every boot forever or fails
outright. This is the single failure mode that can't be shrugged off.

### Why it's a real risk (and not paranoia)

`lab-vm.sh` attaches two virtio-blk disks (`examples/.../lab-vm.sh:2075`):

```
disk0 = the blank 20 GB install target   (added FIRST,  bootindex=0)
disk1 = ipxe.qcow2 ROM                    (added SECOND, bootindex=1)
```

`bootindex` controls **firmware boot order**, *not* the Linux device name. The
device name (`/dev/vda` vs `/dev/vdb`) is assigned by **PCI enumeration order**,
which is a *different mechanism*. The preseed pins the whole install to
`/dev/vda`:

```
d-i partman-auto/disk      string /dev/vda
d-i grub-installer/bootdev string /dev/vda
```

So the install is safe **iff** `/dev/vda` is the blank target — not the ROM. If
your QEMU happened to enumerate them the other way, that pinning would point
straight at the ROM. That's why this is a "might," not a "will."

### How the `vda` pinning closes it — verified, with the receipt

On the lab's QEMU config (`q35` + `virtio-blk-pci`, KVM), the disk added first
to the command line enumerates as `/dev/vda`. Booted a kernel against the exact
two-disk argv `lab-vm.sh` produces (20 GB target first, 4 MiB ROM second) and
read the kernel's own probe:

```
virtio_blk virtio0: [vda] 41943040 512-byte logical blocks (20.0 GiB)   ← target (added 1st)
virtio_blk virtio1: [vdb]     8192 512-byte logical blocks (4.00 MiB)   ← iPXE ROM (added 2nd)
```

`/dev/vda` = the 20 GiB target, `/dev/vdb` = the ROM. So `partman-auto/disk
/dev/vda` and `grub-installer/bootdev /dev/vda` confine **everything** to the
blank target and never touch the ROM — exactly what the boot-loop needs. This
is the d-i equivalent of the Rocky/Alma kickstart's `ignoredisk --only-use=vda`.

### The honest caveat

This is pinning **by enumeration position** (first-added disk → `vda`), not by a
stable hardware identifier. `lab-vm.sh` doesn't set a `serial=`/`wwn=` on the
drives, so the mapping rests on QEMU assigning PCI slots in command-line order
and Linux naming virtio-blk by probe order — reliable on `q35`/auto-PCI and
verified above, but **not a hard contract**. It could differ if you change the
machine type, pin PCI addresses by hand, add disks, or hit a future QEMU that
reorders. So **confirm it** (next section) the first time you run on a new host
or QEMU version, and consider the deterministic hardening at the end.

---

## 0. Preflight

```bash
command -v qemu-system-x86_64 qemu-img podman docker jq curl || \
  echo "install: qemu-system-x86 qemu-utils podman docker.io jq curl"
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM available" || echo "no KVM — TCG works, slower"
ss -ltn 2>/dev/null | grep -q ':8181 ' && echo "8181 IN USE — pick another port" || echo "8181 free"
df -h "$HOME" | tail -1     # ~3 GB written for a lean install; more for kali-linux-*
```

## 1. Fetch + verify the installer (≈1 min)

```bash
examples/kali-pxe-lab/fetch-kali-installer.sh --arch amd64
ls -lh ~/netboot/kali/linux ~/netboot/kali/initrd.gz
```
**Expect:** `linux: checksum OK`, `initrd.gz: checksum OK`, files ~14 MB / ~44 MB
under `~/netboot/kali/`.

## 2. Stage the preseed

```bash
cp examples/kali-pxe-lab/kali-preseed.cfg ~/netboot/kali/
```

## 3. Build the iPXE ROM (≈1–3 min, Docker)

```bash
netboot/build-ipxe.sh \
    --server http://10.0.2.2:8181 \
    --kernel-path /kali/linux --initrd-path /kali/initrd.gz \
    --append 'auto=true priority=critical preseed/url=http://10.0.2.2:8181/kali/kali-preseed.cfg DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---'
ls -lh ~/netboot/ipxe.qcow2
```

## 4. Serve + confirm all three artifacts (instant)

```bash
phase4-podman/lab-podman.sh up --config examples/kali-pxe-lab/kali-pxe-lab.toml
curl -sI http://localhost:8181/kali/linux            | head -1   # 200
curl -sI http://localhost:8181/kali/initrd.gz        | head -1   # 200
curl -sI http://localhost:8181/kali/kali-preseed.cfg | head -1   # 200
```
All three must be `200`. A `404` ⇒ wrong `$HOME` in the TOML volume or the file
isn't under `~/netboot/kali/`. A `403` on SELinux ⇒ the `:Z` relabel was skipped
(`lab-podman.sh` adds it automatically).

## 5. Create + start, then watch

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/kali-pxe-lab/kali-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start  kali-pxe-install
phase2-qemu-vm/lab-vm.sh console kali-pxe-install     # Ctrl-] detaches; install continues
```

## 6. What you should see, stage by stage

| Phase | On the serial console | Roughly |
|---|---|---|
| **a. firmware** | SeaBIOS tries the blank target (vda) first, no boot sector, falls through to the iPXE ROM (vdb). | 0:00 |
| **b. iPXE** | `Configuring (net0 …)… ok`, then `http://10.0.2.2:8181/kali/linux… ok` and `…/initrd.gz… ok`. | 0:05 |
| **c. d-i starts** | `Loading additional components`, `Detecting network hardware`, `Configuring the network with DHCP`. | 0:30 |
| **d. preseed fetch** | d-i pulls `…/kali/kali-preseed.cfg` (the d-i analog of Anaconda's ks fetch). A mistyped URL 404s here. | 1:00 |
| **e. partition** | `Partitioning disks` runs **non-interactively** on `/dev/vda` (atomic recipe). **This is where the ROM-clobber risk is decided** — see §verify below. | 1:30 |
| **f. base + packages** | `Installing the base system`, then debootstrap + apt from `http.kali.org`. The long pole; tracks your bandwidth. | 3:00–15:00 |
| **g. bootloader** | `Installing GRUB boot loader` to `/dev/vda`. | varies |
| **h. reboot** | `Finishing the installation` → automatic reboot. iPXE does **not** run this time — vda is now bootable. | +0:10 |
| **i. installed Kali** | GRUB → kernel → a `kali-pxe login:` prompt on the serial console. **Done.** | — |

The (h)→(i) transition — landing in the *installed* system, not back in d-i — is
the proof the boot-loop closed correctly.

## 7. Verify the install — and that the ROM survived

Detach (`Ctrl-]`) and SSH in (no cloud-init; d-i made the accounts from the
preseed):

```bash
phase2-qemu-vm/lab-vm.sh ssh kali-pxe-install      # login: kali / kali  (root / lab also works)
```

Inside, the **definitive ROM-survival check** — `vdb` must show **no
partitions** (proof partman obeyed the `vda` pinning and never touched the ROM):

```bash
lsblk
# Expect:
#   vda    20G  disk
#   ├─vda1 ...  part  /
#   └─vda2 ...  part  [swap]    (atomic recipe → one root, maybe swap)
#   vdb   ~4M+  disk            ← NO child partitions = ROM untouched ✓
cat /etc/os-release | grep -i kali        # → Kali GNU/Linux Rolling
sudo dnf 2>/dev/null; apt-get --version | head -1   # it's apt, not dnf — Debian family
```

If `vdb` has partitions on it, the pinning pointed at the wrong disk — see
recovery below.

## 8. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab kali-pxe
phase2-qemu-vm/lab-vm.sh    destroy kali-pxe-install --force
# Optional: reclaim artifacts (~60 MB):  rm -rf ~/netboot/kali ~/netboot/ipxe.qcow2
```

---

## Confirming disk identity *before* you trust an unattended run

On a new host / QEMU version, verify the `vda`=target assumption rather than
discovering it after a wipe. Three ways, cheapest first:

1. **Post-install `lsblk` (non-invasive, after the fact).** §7 above — if the
   install completed and `vdb` is partition-free, the mapping held. Good enough
   for a throwaway lab you can re-run.

2. **Quick standalone enumeration probe (no install, ~30 s).** Boot *any* small
   kernel against the same two-disk argv and read the probe — distinguishable
   by size (target 20 G vs ROM tiny). Using the micro-linux artifacts:

   ```bash
   qemu-img create -f qcow2 /tmp/tgt.qcow2 20G >/dev/null
   qemu-img create -f qcow2 /tmp/rom.qcow2 4M  >/dev/null
   K=micro-linux/out/x86_64        # build with: micro-linux/mlbuild.sh all --arch x86_64
   timeout 25 qemu-system-x86_64 -machine q35,accel=kvm -m 512M \
     -display none -nographic -no-user-config -nodefaults -serial mon:stdio \
     -kernel "$K/kernel" -initrd "$K/initramfs.cpio.gz" -append "console=ttyS0" \
     -drive file=/tmp/tgt.qcow2,if=none,id=disk0,format=qcow2 -device virtio-blk-pci,drive=disk0 \
     -drive file=/tmp/rom.qcow2,if=none,id=disk1,format=qcow2 -device virtio-blk-pci,drive=disk1 \
     2>&1 | grep -E '\[vd[a-z]\].*GiB|\[vd[a-z]\].*MiB'
   rm -f /tmp/tgt.qcow2 /tmp/rom.qcow2
   # Expect: [vda] ... 20.0 GiB   and   [vdb] ... 4.00 MiB
   # If they're swapped, flip the preseed (see recovery).
   ```

3. **A size-checking diagnostic install.** Temporarily drop `priority=critical`
   from the iPXE `--append` (rebuild iPXE) so d-i's text partitioner stops and
   shows each disk with its size (`Virtual disk 1 (vda) - 21.5 GB` vs the tiny
   one). Eyeball it, then restore `priority=critical`.

### Recovery if the mapping is reversed (`vdb` = target)

Edit `examples/kali-pxe-lab/kali-preseed.cfg`, swap both pins to `vdb`, re-copy
to `~/netboot/kali/`, and re-run from step 5:

```
d-i partman-auto/disk      string /dev/vdb
d-i grub-installer/bootdev string /dev/vdb
```

### Deterministic hardening (optional) — pin by size, not position

To make the install bulletproof regardless of enumeration order, let a
`partman/early_command` choose the disk by size at runtime instead of
hardcoding `vda`. Add to the preseed (and you can then drop the static
`partman-auto/disk` line):

```
# Pick the ~20 GB disk as the install target, whatever it's named, and point
# both partman and grub at it.  Runs in d-i's busybox before partitioning.
d-i partman/early_command string \
  TGT=""; for d in /sys/block/vd*; do \
    SZ=$(cat "$d/size"); \
    if [ "$SZ" -gt 33554432 ]; then TGT="/dev/$(basename "$d")"; break; fi; \
  done; \
  debconf-set partman-auto/disk "$TGT"; \
  debconf-set grub-installer/bootdev "$TGT"
```

`33554432` sectors = 16 GiB, a threshold safely above the tiny ROM and below
the 20 GiB target — so it always selects the real target and never the ROM.
This converts the "might" into a "will." The shipped preseed keeps the simpler
static `vda` pin (verified correct for this lab's QEMU); switch to the
early_command if you run across varied machine types or QEMU versions.

---

## Troubleshooting

**iPXE stuck at `Configuring (net0)…`.** VM has no NIC — confirm `network = true`
in the TOML; `stop` then `start` again.

**d-i: `Bad archive mirror` / can't reach `http.kali.org`.** Slirp DNS is
`10.0.2.3`; behind a corporate proxy, d-i won't inherit it. Add
`mirror/http/proxy` to the preseed, or `inst`-style proxy isn't a thing for d-i
— set `d-i mirror/http/proxy string http://host:port`.

**Preseed 404 at phase (d).** The served path must match the iPXE `preseed/url`.
Check `curl -sI http://localhost:8181/kali/kali-preseed.cfg` returns 200 and
that you `cp`'d the preseed into `~/netboot/kali/` (step 2).

**It booted back into d-i a second time.** The target didn't become bootable —
either GRUB install failed, or (the big one) the pinning targeted the ROM.
Re-attach the console during phase (g) for a GRUB error, and run the §verify
enumeration probe to confirm which disk is `vda`.

**Install hangs for a very long time at "Select and install software."** You
likely switched `pkgsel/include` to `kali-linux-default` (a desktop + hundreds
of tools, multiple GB). That's expected — it's downloading. Use the lean default
or `kali-linux-headless` for a faster lab.

---

## Notes

- **This mirrors the Rocky lab's shape.** d-i+preseed replaces Anaconda+kickstart;
  `SHA256SUMS` replaces `.treeinfo`; the iPXE/nginx/QEMU boot-loop is identical.
  The ROM-clobber analysis applies equally to the Rocky/Alma labs (their
  kickstarts use `ignoredisk --only-use=vda`, the Anaconda equivalent of the
  pin verified here).
- **Network install.** Packages come live from `http.kali.org`; only the kernel,
  initrd, and preseed are served locally. Install time tracks mirror bandwidth.
