# debos VM factory — build + boot verify

End-to-end runbook for baking a bootable Debian image with debos and booting it,
plus the real verified transcript. Unlike `kali-vm-builder` (whose multi-GB Kali
build is author-run), a minimal trixie build is light enough to verify here.

> Run from the repo root.

## 0. Preflight

```bash
command -v podman qemu-system-x86_64 qemu-img || echo "install: podman qemu-system-x86 qemu-utils"
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM ok" || echo "no KVM — debos build VM needs it"
ls /usr/share/OVMF/OVMF_CODE*.fd >/dev/null 2>&1 && echo "OVMF ok" || echo "install: ovmf"
id -nG | tr ' ' '\n' | grep -qx kvm && echo "in kvm group" || echo "sudo adduser \$USER kvm; re-login"
```

## 1. Build (≈4–6 min, a few hundred MB of downloads)

```bash
examples/debian-vm-builder/fetch-debos.sh          # optional: pre-pull the debos container
examples/debian-vm-builder/build-debian-vm.sh      # → ~/debian-vm-build/debian-vm.qcow2
```

Watch for the debos actions in order: `Debootstrap → Kernel + base packages →
account run → image-partition → filesystem-deploy → Install systemd-boot →
kernel-install → Recipe done`, then `[build] converting → …qcow2` and
`[build] done`.

## 2. Boot it

Graphical (the intended way):

```bash
examples/debian-vm-builder/run-graphical.sh        # gtk window; login debian/debian
```

Headless boot-check (serial to your terminal, no window):

```bash
examples/debian-vm-builder/run-graphical.sh --display none --serial
# OVMF → systemd-boot menu → kernel → `debian-vm login:`  (Ctrl-a x to quit)
```

## 3. Verify

```bash
ssh -p 2222 debian@127.0.0.1        # password: debian   (root/lab also works)
```

---

## Verified end-to-end (KVM, x86_64, 2026-07-03)

**Build:** debos (rootless-podman container `ghcr.io/go-debos/debos:main`, KVM
build VM) ran the recipe clean — the tell-tale bootloader step:

```text
apt | Setting up systemd-boot (257.13-1~deb13u1) ...
apt | Copied ".../systemd-bootx64.efi.signed" to "/boot/efi/EFI/systemd/systemd-bootx64.efi".
apt | Copied ".../systemd-bootx64.efi.signed" to "/boot/efi/EFI/BOOT/BOOTX64.EFI".
==== Ensure the loader + a boot entry for the installed kernel exist ====
   type: Boot Loader Specification Type #1 (.conf)
  title: Debian GNU/Linux 13 (trixie) (default)
  linux: /boot/efi//<machine-id>/6.12.86+deb13-amd64/linux
==== Recipe done ====
```

Output: a **5.6 GB raw → ~700 MB qcow2**.

**Boot** (headless, OVMF/UEFI):

```text
Reached target multi-user
Reached target graphical
Debian GNU/Linux 13 debian-vm ttyS0
debian-vm login:
```

**Inside** (SSH `debian`/`debian` on the forwarded port), the captured transcript:

```text
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
uname -r            → 6.12.86+deb13-amd64
/sys/firmware/efi   → present (EFI boot ✓)
bootctl status      → Product: systemd-boot 257.13-1~deb13u1   Firmware Arch: x64
lsblk               → vda1 286M vfat /boot/efi   vda2 5.3G ext4 /   (GPT: ESP + root)
ip -4 -br addr      → eth0 UP 10.0.2.15/24        (systemd-networkd DHCP)
ssh-keygen -lf .../ssh_host_ed25519_key.pub → SHA256:1nEM…  (regenerated on first boot)
id debian           → uid=1000(debian) groups=1000(debian),27(sudo)
dpkg -l | grep -c ^ii → 180                       (lean; no desktop)
```

Every piece the recipe assembled is present: UEFI + systemd-boot, the GPT
ESP+root layout, DHCP networking, a working sshd with a *per-VM-unique* host key,
and the `debian` sudo account.

---

## Notes & gotchas

- **UEFI, so OVMF — not SeaBIOS.** The image is systemd-boot on a GPT/ESP, so
  `run-graphical.sh` boots it with OVMF firmware. `install: ovmf` if missing.
- **Networking = systemd-networkd DHCP.** The recipe enables `systemd-networkd`
  with a catch-all `20-wired.network` (`DHCP=yes`) — *not* ifupdown. (An early
  cut mixed the two: an ifupdown `interfaces` file while only `systemd-networkd`
  was enabled → eth0 never came up. Pick one network manager; this recipe uses
  networkd.)
- **SSH host keys need regenerating before sshd's config test.** The recipe
  wipes the install-time host keys (so every built VM isn't identical) — but
  Debian's `ssh.service` runs `ExecStartPre=/usr/sbin/sshd -t`, which *fails*
  with no host keys, so a naive wipe leaves `ssh.service` dead (`Failed to start
  ssh.service` in the boot log; SSH forward dead — verified twice). A first-boot
  *oneshot* ordered `Before=ssh.service` also loses the race. The fix that works:
  an `ssh.service.d/` drop-in that **resets** `ExecStartPre` and runs
  `ssh-keygen -A` *first*, then re-adds `sshd -t`. (trixie's `ssh.service` has
  only that one `ExecStartPre` and gets `/run/sshd` from `RuntimeDirectory=`, so
  the reset is safe.) `ssh-keygen -A` is idempotent — harmless on later boots.
- **The build re-downloads each run** (a fresh fakemachine build VM, no host apt
  cache). Point `--mirror` at a local mirror/`apt-cacher-ng` to speed repeats.
- **Overlay by default.** `run-graphical.sh` boots a COW overlay so the master
  stays pristine; `--no-overlay` mutates it, `--snapshot` discards writes,
  `--fresh` recreates the overlay.
- **Bootloader ordering is load-bearing** — see the comment header in
  `debian-vm.yaml`. Kernel before ESP; `systemd-boot` after `filesystem-deploy`.
