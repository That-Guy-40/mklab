# RUNBOOK — reset a lost root password with `init=/bin/bash`

The classic, distro-agnostic method: tell the kernel to run a **shell as PID 1**
instead of the init system, so you land at a **root prompt with no login**, then
`passwd`. This is the method the **Debian** and **Kali** write-ups use, and it is
one of the two **Arch** methods; **Rocky** calls it `init=/bin/sh` (see the
variations at the end). It is **fully verified end-to-end in this lab** on Debian
12 / BIOS — `# →` lines below are real serial output (full transcript:
[`MANUAL_TESTING.md`](MANUAL_TESTING.md)).

> **The lesson.** Anyone who can edit the boot loader's kernel command line owns
> the box — no password needed. That is not a bug; it is why **console/physical
> access = root**. The defenses (GRUB password, full-disk encryption, Secure
> Boot) are in [`README.md`](README.md#mitigations). This lab makes the threat
> concrete so the mitigation makes sense.

---

## 0. Bring up the box and attach the console

```bash
# from the repo root — BIOS variant (verified); UEFI is debian-uefi.toml
phase2-qemu-vm/lab-vm.sh create --config examples/root-password-reset/debian-bios.toml
phase2-qemu-vm/lab-vm.sh start  rpr-debian-bios

# one-time LAB SETUP (not part of the reset): make GRUB show an interruptible
# menu on the serial console, and set a root password we then "forget".
phase2-qemu-vm/lab-vm.sh ssh rpr-debian-bios -- 'sudo bash -s' \
    < examples/root-password-reset/setup/prestage.sh
```

Why prestage? Cloud images bake `timeout=0` into `grub.cfg`, so GRUB boots
instantly and you can never reach the editor. [`setup/prestage.sh`](setup/prestage.sh)
restores a 5-second, **visible** serial menu (a real installed/physical box has
one) — see [`README.md`](README.md#pre-staging-honest). Then attach the console
and reboot into the menu:

```bash
phase2-qemu-vm/lab-vm.sh console rpr-debian-bios     # detach later with Ctrl-]
# in another terminal (or over ssh): phase2-qemu-vm/lab-vm.sh ssh rpr-debian-bios -- sudo reboot
```

> **Serial-console gotchas (learned the hard way — they matter even by hand).**
> - GRUB's serial input has **no flow control and drops characters typed too
>   fast**. *Type slowly and deliberately*, especially the `init=/bin/bash` you
>   append — paste-bombing the line loses characters and the edit silently fails.
> - **Arrow keys may not work** in GRUB's serial editor (the `Esc` that begins
>   an arrow escape can be read as "discard edits"). Use the **emacs keys**:
>   `Ctrl-n`/`Ctrl-p` = down/up, `Ctrl-e`/`Ctrl-a` = end/start of line.
> - **Any keypress cancels the 5-second auto-boot countdown** — once you press a
>   key the menu waits for you, so there's no rush after the first keystroke.

---

## 1. Interrupt GRUB and open the editor  *(at the menu)*

When the menu appears (`Debian GNU/Linux`, counting down `… automatically in 5s`),
press a key to stop the countdown, then **`e`** to edit the highlighted entry.

```
# → GNU GRUB  version 2.06-13+deb12u1
# →   *Debian GNU/Linux
# →    Advanced options for Debian GNU/Linux
```

---

## 2. Append `init=/bin/bash` to the `linux` line  *(in the editor)*

Move down (`Ctrl-n` / ↓) to the line that begins with **`linux`** — the kernel
command line. Go to its **end** (`Ctrl-e` / End) and append a space then
`init=/bin/bash`, leaving everything else intact:

```
        linux   /boot/vmlinuz-6.1.0-44-cloud-amd64 root=PARTUUID=… ro \
                console=tty0 console=ttyS0,115200 … consoleblank=0 init=/bin/bash
# →                                                ^^^^^^^^^^^^^^^^^ appended (verified)
```

Then **`Ctrl-x`** (or `F10`) to boot the edited entry.

```
# → Booting a command list
# → Begin: Loading essential drivers ... done.
# → Begin: Mounting root file system ... done.
```

`init=/bin/bash` tells the kernel: after the initramfs mounts the real root,
exec `/bin/bash` as **PID 1** instead of `/sbin/init` (systemd). No services, no
login — just a root shell.

---

## 3. You are root. Remount `/` read-write and reset the password.

The root filesystem is mounted **read-only** at this stage, so `passwd`'s write
to `/etc/shadow` would fail until you remount it read-write:

```bash
# → root@(none):/#                ← bash is PID 1; hostname is "(none)", no login happened
mount -o remount,rw /             # (Arch's page uses: mount -n -o remount,rw /)
passwd                            # interactive: type the NEW root password twice
# …or non-interactively:  echo 'root:toor' | chpasswd
# → (password updated successfully)
```

> Throwaway lab credential: this lab resets root to **`toor`**. Never use lab
> passwords on a real or networked machine.

---

## 4. Hand control back to the init system and verify

Because `bash` is PID 1 (not systemd), don't just `reboot` — either re-exec the
real init to finish booting, or force a reboot:

```bash
exec /sbin/init                   # continue a normal boot into systemd (verified)
#  — or —  sync; mount -o remount,ro / ; reboot -f
```

After it boots to the login prompt, confirm the reset took:

```
# → rpr-debian-bios login: root
# → Password:  (the OLD password, "S0meForgottenPass")
# → Login incorrect                         ← old password no longer works ✓
# → rpr-debian-bios login: root
# → Password:  (the NEW password, "toor")
# → root@rpr-debian-bios:~# id
# → uid=0(root) gid=0(root) groups=0(root)  ← reset confirmed ✓
```

---

## Per-source variations — each reconciled against the archived page

The four write-ups differ in the **exact** edit and finish. This table follows
each [archived source](upstream-tutorial/) **verbatim** — it deliberately does
*not* flatten them to match the unified walk above.

| Source | Edit to the `linux` line | Make `/` writable | Set password | Finish |
|---|---|---|---|---|
| **Debian** ([ggCircuit](upstream-tutorial/debian-ggcircuit-reset.html)) | append ` init=/bin/bash` | `mount -o remount,rw /` | `passwd` | `reboot` |
| **Kali** ([linuxconfig](upstream-tutorial/kali-linuxconfig-reset.html)) | replace **`ro`→`rw`** *and* **`quiet`→`init=/bin/bash`** | already `rw` — just run `mount` to confirm | `passwd` (root) | `exec /sbin/init` |
| **Arch** (ArchWiki) | append ` init=/bin/bash` | `mount -n -o remount,rw /` | `passwd` | `reboot -f` |
| **Rocky** ([CIQ](upstream-tutorial/rocky-ciq-reset.html), method 1) | append ` init=/bin/sh` | `mount -o remount,rw /` | `passwd root` | `/usr/sbin/reboot -f` |

Faithful per-source details:
- **Debian (ggCircuit):** *hold **Shift*** during startup if the menu doesn't
  appear; the page labels the boot step "Boot into Recovery Mode". It ends with a
  bare **`reboot`** — but under `init=/bin/bash` (PID 1 = bash, no init) a plain
  `reboot` frequently **kernel-panics** (the Kali page documents exactly that).
  This lab verified the robust finish **`exec /sbin/init`**; `reboot -f` also works.
- **Kali (linuxconfig):** uniquely *edits existing words* rather than appending —
  **`ro`→`rw`** (mounts the root fs writable **at boot**, so there's no remount,
  only a `mount` check) and **`quiet`→`init=/bin/bash`**. If boot misbehaves, also
  remove **`splash`**, and finish with **`exec /sbin/init`** (a plain `reboot`
  panics). It resets **root** via `passwd`.
- **`/bin/sh` vs `/bin/bash`:** both give a root shell as PID 1 (every distro has
  `/bin/sh`); Rocky's page uses `/bin/sh`, the others `/bin/bash`.
- **SELinux (Rocky/RHEL):** you **must** `touch /.autorelabel` or the relabel-on-
  login can lock you out — full walk in [`RUNBOOK-rd-break.md`](RUNBOOK-rd-break.md).

> **Editorial note (not from the linuxconfig page):** since 2020 Kali defaults to
> a **non-root** user (`kali`, with `sudo`). The linuxconfig recipe resets
> **root** (`passwd`); if you instead want to reset the desktop user, `passwd kali`.

---

## Teardown & provenance

```bash
phase2-qemu-vm/lab-vm.sh destroy rpr-debian-bios --force
```

Sources: Debian — ggCircuit KB; Kali — linuxconfig.org; Arch — ArchWiki *Reset
lost root password*; Rocky — CIQ KB. The per-source steps above were **reconciled
against the archived pages** in [`upstream-tutorial/`](upstream-tutorial/) (Debian,
Kali, Rocky vendored byte-exact; Arch cited as a living wiki). All rights remain
with the respective authors. The `init=/bin/bash` reset is **verified** end-to-end
here on Debian 12 / BIOS; the UEFI, Rocky, and Kali **VM runs** are author-run
(see [`MANUAL_TESTING.md`](MANUAL_TESTING.md)).
