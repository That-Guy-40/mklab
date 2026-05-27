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

## 10. HTTPS / TLS variant

The standard pipeline uses plain HTTP.  This section walks the HTTPS
variant end to end: generate a self-signed cert, compile HTTPS-capable
iPXE with the cert embedded, configure nginx for TLS, and boot.

> **Why embed the cert?**  iPXE fetches files before the OS is running,
> so there is no system CA store to consult.  By embedding the DER-form
> cert directly into the iPXE binary at build time (via `CERTSTORE=`),
> iPXE trusts our self-signed cert without a manual `trust` command in the
> boot script.

### 10.1 Prerequisites

```bash
# openssl is needed only on the HOST for cert generation:
openssl version       # OpenSSL 3.x is fine; 1.1 also works
```

The iPXE build itself runs inside Docker, so no additional packages are
needed on the host beyond the §0 preflight.

### 10.2 Generate the self-signed cert (one-time)

```bash
netboot/setup-netboot-dir.sh --tls
```

**Expect:**

```
[info] creating artifact directory: /home/<you>/netboot
[info] creating config directory:   /home/<you>/.config/lab-netboot
[info] writing nginx MIME snippet:  /home/<you>/.config/lab-netboot/ipxe-mime.conf
[info] generating self-signed TLS cert: /home/<you>/.config/lab-netboot/netboot.crt
[info]   cert (PEM) : /home/<you>/.config/lab-netboot/netboot.crt
[info]   key  (PEM) : /home/<you>/.config/lab-netboot/netboot.key
[info]   cert (DER) : /home/<you>/.config/lab-netboot/netboot.der
[info] writing nginx SSL config snippet: /home/<you>/.config/lab-netboot/ipxe-ssl.conf
[info] setup complete
```

**Verify:**

```bash
CONF=~/.config/lab-netboot

ls -l "$CONF"/netboot.{crt,key,der}
# crt + key: PEM format; key should be mode 600 (private)
# der: DER binary, ~2 KB

openssl x509 -in "$CONF/netboot.crt" -noout -subject -dates
# subject=CN=netboot-lab
# notBefore=...   notAfter=... (10 years from today)

openssl x509 -in "$CONF/netboot.crt" -noout -ext subjectAltName
# X509v3 Subject Alternative Name:
#     IP Address:127.0.0.1, IP Address:10.0.2.2

file "$CONF/netboot.der"
# → data  (raw binary, not PEM)

cat "$CONF/ipxe-ssl.conf"
# → ssl_protocols TLSv1.2 TLSv1.3; ...
```

Run `setup-netboot-dir.sh --tls` a second time — the cert files must not
be overwritten (idempotent):

```bash
netboot/setup-netboot-dir.sh --tls 2>&1 | grep -q "already exists" && echo "idempotent OK"
```

### 10.3 Build HTTPS-capable iPXE

```bash
netboot/build-ipxe.sh \
    --server  https://10.0.2.2:8443 \
    --tls \
    --tls-cert ~/.config/lab-netboot/netboot.der
```

> The `--server` URL must match the hostname/IP in the cert's SAN.  The
> self-signed cert generated in §10.2 covers `10.0.2.2` (QEMU slirp
> gateway) and `127.0.0.1`.  For real hardware on a LAN, regenerate the
> cert with your LAN IP or use a proper cert.

**Inside the container you should see:**

```
[info] enabling HTTPS download support in iPXE config...
[info]   DOWNLOAD_PROTO_HTTPS enabled
[info] embedding trust cert: /tls-cert.der
[info]   embedded cert in trust store
[info] building iPXE with -j<N> (arch=x86_64)...
```

**Verify the boot script uses HTTPS:**

```bash
cat ~/netboot/boot.ipxe
# Must show:
# #!ipxe
# dhcp
# kernel https://10.0.2.2:8443/kernel console=ttyS0 root=/dev/ram0 rw
# initrd https://10.0.2.2:8443/initrd.gz
# boot
```

**Verify HTTPS flag is not in the HTTP build (regression check):**

```bash
# Build a plain HTTP iPXE and confirm DOWNLOAD_PROTO_HTTPS is absent:
netboot/build-ipxe.sh --server http://10.0.2.2:8181 --ipxe-ref master 2>&1 \
    | grep -i "HTTPS" && echo "should NOT be present in plain build"
```

### 10.4 Configure nginx for TLS

The `podman-netboot-server.toml` nginx container currently speaks HTTP on
port 8181.  To add HTTPS you need an nginx server block that references
the cert and key.  The generated `ipxe-ssl.conf` snippet covers the TLS
protocol options; you supply the `ssl_certificate` / `ssl_certificate_key`
directives:

```bash
CONF=~/.config/lab-netboot

cat > ~/netboot/nginx-tls.conf <<EOF
server {
    listen       8443 ssl;
    server_name  _;

    ssl_certificate     $CONF/netboot.crt;
    ssl_certificate_key $CONF/netboot.key;
    include             $CONF/ipxe-ssl.conf;
    include             $CONF/ipxe-mime.conf;

    root  /srv/netboot;
    autoindex on;

    location / {
        try_files \$uri =404;
    }
}
EOF
```

Mount this config into the nginx container alongside the existing TOML
setup.  The simplest approach for a quick test is to run nginx directly
with Docker and mount the cert, key, and config:

```bash
docker run --rm -d \
    --name netboot-https \
    -p 8443:8443 \
    -v ~/netboot:/srv/netboot:ro \
    -v ~/.config/lab-netboot:/certs:ro \
    -v ~/netboot/nginx-tls.conf:/etc/nginx/conf.d/tls.conf:ro \
    nginx:alpine

# Verify the HTTPS server is reachable from the host:
curl -k -sI https://localhost:8443/kernel | head -2
# → HTTP/1.1 200 OK
# (-k skips cert verification because the cert is for 10.0.2.2, not localhost)

curl -k -sI https://10.0.2.2:8443/kernel 2>&1 | head -2 ||
    echo "(10.0.2.2 not routable from host — expected; QEMU guest will use it)"
```

> The `-k` flag is only needed when testing from the **host** with
> `localhost`, because the cert's SAN covers `10.0.2.2` (the QEMU slirp
> address), not `127.0.0.1` by name.  iPXE inside QEMU connects to
> `10.0.2.2:8443` and verifies successfully because the cert's SAN
> explicitly lists `10.0.2.2`.

### 10.5 Boot test — HTTPS iPXE in QEMU

Make sure the kernel and initrd from §§2–3 are in `~/netboot/`, the
HTTPS nginx is running on port 8443 (§10.4), and the HTTPS-compiled
`ipxe.qcow2` is in place (§10.3).

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/vm-netboot-ipxe.toml
phase2-qemu-vm/lab-vm.sh start  netboot-ipxe
```

**Expect on the serial console (key lines):**

```
iPXE 1.21.1 ...
net0: <mac> using virtio-net ...
DHCP (net0 <ip>)... ok
https://10.0.2.2:8443/kernel... ok
https://10.0.2.2:8443/initrd.gz... ok
Booting Linux on physical CPU 0x0
...
/ #
```

The URLs now start with `https://`.  If iPXE fails to trust the cert,
the error is:

```
https://10.0.2.2:8443/kernel... Error 0x... (Connection refused / Untrusted)
```

That means the cert was not embedded correctly — re-check §10.3 and
verify that `--tls-cert` pointed at the DER file (not the PEM).

**Stop and clean up:**

```bash
phase2-qemu-vm/lab-vm.sh stop    netboot-ipxe
phase2-qemu-vm/lab-vm.sh destroy netboot-ipxe --force
docker stop netboot-https 2>/dev/null || true
```

### 10.6 Troubleshooting HTTPS

| Symptom | Likely cause | Fix |
|---|---|---|
| `DOWNLOAD_PROTO_HTTPS` not found in container log | `--tls` flag not passed to `build-ipxe.sh` | Re-run with `--tls --tls-cert` |
| `Error 0x... Untrusted` from iPXE | Cert DER not embedded, or wrong cert | Confirm `--tls-cert` points at the `.der` file (not `.crt`/`.pem`) |
| `Error 0x... Invalid argument` | `https://` URL but iPXE built without `--tls` | Rebuild with `--tls` |
| `curl -k https://localhost:8443/kernel` → `Connection refused` | nginx TLS container not running | `docker ps` to verify; re-run §10.4 |
| iPXE connects but cert name mismatch | SAN in cert doesn't cover `10.0.2.2` | Re-generate with `setup-netboot-dir.sh --tls`; it adds `10.0.2.2` to the SAN |
| Want to use a real CA cert | `--tls-cert` in `build-ipxe.sh` accepts any DER cert | Extract the CA chain to DER: `openssl x509 -in ca.pem -outform DER -out ca.der` |

---

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
