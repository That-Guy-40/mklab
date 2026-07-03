# Debian preseed gallery — variant install boot-verify

End-to-end runbook for booting any of the six generated variants through a full
trixie d-i install. Same machinery as [`../debian-pxe-lab/MANUAL_TESTING.md`](../debian-pxe-lab/MANUAL_TESTING.md)
— read that first for the boot-loop stage table and the preflight. This file
adds the **variant-specific** checks and the real captured `lsblk` from the two
verified runs (`lvm-atomic` + `crypto-atomic`).

> Run everything from the repo root; replace `/home/sqs` in the TOML with your
> `$HOME`.

---

## 0. Generate + sanity-check the gallery (offline, instant)

```bash
examples/debian-preseed-gallery/fetch-preseeds.sh
ls ~/netboot/debian-preseed/*.cfg          # six variants
# spot-check the two interesting ones:
grep '^d-i partman-auto/method' ~/netboot/debian-preseed/lvm-atomic.cfg     # → lvm
grep -E 'partman-auto/method|partman-crypto/passphrase' ~/netboot/debian-preseed/crypto-atomic.cfg
grep '^d-i pkgsel/run_tasksel' ~/netboot/debian-preseed/minimal.cfg          # → boolean false
```

The generator **fails closed**: every variant must pin `partman-auto/disk` +
`grub-installer/bootdev`, carry a `method`, and (crypto) a passphrase / (minimal)
the disabled tasksel — or `fetch-preseeds.sh` aborts. A host-safe one-liner
smoke (also wired as the learning-path checkpoint):

```bash
examples/debian-preseed-gallery/fetch-preseeds.sh --no-refresh --only crypto-atomic --out /tmp/dpg-smoke \
  && grep -q '^d-i partman-crypto/passphrase' /tmp/dpg-smoke/crypto-atomic.cfg && echo GEN-OK
rm -rf /tmp/dpg-smoke
```

## 1–4. Fetch installer, select a variant, serve

```bash
examples/debian-pxe-lab/fetch-debian-installer.sh --arch amd64          # d-i kernel+initrd (once)
examples/debian-preseed-gallery/select-preseed.sh lvm-atomic            # bake preseed/url into boot.ipxe
phase4-podman/lab-podman.sh up --config examples/debian-preseed-gallery/debian-preseed-gallery.toml
curl -sI http://localhost:8181/debian-preseed/lvm-atomic.cfg | head -1  # 200
grep -o 'preseed/url=[^ ]*' ~/netboot/boot.ipxe                          # points at lvm-atomic.cfg
```

## 5. Install + verify

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/debian-preseed-gallery/debian-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh start  debian-preseed-install
phase2-qemu-vm/lab-vm.sh console debian-preseed-install     # Ctrl-] detaches
# after it reboots into the installed system:
ssh -o StrictHostKeyChecking=no -p 2222 debian@127.0.0.1 lsblk
```

To switch variants: `select-preseed.sh <other>` → `destroy` + `create` + `start`
(a fresh blank disk each time).

---

## Verified end-to-end (KVM, x86_64, 2026-07-03)

### `lvm-atomic` — LVM, one root LV

```text
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME                   SIZE TYPE FSTYPE      MOUNTPOINT
vda                     20G disk
├─vda1                 966M part ext4        /boot          ← LVM installs get a plain /boot
├─vda2                   1K part
└─vda5                19.1G part LVM2_member
  ├─debian--vg-root     18G lvm  ext4        /              ← root is an LV
  └─debian--vg-swap_1    1G lvm  swap        [SWAP]
```

`/` is `/dev/mapper/debian--vg-root` — the whole disk is one LVM volume group, as
the `lvm` method asks. Contrast the pxe-lab's `regular` run where `/` sits
directly on `vda1`.

### `crypto-atomic` — LUKS → LVM (the full encrypted stack)

The installed system **prompts for the passphrase at boot** (that's the point):

```text
Please unlock disk vda5_crypt:            ← type 'labcrypto'
cryptsetup: vda5_crypt: set up successfully
/dev/mapper/debian--vg-root: clean …
Debian GNU/Linux 13 debian ttyS0
debian login:
```

Then `lsblk` + `cryptsetup status` show the full chain:

```text
NAME                     SIZE TYPE  FSTYPE      MOUNTPOINT
vda                       20G disk
├─vda1                   966M part  ext4        /boot        ← /boot stays UNencrypted (GRUB must read it)
├─vda2                     1K part
└─vda5                  19.1G part  crypto_LUKS
  └─vda5_crypt            19G crypt LVM2_member                ← the LUKS container
    ├─debian--vg-root     18G lvm   ext4        /              ← LVM lives INSIDE the crypt
    └─debian--vg-swap_1    1G lvm   swap        [SWAP]

# cryptsetup status vda5_crypt →
  type:    LUKS2
  cipher:  aes-xts-plain64
  keysize: 512 bits
  device:  /dev/vda5
```

`crypto` = LVM *inside* an encrypted partition — `vda5` is a `crypto_LUKS`
partition, unlocked to `vda5_crypt`, which is the LVM PV. `/boot` stays outside
the encryption so GRUB can load the kernel + initramfs that then unlock the rest.

> **Automating the passphrase over serial.** For a hands-off re-test, drive the
> `Please unlock disk` prompt on the VM's `serial.sock` and send `labcrypto\n`
> (one client at a time on the socket). Or, for the console, just type it at the
> prompt `lab-vm.sh console` shows.

---

## Gotchas

- **Encrypted boot needs the passphrase.** Unlike the other variants, a
  `crypto-atomic` VM will hang at `Please unlock disk vda5_crypt:` until you type
  `labcrypto` (serial console or `lab-vm.sh console`). This is correct behaviour,
  not a hang. A real deployment would use a keyfile / TPM / dropbear-in-initramfs
  for unattended unlock.
- **`crypto` skips the secure-erase** (`partman-auto-crypto/erase_disks false`)
  so the lab is fast. A real encrypted install should wipe the disk with random
  data first — drop that line and expect a long pre-format pass.
- **Hostname is `debian`** (not `debian-preseed`) for the same d-i
  network-preseed reason documented in the pxe-lab MANUAL_TESTING.
- **Switching variants re-images.** A preseed only runs during the install, so a
  new variant means destroy + create + start (fresh disk) — you can't re-layout a
  running system.
