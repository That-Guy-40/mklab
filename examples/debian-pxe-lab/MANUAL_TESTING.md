# Debian PXE lab — full install boot-verify (the ~10–20 min d-i run)

End-to-end, copy-pasteable runbook for actually completing a Debian 13 (trixie)
zero-touch **Debian-installer (d-i)** PXE install in QEMU — from a blank disk to
an SSH login, hands-off. This is the *upstream* d-i lab; the Kali variant
([`../kali-pxe-lab/MANUAL_TESTING.md`](../kali-pxe-lab/MANUAL_TESTING.md)) is the
same machinery on the Kali mirror, and the Rocky/Alma labs cover the
Anaconda/kickstart side.

Budget ~10–20 minutes wall-clock on a KVM-capable x86_64 host for the **lean**
default install (longer under TCG, much longer with a desktop task).

> Run everything from the repo root:
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> ```
> Edit `examples/debian-pxe-lab/debian-pxe-lab.toml` and replace `/home/sqs`
> with your `$HOME` (TOML does not expand `~`/`$HOME`).

---

## 0. Preflight

```bash
command -v qemu-system-x86_64 qemu-img podman docker jq curl || \
  echo "install: qemu-system-x86 qemu-utils podman docker.io jq curl"
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM available" || echo "no KVM — TCG works, slower"
ss -ltn 2>/dev/null | grep -q ':8181 ' && echo "8181 IN USE — pick another port" || echo "8181 free"
df -h "$HOME" | tail -1     # ~2–3 GB written for a lean install
```

## 1. Fetch + verify the installer (≈1 min)

```bash
examples/debian-pxe-lab/fetch-debian-installer.sh --arch amd64
ls -lh ~/netboot/debian/linux ~/netboot/debian/initrd.gz
```
**Expect:** `linux: checksum OK`, `initrd.gz: checksum OK`, files ~12 MB / ~39 MB
under `~/netboot/debian/`. Add `--verify-sig` for the extra GPG check of
`SHA256SUMS.sign` against the Debian signing key.

## 2. Stage the preseed

```bash
cp examples/debian-pxe-lab/debian-preseed.cfg ~/netboot/debian/
```

## 3. Build the iPXE ROM (≈1–3 min, Docker)

```bash
netboot/build-ipxe.sh \
    --server http://10.0.2.2:8181 \
    --kernel-path /debian/linux --initrd-path /debian/initrd.gz \
    --append 'auto=true priority=critical preseed/url=http://10.0.2.2:8181/debian/debian-preseed.cfg DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---'
cat ~/netboot/boot.ipxe    # confirm the kernel line carries the debian preseed/url
```

## 4. Serve + confirm all three artifacts (instant)

```bash
phase4-podman/lab-podman.sh up --config examples/debian-pxe-lab/debian-pxe-lab.toml
curl -sI http://localhost:8181/debian/linux              | head -1   # 200
curl -sI http://localhost:8181/debian/initrd.gz          | head -1   # 200
curl -sI http://localhost:8181/debian/debian-preseed.cfg | head -1   # 200
```
All three must be `200`. A `404` ⇒ wrong `$HOME` in the TOML volume or the file
isn't under `~/netboot/debian/`. A `403` on SELinux ⇒ the `:Z` relabel was
skipped (`lab-podman.sh` adds it automatically).

## 5. Create + start, then watch

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/debian-pxe-lab/debian-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start  debian-pxe-install
phase2-qemu-vm/lab-vm.sh console debian-pxe-install     # Ctrl-] detaches; install continues
```

## 6. What you should see, stage by stage

| Phase | On the serial console | Roughly |
|---|---|---|
| **a. firmware** | SeaBIOS tries the blank target (vda) first, no boot sector, falls through to the iPXE NIC ROM. | 0:00 |
| **b. iPXE** | `Configuring (net0 …)… ok`, then `http://10.0.2.2:8181/debian/linux… ok` and `…/initrd.gz… ok`. | 0:05 |
| **c. d-i starts** | `Loading additional components`, `Detecting network hardware`, `Configuring the network with DHCP`. | 0:30 |
| **d. preseed fetch** | d-i pulls `…/debian/debian-preseed.cfg`. A mistyped URL 404s here. | 1:00 |
| **e. partition** | `Partitions formatting` runs **non-interactively** on `/dev/vda` (atomic recipe). | 1:30 |
| **f. base + packages** | `Installing the base system`, then `Select and install software` (apt from `deb.debian.org`). The long pole. | 3:00–15:00 |
| **g. bootloader** | `Installing GRUB boot loader` to `/dev/vda`. | varies |
| **h. reboot** | `Finishing the installation` → `reboot: Restarting system`. iPXE does **not** run this time — vda is now bootable. | +0:10 |
| **i. installed Debian** | `GNU GRUB version 2.12` → `Loading Linux 6.12…` → a `debian login:` prompt on the serial console. **Done.** | — |

The (h)→(i) transition — landing in the *installed* system, not back in d-i — is
the proof the boot closed correctly.

## 7. Verify the install (the real captured receipt)

SSH in (no cloud-init; d-i made the accounts from the preseed). The lab user is
`debian` / `debian` (root / `lab` also works):

```bash
ssh -o StrictHostKeyChecking=no -p 2222 debian@127.0.0.1
```

Verified end-to-end on **2026-07-03** (KVM, x86_64), the actual output:

```text
== os-release ==
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
== kernel ==
6.12.86+deb13-amd64
== disk layout (regular/atomic → single root) ==
NAME    SIZE TYPE FSTYPE MOUNTPOINT
vda      20G disk
├─vda1 18.9G part ext4   /
├─vda2    1K part
└─vda5  1.1G part swap   [SWAP]
== family: apt not dnf ==
apt 3.0.3 (amd64)
```

`vda1` = ext4 root, `vda5` = swap — exactly the **atomic** recipe (everything in
one root partition + swap). It's `apt`, not `dnf` — the Debian installer family,
as promised.

## 8. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab debian-pxe
phase2-qemu-vm/lab-vm.sh    destroy debian-pxe-install --force
# Optional: reclaim artifacts:  rm -rf ~/netboot/debian ~/netboot/boot.ipxe
```

---

## Notes & gotchas

- **Installed hostname comes out as `debian`, not `debian-pxe`.** This is a
  known d-i quirk with *network* preseeding, not a bug in the preseed. Because
  the NIC must be configured **before** the preseed can be downloaded (that's
  how d-i fetches `preseed/url`), the first `netcfg` pass runs with the default
  hostname, and `netcfg/get_hostname`/`netcfg/hostname` from the preseed don't
  always override it afterward. To force it, add `hostname=debian-pxe domain=lab`
  to the iPXE `--append` (kernel-cmdline preseeding, which happens earliest of
  all) and rebuild iPXE. Left as the documented default because it's cosmetic
  and the same pattern the Kali sibling uses.
- **The `/dev/vda` pin.** The preseed pins `partman-auto/disk` + `grub-installer/
  bootdev` to `/dev/vda`, the VM's only disk. On a different machine type or with
  extra disks, confirm `vda` is the intended target (post-install `lsblk`), or
  switch to a size-based `partman/early_command` — see the identical analysis in
  [`../kali-pxe-lab/MANUAL_TESTING.md`](../kali-pxe-lab/MANUAL_TESTING.md#confirming-disk-identity-before-you-trust-an-unattended-run)
  (§"Confirming disk identity"), which applies verbatim here.
- **Network install.** Packages come live from `deb.debian.org`; only the kernel,
  initrd, and preseed are served locally. Install time tracks mirror bandwidth.
- **Want a different disk layout?** See the companion
  [`../debian-preseed-gallery/`](../debian-preseed-gallery/) — lvm / crypto /
  separate-`/home` / multi / minimal, each a one-word `select-preseed.sh` away.
