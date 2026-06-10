# RUNBOOK — reset a lost root password with `rd.break` (Rocky / RHEL family)

On dracut-based distros (Rocky, AlmaLinux, RHEL, Fedora, CentOS Stream) the
canonical recovery is **`rd.break`**: break into the **initramfs** *before* it
pivots to the real root, then `chroot` into the real root and `passwd`. This is
**method 2 of the CIQ Rocky write-up**; method 1 (`init=/bin/sh`) is covered in
[`RUNBOOK-init-shell.md`](RUNBOOK-init-shell.md). The SELinux relabel step is the
one everybody forgets — and it will lock you out if you skip it.

> Same lesson as the other methods: boot-time access to the kernel command line
> ⇒ root. See [`README.md`](README.md#mitigations) for the defenses.

VM: [`rocky.toml`](rocky.toml) (Rocky 9). **STATUS: author-run** — the reset
*chain* (root shell → remount → `passwd` → relabel → login) is verified on Debian
in this lab; the Rocky-specific `rd.break`/SELinux/`grub2-mkconfig` details below
are faithful to CIQ and to be confirmed on the Rocky VM (see
[`MANUAL_TESTING.md`](MANUAL_TESTING.md)).

---

## 0. Bring up the box

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/root-password-reset/rocky.toml
phase2-qemu-vm/lab-vm.sh start  rpr-rocky
# prestage auto-detects Rocky → grub2-mkconfig (not update-grub):
phase2-qemu-vm/lab-vm.sh ssh rpr-rocky -- 'sudo bash -s' < examples/root-password-reset/setup/prestage.sh
phase2-qemu-vm/lab-vm.sh console rpr-rocky
# reboot it (over ssh: lab-vm.sh ssh rpr-rocky -- sudo reboot)
```

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
phase2-qemu-vm/lab-vm.sh destroy rpr-rocky --force
```

Source: **CIQ Knowledge Base**, *Reset Root Password on Rocky Linux* — archived
byte-exact in [`upstream-tutorial/`](upstream-tutorial/) (provenance + sha256
there). All rights remain with CIQ; archived for offline reference (`git rm` to
remove).
