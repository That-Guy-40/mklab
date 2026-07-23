# RUNBOOK — the systemd debug shell (Arch's second method)

systemd can spawn a **passwordless root shell** at boot via `debug-shell.service`.
The **ArchWiki** lists this as a way to reset a lost root password: add
`systemd.debug_shell` to the kernel command line, switch to the debug shell, and
`passwd`. We document it **two ways**:

- **(A) Faithful to the wiki** — the shell on **tty9**, reached with `Ctrl+Alt+F9`.
  Needs a *graphical* console; **author-run** in this serial-only lab.
- **(B) Serial-redirect adaptation** — point the debug shell at `ttyS0` so it is
  reachable (and verifiable) over `lab-vm.sh console`.

> **Honest caveat — read this first.** As a *pure password reset* the debug shell
> is **contrived**: if you can already edit the kernel command line to add
> `systemd.debug_shell`, you can just add `init=/bin/bash`
> ([`RUNBOOK-init-shell.md`](RUNBOOK-init-shell.md)) and be done in one step. The
> debug shell's *real* job is **debugging an early-boot hang** — a system that
> wedges before login, where you need a root shell *running alongside* the boot
> to inspect it. We include it because the ArchWiki does, and because it teaches a
> genuinely useful systemd capability. The security lesson is the same: console +
> boot-param access ⇒ root.

VM: any systemd distro — use [`debian-bios.toml`](debian-bios.toml) (Debian is
systemd too; Arch isn't instantiable by `lab-vm.sh` — see
[`README.md`](README.md#why-arch-is-demonstrated-on-debian)). **STATUS: author-run.**

---

## (A) Faithful: debug shell on tty9  *(ArchWiki, verbatim intent)*

1. At the boot loader, edit the entry and **append `systemd.debug_shell`** to the
   kernel parameters. *(Some systemd versions also accept `systemd.debug-shell=1`,
   with a hyphen.)* Boot.
2. This does a **normal boot** but additionally starts `debug-shell.service`,
   which runs a root shell (`/bin/sh`) on **tty9**. Press **`Ctrl+Alt+F9`** to
   switch to it.
3. Use **`passwd`** to set a new password for root.
4. When done, **stop the debug shell** so it isn't left running:
   `systemctl disable --now debug-shell.service`.

**Why this is author-run here:** `Ctrl+Alt+F9` switches *virtual terminals* — that
needs a graphical/VT console. `lab-vm.sh` runs VMs **`-nographic` (serial only)**,
which has no VTs to switch to. To follow the wiki literally, launch the disk with
a graphical QEMU (e.g. `qemu-system-x86_64 -hda <disk> -m 2G` without `-nographic`)
and use `Ctrl+Alt+F9` there.

---

## (B) Serial-redirect adaptation (verifiable over `lab-vm.sh console`)

Point the debug shell at the serial line instead of tty9. This is **lab setup**
(done while you still have access), documented as a divergence:

```bash
# redirect debug-shell.service to ttyS0 …
sudo mkdir -p /etc/systemd/system/debug-shell.service.d
printf '[Service]\nTTYPath=/dev/ttyS0\n' | \
    sudo tee /etc/systemd/system/debug-shell.service.d/serial.conf
# …and stop the normal serial login from fighting it for the same tty:
sudo systemctl mask serial-getty@ttyS0.service
```

Now reboot with **`systemd.debug_shell`** on the kernel line (edit it in GRUB as
in [`RUNBOOK-init-shell.md`](RUNBOOK-init-shell.md) §1–§2, but append
`systemd.debug_shell` instead of `init=/bin/bash`). The debug shell appears
directly on the serial console:

```
# (root shell on ttyS0, no login)
# passwd
#   …set the new password…
# systemctl disable --now debug-shell.service      # disarm it
# systemctl unmask serial-getty@ttyS0.service      # restore normal serial login
# reboot
```

Verify as usual: the OLD password is rejected at the login prompt, the NEW one
works (`id` → `uid=0`).

> **Divergence noted:** masking `serial-getty@ttyS0` and the `TTYPath` override are
> not in the upstream recipe — they exist solely because this harness has one
> serial line and no VTs. The faithful path is (A).

---

## UEFI note (author-run)

The debug shell is **firmware-agnostic** — `systemd.debug_shell` (and
`rd.systemd.debug_shell` for the initramfs one) is a *kernel-command-line* option
added at the GRUB menu, and reaching that menu over serial under OVMF is already
proven ([`MANUAL_TESTING.md`](MANUAL_TESTING.md#debian-uefiovmf--verified-end-to-end)).
Nothing in (A) or (B) changes on UEFI: OVMF runs its own boot-manager phase, then
GRUB appears exactly as on BIOS and you press `e` / drop to the command line the
same way. The only firmware caveat is the shared one — a **GRUB password** or
locked-down Secure-Boot config blocks the cmdline edit (that's the point of it).

## Provenance

Source: **ArchWiki — *Reset lost root password*** (the `systemd.debug_shell` and
`init=/bin/bash` methods). Per the repo convention a **living wiki is cited, not
mirrored** — canonical URL + retrieved date are in
[`upstream-tutorial/`](upstream-tutorial/). All rights remain with the ArchWiki
contributors (CC BY-SA / GFDL).
