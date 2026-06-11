# RUNBOOK — reset a lost root password with `rd.break` (Rocky / RHEL family)

On dracut-based distros (Rocky, AlmaLinux, RHEL, Fedora, CentOS Stream) the
canonical recovery is **`rd.break`**: break into the **initramfs** *before* it
pivots to the real root, then `chroot` into the real root and `passwd`. This is
**method 2 of the CIQ Rocky write-up**; method 1 (`init=/bin/sh`) is covered in
[`RUNBOOK-init-shell.md`](RUNBOOK-init-shell.md). The SELinux relabel step is the
one everybody forgets — and it will lock you out if you skip it.

> Same lesson as the other methods: boot-time access to the kernel command line
> ⇒ root. See [`README.md`](README.md#mitigations) for the defenses.

VM: [`rocky.toml`](rocky.toml) → a real Rocky 9 install from the
[rocky-kickstart-gallery](../rocky-kickstart-gallery/) (variant `GenericCloud-Base`).
**STATUS: ✅ verified end-to-end** on that kickstart-installed Rocky 9 (2026-06-11,
kernel `5.14.0-687.el9`) — including the SELinux relabel (the new login shows the
correct context). Build + reset it hands-off with
[`reset-demo-rocky.sh`](reset-demo-rocky.sh), or stage a hand-walk target with
[`setup-rocky-target.sh`](setup-rocky-target.sh). Evidence in
[`MANUAL_TESTING.md`](MANUAL_TESTING.md#rocky-rdbreak--verified-end-to-end-on-a-kickstart-installed-rocky-9).

> **AlmaLinux is identical.** AlmaLinux 9 and Rocky 9 are the same RHEL 9 rebuild —
> same dracut, grub2, BLS menuentry layout, and SELinux — so every step below is
> byte-for-byte the same. The only distro difference is upstream of the reset: the
> AlmaLinux `gencloud` kickstart bakes `bootloader --timeout=0` (a *hidden* menu, vs.
> Rocky's `--timeout=1`), so the pre-stage also sets `GRUB_TIMEOUT_STYLE=menu` to
> reveal it. VM: [`almalinux.toml`](almalinux.toml) → a real AlmaLinux 9 install from
> the [almalinux-kickstart-gallery](../almalinux-kickstart-gallery/) (variant
> `gencloud`). **STATUS: ✅ verified end-to-end** (2026-06-11, kernel
> `5.14.0-687.el9`, relabel included). Build + reset it hands-off with
> [`reset-demo-almalinux.sh`](reset-demo-almalinux.sh), or stage a hand-walk target
> with [`setup-almalinux-target.sh`](setup-almalinux-target.sh).

---

## 0. Bring up the box

Build a real Rocky 9 install (Anaconda + the `GenericCloud-Base` kickstart) and
pre-stage it with one script — see [`rocky.toml`](rocky.toml) for the by-hand
gallery commands it runs:

```bash
examples/root-password-reset/setup-rocky-target.sh   # install + pre-stage, ~10-15 min
phase2-qemu-vm/lab-vm.sh console rocky-kickstart-install   # then follow this RUNBOOK
```

The kickstart already sets `console=ttyS0` (serial-ready) and `rootpw
S0meForgottenPass`; the only pre-stage is widening GRUB's `--timeout=1` to an
interruptible 5 s (**`grub2-mkconfig`**, not `update-grub` — Rocky). To watch the
whole thing run itself instead, use
[`reset-demo-rocky.sh`](reset-demo-rocky.sh).

The [serial-console gotchas in `RUNBOOK-init-shell.md`](RUNBOOK-init-shell.md#0-bring-up-the-box-and-attach-the-console)
apply here too (type slowly, use `Ctrl-n`/`Ctrl-e`, any key halts the countdown).

---

## 1. Add `rd.break` to the kernel line  *(CIQ, verbatim order)*

1. At the GRUB menu, highlight the kernel and press **`e`** to edit.
2. On the line starting with **`linux`**, add **`rd.break`** to the end.
3. Press **`Ctrl-x`** to boot.

You land in the dracut **initramfs** emergency shell (prompt `switch_root:/#` or
`(initramfs)`) — *before* the real root is pivoted in. The real root is mounted,
read-only, at **`/sysroot`**.

> **CIQ note (matters in a VM):** a `console=` directive on the boot line (e.g.
> `console=ttyS0,115200n8`) can send the shell somewhere you're not looking. If
> you don't get a prompt, remove the `console=` argument when editing in step 1.

---

## 2. Remount `/sysroot` rw, chroot, set the password  *(CIQ, verbatim)*

```bash
mount -o remount,rw /sysroot      # the real root is read-only under /sysroot
chroot /sysroot                   # now "/" is the real system
passwd root                       # set the NEW root password
touch /.autorelabel               # ← SELinux: relabel the whole fs on next boot
exit                              # leave the chroot
exit                              # leave the initramfs → continue booting
```

**Why each step:**
- **`/sysroot`, not `/`:** with `rd.break` you're in the *initramfs*; its `/` is a
  tiny RAM root. The installed system is mounted read-only at `/sysroot`.
- **`chroot /sysroot`:** so `passwd` edits the **real** `/etc/shadow`, not the
  initramfs's.
- **`touch /.autorelabel` (the load-bearing SELinux step):** when `passwd`
  rewrites `/etc/shadow` from inside the initramfs/chroot, the new file can get
  the **wrong SELinux label**. On a labeled system that can make login fail even
  with the correct password. `/.autorelabel` tells SELinux to **relabel the
  entire filesystem on the next boot** (one slow boot), fixing the context.
  *Skipping this is the #1 reason a "successful" RHEL-family reset still won't let
  you in.* (Alternative without a full relabel: after chroot,
  `load_policy -i` then `chcon -u system_u -r object_r -t shadow_t /etc/shadow`.)

---

## 3. Verify

The first boot after `/.autorelabel` runs a full relabel (`*** Relabeling …`) and
reboots once more, then:

```
login: root
Password:  <OLD password>  →  Login incorrect          # ✓ old no longer works
login: root
Password:  <NEW password>  →  # id → uid=0(root) …      # ✓ reset confirmed
```

---

## The Debian / initramfs-tools cousin: `break=`

Debian/Ubuntu (initramfs-tools, not dracut) have **no `rd.break`**. The analogue
is **`break=premount`** (or just `break`) on the kernel line, which drops you to a
`(initramfs)` shell with the real root under `/root`. In practice Debian's
initramfs shell is minimal and the **`init=/bin/bash`** method
([`RUNBOOK-init-shell.md`](RUNBOOK-init-shell.md)) is simpler and what the Debian
write-up uses — so that is Debian's primary path here.

---

## Teardown & provenance

```bash
phase4-podman/lab-podman.sh down    --lab rocky-kickstart
phase2-qemu-vm/lab-vm.sh    destroy rocky-kickstart-install --force
```

Source: **CIQ Knowledge Base**, *Reset Root Password on Rocky Linux* — archived
byte-exact in [`upstream-tutorial/`](upstream-tutorial/) (provenance + sha256
there). All rights remain with CIQ; archived for offline reference (`git rm` to
remove).
