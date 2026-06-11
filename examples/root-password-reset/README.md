# Reset a lost root password — a Phase-2 VM lab

A **slew of faithful, hand-walkable tutorials** for resetting a lost root password
on a running VM, drawn from four upstream write-ups (Arch, Rocky, Kali, Debian)
and covering **BIOS and EFI** boot, the **systemd debug shell**, and several
**other approaches**. You reboot the VM, interrupt the boot loader, get a root
shell *without authenticating*, and set a new password.

> ## The lesson
> Every method here works because **whoever controls the boot path controls the
> machine** — editing the kernel command line, breaking into the initramfs, or
> mounting the disk elsewhere all bypass the login entirely. The root password is
> **not** a boundary against console/physical/disk access. The real boundaries
> are a **GRUB password**, **full-disk encryption (LUKS)**, **Secure Boot**, and
> **physical security** — see [Mitigations](#mitigations). This is the same
> "X is not a security boundary" framing as [`../chroot-breakout/`](../chroot-breakout/).

Why a **VM** (not a chroot/container): the technique *is* interrupting the boot
loader and controlling the kernel command line — impossible without a real
machine and its boot path. Panicking/rebooting a throwaway VM is free.

---

## The matrix

| Method | RUNBOOK | Upstream source(s) | Demonstrated on | Status |
|---|---|---|---|---|
| `init=/bin/bash` · `init=/bin/sh` | [init-shell](RUNBOOK-init-shell.md) | Debian (ggCircuit), Kali (linuxconfig), Arch, Rocky (method 1) | [`debian-bios`](debian-bios.toml) / [`-uefi`](debian-uefi.toml), [`kali`](kali.toml) † | ✅ **verified** (Debian/BIOS) |
| `rd.break` → `chroot /sysroot` (+SELinux relabel) | [rd-break](RUNBOOK-rd-break.md) | Rocky / RHEL family (CIQ) | [`rocky`](rocky.toml) → gallery | ✅ **verified** (Rocky 9) |
| **systemd debug shell** (`systemd.debug_shell`) | [systemd-debug-shell](RUNBOOK-systemd-debug-shell.md) | Arch | (any systemd distro) | ⏳ author-run |
| **Other** — live media, offline disk edit, recovery mode, *why `sulogin` doesn't help* | [other-approaches](RUNBOOK-other-approaches.md) | general | — | reference |

† Kali, two ways: its **prebuilt QEMU image is not serial-bootable** under this
headless harness — it boot-loops at GRUB (the image's GRUB wants a video device;
`lab-vm.sh` runs `-display none -nographic -nodefaults`; tested 2026-06-10). **But
the linuxconfig recipe is verified end-to-end on a *real* installed Kali** — built
with d-i + a preseed via [`../kali-preseed-gallery/`](../kali-preseed-gallery/)
(`headless-default`), which produces a serial-reachable grub-pc; the
`ro`→`rw` / `quiet`→`init=/bin/bash` reset gives old-pw-rejected, new-pw-`uid=0`.
Both in [`MANUAL_TESTING.md`](MANUAL_TESTING.md#kali-method--verified-end-to-end-on-a-preseed-installed-kali).
So **[`kali.toml`](kali.toml) now *delegates* to that gallery** (it carries the
Kali pre-stage + reset workflow but no `[[vm]]` of its own — dogfooding the
gallery's verified install instead of the dead-end 7z).

**Firmware axis:** [`debian-bios.toml`](debian-bios.toml) (SeaBIOS, verified) and
[`debian-uefi.toml`](debian-uefi.toml) (OVMF/UEFI) are a **pair** proving the
technique is **firmware-agnostic** — once you reach the GRUB editor, the steps are
identical; only *getting to the menu* differs (and on EFI/Arch the boot loader may
be **systemd-boot**, where you also press `e`).

---

## Quick start (the verified path)

```bash
# from the repo root
phase2-qemu-vm/lab-vm.sh create --config examples/root-password-reset/debian-bios.toml
phase2-qemu-vm/lab-vm.sh start  rpr-debian-bios

# one-time lab setup (NOT part of the reset): interruptible serial GRUB menu
# + a root password we then "forget":
phase2-qemu-vm/lab-vm.sh ssh rpr-debian-bios -- 'sudo bash -s' \
    < examples/root-password-reset/setup/prestage.sh

# now do the reset by hand — attach the console and follow the runbook:
phase2-qemu-vm/lab-vm.sh console rpr-debian-bios     # Ctrl-] to detach
#   → RUNBOOK-init-shell.md: reboot, press 'e', append init=/bin/bash, Ctrl-x,
#     mount -o remount,rw /, passwd, exec /sbin/init, log in with the new password.

phase2-qemu-vm/lab-vm.sh destroy rpr-debian-bios --force   # when done
```

> **Serial-console gotcha (important even by hand):** GRUB's serial input drops
> characters typed too fast — **type the `init=/bin/bash` slowly**, and if the
> arrow keys misbehave use `Ctrl-n`/`Ctrl-p`/`Ctrl-e`. Full detail in
> [`RUNBOOK-init-shell.md`](RUNBOOK-init-shell.md) and
> [`MANUAL_TESTING.md`](MANUAL_TESTING.md).

---

## Pre-staging (honest)

The reset assumes only **console access**. But cloud images generate their
`grub.cfg` with `timeout=0`, so GRUB boots instantly and the menu is never
reachable — a *cloud quirk*, not how a real installed/physical machine behaves.
[`setup/prestage.sh`](setup/prestage.sh) **restores a normal 5-second, visible
serial menu** (and sets the to-be-"forgotten" root password). That is **lab setup,
not part of the reset.** "Isn't restoring the menu cheating?" — no: a physical box
*has* that menu, which is exactly why the [Mitigations](#mitigations) (a GRUB
password) exist. The lab shows the threat so the mitigation makes sense.

Pre-staging is delivered over ssh and auto-detects the distro (Debian/Kali →
`update-grub` + grub.d drop-in; Rocky → `grub2-mkconfig`).

### Why Arch is demonstrated on Debian
`lab-vm.sh` has no Arch cloud image or `pacstrap` backend, so an Arch VM isn't
buildable here. Arch's two methods (`init=/bin/bash`, the systemd debug shell) are
**not Arch-specific** — they work on any systemd distro — so we demonstrate them
on Debian and **cite** the ArchWiki (a living wiki → cite, don't mirror).

---

## Mitigations

The reset is trivial *by design* once you have console/boot/disk access. To
actually protect a machine:

- **GRUB password** — `grub-mkpasswd-pbkdf2` + a `password_pbkdf2` superuser in
  `/etc/grub.d/40_custom`; require it to **edit entries** (`e`) or use the command
  line (`c`). Blocks [init-shell](RUNBOOK-init-shell.md) / [rd.break](RUNBOOK-rd-break.md) / [debug-shell](RUNBOOK-systemd-debug-shell.md).
- **Full-disk encryption (LUKS)** — defeats the [offline disk edit and live-media
  chroot](RUNBOOK-other-approaches.md): without the passphrase the data is opaque.
- **Secure Boot + firmware/BIOS password** — stop booting alternate media and
  tampering with the boot chain.
- **Physical security** — the GRUB password and LUKS only matter if the attacker
  can't just pull the disk or reset firmware. Defense in depth.

A GRUB password without disk encryption still loses to pulling the disk (offline
edit); encryption without a firmware/Secure-Boot story still loses to some boot-
media attacks. Layer them.

---

## What's in here

| File | What |
|---|---|
| [`RUNBOOK-init-shell.md`](RUNBOOK-init-shell.md) | `init=/bin/bash`·`/bin/sh` method (**verified**); Debian/Kali/Arch/Rocky variants |
| [`RUNBOOK-rd-break.md`](RUNBOOK-rd-break.md) | Rocky/RHEL `rd.break` + SELinux relabel; Debian `break=` note |
| [`RUNBOOK-systemd-debug-shell.md`](RUNBOOK-systemd-debug-shell.md) | Arch debug shell — faithful tty9 **and** serial-redirect |
| [`RUNBOOK-other-approaches.md`](RUNBOOK-other-approaches.md) | live media, offline edit, recovery mode, why `sulogin` doesn't help |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | real verified serial transcript + author-run status |
| [`debian-bios.toml`](debian-bios.toml) · [`debian-uefi.toml`](debian-uefi.toml) | the firmware pair |
| [`kali.toml`](kali.toml) · [`rocky.toml`](rocky.toml) | Both **delegate to their galleries** (no `[[vm]]`): `kali.toml` → [`../kali-preseed-gallery/`](../kali-preseed-gallery/) (the prebuilt 7z is unbootable headless), `rocky.toml` → [`../rocky-kickstart-gallery/`](../rocky-kickstart-gallery/); each carries its distro's pre-stage + reset workflow |
| [`setup-kali-target.sh`](setup-kali-target.sh) · [`reset-demo.sh`](reset-demo.sh) | **Kali** on-ramp + hands-off proof: build/pre-stage a real headless Kali, then serial-drive the `init=/bin/bash` reset and verify *old-rejected / new-`uid=0`* |
| [`setup-rocky-target.sh`](setup-rocky-target.sh) · [`reset-demo-rocky.sh`](reset-demo-rocky.sh) | **Rocky** on-ramp + hands-off proof: build/pre-stage a real Rocky 9 (kickstart), then serial-drive the **`rd.break`** reset (incl. the SELinux relabel) and verify |
| [`setup/prestage.sh`](setup/prestage.sh) | one-time lab setup (interruptible serial menu + "forgotten" pw) for the cloud-image distros (Debian/Rocky) |
| [`tools/`](tools/) | [`serial-drive.py`](tools/serial-drive.py) — scripts the QEMU serial console (the GRUB char-drop workaround); behind the verified transcripts |
| [`upstream-tutorial/`](upstream-tutorial/) | provenance for all four sources; Rocky archived byte-exact |

**Verified** end-to-end on Debian 12 / BIOS (KVM); other distros/firmware/methods
are author-run and rest on that chain — details in
[`MANUAL_TESTING.md`](MANUAL_TESTING.md).
