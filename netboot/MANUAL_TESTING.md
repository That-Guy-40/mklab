# Netboot pipeline — Manual Testing Walkthrough

A copy-pasteable, top-to-bottom exercise of the full netboot pipeline:
setup → chroot → initrd → iPXE build → nginx → QEMU boot. Each step
states what to expect and how to recognise breakage.

> **Working directory:** all commands assume you are in the repo root:
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> ```

## 0. Preflight — host packages

```bash
# Required:
sudo apt-get install -y jq debootstrap debian-archive-keyring \
    qemu-system-x86 qemu-utils

# Docker (for build-ipxe.sh — must be running):
docker info &>/dev/null && echo "Docker OK" || echo "Docker not running"

# Podman (for the nginx container):
podman --version
```

Check KVM access (avoids slow TCG emulation):

```bash
ls -l /dev/kvm            # must exist
groups | grep -q kvm && echo "kvm group OK" || echo "add yourself: sudo usermod -aG kvm $USER"
```

> If you are not in the `kvm` group, log out and back in after running
> `sudo usermod -aG kvm $USER`, or rerun any `lab-vm.sh` command with
> `sudo` as a workaround. The `disk-image` and `kernel+initrd` backends
> don't otherwise need root.

Verify the pipeline scripts are executable:

```bash
bash -n netboot/setup-netboot-dir.sh && echo "setup OK"
bash -n netboot/build-ipxe.sh        && echo "build-ipxe OK"
bash -n netboot/ipxe-build-inner.sh  && echo "inner OK"
```

## 1. One-time host setup

```bash
netboot/setup-netboot-dir.sh
```

**Expect:**

```
[info] creating artifact directory: /home/<you>/netboot
[info] creating config directory:   /home/<you>/.config/lab-netboot
[info] writing nginx MIME snippet:  /home/<you>/.config/lab-netboot/ipxe-mime.conf
[info] setup complete
```

**Verify:**

```bash
ls ~/netboot/                                   # empty dir, should exist
cat ~/.config/lab-netboot/ipxe-mime.conf        # should show types { application/x-ipxe ipxe; }
```

**Run a second time** — should be idempotent (no errors, just re-prints the paths).

## 2. Build the netboot chroot (Phase 1)

Uses `chroot-netboot-minimal.toml`: Debian bookworm minbase +
`linux-image-amd64` + `busybox-static`. Takes ~2 minutes.

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --config examples/chroot-netboot-minimal.toml
```

**Expect:**

```
[info] debootstrap (native): debian/bookworm arch=x86_64 → /var/chroots/netboot-minimal
[info] ── done: netboot-minimal ──
```

**Verify:**

```bash
sudo phase1-chroot/lab-chroot.sh verify netboot-minimal
# → os: Debian GNU/Linux 12 (bookworm)
# → exec test: /bin/busybox OK

ls /var/chroots/netboot-minimal/bin/busybox    # must exist
ls /var/chroots/netboot-minimal/boot/vmlinuz-* # kernel blob must be here
```

## 3. Export kernel + initrd (Phase 1 `export-initrd`)

Packs the chroot as a cpio.gz initrd and copies the kernel. Needs root
to read the chroot. Takes ~30 seconds (mostly gzip compression).

```bash
sudo phase1-chroot/lab-chroot.sh export-initrd netboot-minimal \
    --kernel ~/netboot/kernel \
    --output ~/netboot/initrd.gz
```

**Expect:**

```
[info] writing busybox /init preset
[info] packing initrd ...
[info] initrd: <N> MB → ~/netboot/initrd.gz
[info] kernel copied → ~/netboot/kernel
```

**Verify:**

```bash
ls -lh ~/netboot/kernel ~/netboot/initrd.gz
# kernel: ~8 MB, initrd.gz: ~50–150 MB depending on installed packages

file ~/netboot/initrd.gz          # → gzip compressed data
file ~/netboot/kernel             # → Linux kernel x86 boot executable

# Confirm /init is present inside the initrd:
zcat ~/netboot/initrd.gz | cpio -t 2>/dev/null | grep '^init$'
# → init

# Confirm /init is the busybox preset (starts with #!/bin/busybox):
zcat ~/netboot/initrd.gz | cpio -i --to-stdout init 2>/dev/null | head -3
# → #!/bin/busybox sh
# → /bin/busybox --install -s
```

## 4. Build iPXE (inside Docker, ~15 min first run)

Downloads iPXE source from GitHub, compiles inside a `debian:bookworm`
Docker container, and produces USB/EFI/qcow2 images plus `boot.ipxe`.

```bash
netboot/build-ipxe.sh --server http://10.0.2.2:8181
```

> First run pulls the Docker image and compiles iPXE from scratch —
> expect 10–20 minutes. Subsequent runs without `--ipxe-ref` changes
> will re-clone and re-build (iPXE compilation cannot be cached across
> Docker runs with the current inner script design).

**Expect (truncated):**

```
[info] Docker OK
[info] starting Docker build (arch=x86_64 ref=master) ...
[info] ipxe-build-inner starting
[info] installing build dependencies...
...
[info] copying outputs to /out/
[info]   /out/boot.ipxe
[info]   /out/ipxe.usb
[info]   /out/ipxe.efi
[info] ipxe-build-inner done
[info] converting ipxe.usb → ipxe.qcow2 ...
[info] build complete — outputs in /home/<you>/netboot:
[info]   boot.ipxe  (4.0K)
[info]   ipxe.usb  (400K)
[info]   ipxe.efi  (1.2M)
[info]   ipxe.qcow2  (708K)
```

**Verify:**

```bash
ls -lh ~/netboot/{boot.ipxe,ipxe.usb,ipxe.efi,ipxe.qcow2}
# All four files must exist.

cat ~/netboot/boot.ipxe
# Must show:
# #!ipxe
# dhcp
# kernel http://10.0.2.2:8181/kernel console=ttyS0 root=/dev/ram0 rw
# initrd http://10.0.2.2:8181/initrd.gz
# boot

file ~/netboot/ipxe.qcow2   # → QEMU QCOW2 Image
```

## 5. Start the nginx container (Phase 4, rootless)

```bash
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml
```

**Expect:**

```
[info] ── bringing up lab 'netboot-srv' ...
[info] starting (plain) service 'http' as lab-netboot-srv-http ...
[info] ── lab 'netboot-srv' up ──
```

**Verify all three artifacts are served:**

```bash
curl -sI http://localhost:8181/kernel    | head -2   # → HTTP/1.1 200 OK
curl -sI http://localhost:8181/initrd.gz | head -2   # → HTTP/1.1 200 OK
curl -s  http://localhost:8181/boot.ipxe             # → the iPXE script

# Verify the iPXE MIME type (critical for real hardware chainloading):
curl -sI http://localhost:8181/boot.ipxe | grep -i content-type
# → Content-Type: application/x-ipxe
```

If `Content-Type: application/x-ipxe` is missing, check that
`~/.config/lab-netboot/ipxe-mime.conf` exists (step 1) — the nginx
container mounts it as `/etc/nginx/conf.d/ipxe-mime.conf`.

## 6a. Boot test — direct kernel+initrd (fastest)

No iPXE involved. QEMU loads kernel + initrd directly from disk and
boots. Use this first to confirm the initrd itself is working.

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-direct.toml
phase2-qemu-vm/lab-vm.sh start  netboot-direct
```

**Expect on the serial console:**

```
[    0.000000] Booting Linux on physical CPU 0x0
...
[    0.5xxxxx] Run /init as init process
/ # 
```

A busybox `sh` prompt at `/`. Try:

```bash
/bin/busybox ls /
ip link
```

**Stop the VM:**

```bash
phase2-qemu-vm/lab-vm.sh stop netboot-direct    # or Ctrl-A X in QEMU
phase2-qemu-vm/lab-vm.sh destroy netboot-direct --force
```

## 6b. Boot test — full iPXE simulation

Boots from the `ipxe.qcow2` USB image, exactly as real hardware boots
from a USB stick. iPXE does DHCP via QEMU slirp, fetches kernel +
initrd from the nginx container (step 5 must be running), then boots.

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-ipxe.toml
phase2-qemu-vm/lab-vm.sh start  netboot-ipxe
```

**Expect on the serial console (in order):**

```
iPXE 1.21.1 ...
net0: <mac> using virtio-net ...
DHCP (net0 <ip>)... ok
http://10.0.2.2:8181/kernel... ok
http://10.0.2.2:8181/initrd.gz... ok
Booting Linux on physical CPU 0x0
...
/ #
```

If the HTTP fetches fail, confirm the nginx container is still running:

```bash
phase4-podman/lab-podman.sh list --lab netboot-srv   # → http ● running
```

**Stop the VM:**

```bash
phase2-qemu-vm/lab-vm.sh stop netboot-ipxe
```

## 7. Iteration loop (after the first successful boot)

When you change the chroot (install packages, edit `/init`, etc.):

```bash
# Re-export initrd — nginx picks up the new file immediately:
sudo phase1-chroot/lab-chroot.sh export-initrd netboot-minimal \
    --kernel ~/netboot/kernel \
    --output ~/netboot/initrd.gz

# Restart the VM to pick up the new initrd:
phase2-qemu-vm/lab-vm.sh stop  netboot-ipxe
phase2-qemu-vm/lab-vm.sh start netboot-ipxe
```

No nginx restart needed. No iPXE rebuild needed (unless `--server` changes).

## 8. Cleanup

```bash
# Stop the VM:
phase2-qemu-vm/lab-vm.sh stop    netboot-ipxe
phase2-qemu-vm/lab-vm.sh destroy netboot-ipxe --force

# Stop nginx:
phase4-podman/lab-podman.sh down --lab netboot-srv

# Destroy the chroot (optional — keep it if you want to iterate):
sudo phase1-chroot/lab-chroot.sh destroy netboot-minimal --force

# Remove build artifacts (optional):
rm -rf ~/netboot/
```

## 9. Real hardware (optional)

If the QEMU simulation booted successfully, the same `ipxe.usb` works
on physical hardware. Use your LAN IP instead of `10.0.2.2`:

```bash
# Rebuild iPXE with your LAN IP:
netboot/build-ipxe.sh --server http://192.168.1.50:8181

# Flash to USB:
sudo dd if=~/netboot/ipxe.usb of=/dev/sdX bs=4M status=progress && sync

# Serve the artifacts (nginx container serves on your host's 8181):
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml

# Plug USB into target machine, boot from USB, watch the serial / HDMI console
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: rootlessport … address already in use` | Port 8181 (or 8080) in use by another process | `ss -tlnp sport eq :8181` to find it; or change `ports = []` in the TOML and rebuild iPXE with matching `--server` |
| `boot.ipxe` served as `text/plain`, iPXE refuses it | `ipxe-mime.conf` not mounted into container | Re-run `setup-netboot-dir.sh`; confirm `~/.config/lab-netboot/ipxe-mime.conf` exists |
| iPXE HTTP fetch times out: `Connection timed out` | `10.0.2.2:8181` not reachable from guest | nginx not running, or port mismatch; `curl http://localhost:8181/kernel` from host |
| `[error] image not readable: /home/…/netboot/ipxe.qcow2` | `build-ipxe.sh` not run yet, or `qemu-img` missing | Run step 4; install `qemu-utils` |
| Kernel boots but `/init` not found | `/init` missing or not executable in the initrd | Check step 3 verification; re-export with `--init-script busybox` |
| VM is 'netboot-ipxe' already exists | Stale state from a prior run with `sudo` | `sudo phase2-qemu-vm/lab-vm.sh destroy netboot-ipxe --force` |
| `Docker daemon is not running` | Docker not started | `sudo systemctl start docker` (or `snap start docker`) |
| `cloud_init=false` ignored, seed ISO generated | Running an older build before the jq boolean fix | Pull latest and recreate the VM |

## Running the test suite

The export-initrd test suite covers the packing logic without needing a
real debootstrap chroot:

```bash
sudo phase1-chroot/tests/test-export-initrd.sh
# → 8 tests, all PASS (takes ~5 s)
```

Phase 2 validation tests (no daemon required):

```bash
bash phase2-qemu-vm/tests/test-validation.sh
# → PASS: validation guardrails OK
```
