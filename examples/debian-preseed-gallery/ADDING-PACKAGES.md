# Adding a package (or a variant) — `debian-preseed-gallery`

Like the [`debian-pxe-lab`](../debian-pxe-lab/ADDING-PACKAGES.md), this lab
installs via **d-i + a preseed** — no chroot. The twist: the package set lives in
the **shared** [`base-preseed.cfg`](base-preseed.cfg), so a package added there
lands in **every** generated variant. "Add a package" = edit the base,
**regenerate**, re-select, and **reinstall**.

## Add a package (applies to all variants)

1. **Edit `pkgsel/include`** (or `tasksel/first`) in `base-preseed.cfg`:
   ```text
   d-i pkgsel/include   string openssh-server sudo curl vim htop git
   ```

2. **Regenerate** the gallery (re-stamps every variant with the new body):
   ```bash
   examples/debian-preseed-gallery/fetch-preseeds.sh
   ```

3. **Re-select + reinstall** the variant you're testing (the artifact server must
   be up):
   ```bash
   examples/debian-preseed-gallery/select-preseed.sh lvm-atomic
   phase4-podman/lab-podman.sh up      --config examples/debian-preseed-gallery/debian-preseed-gallery.toml
   phase2-qemu-vm/lab-vm.sh    destroy debian-preseed-install --force
   phase2-qemu-vm/lab-vm.sh    create  --config examples/debian-preseed-gallery/debian-preseed-gallery.toml
   phase2-qemu-vm/lab-vm.sh    start   debian-preseed-install
   ```

4. **Verify** (login `debian`/`debian`; `crypto-atomic` needs the `labcrypto`
   unlock first):
   ```bash
   phase2-qemu-vm/lab-vm.sh ssh debian-preseed-install -- 'dpkg -l vim htop git | grep ^ii'
   ```

> The `minimal` variant sets `pkgsel/run_tasksel boolean false`, so it installs
> **only** the base system + your `pkgsel/include` — packages you add there still
> appear, but no desktop/`standard` task will.

## Add a new *variant* (a new partitioning layout)

Variants are defined in `fetch-preseeds.sh`, in two places:

1. Add the name to the `ALL_VARIANTS` array.
2. Add a `case` arm in `partman_block()` emitting its `partman-auto/method` +
   `choose_recipe` (+ any extras — see how `crypto-atomic` adds the passphrase).

Then `fetch-preseeds.sh` regenerates it alongside the rest, and
`select-preseed.sh <newname>` boots it. Every variant traces back to an option
documented in [`upstream-preseed/example-preseed.txt`](upstream-preseed/README.md)
— keep it that way (add the `server` recipe, say, not an invented layout).

## Notes

- **Per-variant package differences?** The generator only swaps *partitioning*
  (and the tasksel line for `minimal`). If you truly need different packages per
  variant, add a second marker region to `base-preseed.cfg` and a swap for it in
  `gen_variant()` — but that's usually a sign you want a separate lab.
- **Late-command hook.** `d-i preseed/late_command string in-target <cmd>` runs in
  the installer with `/target` mounted — for config drops or service enables apt
  can't express. Put it in `base-preseed.cfg` to apply to all variants.

## TL;DR

```bash
# 1. edit pkgsel/include in base-preseed.cfg
examples/debian-preseed-gallery/fetch-preseeds.sh                          # 2. regenerate
examples/debian-preseed-gallery/select-preseed.sh lvm-atomic               # 3. re-select
phase2-qemu-vm/lab-vm.sh destroy debian-preseed-install --force            #    reinstall
phase2-qemu-vm/lab-vm.sh create  --config examples/debian-preseed-gallery/debian-preseed-gallery.toml
phase2-qemu-vm/lab-vm.sh start   debian-preseed-install
phase2-qemu-vm/lab-vm.sh ssh     debian-preseed-install -- 'dpkg -l <pkg> | grep ^ii'   # 4. verify
```
