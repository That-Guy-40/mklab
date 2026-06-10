# Manual testing — root-password-reset

The **`init=/bin/bash` reset is verified end-to-end in a real KVM VM** on this
host (Debian 12 bookworm, kernel `6.1.0-44-cloud-amd64`, QEMU 8.2, BIOS/SeaBIOS,
serial console) — driven over the QEMU serial socket. The reset *chain* (boot to
a root shell → remount rw → change the password → reboot → **old password
rejected, new password works**) is the load-bearing proof. The other distros /
firmware / methods are **author-run** (clearly marked) and rest on this verified
chain plus their faithful upstream steps.

| Step | Proof | Status |
|---|---|---|
| Pre-stage → interruptible serial GRUB menu | `set timeout=5` in regenerated `grub.cfg`; menu shows on serial | ✅ verified |
| BIOS boot of Debian genericcloud | `/sys/firmware/efi` absent | ✅ verified |
| **`e`-menu-edit** → `init=/bin/bash` on the `linux` line | `…consoleblank=0 init=/bin/bash` | ✅ verified |
| Boots to root shell (PID 1 bash) | `root@(none):/#`, `id`→`uid=0` | ✅ verified |
| remount rw + `chpasswd root:toor` | `CHPWRC=0` | ✅ verified |
| `exec /sbin/init` → normal boot | reaches `login:` | ✅ verified |
| **OLD password rejected** | `Login incorrect` for `S0meForgottenPass` | ✅ verified |
| **NEW password works** | `root@…# id`→`uid=0(root)` for `toor` | ✅ verified |
| GRUB **command-line** (`c`) variant | same chain, deterministic | ✅ verified |
| Debian **UEFI/OVMF** firmware path | reach GRUB menu over serial under OVMF | ⏳ author-run |
| **Rocky** `rd.break` + `/.autorelabel` | RHEL initramfs + SELinux relabel | ⏳ author-run |
| **Kali** init=/bin/bash (non-root) | prebuilt image GRUB on serial | ⏳ author-run |
| **systemd debug shell** (tty9 / serial-redirect) | passwordless root shell | ⏳ author-run |

---

## A. Pre-stage: restore an interruptible serial GRUB menu

Cloud `grub.cfg` ships `set timeout=0` (menu flashes by). `setup/prestage.sh`
adds a `99-…` grub.d drop-in and `update-grub`:

```
$ sudo grep -nE 'set timeout=' /boot/grub/grub.cfg
66:    set timeout=5            # was 0 — now a 5s, visible, serial menu
```
**PASS** — and the menu is reachable over `lab-vm.sh console` (banner `Welcome to
GRUB`, entry `*Debian GNU/Linux`, `… automatically in 5s`).

## B–H. The reset, over the serial console  (centerpiece)

Catch the menu → `e` → `Ctrl-n` to the `linux` line → `Ctrl-e` → type
` init=/bin/bash` (slowly!) → `Ctrl-x`:

```
GNU GRUB  version 2.06-13+deb12u1
        linux  /boot/vmlinuz-6.1.0-44-cloud-amd64 root=PARTUUID=… ro \
               console=tty0 console=ttyS0,115200 … consoleblank=0 init=/bin/bash
Booting a command list
Begin: Mounting root file system ... done.
root@(none):/#                         ← bash is PID 1 (hostname "(none)", no login)
root@(none):/# mount -o remount,rw /
root@(none):/# echo 'root:toor' | chpasswd
CHPWRC=0
root@(none):/# exec /sbin/init         ← hand back to systemd; normal boot resumes
…
rpr-debian-bios login: root
Password:                              ← OLD password "S0meForgottenPass"
Login incorrect                        ← ✓ old password no longer works
rpr-debian-bios login: root
Password:                              ← NEW password "toor"
root@rpr-debian-bios:~# id
uid=0(root) gid=0(root) groups=0(root) ← ✓ reset confirmed
```
**PASS** — the full chain. The GRUB **command-line** variant (`c` → `search` /
`linux … init=/bin/bash` / `initrd` / `boot`) reaches the same `root@(none):/#`
and the same verified login outcome.

---

## The serial-driving gotcha that this lab discovered

The single hardest part of automating this was **GRUB's serial input has no flow
control and silently drops characters** sent faster than it consumes them — a
long `linux …` line or a rapid key burst arrives garbled, so the edit "didn't
take" with no error. **Fix: send character-by-character with a ~40 ms delay, and
single-step keystrokes.** Also: GRUB's serial editor often **ignores arrow-key
escapes** (the leading `Esc` reads as "discard edits") — use `Ctrl-n`/`Ctrl-p`/
`Ctrl-a`/`Ctrl-e`; **any keypress cancels** the 5-second countdown; **only one
client** may attach to the serial socket at a time; and the QEMU monitor
`sendkey` does **not** reach a serial GRUB (it targets the emulated PS/2/VGA
keyboard). A **human** typing at `lab-vm.sh console` is naturally slow enough and
never hits any of this — it is purely an automation concern, but it's documented
in [`RUNBOOK-init-shell.md`](RUNBOOK-init-shell.md) so anyone scripting it knows.

---

## Author-run items (to confirm; chain already proven on Debian)

- **`debian-uefi.toml`** — only the firmware *path to the menu* differs (OVMF
  shows its own phase first); the edit + reset are identical.
- **`rocky.toml`** — `rd.break` → `chroot /sysroot` → `passwd root` → **`touch
  /.autorelabel`** (the SELinux relabel; skipping it can deny login even with the
  right password); prestage uses `grub2-mkconfig`; a `console=` arg may need
  removing to see the initramfs shell (CIQ note).
- **`kali.toml`** — linuxconfig's recipe (now reconciled against the archived
  page): on the `linux` line **`ro`→`rw`** *and* **`quiet`→`init=/bin/bash`**, so
  `/` is writable at boot (just `mount` to confirm), `passwd` (root), finish with
  **`exec /sbin/init`** (plain `reboot` panics; remove `splash` if needed). Same
  PID-1-bash family as the verified Debian run; confirm the **prebuilt image's
  GRUB is serial-reachable** (it targets a desktop) and the **non-root** nuance.
- **systemd debug shell** — tty9 path needs a graphical QEMU; the serial-redirect
  adaptation (`TTYPath=/dev/ttyS0` + mask `serial-getty@ttyS0`) is verifiable here.

## Environment notes

- Host: KVM available; Debian genericcloud qcow2 (~3 GB root — no resize needed
  for this lab, unlike kdump). Each verification run = power-cycle
  (`lab-vm.sh stop --force && start`) for a deterministic boot → GRUB catch.
- Nothing here touched the host; every reset was contained to the throwaway VM.
- Throwaway lab credentials only (`S0meForgottenPass` → `toor`); never reuse on a
  real or networked machine.
