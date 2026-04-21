# Phase 2 — Manual Testing Walkthrough

A copy-pasteable, step-by-step exercise of `lab-vm.sh`. Run top-to-bottom on
a Debian / Ubuntu host with hardware virtualization enabled.

> **Set up:**
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> alias lv='phase2-qemu-vm/lab-vm.sh'        # no sudo: VMs run as your user
> ```

## 0. Preflight

```bash
sudo apt-get update
sudo apt-get install -y \
    jq curl socat genisoimage \
    qemu-system-x86 qemu-system-arm qemu-system-misc qemu-utils \
    ovmf qemu-efi-aarch64 u-boot-qemu opensbi \
    yq                       # mikefarah/yq for TOML
sudo usermod -aG kvm "$USER"
# log out and back in, or:  newgrp kvm
ls -l /dev/kvm                # should be crw-rw---- root kvm; you should be in kvm
```

> `sudo` is assumed already present on the host. **Inside the cloud-image VMs**
> sudo IS pre-installed (cloud-init relies on it for the `lab` user's NOPASSWD
> setup). `file` is not pulled in by these steps and is not used by the Phase 2
> scripts or tests.

Verify the script:

```bash
lv version             # → "lab-vm.sh 0.1.0"
lv help                # → full usage
lv list                # → empty header line
```

## 1. Validation guardrails (no QEMU launched)

Each of these should print a clear `[error]` and exit non-zero:

```bash
lv create --name x --backend bogus --arch x86_64
lv create --name x --arch m68k --distro debian --suite bookworm
lv create --name x --backend kernel+initrd --arch x86_64 \
          --kernel /tmp/no --initrd /tmp/no
lv create --name x --backend from-chroot --arch x86_64
lv create --name x --backend disk-image --arch x86_64
```

You can mechanise these with the test script:

```bash
phase2-qemu-vm/tests/test-validation.sh
phase2-qemu-vm/tests/test-arch-table.sh
```

## 2. Native x86_64 Debian VM (KVM, full UEFI)

The first run downloads the Debian cloud image (~350 MB, cached afterward).
End-to-end takes 2–4 minutes including cloud-init.

```bash
lv create --name deb1 --distro debian --suite bookworm --arch x86_64 \
          --memory 1G --cpus 1
```

**Expect:**
- `creating overlay qcow2: ... (backed by ...debian-bookworm-x86_64.qcow2)`
- `generating cloud-init seed iso`
- `accel: kvm`
- `── VM 'deb1' provisioned (not started; run: lab-vm.sh start deb1) ──`

```bash
lv list                # → deb1, stopped
lv start deb1
```

**Expect:**
- `starting deb1 (accel=kvm arch=x86_64 mem=1G cpus=1)`
- `deb1 running (pid NNNN)`
- `ssh:     ssh -p 2222 lab@127.0.0.1`
- `console: lab-vm.sh console deb1`

**Watch the console come up (Ctrl-] to detach):**

```bash
lv console deb1
```

You'll see Linux kernel boot, then cloud-init initializing the user, then a
login prompt for `deb1 login:`. Detach with `Ctrl-]`.

**SSH in:**

```bash
lv ssh deb1
# inside:
sudo apt-get update
sudo apt-get install -y htop
exit
```

Or non-interactive:

```bash
lv ssh deb1 -- 'uname -a; cat /etc/os-release'
```

**Stop gracefully** (sends `system_powerdown` via QMP, waits up to 30 s):

```bash
lv stop deb1
lv list                # → deb1, stopped
```

**Restart the same VM** (state is preserved in the qcow2 overlay):

```bash
lv start deb1
lv ssh   deb1 -- 'which htop'   # → /usr/bin/htop  (survived reboot)
lv stop  deb1
```

**Destroy:**

```bash
lv destroy deb1                # answer y
lv list                        # → empty
```

## 3. Foreign-arch aarch64 VM (TCG, AAVMF)

Slow (TCG emulation) but works on any host. ~5–10 min to first SSH.

```bash
lv create --name arm1 --distro debian --suite bookworm --arch aarch64 \
          --memory 1G --cpus 1
lv start arm1
lv console arm1                # watch the boot; Ctrl-] to detach when bored
```

**Verify the guest really is aarch64:**

```bash
lv ssh arm1 -- uname -m        # → aarch64
```

```bash
lv stop arm1
lv destroy arm1
```

## 4. microvm with Alpine (fastest boot path)

```bash
lv create --name alp1 --distro alpine --suite 3.19 --arch x86_64 \
          --microvm --memory 256M --cpus 1
lv start alp1
```

Boot should be measurably faster (sub-second after image warm-up). SSH
availability still depends on cloud-init finishing.

```bash
lv ssh alp1 -- 'cat /etc/alpine-release'
lv destroy alp1 --force
```

## 5. TOML config equivalence

Same VM, two ways:

```bash
# CLI:
lv create --name deb-cli --distro debian --suite bookworm --arch x86_64 \
          --memory 1G --cpus 1 --ssh-port 2245
lv list

# TOML:
cat > /tmp/deb-cfg.toml <<EOF
[[vm]]
name     = "deb-cfg"
backend  = "disk-image"
distro   = "debian"
suite    = "bookworm"
arch     = "x86_64"
memory   = "1G"
cpus     = 1
ssh_port = 2246
EOF
lv create --config /tmp/deb-cfg.toml
lv list                        # → both deb-cli and deb-cfg

lv destroy deb-cli --force
lv destroy deb-cfg --force
rm -f /tmp/deb-cfg.toml
```

## 6. Direct kernel boot (`kernel+initrd`)

Boot the host's kernel inside a VM with no disk image. This is the
microvm-style fast iteration loop.

```bash
lv create --name kboot --backend kernel+initrd --arch x86_64 \
          --memory 512M --cpus 1 \
          --kernel /boot/vmlinuz-$(uname -r) \
          --initrd /boot/initrd.img-$(uname -r) \
          --append "console=ttyS0,115200 root=/dev/ram0 rdinit=/bin/sh"

lv start kboot
lv console kboot               # you should see kernel boot to a shell
# Ctrl-] to detach
lv stop kboot --force          # no init system to powerdown gracefully
lv destroy kboot --force
```

**Expect:** kernel and initrd boot under QEMU, console shows kernel logs and
drops to a shell prompt. SSH won't work in this minimal setup (no sshd in
the initrd).

## 7. Lifecycle / failure paths

### Already-running guard

```bash
lv create --name dup --distro debian --suite bookworm --arch x86_64
lv start dup
lv start dup       # → "dup is already running (pid NNNN)" (no-op)
lv stop  dup
lv destroy dup --force
```

### Already-exists guard

```bash
lv create --name dup --distro debian --suite bookworm --arch x86_64
lv create --name dup --distro debian --suite bookworm --arch x86_64
# → [error] VM 'dup' already exists.  Destroy it first
lv destroy dup --force
```

### Force-stop a stuck VM

If a guest hangs and `system_powerdown` doesn't take, the script falls back
to SIGTERM, then SIGKILL. To skip QMP entirely:

```bash
lv stop deb1 --force           # SIGTERM → SIGKILL escalation
```

### `--keep-disk` on destroy

Preserves the qcow2 in `${LAB_STATE_DIR}/orphaned-disks/` for forensics:

```bash
lv create --name probe --distro debian --suite bookworm --arch x86_64
lv start probe
# ... do something inside ...
lv stop probe
lv destroy probe --force --keep-disk
ls ~/.local/state/lab-create/orphaned-disks/   # → probe-<epoch>.qcow2
```

## 8. State and image cache inspection

```bash
ls ~/.local/state/lab-create/vms/                     # one dir per VM
ls ~/.local/state/lab-create/vms/<name>/
# manifest.toml, disk.qcow2, seed.iso, qemu.pid (if running),
# monitor.sock, qmp.sock, serial.sock, qemu.log, vars.fd

ls -la ~/.cache/lab-create/images/                    # cached cloud images
du -sh ~/.cache/lab-create/images/*

cat ~/.local/state/lab-create/vms/<name>/manifest.toml

tail -50 ~/.local/state/lab-create/vms/<name>/qemu.log
```

To force a re-download of a cached image:

```bash
rm ~/.cache/lab-create/images/debian-bookworm-x86_64.qcow2
# next `create` for that distro/suite/arch will re-fetch
```

## 9. Run the automated suite

```bash
phase2-qemu-vm/tests/run-all.sh
```

Expect (on a fully-tooled host):

- `test-validation.sh` — pass (~1 s)
- `test-arch-table.sh` — pass (~1 s)
- `test-debian-x86_64-boot.sh` — pass (~2–4 min on KVM); skips without `/dev/kvm`

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `accel: tcg (no /dev/kvm; ...)` | KVM modules not loaded or `/dev/kvm` not present | `sudo modprobe kvm kvm_intel` (or `kvm_amd`); enable VT-x/AMD-V in BIOS |
| `accel: tcg (/dev/kvm exists but not r+w by uid=...)` | Your user not in the `kvm` group | `sudo usermod -aG kvm $USER && newgrp kvm` |
| `qemu-system-aarch64 not found` | Missing arch-specific QEMU binary | `apt-get install qemu-system-arm` |
| `no firmware found for x86_64` | OVMF not installed | `apt-get install ovmf` |
| `no firmware found for aarch64` | AAVMF not installed | `apt-get install qemu-efi-aarch64` |
| SSH never comes up | cloud-init still running, or seed iso not attached | `lv console <name>` to watch boot; check `qemu.log` |
| `download failed: https://...` | Cloud image URL changed or network issue | Check upstream image-server layout; supply `--image /path/to/qcow2` to bypass cache |
| Foreign-arch boot is glacially slow | Expected — TCG emulates everything | Reduce `--cpus 1 --memory 512M` to keep it usable |

Reach for `LAB_LOG_LEVEL=debug` to see the full QEMU argv:

```bash
LAB_LOG_LEVEL=debug lv start deb1
```
