# RUNBOOK — other ways to reset a lost root password

Beyond editing the kernel command line ([`init-shell`](RUNBOOK-init-shell.md),
[`rd.break`](RUNBOOK-rd-break.md)) and the [systemd debug shell](RUNBOOK-systemd-debug-shell.md),
here is the broader landscape — including one approach that **looks** like it
should work but doesn't. They all reinforce the same lesson: **the root password
protects nothing against someone with console/boot/disk access** — the real
boundary is a GRUB password + full-disk encryption ([`README.md`](README.md#mitigations)).

**STATUS: reference/author-run.** These are documented for completeness; the
boot-loader-edit method is the one verified end-to-end in this lab.

---

## 1. Live media (or installer rescue mode) → chroot

Bootloader-independent — works even when GRUB is password-protected, as long as
the **disk isn't encrypted**.

1. Boot a live ISO (or the distro installer's **rescue/troubleshooting** mode)
   instead of the installed system.
2. Mount the installed root (and `/boot`, and bind `/dev /proc /sys`), then chroot:
   ```bash
   mount /dev/sda2 /mnt              # the root partition
   mount /dev/sda1 /mnt/boot         # if separate
   for d in dev proc sys; do mount --rbind /$d /mnt/$d; done
   chroot /mnt
   passwd root                       # set the new password
   # RHEL family: touch /.autorelabel before exiting (SELinux — see rd.break runbook)
   exit; reboot
   ```
3. RHEL family in rescue mode lands you under **`/mnt/sysimage`** (use
   `chroot /mnt/sysimage`).

The installer rescue mode is just a packaged version of this: it finds your
install and offers to chroot for you.

---

## 2. Offline: edit the disk from another machine

If you can detach the disk (or open the VM image on the host), you don't need to
boot the target at all:

```bash
# on the host, against a powered-off VM image:
sudo modprobe nbd; sudo qemu-nbd -c /dev/nbd0 disk.qcow2
sudo mount /dev/nbd0p2 /mnt && sudo chroot /mnt passwd root   # then unmount + qemu-nbd -d
```

Or edit `/etc/shadow` directly: replace root's password hash field with one you
generate (`openssl passwd -6` / `mkpasswd`), or blank it for a passwordless root
(then set a real one after logging in). `passwd --root /mnt root` does the same
without a chroot. This is why **disk encryption (LUKS)** — not the login password
— is the actual defense.

---

## 3. GRUB recovery-mode menu entry (Debian/Ubuntu)

GRUB's **Advanced options → "… (recovery mode)"** boots single-user to a
maintenance menu. On Debian/Ubuntu it offers a **root shell** option (after, on
some configs, prompting for the root password — see §4). When it gives a shell
without a password, it's the same as `init=/bin/bash`: `mount -o remount,rw /`,
`passwd`. No bootloader editing needed if the recovery entry is present.

---

## 4. Why `rescue`/`emergency` targets do NOT help a *lost* password

A natural guess is to boot `systemd.unit=rescue.target` (or `emergency.target`,
or legacy `single`/`1`). **These don't help when the password is truly lost** —
they run **`sulogin`**, which **prompts for the root password** before giving a
shell:

```
Give root password for maintenance (or press Control-D to continue):
```

If you knew it, you wouldn't be here. (They *do* work if root has an **empty or
locked** password, where `sulogin` may grant a shell — distro-dependent — which
is itself a reason not to leave root unlocked.) The methods that actually work
for a *lost* password are the ones that **bypass authentication entirely**:
`init=/bin/bash`, `rd.break`, the debug shell, live media, and offline edits —
i.e. everything else in this lab. Knowing *why* `sulogin` is the dividing line is
half the lesson.

---

## 5. Cloud-native aside

On a cloud VM you'd normally never do any of this: re-run **cloud-init** with a
new `chpasswd`/SSH key via the provider console, or attach the volume to a
known-good instance (that's §2). Mentioned for completeness — the boot-loader
methods are for the bare-metal / "I'm at the console" case this lab models.

---

These approaches are general Linux recovery knowledge (no single upstream
tutorial); the four cited tutorials cover §-method variants above. See
[`README.md`](README.md) for the matrix and [`upstream-tutorial/`](upstream-tutorial/)
for provenance.
