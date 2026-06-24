# MANUAL_TESTING — rhel-bootc-minimal

Real, captured results. Both the **build + verify** path (RUNBOOK §9.0–§9.4) and
the **boot** path (`bootc install to-disk` → QEMU) are **VERIFIED end to end** on
this host. The four minimal-manifest "boot gotchas" we hit (and fixed) are below.

## Test host

| | |
|---|---|
| podman | 4.9.3 |
| buildah | 1.33.7 |
| docker | 29.5.3 (present, unused here) |
| base image | `quay.io/centos-bootc/centos-bootc:stream9` (1.98 GB), bootc 1.15.2, CentOS Stream 9 |
| kernel userns | `kernel.unprivileged_userns_clone = 1`, `apparmor_restrict_unprivileged_userns = 0` |

---

## ✅ §9.0 — manifests present in the base image

```
$ podman run --rm quay.io/centos-bootc/centos-bootc:stream9 \
      /usr/libexec/bootc-base-imagectl list
minimal: Effectively just bootc, systemd, kernel, and dnf as a starting point.
---
standard: A relatively full, but still generic base image. Roughly
similar to a headless server installation. Automatic updates
are on by default.
```
**PASS** — the `minimal` manifest exists and is exactly "bootc, systemd, kernel, dnf".

---

## ✅ §9.3 — the privilege ladder, reproduced exactly

The chapter's "mount namespacing is off by default" warning is real. Observed, in
order, building `Containerfile.centos`:

| Build flags | Result |
|---|---|
| *(plain rootless `podman build`)* | ❌ `bwrap: Creating new namespace failed: Operation not permitted` |
| `--security-opt seccomp=unconfined --security-opt label=disable --cap-add all` | ❌ got through the install, then `fuse: device not found, try 'modprobe fuse' first` at "Regenerating rpmdb for target" |
| `… + --device /dev/fuse` | ✅ build completes |
| **`--cap-add=all --security-opt=label=type:container_runtime_t --device /dev/fuse`** (the chapter's §9.3 recipe) | ✅ build completes |

**PASS** — and it shows *why* each flag is needed: caps+seccomp to create the
namespace, `/dev/fuse` for the rpmdb rewrite. `build-minimal.sh` uses the chapter's
exact §9.3 flags.

---

## ✅ §9.4 — build + verify the minimal image (the verified path)

```
$ ./build-minimal.sh --base centos
==> building localhost/bootc-minimal:centos from Containerfile.centos
...
[1/2] STEP 2/2: RUN /usr/libexec/bootc-base-imagectl build-rootfs --manifest=minimal /target-rootfs
...
rootfs: /target-rootfs/rootfs
Checks passed: 13
Checks skipped: 1
[2/2] STEP .../7: RUN set -xeuo pipefail && dnf -y install NetworkManager openssh-server && ...
Successfully tagged localhost/bootc-minimal:centos
```

**Size — the headline result:**
```
$ podman images --format '{{.Repository}}:{{.Tag}}  {{.Size}}'
localhost/bootc-minimal:centos              812 MB     # minimal + NetworkManager + openssh-server
quay.io/centos-bootc/centos-bootc:stream9   1.98 GB    # stock base
# (a bare minimal image, no added packages, is 759 MB)
```

**Contents:**
```
$ podman run --rm localhost/bootc-minimal:centos sh -c \
      'command -v bootc dnf sshd; ls /usr/lib/modules/*/vmlinuz'
/usr/bin/bootc
/usr/bin/dnf
/usr/sbin/sshd
/usr/lib/modules/5.14.0-710.el9.x86_64/vmlinuz
```

**Lint:**
```
$ podman run --rm localhost/bootc-minimal:centos bootc container lint
Checks passed: 13
Checks skipped: 1
```

**PASS** — ~59% smaller than the base, contains exactly bootc + dnf + the kernel
plus the two packages we added, and passes `bootc container lint`.

---

## ⚠️ Gotchas confirmed by failing first

### `RUN <<EORUN` heredoc needs podman ≥ 5
Building the byte-faithful heredoc form on podman 4.9.3:
```
$ podman build ... < Containerfile.rhel-heredoc-form
[2/2] STEP 4/13: set -xeuo pipefail
Error: building at STEP "SET ": Build error: Unknown instruction: "SET"
```
Dockerfile-heredoc parsing landed in buildah 1.34 / podman 5. `Containerfile.centos`
uses an equivalent `&&`-chain so the runnable path works on podman 4.x.
`Containerfile.rhel` keeps the heredoc (faithful; build it on podman ≥ 5).

### `cowsay` is EPEL-only
The §9.2 example installs `cowsay`, but it isn't in RHEL/CentOS base repos:
```
$ # Containerfile customization: dnf -y install NetworkManager cowsay
No match for argument: cowsay
Error: Unable to find a match: cowsay
```
Enable `epel-release` first (RUNBOOK "An optional cow"), or use §9.4's
`openssh-server` instead — which is also what the boot path needs.

---

## ⚠️ Boot gotchas — the minimal manifest's omissions, surfaced one by one

Turning the minimal image into a bootable disk took **four** corrections, each
teaching exactly what "minimal" leaves out. We first tried `bootc-image-builder`
(bib), then pivoted to `bootc install to-disk` from the image itself (bib is a
wrapper around the same code; running the image's own bootc is simpler and dodges
nothing here — the real fixes were image-content + how we ran it):

1. **`missing required info: DefaultRootFs`** — the minimal manifest strips the
   bootc install config that declares the root filesystem type. Fixed by naming it
   explicitly: `--rootfs xfs` (bib) / `--filesystem xfs` (`bootc install`).

2. **`Installing bootloader: Probing bootupd --filesystem support: No such file
   or directory (os error 2)`** — the killer. With `BOOTC_BOOTLOADER_DEBUG=2` the
   actual exec is visible:
   ```
   DEBUG exec: "bwrap" "--bind" ".../deploy/<hash>.0" "/" "--proc" "/proc" ...
                "--" "bootupctl" "backend" "install" "--help"
   error: ... No such file or directory (os error 2)
   ```
   The ENOENT is **`bwrap` itself** — `bootc install` runs bootupd inside a
   **bubblewrap** chroot of the deployed tree, and the minimal manifest ships **no
   `bubblewrap`** (the full base has it). Fix: `dnf -y install bubblewrap`.
   (The bootloader *payload* — bootupd + the staged EFI/BIOS files in
   `/usr/lib/bootupd/updates/` — IS in minimal; only the bwrap *tool* was missing.)

3. **No way to log in** — minimal leaves root `*`-locked (`/etc/shadow`) and adds
   no user. We bake a throwaway `root:lab` for the serial console.

4. **rootless→root storage trap** — `bootc install` runs as root and reads ROOT
   container storage, but `build-minimal.sh` builds into your *rootless* storage.
   `make-disk.sh` bridges with `podman save | sudo podman load` — but only if you
   run it **as your user** (not `sudo`), else `podman save` reads root's (stale)
   image. The script now refuses to run under sudo for this reason.

---

## ✅ Boot path (build → `bootc install to-disk` → QEMU) — VERIFIED end to end

`make-disk.sh` produced `output/disk.qcow2` (≈970 MB):
```
Installing bootloader via bootupd
Added 01_users.cfg ... Installed: "centos/grub.cfg" ...
Installation complete!
```
`lab-vm.sh` booted it (UEFI/OVMF, `backend=disk-image` + `image=` CoW overlay,
`cloud_init=false`).  Captured over the serial console (`root`/`lab`):
```
localhost login: root
Password:
[root@localhost ~]# uname -r
5.14.0-710.el9.x86_64
[root@localhost ~]# . /etc/os-release; echo "$PRETTY_NAME"
CentOS Stream 9
[root@localhost ~]# cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt3)/boot/ostree/default-<hash>/vmlinuz-5.14.0-710.el9.x86_64 \
  root=UUID=bcf1d178-... rw console=ttyS0 console=tty0 \
  ostree=/ostree/boot.1/default/<hash>/0
[root@localhost ~]# bootc status
  ... booted:
    image:  image: localhost/bootc-minimal:centos   (transport: registry)
    imageDigest: sha256:b5a3481e1b09...
```
**PASS** — a real **ostree** boot (`ostree=` on the cmdline, kernel from inside
the image), `bootc status` reports the booted image, and the image-is-the-OS claim
holds end to end.
