# Adding a package (the Hands-Off way) — `debian-hands-off-install`

Unlike the other Debian labs, you don't edit *one* preseed here — you either
select a **class** on the boot line or drop a fragment into the lab **`local/`
overlay**. Both are the framework's intended extension points.

## Option A — select an existing class (no file edits)

The framework ships many classes; pick them on the iPXE boot line via
`auto-install/classes=` (semicolon-separated), then rebuild iPXE + reinstall:

```bash
# e.g. add a desktop + a UK locale to the atomic partitioning:
netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
    --kernel-path /debian/linux --initrd-path /debian/initrd.gz \
    --append 'auto=true priority=critical preseed/url=http://10.0.2.2:8181/hands-off/trixie/preseed.cfg auto-install/classes=partition/atomic;desktop;loc/gb hands-off/checksigs=false DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---'
phase2-qemu-vm/lab-vm.sh destroy debian-hands-off-install --force
phase2-qemu-vm/lab-vm.sh create  --config examples/debian-hands-off-install/debian-hands-off-lab.toml
phase2-qemu-vm/lab-vm.sh start   debian-hands-off-install
```

Browse the available classes in the checkout: `ls ~/hands-off-src/preseed/classes/`
(and their `preseed` fragments).

## Option B — add packages via the lab `local/` overlay

For packages that aren't a whole class, add a `pkgsel/include` to the overlay's
`local/preseed`, then re-stage:

1. Edit [`lab-overlay/local/preseed`](lab-overlay/local/preseed) — append:
   ```text
   d-i pkgsel/include string openssh-server sudo curl vim htop git
   ```
   (The framework default already installs openssh-server + friends; this adds to
   the assembled set.)

2. **Re-stage** (regenerates + re-signs, or `--no-sign`):
   ```bash
   examples/debian-hands-off-install/setup-hands-off.sh            # signed
   #  or: setup-hands-off.sh --no-sign
   ```
   Re-staging is what makes the new `local/preseed` part of the signed `MD5SUMS`
   (signed mode) — editing the served copy by hand would fail the checksum.

3. **Reinstall**:
   ```bash
   phase2-qemu-vm/lab-vm.sh destroy debian-hands-off-install --force
   phase2-qemu-vm/lab-vm.sh create  --config examples/debian-hands-off-install/debian-hands-off-lab.toml
   phase2-qemu-vm/lab-vm.sh start   debian-hands-off-install
   ```

4. **Verify** (login `debian`/`debian`):
   ```bash
   phase2-qemu-vm/lab-vm.sh ssh debian-hands-off-install -- 'dpkg -l vim htop git | grep ^ii'
   ```

## Option C — write your own class

The real Hands-Off idiom: add a class dir under the overlay (`local/<name>/` with
a `filter` + `preseed`), select it with `auto-install/classes=<name>`, re-stage.
See the upstream `preseed/classes/` for the pattern (a `filter` decides activation;
a `preseed` fragment is what gets composed in) and `preseed/local/README` for the
site-local layout.

## Notes

- **Why re-stage, not edit the served copy?** In signed mode the served
  `MD5SUMS` must cover every file; `setup-hands-off.sh` regenerates + re-signs it.
  Hand-editing `~/netboot/hands-off/trixie/…` desyncs the checksums and the
  install aborts at the gpgv/checksum step.
- **A class vs. `pkgsel/include`.** A class is reusable across a fleet and can
  carry scripts/recipes, not just packages — prefer it for anything you'd reuse.
