# AlmaLinux PXE lab — full install boot-verify

A step-by-step manual test of the AlmaLinux zero-touch PXE install, with the exact
host-side checks that prove each stage. The boot mechanism is QEMU `pxe-install`
(BIOS): **SeaBIOS → the NIC's own iPXE option ROM → TFTP `boot.ipxe` (run directly)
→ HTTP kernel/initrd/stage2 → Anaconda → kickstart → reboot into the installed
disk.** `pxe_bootfile = "boot.ipxe"` (not the `ipxe.pxe` binary) — see
[`README.md`](README.md) §"under the hood" for why.

For the quick copy-paste version, use [`QUICKSTART.md`](QUICKSTART.md). This file is
the slower walkthrough with verification at each step.

---

## 0. Build the lab

From the repo root (see [`QUICKSTART.md`](QUICKSTART.md) for details):

```bash
examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --release 9 --arch x86_64
netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01
netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
    --kernel-path /vmlinuz --initrd-path /initrd.img \
    --append 'inst.stage2=http://10.0.2.2:8181/ inst.repo=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'
phase4-podman/lab-podman.sh up --config examples/almalinux-pxe-lab/almalinux-pxe-lab.toml
```

---

## 1. Pre-flight: confirm the artifacts + the boot script

The **#1 failure point** is an artifact that doesn't serve. All four must be `200`:

```bash
for u in vmlinuz initrd.img images/install.img ks/52-54-00-a1-9a-01.ks; do
    printf '%-32s ' "$u"; curl -sI "http://localhost:8181/$u" | head -1
done   # every line must say HTTP/1.1 200 OK
```

Confirm `boot.ipxe` is a single-line-`kernel` script with the retry loop (this is
what the NIC's iPXE runs verbatim):

```bash
cat ~/netboot/boot.ipxe
# Expect: #!ipxe / :start / dhcp || goto retry /
#         kernel http://10.0.2.2:8181/vmlinuz inst.stage2=… (ALL on ONE line) || goto retry /
#         initrd … / boot || goto retry / :retry / sleep 3 / goto start
```

> If `boot.ipxe` is missing, the boot drops to the `ipxe.pxe` binary chainload (the
> old, flaky path). Re-run `build-ipxe.sh`.

---

## 2. Create + start the VM, watching the boot chain

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/almalinux-pxe-lab/almalinux-pxe-lab.toml
# mark the nginx log so we only see THIS boot's fetches:
podman logs lab-almalinux-pxe-http 2>&1 | wc -l > /tmp/alma_mark
phase2-qemu-vm/lab-vm.sh start almalinux-pxe-install
```

Within ~15–20 s the nginx log should show the netboot chain. The key tell is the
**`iPXE/1.21.1` user-agent** on the kernel/initrd GETs — that's the NIC's *native*
ROM iPXE running `boot.ipxe`, **not** a chainloaded `iPXE/2.0.0` binary:

```bash
mark=$(cat /tmp/alma_mark)
podman logs lab-almalinux-pxe-http 2>&1 | tail -n +$((mark+1))
```

Expected sequence:

```
GET /vmlinuz             200  ...  "iPXE/1.21.1..."   ← NIC ROM ran boot.ipxe
GET /initrd.img          200  ...  "iPXE/1.21.1..."
GET /.treeinfo           200  ...  "curl/..."          ← Anaconda/dracut
GET /images/install.img  200  1264664576  "curl/..."   ← full 1.2 GB stage2, complete
GET /images/updates.img  404                           ← optional, harmless
GET /images/product.img  404                           ← optional, harmless
GET /ks/52-54-00-a1-9a-01.ks  200  "curl/..."          ← kickstart → Anaconda installing
```

The `install.img` line showing its **full** byte count (no truncation) at 4 GB RAM
is the proof the stage2 loaded into the initramfs tmpfs without the `dracut: FATAL:
No space left` cutoff.

> From the kickstart onward, Anaconda pulls **packages** from the upstream
> AlmaLinux mirror (`repo.almalinux.org`), not from your nginx — so the nginx log
> goes quiet during package install. That's expected.

---

## 3. Watch the install on the serial console (optional)

```bash
phase2-qemu-vm/lab-vm.sh console almalinux-pxe-install   # Ctrl-] to detach
```

A minimal `@core` install from a fast mirror finishes in a few minutes; larger
package sets take longer. When it's done the kickstart's `reboot` fires and the
**installed** system comes up to a getty: `localhost login:`.

---

## 4. Confirm the install completed + the loop terminated

The decisive check — the netboot fetches happened **once**; the second boot came
from the disk (so the NIC ROM was never reached again):

```bash
podman logs lab-almalinux-pxe-http 2>&1 | grep -a 'GET /vmlinuz'   # exactly ONE line
```

Log in and identify the running system (over SSH, or via the serial console with
`lab` / `lab`):

```bash
phase2-qemu-vm/lab-vm.sh ssh almalinux-pxe-install     # password: lab
cat /etc/almalinux-release      # → AlmaLinux release 9.x (e.g. 9.8 Olive Jaguar)
uname -r                        # → the INSTALLED kernel (5.14.x el9), not the installer
uptime                          # → small (just rebooted)
lsblk -no NAME,SIZE,MOUNTPOINT /dev/vda
# → vda → vda1 /boot + vda2 (LVM: almalinux-root / + almalinux-swap [SWAP])
```

If `uname -r` shows the installed el9 kernel and `lsblk` shows the
`almalinux-root`/`-swap` LVM on `/dev/vda`, the full PXE → install → reboot cycle
succeeded.

---

## 5. Tear down

```bash
phase4-podman/lab-podman.sh down    --lab almalinux-pxe
phase2-qemu-vm/lab-vm.sh    destroy almalinux-pxe-install --force
rm -f /tmp/alma_mark
# Reclaim the big artifacts: rm -rf ~/netboot/{vmlinuz,initrd.img,images,ks,ipxe.*,boot.ipxe,.treeinfo}
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| A `curl -sI` artifact check ≠ `200` | nginx volume path wrong (`$HOME` ≠ `/home/sqs`? edit the TOML), or fetch didn't finish. Fix before booting. |
| A second `iPXE 2.0.0+` banner, then "Booting from Floppy" / "No bootable device" | You're chainloading the `ipxe.pxe` **binary**. Confirm `pxe_bootfile = "boot.ipxe"` and that `~/netboot/boot.ipxe` exists (re-run `build-ipxe.sh`). |
| `console=ttyS0: command not found` in iPXE / truncated kernel args | A newline split the `kernel` line (wrapped `--append` paste). Re-run `build-ipxe.sh` (it collapses `--append` to one line) and keep `--append '…'` on a single line. |
| Install dies at dracut "No space left" | RAM too low — keep `memory = "4096M"` (or higher). |
| `install.img` fetch shows a truncated byte count or `curl 18` | stage2 streamed from a remote mirror instead of locally — confirm `inst.stage2=http://10.0.2.2:8181/` is in the `--append` and `~/netboot/images/install.img` serves `200`. |
| nginx keeps re-serving `/vmlinuz` after the install | the disk didn't become bootable — check the kickstart partitioned/bootloadered `/dev/vda` (the install target carries `bootindex=0`). |

> **Verified on KVM:** native `iPXE/1.21.1` ran `boot.ipxe` → fetched
> `vmlinuz` + `initrd.img` + the full 1.26 GB `install.img` + kickstart → Anaconda
> installed → rebooted into **AlmaLinux 9.8 (Olive Jaguar)** (`lab`/`lab`; el9
> kernel; `almalinux-root`/`-swap` LVM on `/dev/vda`; netboot fetched exactly once).
