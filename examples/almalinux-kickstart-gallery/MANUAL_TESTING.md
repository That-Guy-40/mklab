# AlmaLinux kickstart gallery — boot-verify walkthrough

Manual test of the gallery: stage the upstream catalog, pick a variant, and watch
it install zero-touch in a QEMU VM, with the host-side checks that prove each
stage. The boot mechanism is QEMU `pxe-install` (BIOS): **SeaBIOS → the NIC's own
iPXE option ROM → TFTP `boot.ipxe` (run directly) → HTTP kernel/initrd/stage2 →
Anaconda → kickstart → reboot into the installed disk.**

The surface unique to this gallery (vs. the almalinux-pxe-lab) is the **catalog
fetch + patch** and the **variant selector**; those are checked first.

---

## 0. Build the lab

From the repo root:

```bash
# installer images (reused from almalinux-pxe-lab; verified against .treeinfo)
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --release 9 --arch x86_64
# the whole kickstart catalog
examples/almalinux-kickstart-gallery/fetch-kickstarts.sh
# bake a variant into boot.ipxe
examples/almalinux-kickstart-gallery/select-kickstart.sh gencloud
# serve
phase4-podman/lab-podman.sh up --config examples/almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml
```

---

## 1. Verify the fetch + patch

```bash
D=~/netboot/almalinux-kickstart
ls "$D"/*.ks | wc -l            # 5 patched, served copies (gencloud/oci/gcp/azure/vagrant)
ls "$D"/raw/*.ks | wc -l        # same count, verbatim upstream

# The LOAD-BEARING patch: served copy partitions /dev/vda; raw copy targets /dev/sda.
grep -nE 'parted .*-- mklabel|onpart=' "$D/almalinux-9.gencloud-x86_64.ks"       # → /dev/vda, onpart=vdaN
grep -nE 'parted .*-- mklabel|onpart=' "$D/raw/almalinux-9.gencloud-x86_64.ks"   # → /dev/sda, onpart=sdaN

# Fail-closed guarantee: NO served copy may still reference sda, or power off:
grep -lE '/dev/sda|onpart=sda' "$D"/*.ks            # → (no output)
grep -lE '^(shutdown|poweroff|halt)$' "$D"/*.ks     # → (no output)

# Terminal action: served copy reboots (no --eject); raw has reboot --eject.
grep -nE '^reboot' "$D/almalinux-9.gencloud-x86_64.ks"        # → reboot
grep -nE 'reboot'  "$D/raw/almalinux-9.gencloud-x86_64.ks"    # → reboot --eject

# Root pw (patch #3): served copy normalises to 'lab'; raw is upstream 'almalinux'.
grep -nE '^rootpw' "$D/almalinux-9.gencloud-x86_64.ks"        # → rootpw --plaintext lab
grep -nE '^rootpw' "$D/raw/almalinux-9.gencloud-x86_64.ks"    # → rootpw --plaintext almalinux
```

> Every variant here is a disk image with a bootloader, so all five boot as a VM.
> (Unlike Rocky's catalog, there are no container-rootfs kickstarts to avoid.)

## 2. Verify the served artifacts (the #1 failure point)

```bash
for u in vmlinuz initrd.img images/install.img \
         almalinux-kickstart/almalinux-9.gencloud-x86_64.ks boot.ipxe; do
    printf '%-52s ' "$u"; curl -sI "http://localhost:8181/$u" | head -1
done   # every line must say HTTP/1.1 200 OK

# install.img must be the AlmaLinux stage2 — verify it against .treeinfo, not just
# that it 200s.  (See the trap in Troubleshooting: a same-size leftover can shadow it.)
want=$(awk '$1=="images/install.img"{sub(/^sha256:/,"",$3);print $3}' ~/netboot/.treeinfo)
have=$(sha256sum ~/netboot/images/install.img | cut -d' ' -f1)
[ "$want" = "$have" ] && echo "install.img OK ($have)" || echo "install.img MISMATCH want=$want have=$have"

# boot.ipxe should bake the chosen kickstart + the AppStream addrepo onto ONE line,
# and NOT carry inst.repo (the kickstart has its own `url --url …BaseOS…`):
grep -o 'inst.ks=[^ ]*'      ~/netboot/boot.ipxe   # → .../almalinux-kickstart/almalinux-9.gencloud-x86_64.ks
grep -o 'inst.addrepo=[^ ]*' ~/netboot/boot.ipxe   # → AppStream,.../AppStream/.../os/
grep -c 'inst.repo='         ~/netboot/boot.ipxe   # → 0
```

## 3. Boot the VM and watch the netboot chain

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml
podman logs lab-almalinux-kickstart-http 2>&1 | wc -l > /tmp/akg_mark
phase2-qemu-vm/lab-vm.sh start almalinux-kickstart-install

# within ~20 s, the nginx log shows the chain (note iPXE/1.21.1 = native NIC ROM):
mark=$(cat /tmp/akg_mark); podman logs lab-almalinux-kickstart-http 2>&1 | tail -n +$((mark+1))
```

Expected (analogous to the rocky gallery):

```
GET /vmlinuz             200  iPXE/1.21.1   ← NIC ROM ran boot.ipxe (not a 2.0.0 chainload)
GET /initrd.img          200  iPXE/1.21.1
GET /.treeinfo           200  curl          ← Anaconda/dracut
GET /images/install.img  200  1264664576  curl   ← full AlmaLinux stage2, complete
GET /almalinux-kickstart/almalinux-9.gencloud-x86_64.ks  200  curl   ← THE gallery kickstart
```

From the kickstart onward, Anaconda pulls packages from the upstream mirror
(the kickstart's BaseOS `url` + the AppStream addrepo), not nginx — so the nginx
log goes quiet during install.

## 4. Confirm install + reboot

```bash
phase2-qemu-vm/lab-vm.sh console almalinux-kickstart-install   # Ctrl-] to detach
```

Sanity that you booted the right distro — early in the serial log Anaconda prints
its product banner; it must say **AlmaLinux**, not Rocky:

```
anaconda 34.25.7.14-1.el9.alma.1 for AlmaLinux 9.8 started.
```

When the kickstart's (patched) `reboot` fires, the installed system comes up to a
getty: `localhost login:`. The decisive host-side check — netboot fetched once →
the disk booted → loop terminated:

```bash
podman logs lab-almalinux-kickstart-http 2>&1 | grep -a 'GET /vmlinuz'   # exactly ONE line
```

Log in on the serial console with **`root` / `lab`** (the gallery normalises root
by default — patch #3) and confirm the installed system:

```bash
phase2-qemu-vm/lab-vm.sh console almalinux-kickstart-install   # login: root / lab
#   cat /etc/almalinux-release ; uname -r ; lsblk -no NAME,SIZE,MOUNTPOINT /dev/vda
```

(If you staged with `--no-unlock-root`, root keeps the upstream `almalinux`
password — you'll log in with `root` / `almalinux` instead.)

## 5. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab almalinux-kickstart
phase2-qemu-vm/lab-vm.sh    destroy almalinux-kickstart-install --force
rm -f /tmp/akg_mark
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| An artifact ≠ `200` | nginx volume path wrong (`$HOME` ≠ `/home/sqs`? edit the TOML), or a fetch step didn't finish. |
| **Anaconda banner says "Rocky Linux", or the Storage module crashes (`Modules.Storage … exited with status 1`)** | The served `install.img` is the **wrong distro's stage2** — usually a same-size leftover from another lab in `~/netboot/images/`. Verify it against `.treeinfo` (step 2). Re-run `fetch-almalinux-installer.sh`; the fixed script downloads via a `.part` sidecar + atomic move, so a wrong **same-size** file can't survive the checksum gate (the old `curl -C -` resume saw a full-size file and appended nothing, leaving the stale bytes forever). |
| `install.img` checksum mismatch even after re-fetch | The mirror may be **mid-publish** (`.treeinfo` updated ahead of the file sync). The fixed fetch retries once fresh, then aborts; wait a few minutes, or pass a different `--mirror`. |
| Install dies in `%pre` ("/dev/sda: unrecognised disk label") | You staged with `--verbatim` (the unpatched Packer `/dev/sda`). Re-fetch without `--verbatim`, rebuild, `destroy`+`create`. |
| A second `iPXE 2.0.0+` banner then "No bootable device" | `pxe_bootfile` points at the `ipxe.pxe` binary. Set it to `boot.ipxe`; ensure `~/netboot/boot.ipxe` exists (re-run `select-kickstart.sh`). |
| Anaconda: "no package / nothing provides …" | AppStream missing — confirm `inst.addrepo=AppStream,…` is in `boot.ipxe` (re-run `select-kickstart.sh`). |
| Install dies at dracut "No space left" | RAM too low — keep `memory = "4096M"`. |
| VM powers OFF after install instead of rebooting | You staged with `--verbatim` (upstream `reboot --eject` may leave the CD ejected/odd). Re-fetch without `--verbatim`, rebuild, `destroy`+`create`. |

> **Verified on KVM:** `gencloud` — native iPXE ran `boot.ipxe` →
> `vmlinuz`+`initrd.img`+full 1.2 GB `install.img` (sha256-verified AlmaLinux
> stage2) + the patched kickstart → `anaconda … for AlmaLinux 9.8` installed
> `@core` from BaseOS+AppStream onto the patched `/dev/vda` → rebooted into the
> installed system → **`root` / `lab` logged in** on the console (AlmaLinux 9.8),
> confirming the `/dev/sda`→`/dev/vda`, `reboot --eject`→`reboot`, and root-pw
> patches.
