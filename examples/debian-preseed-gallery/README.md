# Debian 13 "trixie" preseed **gallery** — pick a partitioning variant

The **pick-a-variant** companion to [`debian-pxe-lab/`](../debian-pxe-lab/). Same
iPXE + rootless-nginx + QEMU `pxe-install` machinery, the same trixie
Debian-installer — but instead of one hard-wired layout you choose from **six
partitioning variants** and boot any one zero-touch.

```bash
examples/debian-preseed-gallery/select-preseed.sh crypto-atomic   # then serve + boot
```

## Where the variants come from (and how this differs from the Kali gallery)

The [`kali-preseed-gallery/`](../kali-preseed-gallery/) fetches a purpose-built
**upstream catalog** of ~15 ready `.cfg` files
([`kalilinux/recipes/kali-preseed-examples`](https://gitlab.com/kalilinux/recipes/kali-preseed-examples)).
**Debian has no such catalog** — it ships exactly **one** official reference,
[`example-preseed.txt`](upstream-preseed/README.md), which documents every
partitioning option *inline* as a commented alternative. So the honest Debian
"gallery" is: take Debian's own reference and expose its documented variants as
ready-to-boot preseeds.

`fetch-preseeds.sh` does exactly that — it stamps each variant's **partitioning
block** (straight from the example's documented `method` / `recipe` options)
into [`base-preseed.cfg`](base-preseed.cfg) (the common lab body) and writes one
complete, `/dev/vda`-pinned preseed per variant. Generation is **offline and
deterministic**; the official file is fetched only as a side-by-side reference.

| Variant | `partman-auto/method` + recipe | Result |
|---|---|---|
| `regular-atomic` | `regular` + `atomic` | whole disk, one root partition (+swap) — simplest |
| `regular-home` | `regular` + `home` | separate `/home` |
| `regular-multi` | `regular` + `multi` | separate `/home`, `/var`, `/tmp` |
| `lvm-atomic` | `lvm` + `atomic` | LVM, one root logical volume |
| `crypto-atomic` | `crypto` + `atomic` | **LVM inside an encrypted partition** (passphrase `labcrypto`) |
| `minimal` | `regular` + `atomic`, **tasksel off** | base system only (no `standard`/`ssh-server` tasks) |

`regular-atomic` is exactly what the single [`debian-pxe-lab`](../debian-pxe-lab/)
installs — this gallery is that lab plus five siblings.

---

## What's in this directory

| File | Role |
|---|---|
| `fetch-preseeds.sh` | Generate all six variants into `~/netboot/debian-preseed/` (+ fetch the official reference into `raw/`). |
| `base-preseed.cfg` | The common lab body with a marked partitioning region the generator swaps. |
| `select-preseed.sh` | Pick a variant → rebuild iPXE (`boot.ipxe`) pointed at that preseed. |
| `debian-preseed-gallery.toml` | Unified config: Phase 4 nginx server + Phase 2 installer VM. |
| [`upstream-preseed/`](upstream-preseed/README.md) | Byte-exact vendored official `example-preseed.txt` + provenance. |
| `MANUAL_TESTING.md` | End-to-end runbook + real captured transcripts (lvm + crypto verified). |
| `ADDING-PACKAGES.md` | Add packages / a new variant to the gallery. |
| `README.md` | This file. |

Reuses the shared `netboot/build-ipxe.sh` and the `debian-pxe-lab` installer
fetcher — nothing duplicated.

---

## Quick start (QEMU zero-touch)

Run from the repo root. Replace `/home/sqs` in the TOML with your `$HOME` first.

```bash
# 1. Generate the gallery (offline; also drops the official reference in raw/):
examples/debian-preseed-gallery/fetch-preseeds.sh
#    → ~/netboot/debian-preseed/{regular-atomic,regular-home,regular-multi,
#                                lvm-atomic,crypto-atomic,minimal}.cfg

# 2. Fetch + verify the trixie d-i kernel + initrd (reuses the pxe-lab helper):
examples/debian-pxe-lab/fetch-debian-installer.sh --arch amd64

# 3. Pick a variant → build iPXE (bakes preseed/url into boot.ipxe):
examples/debian-preseed-gallery/select-preseed.sh lvm-atomic

# 4. Serve (Phase 4):
phase4-podman/lab-podman.sh up --config examples/debian-preseed-gallery/debian-preseed-gallery.toml
curl -sI http://localhost:8181/debian-preseed/lvm-atomic.cfg | head -1   # 200

# 5. Install (Phase 2) — unattended:
phase2-qemu-vm/lab-vm.sh create --config examples/debian-preseed-gallery/debian-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh start  debian-preseed-install
phase2-qemu-vm/lab-vm.sh console debian-preseed-install     # watch; Ctrl-] detaches
phase2-qemu-vm/lab-vm.sh ssh    debian-preseed-install      # login: debian / debian  (root / lab)
```

### Switching variants

`select-preseed.sh` rebuilds `boot.ipxe` for the new variant; then **destroy +
recreate** the VM so it installs onto a fresh blank disk:

```bash
examples/debian-preseed-gallery/select-preseed.sh crypto-atomic
phase2-qemu-vm/lab-vm.sh destroy debian-preseed-install --force
phase2-qemu-vm/lab-vm.sh create  --config examples/debian-preseed-gallery/debian-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh start   debian-preseed-install
```

### Tear down

```bash
phase4-podman/lab-podman.sh down    --lab debian-preseed
phase2-qemu-vm/lab-vm.sh    destroy debian-preseed-install --force
```

---

## Verifying each variant's disk layout

After the install reboots, `lsblk` shows the layout the variant asked for:

| Variant | `lsblk` signature (verified) |
|---|---|
| `regular-atomic` | `vda1` ext4 `/`, `vda5` swap |
| `regular-home` | `vda1` `/`, a separate `/home` partition, swap |
| `regular-multi` | separate `/home`, `/var`, `/tmp` partitions |
| `lvm-atomic` | `vda` → LVM PV → VG → `root` + `swap` LVs (`/dev/mapper/…-root` mounted `/`) |
| `crypto-atomic` | `vda5` → `crypt` (LUKS) → LVM → `root`+`swap` (unlock prompt at boot, or the preseeded passphrase) |
| `minimal` | like `regular-atomic`, but far fewer packages (`dpkg -l | wc -l` is small) |

See `MANUAL_TESTING.md` for the real captured `lsblk` from the lvm + crypto runs.

---

## The `/dev/vda` pin (why generation, not a patch)

The Kali gallery **patches** upstream files that hardcode `/dev/sda` → `/dev/vda`
for the virtio target. This gallery has no such problem: every variant is
**generated** from `base-preseed.cfg`, which already pins `partman-auto/disk` +
`grub-installer/bootdev` to `/dev/vda`. Installing to a real disk? Regenerate
with `--disk /dev/sda`:

```bash
examples/debian-preseed-gallery/fetch-preseeds.sh --disk /dev/sda
```

The single VM disk enumerates as `/dev/vda`; the same "confirm disk identity
before an unattended wipe" caveat from the pxe-lab
([`../kali-pxe-lab/MANUAL_TESTING.md`](../kali-pxe-lab/MANUAL_TESTING.md#confirming-disk-identity-before-you-trust-an-unattended-run))
applies here too.

---

## Security posture

- **Plaintext lab credentials** (`root:lab`, `debian:debian`) and a **plaintext
  disk passphrase** (`labcrypto`) for the crypto variant. Anyone who can fetch a
  preseed reads them. **Never** serve on an untrusted network. For real use:
  `*-password-crypted` account keys, a strong `partman-crypto/passphrase`, and
  restrict nginx to loopback / a private VLAN.
- **`crypto-atomic` skips the pre-encryption secure-erase** (`partman-auto-crypto/
  erase_disks false`) so the lab finishes fast. A real encrypted install should
  wipe first — drop that line (expect a long zero/random pass over the disk).

---

## Why these choices (under the hood)

- **Why derive instead of fetch a third-party catalog?** Debian's
  `example-preseed.txt` is the canonical, authoritative reference (generated from
  the `installer-team/preseed` source package). Deriving the gallery from *its*
  documented options is maximally faithful and self-contained; a random GitHub
  repo of one person's configs would be lower-provenance. The byte-exact original
  is vendored under [`upstream-preseed/`](upstream-preseed/README.md).
- **Why a marked block in `base-preseed.cfg`?** So the common body (accounts,
  mirror, serial console, grub pin) lives in exactly one place and every variant
  differs *only* in partitioning (and, for `minimal`, the tasksel line) — the
  generator is a transparent block-swap you can read in `fetch-preseeds.sh`.
- **Why is `crypto` interesting?** It's the one variant that adds real state: a
  LUKS container (`partman-crypto/passphrase`) wrapping LVM. It exercises a
  different d-i code path than plain `regular`/`lvm` and is the best proof the
  generation is correct — see the verified `lsblk` in `MANUAL_TESTING.md`.
