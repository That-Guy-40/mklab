# Rocky kickstart gallery — boot-verify walkthrough

Manual test of the gallery: stage the upstream catalog, pick a variant, and watch
it install zero-touch in a QEMU VM, with the host-side checks that prove each
stage. The boot mechanism is QEMU `pxe-install` (BIOS): **SeaBIOS → the NIC's own
iPXE option ROM → TFTP `boot.ipxe` (run directly) → HTTP kernel/initrd/stage2 →
Anaconda → kickstart → reboot into the installed disk.**

The surface unique to this gallery (vs. the rocky-pxe-lab) is the **catalog fetch
+ patch** and the **variant selector**; those are checked first.

---

## 0. Build the lab

From the repo root:

```bash
# installer images (reused from rocky-pxe-lab)
examples/rocky-pxe-lab/fetch-rocky-installer.sh --release 9 --arch x86_64
# the whole kickstart catalog
examples/rocky-kickstart-gallery/fetch-kickstarts.sh
# bake a variant into boot.ipxe
examples/rocky-kickstart-gallery/select-kickstart.sh GenericCloud-Base
# serve
phase4-podman/lab-podman.sh up --config examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml
```

---

## 1. Verify the fetch + patch

```bash
D=~/netboot/rocky-kickstart
ls "$D"/*.ks | wc -l            # ~34 patched, served copies
ls "$D"/raw/*.ks | wc -l        # same count, verbatim upstream

# The key patch: served copy REBOOTs; raw copy still SHUTS DOWN.
grep -nE '^(reboot|shutdown)$' "$D/Rocky-9-GenericCloud-Base.ks"        # → reboot
grep -nE '^(reboot|shutdown)$' "$D/raw/Rocky-9-GenericCloud-Base.ks"    # → shutdown

# No served copy should still power off, and none should reference /dev/sda:
grep -lE '^(shutdown|poweroff|halt)$' "$D"/*.ks   # → (no output)
grep -l '/dev/sda' "$D"/*.ks                       # → (no output)

# Root unlock (patch #3): served copy sets a plaintext password; raw locks root.
grep -nE '^rootpw' "$D/Rocky-9-GenericCloud-Base.ks"      # → rootpw --plaintext lab
grep -nE '^rootpw' "$D/raw/Rocky-9-GenericCloud-Base.ks"  # → …--lock…/locked
grep -lE 'passwd -[ld] root' "$D"/*.ks                     # → (no output: %post re-lock stripped)
```

> Container variants (`Rocky-9-Container-*`) have no bootloader and won't boot as
> a VM — `select-kickstart.sh` warns if you pick one.

## 2. Verify the served artifacts (the #1 failure point)

```bash
for u in vmlinuz initrd.img images/install.img \
         rocky-kickstart/Rocky-9-GenericCloud-Base.ks boot.ipxe; do
    printf '%-46s ' "$u"; curl -sI "http://localhost:8181/$u" | head -1
done   # every line must say HTTP/1.1 200 OK

# boot.ipxe should bake the chosen kickstart + BOTH repos onto ONE kernel line:
grep -o 'inst.ks=[^ ]*'      ~/netboot/boot.ipxe   # → .../rocky-kickstart/Rocky-9-GenericCloud-Base.ks
grep -o 'inst.addrepo=[^ ]*' ~/netboot/boot.ipxe   # → AppStream,.../AppStream/...
```

## 3. Boot the VM and watch the netboot chain

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml
podman logs lab-rocky-kickstart-http 2>&1 | wc -l > /tmp/rkg_mark
phase2-qemu-vm/lab-vm.sh start rocky-kickstart-install

# within ~20 s, the nginx log shows the chain (note iPXE/1.21.1 = native NIC ROM):
mark=$(cat /tmp/rkg_mark); podman logs lab-rocky-kickstart-http 2>&1 | tail -n +$((mark+1))
```

Expected:

```
GET /vmlinuz             200  iPXE/1.21.1   ← NIC ROM ran boot.ipxe (not a 2.0.0 chainload)
GET /initrd.img          200  iPXE/1.21.1
GET /.treeinfo           200  curl          ← Anaconda/dracut
GET /images/install.img  200  1225621504  curl   ← full stage2, complete (no 814 MB cutoff @ 4 GB RAM)
GET /images/updates.img  404                ← optional, harmless
GET /images/product.img  404                ← optional, harmless
GET /rocky-kickstart/Rocky-9-GenericCloud-Base.ks  200  curl   ← THE gallery kickstart
```

From the kickstart onward, Anaconda pulls packages from the upstream mirror
(BaseOS + AppStream), not nginx — so the nginx log goes quiet during install.

## 4. Confirm install + reboot

```bash
phase2-qemu-vm/lab-vm.sh console rocky-kickstart-install   # Ctrl-] to detach
```

When the kickstart's (patched) `reboot` fires, the installed system comes up to a
getty: `localhost login:`. The decisive host-side check — netboot fetched once →
the disk booted → loop terminated:

```bash
podman logs lab-rocky-kickstart-http 2>&1 | grep -a 'GET /vmlinuz'   # exactly ONE line
```

Log in on the serial console with **`root` / `lab`** (the gallery unlocks root by
default — patch #3) and confirm the installed system:

```bash
phase2-qemu-vm/lab-vm.sh console rocky-kickstart-install   # login: root / lab
#   cat /etc/rocky-release ; uname -r ; lsblk -no NAME,SIZE,MOUNTPOINT /dev/vda
```

(If you staged with `--no-unlock-root`, root stays locked — you'll reach the
prompt but need a `Vagrant-*` variant or a cloud-init ssh key to get in.)

## 5. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab rocky-kickstart
phase2-qemu-vm/lab-vm.sh    destroy rocky-kickstart-install --force
rm -f /tmp/rkg_mark
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| An artifact ≠ `200` | nginx volume path wrong (`$HOME` ≠ `/home/sqs`? edit the TOML), or a fetch step didn't finish. |
| A second `iPXE 2.0.0+` banner then "No bootable device" | `pxe_bootfile` points at the `ipxe.pxe` binary. Set it to `boot.ipxe`; ensure `~/netboot/boot.ipxe` exists (re-run `select-kickstart.sh`). |
| Anaconda: "no package / nothing provides …" | AppStream missing — confirm `inst.addrepo=AppStream,…` is in `boot.ipxe` (re-run `select-kickstart.sh`). |
| Install dies at dracut "No space left" | RAM too low — keep `memory = "4096M"`. |
| VM powers OFF after install instead of rebooting | You staged with `--verbatim` (upstream `shutdown`). Re-fetch without `--verbatim`, rebuild, `destroy`+`create`. |
| Picked a `Container-*` variant → never boots | Those are container rootfs kickstarts (no bootloader). Pick a disk-installing variant. |

> **Verified on KVM:** `GenericCloud-Base` — native `iPXE/1.21.1` ran `boot.ipxe`
> → `vmlinuz`+`initrd.img`+full 1.2 GB `install.img`+the patched kickstart → `@core`
> installed from BaseOS+AppStream → rebooted into the installed system → **`root` /
> `lab` logged in** on the console (Rocky Linux 9.8), confirming both the
> `shutdown`→`reboot` and unlock-root patches.
