# Rocky Linux 9 kickstart gallery

Pick any of Rocky's **official image kickstarts** and install it **zero-touch** in
a QEMU VM. This is the Anaconda/kickstart cousin of
[`../kali-preseed-gallery`](../kali-preseed-gallery) (which does the same with
Debian-installer preseeds) — same shape, same gallery convention.

```
fetch-kickstarts.sh ─────► ~/netboot/rocky-kickstart/   (whole catalog: raw/ + lab-patched)
select-kickstart.sh GenericCloud-Base ─► ~/netboot/boot.ipxe   (inst.ks baked for that variant)
        nginx (P4) serves ~/netboot/    QEMU (P2): NIC's iPXE ROM → boot.ipxe → Anaconda → kickstart
```

Upstream: <https://github.com/rocky-linux/kickstarts> (branch **r9**, fetched live as-of **2026-06-07**) — the same
kickstarts Rocky uses to build its cloud, container, vagrant, desktop, EC2/Azure,
OCP and RPI images.

---

## What's in this directory

| File | Role |
|---|---|
| `fetch-kickstarts.sh` | Clone the r9 catalog; stage every `Rocky-9-*.ks` verbatim under `raw/` + a lab-patched copy alongside (served at `/rocky-kickstart/<v>.ks`). |
| `select-kickstart.sh` | Pick a variant → bake its `inst.ks` URL + repos into `boot.ipxe` (+ `ipxe.pxe`/`.efi`). |
| `rocky-kickstart-gallery.toml` | Unified config: Phase 4 nginx artifact server + Phase 2 installer VM. |
| `MANUAL_TESTING.md` | The full boot-verify walkthrough + per-stage checks. |
| `README.md` | This file. |

**Reused** (nothing duplicated):

| Shared tool | Used for |
|---|---|
| [`../rocky-pxe-lab/fetch-rocky-installer.sh`](../rocky-pxe-lab/fetch-rocky-installer.sh) | Fetch + verify the Rocky installer `vmlinuz`/`initrd.img`/`install.img` (the gallery installs from the same Anaconda netboot images as the rocky-pxe-lab). |
| `netboot/build-ipxe.sh` | Build `boot.ipxe` + the iPXE binaries with the chosen variant's boot params embedded. |

---

## The catalog (what you can install)

| Family | Variants (x86_64; `-aarch64` siblings also staged) | VM-bootable? |
|---|---|---|
| **Cloud / headless** | `GenericCloud-Base`, `GenericCloud-LVM`, `EC2-Base`, `EC2-LVM`, `Azure-Base`, `Azure-LVM`, `OCP-Base` | ✅ (BIOS+UEFI, `@core`) |
| **Vagrant** | `Vagrant-Libvirt`, `Vagrant-Vbox`, `Vagrant-VMware` | ✅ |
| **Desktop** | `Workstation`, `Workstation-Lite`, `Workstation-Mainline`, `KDE`, `XFCE`, `MATE`, `Cinnamon` | ✅ (large GUI install — slow) |
| **Container** | `Container-Base`, `Container-Minimal`, `Container-UBI` | ❌ **no bootloader** (container rootfs) |
| **Arm board** | `GenericArm-Minimal`, `RPI-Base` | aarch64 only |

`select-kickstart.sh` accepts the short name (`GenericCloud-Base`), the full
filename (`Rocky-9-GenericCloud-Base.ks`), or anything in between.

> **Logging in:** every staged variant is patched to **unlock root** with the
> password **`lab`** (patch #3 below) — so any disk-installing variant boots to a
> usable `root` / `lab` console login. Pass `--no-unlock-root` to keep the upstream
> locked posture (cloud variants then expect cloud-init/ssh-keys; desktops a
> first-boot user), or `--root-pw <pw>` to pick a different password.

---

## Does the kickstart need patching for this environment?

I checked the whole r9 catalog. Three findings:

1. **Disk references — no patch needed.** Every `Rocky-9-*.ks` already targets
   **`/dev/vda`** (they're virt/cloud kickstarts). Contrast the Kali preseed
   gallery, whose upstream hardcodes `/dev/sda` and *must* be rewritten. The
   fetch script still normalises any stray `/dev/sda` → `--disk` defensively, but
   today it's a no-op.
2. **Terminal action — patched `shutdown` → `reboot`.** Every variant ends with
   `shutdown` (so the image-build tool can snapshot the finished disk). In an
   interactive VM you want it to **reboot into the installed system** instead, so
   `fetch-kickstarts.sh` rewrites the terminal action. The blank install target
   carries `bootindex=0`, so on that reboot SeaBIOS boots the disk and the netboot
   loop terminates. Use `--verbatim` to keep the upstream `shutdown` behaviour.
3. **Root login — patched unlocked.** Most variants `rootpw --lock` (and the cloud
   ones *also* `passwd -d root; passwd -l root` in `%post`) — correct for an image
   you log into via cloud-init / injected ssh keys, but a lab VM has no datasource,
   so you'd reach a login prompt you can't use. `fetch-kickstarts.sh` rewrites every
   `rootpw` to `rootpw --plaintext lab` (change with `--root-pw`) and strips the
   `%post` re-lock lines. `--no-unlock-root` keeps root locked.

The verbatim originals are always kept under `~/netboot/rocky-kickstart/raw/`.

One thing the **boot params** (not the kickstart) handle: the cloud/container
variants carry no `url`/`repo`, so `select-kickstart.sh` supplies **both** repos —
`inst.repo=…/BaseOS/…` and `inst.addrepo=AppStream,…/AppStream/…` — which the
`@core` + cloud package sets need. (The desktop variants carry their own `url`/`repo`.)

---

## Workflow

Run from the repo root. Replace `/home/sqs` in the TOML with your `$HOME` first
(TOML has no shell expansion).

```bash
# 1. Fetch the Rocky installer kernel + initrd + stage2 (reuses rocky-pxe-lab):
examples/rocky-pxe-lab/fetch-rocky-installer.sh --release 9 --arch x86_64

# 2. Stage the whole kickstart catalog (raw/ verbatim + lab-patched copies):
examples/rocky-kickstart-gallery/fetch-kickstarts.sh

# 3. Pick a variant → bakes inst.ks + BaseOS/AppStream into boot.ipxe:
examples/rocky-kickstart-gallery/select-kickstart.sh GenericCloud-Base

# 4. Serve the artifacts (rootless nginx on :8181):
phase4-podman/lab-podman.sh up --config examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml

# 5. Create + start the installer VM (unattended; reboots into the install):
phase2-qemu-vm/lab-vm.sh create  --config examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml
phase2-qemu-vm/lab-vm.sh start   rocky-kickstart-install
phase2-qemu-vm/lab-vm.sh console rocky-kickstart-install   # watch Anaconda; Ctrl-] detaches
```

**Switching variants:** re-run `select-kickstart.sh <other>`, then `destroy` +
`create` the VM (blank the target disk) before `start`.

**Tear down:**

```bash
phase4-podman/lab-podman.sh down    --lab rocky-kickstart
phase2-qemu-vm/lab-vm.sh    destroy rocky-kickstart-install --force
```

---

## How it boots

Identical mechanism to the `rocky-pxe-lab` (see its README for the deep dive):
SeaBIOS → the NIC's option ROM (which on QEMU *is* iPXE) → TFTP `boot.ipxe`, run
directly (no `ipxe.pxe` binary chainload, so no flaky UNDI re-DHCP) → fetch
`vmlinuz`/`initrd.img` + the local `install.img` stage2 over HTTP → Anaconda runs
the selected kickstart → installs to `/dev/vda` → **reboots** (the gallery patch)
into the installed system. 4 GB RAM because the ~1.2 GB stage2 loads into the
initramfs tmpfs.

- **UEFI:** drop `firmware` in the TOML and set `pxe_bootfile = "ipxe.efi"`.
- **Real hardware** with a non-iPXE firmware PXE: set `pxe_bootfile = "ipxe.pxe"`.

---

## Security posture

These are throwaway lab installs. By default the gallery **unlocks root with the
cleartext password `lab`** (patch #3) and serves that kickstart over HTTP — fine
for a local QEMU lab, but **never** serve it on an untrusted network (anyone who
can fetch the kickstart reads the password). nginx is reachable only via the QEMU
slirp `10.0.2.2` mapping for Path-A use. For a locked-down posture, stage with
`--no-unlock-root` (keeps the upstream locked root) and/or restrict nginx to
loopback.

---

## What's verified

`GenericCloud-Base` was boot-verified end-to-end on KVM: native `iPXE/1.21.1` ran
`boot.ipxe` → fetched `vmlinuz` + `initrd.img` + the full 1.2 GB stage2 + the
patched gallery kickstart → Anaconda installed `@core` from BaseOS+AppStream →
**rebooted into the installed system** (the `shutdown`→`reboot` patch) → and
**`root` / `lab` logged straight in** on the console (the unlock patch — note
GenericCloud locks root *twice* upstream), confirming Rocky Linux 9.8. The other
disk-installing variants share the identical boot path and differ only in package
set / partitioning; `MANUAL_TESTING.md` has the per-stage checks.
