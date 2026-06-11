# AlmaLinux 9 kickstart gallery

Pick any of AlmaLinux's **official image-build kickstarts** and install it
**zero-touch** in a QEMU VM. This is the AlmaLinux counterpart of
[`../rocky-kickstart-gallery`](../rocky-kickstart-gallery) and the Anaconda/kickstart
cousin of [`../kali-preseed-gallery`](../kali-preseed-gallery) (which does the same
with Debian-installer preseeds) — same shape, same gallery convention.

```
fetch-kickstarts.sh ─────► ~/netboot/almalinux-kickstart/  (whole catalog: raw/ + lab-patched)
select-kickstart.sh gencloud ─► ~/netboot/boot.ipxe        (inst.ks baked for that variant)
        nginx (P4) serves ~/netboot/    QEMU (P2): NIC's iPXE ROM → boot.ipxe → Anaconda → kickstart
```

Upstream: <https://github.com/AlmaLinux/cloud-images> (branch **main**, fetched live
as-of **2026-06-11**) — the same kickstarts AlmaLinux's Packer pipeline uses to
build its GenericCloud, OCI, GCP, Azure and Vagrant images.

> **Why a different upstream than Rocky?** Rocky publishes a flat
> [`rocky-linux/kickstarts`](https://github.com/rocky-linux/kickstarts) catalog
> (`Rocky-9-*.ks`). AlmaLinux has no such standalone repo — its image kickstarts
> live inside the **cloud-images** Packer repo under `http/`, named
> `almalinux-<release>.<platform>-<arch>.ks`. They're written for Packer's build
> VM, which changes one patch from cosmetic to **load-bearing** (the disk device —
> see below).

---

## What's in this directory

| File | Role |
|---|---|
| `fetch-kickstarts.sh` | Clone the `main` catalog; stage every `almalinux-9.*-x86_64.ks` verbatim under `raw/` + a lab-patched copy alongside (served at `/almalinux-kickstart/<file>`). |
| `select-kickstart.sh` | Pick a variant → bake its `inst.ks` URL + the AppStream repo into `boot.ipxe` (+ `ipxe.pxe`/`.efi`). |
| `almalinux-kickstart-gallery.toml` | Unified config: Phase 4 nginx artifact server + Phase 2 installer VM. |
| `MANUAL_TESTING.md` | The full boot-verify walkthrough + per-stage checks. |
| `README.md` | This file. |

**Reused** (nothing duplicated):

| Shared tool | Used for |
|---|---|
| [`../almalinux-pxe-lab/fetch-almalinux-installer.sh`](../almalinux-pxe-lab/fetch-almalinux-installer.sh) | Fetch + verify the AlmaLinux installer `vmlinuz`/`initrd.img`/`install.img` against the tree's `.treeinfo` (the gallery installs from the same Anaconda netboot images as the almalinux-pxe-lab). |
| `netboot/build-ipxe.sh` | Build `boot.ipxe` + the iPXE binaries with the chosen variant's boot params embedded. |

---

## The catalog (what you can install)

All five are full **disk images with a bootloader** — every one boots as a VM
(unlike Rocky's catalog, which also ships container-rootfs kickstarts that have no
bootloader). They differ mainly in package set, cloud-agent packages, and a few
`%post` tweaks; the partition layout (GPT: biosboot + ESP + `/boot` + `/`) is shared.

| Variant | Upstream file | Built for |
|---|---|---|
| **`gencloud`** | `almalinux-9.gencloud-x86_64.ks` | GenericCloud — the lean, **recommended first** variant (≈ Rocky's `GenericCloud-Base`). |
| `oci` | `almalinux-9.oci-x86_64.ks` | Oracle Cloud Infrastructure |
| `gcp` | `almalinux-9.gcp-x86_64.ks` | Google Cloud (partitions **declaratively** — the disk patch is a no-op here) |
| `azure` | `almalinux-9.azure-x86_64.ks` | Microsoft Azure |
| `vagrant` | `almalinux-9.vagrant-x86_64.ks` | Vagrant box |

`select-kickstart.sh` accepts the short name (`gencloud`), the full filename
(`almalinux-9.gencloud-x86_64.ks`), or a `_vN` micro-arch form. Pass
`--arch aarch64` / `--release 8` (to both scripts) for the other trees AlmaLinux
publishes.

> **Logging in:** AlmaLinux's cloud kickstarts already **unlock root**
> (`rootpw --plaintext almalinux` upstream), so a disk-installing variant boots to
> a usable console login even with no cloud datasource. The gallery just
> **normalises** that password to **`lab`** (patch #3, matching the other mklab
> labs). Pass `--root-pw <pw>` to choose another, or `--no-unlock-root` to keep the
> upstream `almalinux` password untouched.

---

## Does the kickstart need patching for this environment?

I checked the whole `main` catalog. Three findings — and #1 is the one that bites:

1. **Disk device — REQUIRED patch (this is the big difference from Rocky).** These
   are *Packer* kickstarts: they partition **`/dev/sda`** in a `%pre` `parted`
   script and reference it again as `--onpart=sdaN`. Packer's build VM presents a
   SATA disk (`sda`); our QEMU `pxe-install` VM uses **virtio** (`/dev/vda`). An
   unpatched kickstart fails in `%pre` ("/dev/sda: unrecognised disk label" / no
   such device) and the whole install dies. `fetch-kickstarts.sh` rewrites **both**
   `/dev/sda`→`/dev/vda` **and** `onpart=sda`→`onpart=vda`, and **fails closed** if
   any `sda` reference survives. (Contrast Rocky, whose kickstarts already target
   `/dev/vda` — there the same rewrite is a defensive no-op. `gcp` here partitions
   declaratively, so it's a no-op for that one variant too.)
2. **Terminal action — `reboot --eject` → `reboot`.** Every variant ends with
   `reboot --eject` (eject the install CD, which a netboot doesn't have). The patch
   drops `--eject` and rewrites any stray `shutdown`/`poweroff`/`halt` → `reboot`,
   so the VM **reboots into the installed system**. The blank target carries
   `bootindex=0`, so on that reboot SeaBIOS boots the disk and the netboot loop
   terminates. Use `--verbatim` to keep the upstream behaviour.
3. **Root login — normalised, not unlocked.** AlmaLinux's kickstarts *already* set
   `rootpw --plaintext almalinux` (and `PermitRootLogin yes`), so root is usable
   out of the box — unlike Rocky's, which `rootpw --lock` and *also* `passwd -l`
   root in `%post`. The patch just normalises the password to `lab` and
   defensively strips any `%post` re-lock line (AlmaLinux has none, but the Rocky
   gallery did, so the rule is shared). `--no-unlock-root` leaves it as `almalinux`.

The verbatim originals are always kept under `~/netboot/almalinux-kickstart/raw/`.

One thing the **boot params** (not the kickstart) handle: each AlmaLinux kickstart
carries its **own** `url --url …/BaseOS/…`, so `select-kickstart.sh` supplies
**only** the AppStream repo as `inst.addrepo=AppStream,…` — it does **not** pass
`inst.repo` (that would clash with the kickstart's `url`). The `@core` + cloud
package sets need AppStream in addition to the kickstart's BaseOS.

---

## Workflow

Run from the repo root. Replace `/home/sqs` in the TOML with your `$HOME` first
(TOML has no shell expansion).

```bash
# 1. Fetch the AlmaLinux installer kernel + initrd + stage2 (reuses almalinux-pxe-lab):
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --release 9 --arch x86_64

# 2. Stage the whole kickstart catalog (raw/ verbatim + lab-patched copies):
examples/almalinux-kickstart-gallery/fetch-kickstarts.sh

# 3. Pick a variant → bakes inst.ks + AppStream addrepo into boot.ipxe:
examples/almalinux-kickstart-gallery/select-kickstart.sh gencloud

# 4. Serve the artifacts (rootless nginx on :8181):
phase4-podman/lab-podman.sh up --config examples/almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml

# 5. Create + start the installer VM (unattended; reboots into the install):
phase2-qemu-vm/lab-vm.sh create  --config examples/almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml
phase2-qemu-vm/lab-vm.sh start   almalinux-kickstart-install
phase2-qemu-vm/lab-vm.sh console almalinux-kickstart-install   # watch Anaconda; Ctrl-] detaches
```

**Switching variants:** re-run `select-kickstart.sh <other>`, then `destroy` +
`create` the VM (blank the target disk) before `start`.

**Tear down:**

```bash
phase4-podman/lab-podman.sh down    --lab almalinux-kickstart
phase2-qemu-vm/lab-vm.sh    destroy almalinux-kickstart-install --force
```

---

## How it boots

Identical mechanism to the `almalinux-pxe-lab` / `rocky-kickstart-gallery` (see the
rocky README for the deep dive): SeaBIOS → the NIC's option ROM (which on QEMU *is*
iPXE) → TFTP `boot.ipxe`, run directly (no `ipxe.pxe` binary chainload, so no flaky
UNDI re-DHCP) → fetch `vmlinuz`/`initrd.img` + the local `install.img` stage2 over
HTTP → Anaconda runs the selected kickstart → partitions `/dev/vda` → **reboots**
(the gallery patch) into the installed system. 4 GB RAM because the ~1.2 GB stage2
loads into the initramfs tmpfs.

- **UEFI:** drop `firmware` in the TOML and set `pxe_bootfile = "ipxe.efi"`.
- **Real hardware** with a non-iPXE firmware PXE: set `pxe_bootfile = "ipxe.pxe"`.

---

## Security posture

These are throwaway lab installs. By default the gallery **normalises root to the
cleartext password `lab`** (patch #3) and serves that kickstart over HTTP — fine
for a local QEMU lab, but **never** serve it on an untrusted network (anyone who
can fetch the kickstart reads the password). nginx is reachable only via the QEMU
slirp `10.0.2.2` mapping for guest use. For a locked-down posture, stage with
`--no-unlock-root` (keeps the upstream `almalinux` password) and/or restrict nginx
to loopback.

---

## What's verified

`gencloud` (GenericCloud) was boot-verified end-to-end on KVM: native `iPXE` ran
`boot.ipxe` → fetched `vmlinuz` + `initrd.img` + the full 1.2 GB `install.img`
stage2 + the patched gallery kickstart → **`anaconda … for AlmaLinux 9.8`** ran the
kickstart (partitioning the patched `/dev/vda`, installing `@core` from
BaseOS+AppStream) → **rebooted into the installed system** (the
`reboot --eject`→`reboot` patch) → and **`root` / `lab` logged straight in** on the
serial console, confirming AlmaLinux 9.8. The other disk-installing variants share
the identical boot path and differ only in package set / cloud-agent packages;
`MANUAL_TESTING.md` has the per-stage checks **and** the one trap worth knowing — a
stale same-size `install.img` from a prior lab can shadow the real one (it's how
this lab first booted a *Rocky* stage2 by mistake); the fixed
`fetch-almalinux-installer.sh` now downloads via a `.part` sidecar so a wrong
same-size file can't survive its checksum gate.
