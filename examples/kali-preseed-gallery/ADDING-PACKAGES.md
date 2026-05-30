# Adding a package — `kali-preseed-gallery`

Like `kali-pxe-lab`, this installs Kali via **d-i + a preseed** over PXE — **no
chroot**. The difference is *which* preseed: this lab stages the **whole upstream
catalog** of variants and lets you pick one with `select-preseed.sh`. Packages
are decided at install time by the **selected variant's** `pkgsel/include` /
`tasksel`. So "add a package" = edit that staged variant, rebuild its iPXE ROM,
and **reinstall** (a preseed bakes the set in at install time — no `--vm-only`).

## Where packages are declared

In the **staged, served copy** of the variant you're booting:

```
~/netboot/kali-preseed/<variant>        # e.g. ~/netboot/kali-preseed/xfce-default
```

Open it and find the package-selection line (upstream variants use the same d-i
keys as `kali-pxe-lab`):

```text
d-i pkgsel/include   string <packages…>
tasksel tasksel/first multiselect <tasks…>
```

> `fetch-preseeds.sh` keeps a verbatim upstream copy under
> `~/netboot/kali-preseed/raw/<variant>` and writes the lab-patched served copy
> to `~/netboot/kali-preseed/<variant>`. Edit the **served** copy (not `raw/`).

## Add one

1. **Edit the staged variant's `pkgsel/include`** — append package name(s) to the
   variant you intend to boot, e.g. for `xfce-default`:
   ```bash
   # edit ~/netboot/kali-preseed/xfce-default, e.g. its pkgsel/include line:
   # d-i pkgsel/include   string ... nmap sqlmap
   ```

2. **Rebuild the iPXE ROM for that variant** (bakes the preseed URL into the boot
   program):
   ```bash
   examples/kali-preseed-gallery/select-preseed.sh xfce-default
   ```

3. **Reinstall** — destroy + recreate + start (artifact server up):
   ```bash
   phase4-podman/lab-podman.sh up      --config examples/kali-preseed-gallery/kali-preseed-gallery.toml   # if not up
   phase2-qemu-vm/lab-vm.sh    destroy kali-preseed-install --force
   phase2-qemu-vm/lab-vm.sh    create  --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
   phase2-qemu-vm/lab-vm.sh    start   kali-preseed-install
   ```

4. **Verify** after it reboots into the installed system (login `kali`/`kali`):
   ```bash
   phase2-qemu-vm/lab-vm.sh ssh kali-preseed-install -- 'dpkg -l nmap sqlmap | grep ^ii'
   ```

## Notes

- **Re-fetch overwrites your edit.** `fetch-preseeds.sh` re-downloads and
  re-stages the served copies, so a later `fetch-preseeds.sh` run **clobbers**
  the `pkgsel/include` you edited. If you re-fetch, re-apply the edit (or keep a
  patch). The `raw/` copy is always the pristine upstream reference.
- **Edit the variant you actually boot.** `select-preseed.sh xfce-default` bakes
  in the URL of `xfce-default`; editing a different variant's file has no effect
  on that boot.
- **No `--vm-only`** — that's a `from-chroot` mechanism; here the install *is* the
  build, so a changed package set means re-running the install.

## TL;DR

```bash
# 1. add the pkg to `d-i pkgsel/include` in ~/netboot/kali-preseed/<variant>
examples/kali-preseed-gallery/select-preseed.sh <variant>            # 2. rebuild iPXE
phase2-qemu-vm/lab-vm.sh destroy kali-preseed-install --force        # 3. reinstall
phase2-qemu-vm/lab-vm.sh create  --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh start   kali-preseed-install
phase2-qemu-vm/lab-vm.sh ssh     kali-preseed-install -- 'dpkg -l <pkg> | grep ^ii'   # 4. verify
```
