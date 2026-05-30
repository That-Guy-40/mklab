# OffSec AWAE chroot → VM — build & verify

Verify the pipeline in two stages: a fast **smoke test** (Kali base → VM) to prove
the chroot→VM machinery, then the **full AWAE** build on top of it.

## 0. Prereqs (host)

```bash
# debootstrap + Kali keyring + the from-chroot backend's imaging tools + QEMU:
sudo apt-get install -y debootstrap kali-archive-keyring \
                        syslinux extlinux parted rsync qemu-utils qemu-system-x86
dpkg -s kali-archive-keyring >/dev/null 2>&1 && echo "keyring OK" || echo "install kali-archive-keyring"
for b in debootstrap extlinux parted rsync qemu-img qemu-system-x86_64; do
  command -v "$b" >/dev/null && echo "OK  $b" || echo "MISSING  $b"
done
```

## 1. Smoke test the pipeline (do this first)

```bash
sudo examples/offsec-awae-vm/build-vm.sh --smoke
```

You should see, in order:

1. **[1/3] chroot** — debootstrap fetch/extract of `kali-rolling` (pulls
   `kali-archive-keyring` so the chroot's apt is trusted) → `users: creating 'kali'`
   → post_commands: `apt-get update` → install `linux-image-amd64 systemd-sysv
   openssh-server` → write `10-dhcp.network` → `systemctl enable …` → set root pw.
2. **[2/3] VM image** — `from-chroot` makes a qcow2: partition, `mkfs.ext4`,
   `rsync` the tree in, install MBR + extlinux pointing at `/boot/vmlinuz*`.
3. **[3/3] start** — QEMU boots headless.

Then attach the console and log in:

```bash
sudo phase2-qemu-vm/lab-vm.sh console offsec-awae-smoke-vm   # quit: Ctrl-A X
# extlinux → kernel boot → systemd → login:  kali / kali
```

Inside the VM, confirm it's a real booted Kali with networking:

```bash
cat /etc/os-release | grep -i kali     # PRETTY_NAME=Kali GNU/Linux …
ip -br a                               # an en*/eth* NIC with a DHCP address
systemctl is-active ssh                # active
```

**If the smoke VM boots and logs in, the pipeline is good.** Tear it down before
the full build (or keep it — different names):

```bash
sudo phase2-qemu-vm/lab-vm.sh destroy offsec-awae-smoke-vm
sudo phase1-chroot/lab-chroot.sh destroy offsec-awae-smoke --force
```

## 2. Full AWAE build

```bash
sudo examples/offsec-awae-vm/build-vm.sh           # build + start
# or: sudo examples/offsec-awae-vm/build-vm.sh --no-start
```

Same three phases, but step [1/3] also enables `contrib non-free non-free-firmware`
and installs `offsec-awae code-oss gobuster jd-gui` — **several GB, takes a while.**

Verify the toolset in the chroot before/without booting:

```bash
C=offsec-awae
phase1-chroot/lab-chroot.sh enter $C -- dpkg -l offsec-awae code-oss gobuster jd-gui | grep ^ii
phase1-chroot/lab-chroot.sh enter $C -- su - kali -c 'whoami; gobuster version'
```

…or in the booted VM (`lab-vm console offsec-awae-vm`, login kali/kali):

```bash
gobuster version
which code-oss jd-gui          # present; GUI apps — need X (see README "Getting the desktop")
```

## 3. Tear down

```bash
sudo phase2-qemu-vm/lab-vm.sh   destroy offsec-awae-vm
sudo phase1-chroot/lab-chroot.sh destroy offsec-awae --force   # removes /var/lib/lab-create/chroots/offsec-awae
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| chroot apt: `OpenPGP … Missing key …` | chroot lacks the Kali key — it's in `include`; rebuild, or `apt-get install --reinstall kali-archive-keyring`. |
| `Package 'offsec-awae'/'…' has no installation candidate` | the `sed` enabling `contrib non-free non-free-firmware` must run before the install (it's in the TOML). |
| heavy install: `… not installable` (transient skew) | `sudo lab-chroot.sh enter offsec-awae -- apt-get full-upgrade -y`, then re-run install. Steps [1/3].2-3 already leave a bootable base, so the VM still builds. |
| `lab-vm create` fails on `extlinux`/`losetup`/`parted` | missing host tools or not root — install (§0) and run under `sudo`. from-chroot is x86_64 BIOS only. |
| VM lands at a **UEFI Shell** (`Shell>`) | MBR/BIOS disk booted under UEFI — the `[[vm]]` spec needs `firmware = "bios"` (set now). `sudo lab-vm.sh destroy <vm>` then re-`create` (the manifest stores firmware at create time). |
| **dracut emergency shell** / "root account is locked" | host-only dracut initramfs can't mount the virtio root (that locked root is the *initramfs's*). The TOML forces `hostonly=no` + virtio — **rebuild the chroot**, not just the VM. Confirm with `sudo chroot <chroot> lsinitrd /boot/initrd.img-* \| grep virtio_pci`. |
| `console` says "no VM" after a `sudo` build | run it as **root** too (lab-vm's state dir is EUID-dependent). VMs are addressed by name, so `sudo lab-vm.sh console <name>` works even if `sudo lab-vm.sh list` shows nothing. |
| serial console blank after start | wait ~20s; the chroot enables `serial-getty@ttyS0` and lab-vm sets `console=ttyS0`. |
| `disk_size` too small (`No space left` during rsync) | the qcow2 must exceed the installed chroot; bump `[[vm]].disk_size` (full lab defaults to 24G). |
| SSH refused | wait for DHCP; check `ip a` on the console. systemd-networkd matches `en*`/`eth*`. |

> **Verification status:** pipeline authored against `lab-vm`'s `from-chroot`
> backend (the same one `examples/vm-from-chroot-debian.toml` uses) adapted to a
> Kali chroot. Run `--smoke` to confirm the chroot→VM boot on your host, then the
> full AWAE build. (Both configs parse; `vm.chroot` is wired to `chroot.target`.)
