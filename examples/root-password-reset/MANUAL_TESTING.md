# Manual testing — root-password-reset

The **`init=/bin/bash` reset is verified end-to-end in a real KVM VM** on this
host (Debian 12 bookworm, kernel `6.1.0-44-cloud-amd64`, QEMU 8.2, BIOS/SeaBIOS,
serial console) — driven over the QEMU serial socket. The reset *chain* (boot to
a root shell → remount rw → change the password → reboot → **old password
rejected, new password works**) is the load-bearing proof. The other distros /
firmware / methods are **author-run** (clearly marked) and rest on this verified
chain plus their faithful upstream steps. **Kali** is covered two ways: its
upstream **prebuilt desktop image boot-loops at GRUB** on this headless harness
(can't be driven — [Kali (prebuilt image)](#kali-prebuilt-image--tested-not-serial-bootable)),
but the **linuxconfig recipe is verified end-to-end on a *real* installed Kali**
(built via the [preseed gallery](../kali-preseed-gallery/) —
[Kali method](#kali-method--verified-end-to-end-on-a-preseed-installed-kali)).
**Rocky**'s `rd.break` method is likewise **verified end-to-end on a real Rocky 9**
(kickstart-installed via the [kickstart gallery](../rocky-kickstart-gallery/) —
[Rocky rd.break](#rocky-rdbreak--verified-end-to-end-on-a-kickstart-installed-rocky-9)),
SELinux relabel and all.

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
| **Rocky** `rd.break` + `/.autorelabel` on real Rocky 9 | dracut `switch_root:/#`; relabel runs; old pw `Login incorrect`, new pw `uid=0(root)` (correct SELinux context) | ✅ **verified** ([below](#rocky-rdbreak--verified-end-to-end-on-a-kickstart-installed-rocky-9)) |
| **Kali** prebuilt QEMU image on serial | boot-loops at GRUB — no video device | ❌ **tested → not serial-bootable** ([below](#kali-prebuilt-image--tested-not-serial-bootable)) |
| **Kali method** on a *real installed* Kali (linuxconfig recipe) | `/proc/cmdline`=`…rw init=/bin/bash…`; old pw `Login incorrect`, new pw `uid=0(root)` | ✅ **verified** ([below](#kali-method--verified-end-to-end-on-a-preseed-installed-kali)) |
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
The driver that bakes in all of these workarounds is
[`tools/serial-drive.py`](tools/serial-drive.py) (see [`tools/README.md`](tools/README.md)).

---

## Kali (prebuilt image) — tested, **not** serial-bootable

Kali's prebuilt QEMU desktop image (`kali.toml`'s *original* disk-image spec) was
taken end-to-end on **2026-06-10** and the result is a clean **negative**: the
**prebuilt Kali QEMU image cannot be driven on `lab-vm.sh`'s headless, serial-only
QEMU.** The reset *method* is unaffected (same `init=/bin/bash` family verified on
Debian above); the *image* is the problem. This test is **why `kali.toml` now
[delegates](#kali-method--verified-end-to-end-on-a-preseed-installed-kali) to the
preseed gallery** (no `[[vm]]` of its own); the run below is the record that
motivated that switch.

**What was run.** `lab-vm.sh create --config kali.toml` downloaded and sha256-
verified `kali-linux-2026.1-qemu-amd64.7z` (resolved from `kali-rolling`),
extracted the 15 GB qcow2, and provisioned `rpr-kali` (q35, KVM, SeaBIOS/BIOS,
virtio-blk). `lab-vm.sh start` + an 80 s passive serial capture
([`tools/serial-drive.py`](tools/serial-drive.py) `--capture`) showed an endless
boot loop:

```
SeaBIOS (version 1.16.3-debian-1.16.3-2)
iPXE (https://ipxe.org) 00:02.0 …
Booting from Hard Disk...
GRUB loading.
Welcome to GRUB!            ← then ESC c / ESC[2J (gfxterm setup) … and RESET
SeaBIOS (version 1.16.3-debian-1.16.3-2)   ← back to firmware; repeat ~4×/second
```

**301 SeaBIOS resets in 80 seconds.** No kernel, no menu countdown, no login —
GRUB faults the instant it tries to bring up its **graphical** terminal, because
`lab-vm.sh` runs QEMU with **`-display none -nographic -nodefaults`** (no video
device at all).

**Root cause, isolated by experiment.** Re-booting the *same* image under QEMU
with one change — **`-device VGA` added** — gave **0 resets**: the loop vanished,
proving the missing video device is the cause (the prebuilt image's GRUB is built
for a graphical console). But with VGA present the serial line went **completely
silent** — the image sends its console to the VGA framebuffer, not `ttyS0`. So
the image is undriveable on a serial-only harness **both ways**: without a video
device GRUB boot-loops; with one, nothing reaches serial.

| QEMU display setup | SeaBIOS resets | Serial usable? |
|---|---|---|
| `-display none -nographic -nodefaults` (how `lab-vm.sh` runs) | **301 / 80 s** (boot loop) | no — loops before any menu |
| same **+ `-device VGA`** (diagnostic only) | **0** | no — boots, but output is on VGA |

**Why this isn't fixable inside the lab as-is.** The Debian/Rocky cloud images
are already serial-aware (`GRUB_TERMINAL="console serial"`), so `prestage.sh`
only needs to lengthen the timeout. The Kali *desktop* prebuilt image is not —
and you can't reach a login to *run* `prestage.sh` (serial is dead before login).
Making this image work needs one of: **(a)** a **graphical QEMU** display
(SPICE/GTK/VNC) to watch and type — `lab-vm.sh` is deliberately serial-only; or
**(b)** a **one-time offline GRUB edit** of the qcow2 (mount it elsewhere, add
`GRUB_TERMINAL="console serial"` + `GRUB_SERIAL_COMMAND` and a non-gfx
`terminal_output`, regenerate `grub.cfg`) before first serial boot — which needs
root/`qemu-nbd` and is itself the "offline disk edit" technique from
[`RUNBOOK-other-approaches.md`](RUNBOOK-other-approaches.md).

**Net:** the **method** is faithful and proven (Debian); the **Kali prebuilt
image** is documented here as not serial-bootable under this harness, rather than
left as an unverified "author-run" claim.

---

## Kali method — verified end-to-end on a preseed-installed Kali

The prebuilt *image* can't boot here, but the **linuxconfig recipe itself is now
verified end-to-end on a genuinely-installed Kali** (kali-rolling, kernel
`6.19.14+kali-amd64`, BIOS). The trick (suggested mid-build): instead of the
desktop 7z, **install Kali with d-i + a preseed** via the sibling
[`../kali-preseed-gallery/`](../kali-preseed-gallery/) `headless-default` variant.
A preseed install lays down a normal **grub-pc in the MBR** whose **menu renders
on the serial console** — exactly what the graphical 7z lacked:

```
SeaBIOS … Booting from Hard Disk...
 *Kali GNU/Linux
  Advanced options for Kali GNU/Linux
  The highlighted entry will be executed automatically in 5s … 4s … 3s …
```

**Pre-stage (lab setup, as on Debian).** The headless install puts `console=ttyS0`
on the *installer* but not the *installed* kernel, and Kali locks root by default.
So a one-time pre-stage (over the serial login, `kali`/`kali`) appends
`GRUB_CMDLINE_LINUX="console=ttyS0,115200n8"` + `GRUB_TIMEOUT_STYLE=menu`, sets the
"forgotten" root password (`echo root:S0meForgottenPass | chpasswd`), and
`update-grub` — making the box behave like a serial-console machine with a root
password to lose. (Not part of the reset.)

**The reset** (driven with [`tools/serial-drive.py`](tools/serial-drive.py); the
linuxconfig edit `ro`→`rw`, `quiet`→`init=/bin/bash` typed at the GRUB command
line so the result is byte-identical and deterministic — per the CLAUDE.md serial
note):

```
# → [    0.000000] Command line: BOOT_IMAGE=/boot/vmlinuz-6.19.14+kali-amd64 \
# →     root=UUID=59381e9b-… rw init=/bin/bash console=ttyS0,115200n8   ← ground truth (/proc/cmdline)
# → root@(none):/#                         ← bash is PID 1 (echo PID-IS-$$ → PID-IS-1)
# → root@(none):/# id  → uid=0(root) gid=0(root) groups=0(root)
# → root@(none):/# mount -o remount,rw /
# → root@(none):/# echo 'root:toor' | /usr/sbin/chpasswd   → CHPW-RC-IS-0
# → root@(none):/# exec /sbin/init         ← hand back to systemd; normal boot resumes
# → kali login: root
# → Password:                              ← OLD password "S0meForgottenPass"
# → Login incorrect                        ← ✓ old password no longer works
# → kali login: root
# → Password:                              ← NEW password "toor"
# → Linux kali 6.19.14+kali-amd64 …        ← MOTD: logged in
# → root@kali:~# id  → uid=0(root) gid=0(root) groups=0(root)   ← ✓ reset confirmed
```

**PASS** — the same chain proven on Debian, now on real Kali. This is the faithful
reproduction `kali.toml` could not deliver (its prebuilt image is unbootable
headless). The human-facing `e`-menu-edit (`ro`→`rw`, `quiet`→`init=/bin/bash`) in
[`RUNBOOK-init-shell.md`](RUNBOOK-init-shell.md) yields this exact `/proc/cmdline`.

### Reproduce it (the exact methodology used)

> **Scripted.** [`setup-kali-target.sh`](setup-kali-target.sh) runs steps 1–2 below
> and leaves a ready-to-reset target (hand-walk the reset yourself);
> [`reset-demo.sh`](reset-demo.sh) does that **and** step 3 hands-off, then verifies
> *old-rejected / new-`uid=0`*. Both reuse [`tools/serial-drive.py`](tools/serial-drive.py),
> confirm every step **live** (each `EXPECT`-gated), and **retry** transient serial
> hiccups (GRUB's input has no flow control). **Verified on KVM** (2026-06-11):
> `setup` → `6/6 DONE`; `reset-demo` → PASS, 4/4 consecutive runs. The manual steps
> below are what they automate:

```bash
# 1. Install a REAL Kali via d-i + preseed (not the unbootable desktop 7z):
examples/kali-pxe-lab/fetch-kali-installer.sh --arch amd64          # d-i kernel/initrd → ~/netboot/kali/
examples/kali-preseed-gallery/select-preseed.sh headless-default    # bake boot.ipxe for this variant
phase4-podman/lab-podman.sh up     --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh   create  --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh   start   kali-preseed-install              # unattended d-i → reboots into Kali

# 2. Pre-stage over the serial console (lab setup, login kali/kali, sudo).  These are
#    APPEND-ONLY edits — /etc/default/grub is sourced as shell, so a trailing
#    reassignment wins (this dodges the char-drop trap that mangles long sed lines):
echo 'GRUB_CMDLINE_LINUX="console=ttyS0,115200n8"' | sudo tee -a /etc/default/grub
echo 'GRUB_TIMEOUT_STYLE=menu'                     | sudo tee -a /etc/default/grub
echo 'root:S0meForgottenPass'                      | sudo chpasswd       # the pw to "forget"
sudo update-grub

# 3. The reset — power-cycle, catch GRUB on serial, press `c`, and type the
#    linuxconfig-EDITED linux line verbatim (ro→rw, quiet→init=/bin/bash):
#      search --no-floppy --fs-uuid --set=root <UUID>
#      linux  /boot/vmlinuz-<ver> root=UUID=<UUID> rw init=/bin/bash console=ttyS0,115200n8
#      initrd /boot/initrd.img-<ver>
#      boot
#    → root@(none):/#  → mount -o remount,rw /  → passwd root (set "toor")  → exec /sbin/init
#    Then log in: OLD "S0meForgottenPass" → Login incorrect; NEW "toor" → uid=0(root).
```

All serial driving used [`tools/serial-drive.py`](tools/serial-drive.py) (char-by-char
40 ms send; one client per `serial.sock`); each power-cycle was
`lab-vm.sh stop --force && start` then **attach in the same command** so GRUB's 5 s
window isn't missed.

### Gotchas hit (and the fixes) — the under-the-hood lessons

- **The desktop 7z boot-loops headless; a preseed install doesn't.** The 7z's GRUB
  is built for **gfxterm** and faults with no video device (`-nodefaults`); d-i's
  `grub-installer`, run with `console=ttyS0`, sets `GRUB_TERMINAL=serial`, so the
  installed grub-pc talks to the UART. *Same distro, different boot loader config.*
- **`console=ttyS0` reaches the installer, not the installed kernel.** The gallery's
  iPXE append has `console=ttyS0` **before** d-i's `---` marker, so it configures the
  installer only. The GRUB *menu* shows on serial (grub-installer detected serial),
  but the booted kernel/getty default to tty0 → serial goes silent after GRUB. Fix:
  bake `console=ttyS0` into the installed `GRUB_CMDLINE_LINUX` (step 2).
- **No guest→host network in the installed system.** `meta-default` ships no `curl`
  and doesn't auto-bring-up `eth0`, so `curl|sudo bash` of a served pre-stage script
  fetched a **0-byte file** silently. Fix: deliver the pre-stage by **typing it at
  the serial console**, not over HTTP.
- **Serial char-drop truncated the longest line.** `echo '…' | sudo tee …` lost the
  `| sudo tee` tail (no flow control), so `console=ttyS0` silently didn't get written
  — caught only by `grep`-verifying the file afterward. Fixes: **shorter lines** and
  **`grep`-verify every edit landed** before moving on.
- **Kali locks root by default** (`passwd -S root` → `L`). The pre-stage `chpasswd`
  both unlocks and sets it, giving an OLD password that must then be rejected.

---

## Rocky rd.break — verified end-to-end on a kickstart-installed Rocky 9

The RHEL-family method (CIQ's `rd.break`) is **verified end-to-end on a real Rocky
Linux 9** (kernel `5.14.0-687.el9`, SELinux **enforcing**). The target is an
Anaconda/kickstart install from the sibling
[`../rocky-kickstart-gallery/`](../rocky-kickstart-gallery/) (`GenericCloud-Base`)
— the Rocky analogue of the Kali preseed install. Unlike Kali's desktop 7z it boots
fine on serial (the kickstart bakes `console=ttyS0`) and sets the "forgotten" root
password directly (`rootpw S0meForgottenPass`).

**Pre-stage (lab setup).** The only thing to fix is the kickstart's
`bootloader --timeout=1` (the GRUB menu flashes by): log in `root`/`S0meForgottenPass`
over serial, `GRUB_TIMEOUT=5`, **`grub2-mkconfig -o /boot/grub2/grub.cfg`** (Rocky,
not `update-grub`). No console-baking, no root-pw change.

**The reset** (driven by [`reset-demo-rocky.sh`](reset-demo-rocky.sh) with
[`tools/serial-drive.py`](tools/serial-drive.py); the `rd.break` word is appended in
the GRUB **editor** — `e`, Ctrl-n×3 to the `linux` line, Ctrl-e, ` rd.break`, Ctrl-x):

```
# → [    1.9] dracut-pre-pivot: Warning: Break before switch_root
# → Entering emergency mode. Exit the shell to continue.
# → switch_root:/#                         ← the dracut initramfs shell (real root at /sysroot, ro)
# → switch_root:/# mount -o remount,rw /sysroot
# → switch_root:/# chroot /sysroot /bin/bash -c 'echo root:toor | chpasswd && touch /.autorelabel && echo OK'
# → OK
# → switch_root:/# exit                     ← continue boot → SELinux relabels the whole fs
# → *** Warning -- SELinux targeted policy relabel is required.
# → Running: /sbin/fixfiles -T 0 restore ;  Relabeling / /boot /dev …     ← the slow, easy-to-forget step
# → localhost login: root
# → Password:  (OLD "S0meForgottenPass")  → Login incorrect      ← ✓ old rejected
# → localhost login: root
# → Password:  (NEW "toor")               → [root@localhost ~]#
# → # id  → uid=0(root) … context=unconfined_u:unconfined_r:unconfined_t:s0   ← ✓ reset + relabel confirmed
```

**PASS** — old rejected, new `uid=0`, and the **SELinux context is correct** (proof
the `/.autorelabel` did its job — skip it and login can fail even with the right
password). Verified on KVM 2026-06-11: `setup-rocky-target.sh` → `6/6 DONE`;
`reset-demo-rocky.sh` → PASS.

### Rocky gotchas (and the fixes)

- **Rocky's grub2 drops typed input on long lines over serial** — it redraws the
  whole line on every keystroke, and under that flood it loses keys (a `boot` came
  out `obot`). Fix: a tunable **`--char-delay`** on `serial-drive.py` (Rocky uses
  `0.08`, double the default), and the `rd.break` edit is an **editor-append** (one
  word) rather than retyping the long `linux`/`initrd` lines at the GRUB command line.
- **The dracut emergency shell is on serial** because the cmdline has only
  `console=ttyS0` (no `console=tty0`) — so the CIQ "remove `console=`" caveat does
  *not* apply here; keep it. The prompt is **`switch_root:/#`**.
- **`chroot /sysroot /bin/bash -c '…'`** runs the reset non-interactively (the
  initramfs has no `passwd`/`chpasswd` — that's *why* you chroot into the real root).
- **SELinux relabel takes real time** (`fixfiles … restore`) and reboots once more,
  so the demo waits `EXPECT[360] login:` after the `exit`.
- **Editor-append timing matters**: pace Ctrl-n (~0.7 s apart) and let GRUB settle
  (~2 s) after the append before Ctrl-x, or the boot races the edit.

---

## Author-run items (to confirm; chain already proven on Debian)

- **`debian-uefi.toml`** — only the firmware *path to the menu* differs (OVMF
  shows its own phase first); the edit + reset are identical.
- **`rocky.toml`** — **not author-run: VERIFIED** (see *Rocky rd.break* above).
  `rocky.toml` delegates to the kickstart gallery; the CIQ `rd.break` →
  `chroot /sysroot` → `passwd` → **`touch /.autorelabel`** chain (incl. the SELinux
  relabel) is proven on a real Rocky 9 via [`reset-demo-rocky.sh`](reset-demo-rocky.sh).
- **`kali.toml`** — **not author-run: VERIFIED** (see *Kali method* above). The
  prebuilt-7z spec is gone; `kali.toml` now delegates to the preseed gallery and
  the linuxconfig recipe (`ro`→`rw`, `quiet`→`init=/bin/bash`, `passwd` root,
  `exec /sbin/init`) is proven on a real installed Kali. The **non-root** nuance
  (Kali locks root) is handled by the pre-stage, which sets the "forgotten" pw.
- **systemd debug shell** — tty9 path needs a graphical QEMU; the serial-redirect
  adaptation (`TTYPath=/dev/ttyS0` + mask `serial-getty@ttyS0`) is verifiable here.

## Environment notes

- Host: KVM available; Debian genericcloud qcow2 (~3 GB root — no resize needed
  for this lab, unlike kdump). Each verification run = power-cycle
  (`lab-vm.sh stop --force && start`) for a deterministic boot → GRUB catch.
- Nothing here touched the host; every reset was contained to the throwaway VM.
- Throwaway lab credentials only (`S0meForgottenPass` → `toor`); never reuse on a
  real or networked machine.
