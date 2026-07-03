# Adding a package — `debian-pxe-lab`

This lab installs Debian via the **Debian-installer (d-i) + a preseed** over PXE
— there is **no chroot**. Which packages get installed is decided at install
time by the preseed's `pkgsel/include` and `tasksel` lines. So "add a package" =
edit the preseed, re-stage it, and **reinstall** the VM (a preseed bakes the
package set in during the install; you can't `--vm-only` re-image it).

## Where packages are declared

`debian-preseed.cfg`, the package-selection block:

```text
tasksel tasksel/first                multiselect standard, ssh-server
d-i pkgsel/include                   string openssh-server sudo curl
```

`pkgsel/include` is the per-package list; `tasksel/first` selects whole tasks.
The desktop tasks are the big levers: `gnome-desktop`, `xfce-desktop`,
`kde-desktop`, `cinnamon-desktop`, `mate-desktop`, `lxqt-desktop` — each pulls a
full DE.

## Add one

1. **Edit `pkgsel/include`** in `debian-preseed.cfg` — append package name(s):
   ```text
   d-i pkgsel/include   string openssh-server sudo curl vim htop git
   ```
   or add a whole task to `tasksel/first`:
   ```text
   tasksel tasksel/first   multiselect standard, ssh-server, xfce-desktop
   ```
   For contrib/non-free packages, enable those components first:
   ```text
   d-i apt-setup/contrib            boolean true
   d-i apt-setup/non-free           boolean true
   d-i apt-setup/non-free-firmware  boolean true
   ```

2. **Re-stage** the preseed into the served directory (nginx serves `~/netboot/`):
   ```bash
   cp examples/debian-pxe-lab/debian-preseed.cfg ~/netboot/debian/
   ```

3. **Reinstall** — a preseed runs only during the install, so destroy and rebuild
   the VM (the artifact server must be up):
   ```bash
   phase4-podman/lab-podman.sh up      --config examples/debian-pxe-lab/debian-pxe-lab.toml   # if not already up
   phase2-qemu-vm/lab-vm.sh    destroy debian-pxe-install --force
   phase2-qemu-vm/lab-vm.sh    create  --config examples/debian-pxe-lab/debian-pxe-lab.toml
   phase2-qemu-vm/lab-vm.sh    start   debian-pxe-install        # walk away; reinstalls unattended
   ```

4. **Verify** after it reboots into the installed system (login `debian`/`debian`):
   ```bash
   phase2-qemu-vm/lab-vm.sh ssh debian-pxe-install -- 'dpkg -l vim htop git | grep ^ii'
   ```

## Notes

- **Already-installed VM, quick tweak?** The installed system is a normal,
  persistent Debian — you can just `… ssh debian-pxe-install -- 'sudo apt-get
  install -y <pkg>'`. But that change lives only in *that* VM; to make it part of
  the **zero-touch build**, it has to go in the preseed (steps above).
- **Late-command hook.** For anything apt can't express (dropping a config file,
  enabling a service), d-i supports `preseed/late_command` — it runs in the
  installer with `/target` mounted, e.g.:
  ```text
  d-i preseed/late_command string in-target systemctl enable ssh
  ```
- **Why no `--vm-only`.** That's a `from-chroot` thing. Here the install is the
  build, so changing the package set means re-running the install.
- A bigger `pkgsel/include` (or a desktop task) lengthens the unattended install
  — the default is deliberately lean so the lab finishes fast.

## TL;DR

```bash
# 1. add the pkg to `d-i pkgsel/include` in debian-preseed.cfg
cp examples/debian-pxe-lab/debian-preseed.cfg ~/netboot/debian/          # 2. re-stage
phase2-qemu-vm/lab-vm.sh destroy debian-pxe-install --force             # 3. reinstall
phase2-qemu-vm/lab-vm.sh create  --config examples/debian-pxe-lab/debian-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start   debian-pxe-install
phase2-qemu-vm/lab-vm.sh ssh     debian-pxe-install -- 'dpkg -l <pkg> | grep ^ii'   # 4. verify
```
