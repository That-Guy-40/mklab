# Kali preseed gallery — boot any upstream preseed variant, zero-touch

Experiment with the **whole** [Kali preseed-examples catalog](https://gitlab.com/kalilinux/recipes/kali-preseed-examples):
fetch all ~15 official Debian-installer preseed variants, then install any one
of them into a throwaway VM with **no keystrokes** — PXE → iPXE → d-i → preseed
→ reboot into the installed Kali.

This is the **pick-a-variant** companion to [`../kali-pxe-lab/`](../kali-pxe-lab/),
which serves a *single* hand-written preseed. Same iPXE + nginx + QEMU two-disk
boot-loop; the only new idea is a **selectable gallery** of upstream preseeds.

```
fetch-preseeds.sh ──► ~/netboot/kali-preseed/   (all variants, vda-patched)
select-preseed.sh xfce-default ──► ~/netboot/ipxe.qcow2   (ROM baked for that one)
        nginx (P4) serves ~/netboot/    QEMU (P2) boots the ROM → d-i → preseed
```

---

## The catalog (what each variant installs)

Every file is a **complete, standalone** d-i preseed. The matrix is two axes —
**desktop environment** × **partitioning** — plus a couple of specials:

| Variant | Desktop | Partitioning | Notes |
|---|---|---|---|
| `headless-default` | none (CLI) | regular, one partition | **fastest** — recommended first run |
| `xfce-default` | XFCE | regular, one partition | the Kali default desktop |
| `kde-default` | KDE | regular, one partition | |
| `gnome-default` | GNOME | regular, one partition | |
| `xfce-large` / `kde-large` / `gnome-large` | …+ `meta-large` | regular | bigger tool set (`meta-large` vs `meta-default`) |
| `regular-multi` | XFCE | regular, **multi** (`/home`,`/var`,`/tmp` split) | |
| `lvm` | XFCE | **LVM**, one volume | |
| `lvm-multi` | XFCE | **LVM**, multi | |
| `crypto` | XFCE | **LUKS-encrypted** LVM | prompts for nothing (passphrase is preseeded by upstream) |
| `crypto-multi` | XFCE | **LUKS**, multi | |
| `skip-wipe-lvm` / `skip-wipe-crypto` | XFCE | LVM / LUKS | **skips the secure pre-wipe** — much faster, less secure |
| `packer-preseed` | XFCE | regular | tuned for Packer image builds |

> **Cost warning.** Anything with a desktop (`xfce/kde/gnome*`, and the
> `lvm/crypto/regular-multi/skip-wipe` variants, which all default to XFCE)
> debootstraps a **full desktop + tool set over the network** — that's GBs and
> can take 30–60+ min. `headless-default` is by far the quickest to see the
> whole pipeline work. `*-large` and `crypto*` (secure-wipe) are the slowest.

Run `fetch-preseeds.sh` then look in `~/netboot/kali-preseed/` for the live list;
the verbatim upstream copies are kept under `~/netboot/kali-preseed/raw/`.

---

## What's in this directory

| File | Role |
|---|---|
| `fetch-preseeds.sh` | Download the upstream catalog (GitLab API) + stage **vda-patched** copies for this lab. `--verbatim` to skip patching. |
| `select-preseed.sh` | Pick a variant → (re)build the iPXE ROM pointed at it (wraps `netboot/build-ipxe.sh`). `--print-only` to dry-run. |
| `kali-preseed-gallery.toml` | Unified config: Phase 4 nginx + Phase 2 two-disk installer VM. |
| `MANUAL_TESTING.md` | Copy-pasteable curl/boot verification runbook. |
| `README.md` | This file. |

Reused **unchanged** — nothing duplicated:

| Shared tool | Used for |
|---|---|
| `../kali-pxe-lab/fetch-kali-installer.sh` | Fetch + verify the d-i `linux`/`initrd.gz` (same artifacts as the PXE lab). |
| `netboot/build-ipxe.sh` | Build the iPXE ROM with the chosen preseed's boot params. |
| `phase4-podman/lab-podman.sh`, `phase2-qemu-vm/lab-vm.sh` | Serve + boot — no new phase code. |

---

## Prerequisites

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils podman docker.io jq curl
# (Rocky/Fedora host: dnf install qemu-kvm qemu-img podman moby-engine jq ...)
```

The iPXE build runs in Docker (host stays clean); the artifact server runs
rootless under podman. `jq` is used to read the catalog file list from GitLab.

---

## Run it (QEMU, zero-touch)

Run from the repo root. Replace `/home/sqs` in `kali-preseed-gallery.toml` with
your `$HOME` first (TOML has no shell expansion).

### 1. Fetch + verify the d-i kernel and initrd

```bash
examples/kali-pxe-lab/fetch-kali-installer.sh --arch amd64
# → ~/netboot/kali/linux  (~14 MB)  and  ~/netboot/kali/initrd.gz  (~44 MB)
# both verified against the tree's SHA256SUMS.
```

### 2. Fetch the preseed catalog

```bash
examples/kali-preseed-gallery/fetch-preseeds.sh
# → ~/netboot/kali-preseed/<variant>      (vda-patched, served)
# → ~/netboot/kali-preseed/raw/<variant>  (verbatim upstream, reference)
```

### 3. Pick a variant and build the iPXE ROM

```bash
examples/kali-preseed-gallery/select-preseed.sh headless-default
# → ~/netboot/ipxe.qcow2  (ROM baked with preseed/url=…/kali-preseed/headless-default)
# See the exact command without building:  … select-preseed.sh xfce-default --print-only
```

### 4. Start the rootless nginx artifact server (Phase 4)

```bash
phase4-podman/lab-podman.sh up --config examples/kali-preseed-gallery/kali-preseed-gallery.toml

# Verify all three artifacts are actually served (the #1 failure point):
curl -sI http://localhost:8181/kali/linux                          | head -1   # 200
curl -sI http://localhost:8181/kali/initrd.gz                      | head -1   # 200
curl -sI http://localhost:8181/kali-preseed/headless-default       | head -1   # 200
```

A `404` means the file isn't under `~/netboot/` (or the TOML volume still says
`/home/sqs`). A `403` on SELinux means the `:Z` relabel didn't happen —
`lab-podman.sh` adds it automatically.

### 5. Create + start the installer VM (Phase 2)

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh start   kali-preseed-install
phase2-qemu-vm/lab-vm.sh console kali-preseed-install     # watch; Ctrl-] to detach
```

The boot-loop in motion:

1. **First boot:** the blank target disk (`vda`, bootindex 0) has no boot sector,
   so the firmware falls through to the iPXE ROM (`vdb`, bootindex 1). iPXE DHCPs,
   fetches `linux`/`initrd.gz`, and d-i starts with your chosen preseed.
2. **d-i runs the preseed** — partitions `vda`, debootstraps Kali, installs GRUB
   to `vda`, reboots.
3. **Second boot:** `vda` is bootable and wins; iPXE is never reached again. You
   land at a Kali login (or desktop greeter, for the DE variants).

```bash
phase2-qemu-vm/lab-vm.sh console kali-preseed-install     # serial console always works
# SSH only works if the variant installed openssh-server (headless-default does
# NOT by default) — see "Logging in" below.
```

### 6. Switch variants

```bash
examples/kali-preseed-gallery/select-preseed.sh lvm-multi         # rebuild the ROM
phase2-qemu-vm/lab-vm.sh destroy kali-preseed-install --force     # blank the target disk
phase2-qemu-vm/lab-vm.sh create  --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh start   kali-preseed-install
```

### 7. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab kali-preseed-gallery
phase2-qemu-vm/lab-vm.sh    destroy kali-preseed-install --force
```

---

## Why the disk patch (the one genuinely install-breaking issue)

This is the single adaptation between "the upstream files" and "a lab that
actually boots," so it's worth understanding.

**Every upstream variant hardcodes `d-i grub-installer/bootdev string /dev/sda`
and sets *no* `partman-auto/disk`.** That's fine on a typical bare-metal box with
one SATA/NVMe disk. But this lab uses the **two-disk boot-loop**: the installer
arrives from an **iPXE ROM on a second virtio disk**, so the guest sees:

- `/dev/vda` — the blank install target (bootindex 0)
- `/dev/vdb` — the iPXE ROM (bootindex 1, the fallback that started d-i)

Served unpatched, that breaks two ways:

1. **`/dev/sda` doesn't exist on a virtio bus** → `grub-install` fails, no boot
   sector is written to `vda`, and the VM just falls back to iPXE forever.
2. **With no `partman-auto/disk` and two disks present**, d-i's guided
   partitioner either *prompts* (breaking "unattended") or could pick `/dev/vdb`
   and **partition over the iPXE ROM** mid-install.

So `fetch-preseeds.sh` rewrites each served copy to pin **both** to `/dev/vda`:

```diff
-d-i grub-installer/bootdev string /dev/sda
+d-i grub-installer/bootdev           string /dev/vda
+d-i partman-auto/disk                string /dev/vda
```

That's exactly what `../kali-pxe-lab/kali-preseed.cfg` bakes in by hand — it's the
d-i equivalent of a kickstart's `ignoredisk --only-use=vda`. The verbatim upstream
files are preserved under `raw/` so you can diff and see precisely what changed.

**On real hardware** with a single `/dev/sda`, the upstream value is usually
correct — run `fetch-preseeds.sh --verbatim` there (or `--disk /dev/nvme0n1` to
pin a specific device).

---

## Logging in

- **Serial console** (`lab-vm.sh console`) always works post-install: the iPXE
  append puts `console=ttyS0,115200n8` after the d-i `---` marker, so it reaches
  the *installed* kernel regardless of the preseed.
- **Credentials** come from the upstream preseed: user **`kali` / `kali`** (and
  the variants don't set a separate root password, so use `sudo`).
- **SSH** needs `openssh-server`, which not every variant includes (e.g.
  `headless-default` doesn't). To guarantee SSH, add it to the variant's
  `pkgsel/include` line before step 3, or just `sudo apt install -y openssh-server`
  from the console after first boot.

---

## Security posture (read before exposing anything)

- **Plaintext lab credentials.** The upstream preseeds set `kali:kali` in
  cleartext (and the `crypto*` variants preseed the LUKS passphrase too). Anyone
  who can fetch the preseed over HTTP reads them. **Never serve this on an
  untrusted network.** For real use, switch to `*-password-crypted`
  (`mkpasswd -m sha-512`) and restrict nginx to loopback / a private VLAN.
- **QEMU-only by default.** nginx is reachable from the guest via the slirp
  `10.0.2.2` mapping; it is not meant to face a real LAN here.
- **Kali is an offensive-security distro.** The desktop/`*-large` variants ship
  hundreds of tools — keep these VMs off networks you don't own.

---

## What's verified vs documented

Honest about what was actually exercised on this host vs. a written procedure:

| Step | Status |
|---|---|
| `fetch-preseeds.sh` downloads all 15 variants from GitLab | ✅ verified (live run) |
| vda-patch pins grub+partman to `/dev/vda`, `raw/` keeps `/dev/sda` | ✅ verified (all 15, incl. the `packer-preseed` commented-disk edge case) |
| `select-preseed.sh` resolves a variant + builds the correct iPXE append | ✅ verified (`--print-only`) |
| `kali-preseed-gallery.toml` parses; MAC valid hex | ✅ verified (`tomllib`) |
| iPXE ROM build (Docker), nginx serve, full d-i install + reboot | 📄 documented — multi-GB, ~10–60 min per variant |

For a path with a recorded end-to-end boot, see [`../kali-pxe-lab/MANUAL_TESTING.md`](../kali-pxe-lab/MANUAL_TESTING.md);
this gallery shares that lab's iPXE/nginx/boot-loop machinery verbatim. The
gallery's `MANUAL_TESTING.md` has the copy-pasteable checks for the new parts.

---

## Why these choices (the "under the hood" notes)

- **Why fetch verbatim *and* patch?** So you're genuinely experimenting with the
  upstream files (kept under `raw/`), while the served copies are the minimum
  changed to boot in this lab. The patch is fail-closed: if a variant can't be
  pinned to the lab disk, the fetch aborts rather than serve a preseed that would
  silently break the install (or wipe the ROM).
- **Why rebuild the ROM per variant instead of an iPXE menu?** A baked-in
  `preseed/url=` keeps the install **zero-touch** (a boot menu needs a keystroke).
  The ROM is tiny and builds in seconds, so `select-preseed.sh <name>` is the
  whole "switch" cost.
- **Why reuse `kali-pxe-lab/fetch-kali-installer.sh`?** The d-i kernel/initrd are
  identical — only the preseed differs between the two labs. No point duplicating
  the SHA256SUMS-verified fetcher.
