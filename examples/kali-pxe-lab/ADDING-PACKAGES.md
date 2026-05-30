# Adding a package — `kali-pxe-lab`

This lab installs Kali via the **Debian-installer (d-i) + a preseed** over PXE —
there is **no chroot**. Which packages get installed is decided at install time
by the preseed's `pkgsel/include` and `tasksel` lines. So "add a package" =
edit the preseed, re-stage it, and **reinstall** the VM (a preseed bakes the
package set in during the install; you can't `--vm-only` re-image it).

## Where packages are declared

`kali-preseed.cfg`, the package-selection block:

```text
tasksel tasksel/first                multiselect standard
d-i pkgsel/include                   string openssh-server sudo curl
```

`pkgsel/include` is the per-package list; `tasksel/first` selects whole tasks.
For a real Kali toolset, the upstream metapackages are the big levers:
`kali-linux-headless` (CLI tools, no GUI) or `kali-linux-default` (classic
toolset + XFCE) — both pull GBs.

## Add one

1. **Edit `pkgsel/include`** in `kali-preseed.cfg` — append package name(s):
   ```text
   d-i pkgsel/include   string openssh-server sudo curl nmap sqlmap
   ```
   (or swap in a metapackage:
   `d-i pkgsel/include   string openssh-server sudo curl kali-linux-headless`).
   `contrib`/`non-free` are already enabled in this preseed
   (`apt-setup/contrib` + `apt-setup/non-free` are `true`), so non-free tools
   like `nmap` resolve.

2. **Re-stage** the preseed into the served directory (nginx serves `~/netboot/`):
   ```bash
   cp examples/kali-pxe-lab/kali-preseed.cfg ~/netboot/kali/
   ```

3. **Reinstall** — a preseed runs only during the install, so destroy and rebuild
   the VM (the artifact server must be up):
   ```bash
   phase4-podman/lab-podman.sh up      --config examples/kali-pxe-lab/kali-pxe-lab.toml   # if not already up
   phase2-qemu-vm/lab-vm.sh    destroy kali-pxe-install --force
   phase2-qemu-vm/lab-vm.sh    create  --config examples/kali-pxe-lab/kali-pxe-lab.toml
   phase2-qemu-vm/lab-vm.sh    start   kali-pxe-install        # walk away; reinstalls unattended
   ```

4. **Verify** after it reboots into the installed system (login `kali`/`kali`):
   ```bash
   phase2-qemu-vm/lab-vm.sh ssh kali-pxe-install -- 'dpkg -l nmap sqlmap | grep ^ii'
   ```

## Notes

- **Already-installed VM, quick tweak?** The installed system is a normal,
  persistent Kali — you can just `… ssh kali-pxe-install -- 'sudo apt-get install
  -y <pkg>'`. But that change lives only in *that* VM; to make it part of the
  **zero-touch build**, it has to go in the preseed (steps above).
- **Why no `--vm-only`.** That's a `from-chroot` thing. Here the install is the
  build, so changing the package set means re-running the install.
- A bigger `pkgsel/include` lengthens the unattended install (more apt work) —
  the default is deliberately lean so the lab finishes fast.

## TL;DR

```bash
# 1. add the pkg to `d-i pkgsel/include` in kali-preseed.cfg
cp examples/kali-pxe-lab/kali-preseed.cfg ~/netboot/kali/          # 2. re-stage
phase2-qemu-vm/lab-vm.sh destroy kali-pxe-install --force         # 3. reinstall
phase2-qemu-vm/lab-vm.sh create  --config examples/kali-pxe-lab/kali-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start   kali-pxe-install
phase2-qemu-vm/lab-vm.sh ssh     kali-pxe-install -- 'dpkg -l <pkg> | grep ^ii'   # 4. verify
```
