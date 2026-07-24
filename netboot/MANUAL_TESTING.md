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

    ssl_certificate     /certs/netboot.crt;
    ssl_certificate_key /certs/netboot.key;
    include             /certs/ipxe-ssl.conf;
    include             /certs/ipxe-mime.conf;

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

## 11. Traditional DHCP/TFTP PXE boot

Traditional PXE uses **DHCP options 66 + 67** to tell the client where the
TFTP server is and what file to download.  The client then fetches that
file (typically iPXE) via TFTP and executes it.  Once iPXE is running it
chainloads `boot.ipxe` from the HTTP server exactly as in §6b.

This section covers two paths:

- **QEMU (§11.1–11.3)** — QEMU's slirp network has a built-in DHCP+TFTP
  server.  Set `pxe_dir` in the VM spec and no extra containers are needed.
- **Real hardware (§11.4–11.6)** — a dnsmasq container in ProxyDHCP + TFTP
  mode serves TFTP to physical machines without replacing your router's DHCP.

### 11.1 QEMU TFTP PXE — prerequisites

Everything from §§1–5 must be in place: kernel + initrd in `~/netboot/`,
iPXE EFI in `~/netboot/ipxe.efi`, and nginx serving `~/netboot/` on port 8181.

```bash
ls ~/netboot/{kernel,initrd.gz,ipxe.efi,boot.ipxe}   # all must exist
curl -sI http://localhost:8181/kernel | head -1        # → HTTP/1.1 200 OK
```

### 11.2 Create and start the QEMU TFTP PXE VM

```bash
phase2-qemu-vm/lab-vm.sh create \
    --name pxe-tftp \
    --distro debian --suite bookworm --arch x86_64 \
    --memory 2G --cpus 2 \
    --no-cloud-init \
    --pxe-dir ~/netboot \
    --pxe-bootfile ipxe.efi
```

Or via TOML:

```bash
# Edit pxe_dir path in the TOML to match your $HOME, then:
phase2-qemu-vm/lab-vm.sh create --config examples/pxe-boot-mechanics/vm-pxe-tftp-boot.toml
phase2-qemu-vm/lab-vm.sh start  pxe-tftp
```

**Verify the manifest carries the PXE fields:**

```bash
grep -E "pxe_dir|pxe_bootfile" \
    ~/.local/state/lab-create/vms/pxe-tftp/manifest.toml
# → pxe_dir     = "/home/<you>/netboot"
# → pxe_bootfile = "ipxe.efi"
```

**Verify the QEMU command line includes TFTP:**

```bash
phase2-qemu-vm/lab-vm.sh inspect pxe-tftp 2>&1 | grep -i tftp
# OR: check qemu.log after starting the VM
```

### 11.3 Observe the TFTP PXE boot sequence

```bash
phase2-qemu-vm/lab-vm.sh console pxe-tftp
```

**Expect in order on the console:**

```
UEFI Interactive Shell  v2.2
...
Initializing PXE network interface
DHCP: 10.0.2.15 / 10.0.2.2
TFTP: downloading ipxe.efi...

iPXE 1.21.1 ...
net0: <mac> using virtio-net ...
DHCP (net0 10.0.2.15)... ok
http://10.0.2.2:8181/kernel... ok
http://10.0.2.2:8181/initrd.gz... ok
Booting Linux on physical CPU 0x0
...
/ #
```

> If the VM boots directly to UEFI shell without attempting PXE, check
> that `-boot order=n` took effect (inspect the QEMU log) and that OVMF
> has a PXE driver installed.  The standard `ovmf` package includes the
> `VirtioNet` driver.  You can also force network boot from the UEFI shell:
> `Shell> bcfg boot add 0 fs0:\EFI\tools\ipxe.efi "iPXE"` — or press F12
> at the OVMF splash screen.

**Stop:**

```bash
phase2-qemu-vm/lab-vm.sh stop    pxe-tftp
phase2-qemu-vm/lab-vm.sh destroy pxe-tftp --force
```

### 11.4 Real hardware — set up the TFTP directory and dnsmasq config

```bash
netboot/setup-dhcp-tftp.sh \
    --server-ip 192.168.1.50 \
    --iface     eth0 \
    --dir       ~/netboot
```

**Expect:**

```
[info] creating TFTP root: /home/<you>/netboot/tftp
[info]   copied ipxe.efi → .../netboot/tftp/ipxe.efi
[info]   copied boot.ipxe → .../netboot/tftp/boot.ipxe
[info] writing dnsmasq config: ~/.config/lab-netboot/dnsmasq-pxe.conf
```

**Verify the dnsmasq config:**

```bash
cat ~/.config/lab-netboot/dnsmasq-pxe.conf
# Must contain:
#   enable-tftp
#   tftp-root=.../netboot/tftp
#   dhcp-range=192.168.1.50,192.168.1.50,proxy   ← ProxyDHCP mode
#   dhcp-boot=ipxe.efi
```

**Verify the TFTP root:**

```bash
ls ~/netboot/tftp/
# → ipxe.efi  ipxe-signed.efi (if --sign was used)  boot.ipxe
```

### 11.5 Start the dnsmasq container for real hardware

dnsmasq needs `--network=host` to receive DHCP broadcasts from physical
machines.  This requires root on the host (or `CAP_NET_ADMIN`).

```bash
# Option A: Docker directly (simpler for --network=host):
sudo docker run --rm -d \
    --name pxe-dnsmasq \
    --network host \
    --cap-add NET_ADMIN \
    -v ~/netboot/tftp:/tftp:ro \
    -v ~/.config/lab-netboot/dnsmasq-pxe.conf:/etc/dnsmasq.conf:ro \
    alpine:latest \
    sh -c 'apk add -q dnsmasq && dnsmasq --no-daemon --log-facility=-'

# Confirm it's running and listening:
sudo docker logs pxe-dnsmasq 2>&1 | head -10
ss -ulnp | grep ':69 '   # TFTP port — should show dnsmasq
```

**Or via Podman (needs --network=host, also requires root/privs):**

```bash
# Edit the volume paths in examples/podman-pxe-dhcp.toml, then:
sudo phase4-podman/lab-podman.sh up --config examples/podman-pxe-dhcp.toml
```

### 11.6 Test on a physical machine

1. Connect the target machine to the same LAN as your netboot host.
2. Boot the target — enter the BIOS and ensure network boot is enabled.
3. The machine will:
   - Send a DHCP request with `option 60 = "PXEClient"`
   - Your existing router assigns an IP
   - dnsmasq (ProxyDHCP) responds with TFTP server = `192.168.1.50`, bootfile = `ipxe.efi`
   - Machine fetches `ipxe.efi` via TFTP
   - iPXE loads → fetches `boot.ipxe` via HTTP → boots kernel+initrd

**Monitor dnsmasq logs during boot:**

```bash
sudo docker logs -f pxe-dnsmasq 2>&1 | grep -E "DHCP|TFTP|boot"
# → dnsmasq-dhcp: 1234567890 available 192.168.1.50  (ProxyDHCP)
# → dnsmasq-dhcp: 1234567890 vendor class: PXEClient:Arch:00009
# → dnsmasq-dhcp: 1234567890 PXE-boot ipxe.efi on 192.168.1.50
# → dnsmasq-tftp: 23 /tftp/ipxe.efi to 192.168.1.XX
```

**Cleanup:**

```bash
sudo docker stop pxe-dnsmasq
```

### 11.7 DHCP/TFTP troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| VM skips PXE and boots to UEFI shell | OVMF didn't try network boot | Press F12 at OVMF splash, or add `-boot order=n` manually via `LAB_LOG_LEVEL=debug` |
| `TFTP: timeout` | nginx is running but TFTP dir is wrong | Confirm `pxe_dir` matches where `ipxe.efi` lives; `ls ~/netboot/ipxe.efi` |
| Physical machine gets DHCP but no TFTP | ProxyDHCP response blocked by router | Some routers filter extra DHCP responses; try `--full-dhcp` on an isolated VLAN |
| `dnsmasq: bind: Address already in use` | Another DHCP server on port 67 | Use ProxyDHCP mode (default) or stop the conflicting server |
| Physical machine gets `File not found` via TFTP | Wrong bootfile path in dnsmasq config | Check `dhcp-boot=ipxe.efi` in dnsmasq-pxe.conf; confirm `/tftp/ipxe.efi` exists |

---

## 12. Secure Boot — sign iPXE and boot with Secure Boot enabled

Secure Boot verifies the UEFI binary's signature before executing it.
For iPXE to run under Secure Boot, the `ipxe.efi` binary must be signed
with a key that is in the UEFI firmware's **Signature Database (db)**.

This section uses the **snakeoil key** (pre-installed with the `ovmf`
package on Ubuntu/Debian) for QEMU testing — no MOK enrollment step,
no firmware interaction.  For real hardware, §12.5 covers the MOK path.

### 12.1 Prerequisites

```bash
# sbsigntool must be installed:
sbsign --version 2>&1 | head -1   # sbsign: EFI signing tool

# ovmf must include the snakeoil VARS:
ls /usr/share/OVMF/OVMF_CODE_4M.secboot.fd  # Secure Boot enforcement
ls /usr/share/OVMF/OVMF_VARS_4M.snakeoil.fd # Pre-enrolled snakeoil key
ls /usr/share/ovmf/PkKek-1-snakeoil.{key,pem} # Signing key + cert
```

If any are missing: `sudo apt-get install -y sbsigntool ovmf`

### 12.2 Build iPXE and sign with the snakeoil key (combined)

```bash
netboot/build-ipxe.sh \
    --server http://10.0.2.2:8181 \
    --sign --use-snakeoil
```

**Expect at the end of the build:**

```
[info] signing EFI binary: /home/<you>/netboot/ipxe.efi
[info] signing with snakeoil key (QEMU test only — NOT for real hardware)
[warn]   The snakeoil key is world-readable.  Anyone can sign binaries that
[warn]   will boot under a snakeoil OVMF.  Use --generate-mok for real hardware.
[info] signing: .../netboot/ipxe.efi → .../netboot/ipxe-signed.efi
[info] verifying signature...
[info]   signature valid ✓
```

**Verify:**

```bash
ls -lh ~/netboot/ipxe-signed.efi   # ~1–2 MB; slightly larger than ipxe.efi

sbverify --cert /usr/share/ovmf/PkKek-1-snakeoil.pem \
         ~/netboot/ipxe-signed.efi \
    && echo "signature OK"
# → Signature verification OK
```

### 12.3 Sign an existing binary separately

If you already have `ipxe.efi` and just need to sign it:

```bash
netboot/sign-ipxe.sh \
    --use-snakeoil \
    --input  ~/netboot/ipxe.efi \
    --output ~/netboot/ipxe-signed.efi
```

### 12.4 Boot with Secure Boot in QEMU

Replace `ipxe.efi` with the signed binary, then start a VM with `--secure-boot`:

```bash
# In-place replace so the TFTP dir serves the signed version:
cp ~/netboot/ipxe-signed.efi ~/netboot/ipxe.efi

phase2-qemu-vm/lab-vm.sh create --config examples/pxe-boot-mechanics/vm-pxe-secureboot.toml
phase2-qemu-vm/lab-vm.sh start  pxe-secureboot
phase2-qemu-vm/lab-vm.sh console pxe-secureboot
```

**Verify the correct OVMF variant is being used:**

```bash
phase2-qemu-vm/lab-vm.sh inspect pxe-secureboot 2>&1 | grep -i "ovmf\|secboot\|firmware"
# or check the QEMU log:
grep "pflash\|secboot\|OVMF" \
    ~/.local/state/lab-create/vms/pxe-secureboot/qemu.log 2>/dev/null | head -5
```

**Expect in the console (key indicator):**

```
OVMF Secure Boot: Enabled
...
iPXE 1.21.1 ...
```

**What Secure Boot rejection looks like** — if the binary is NOT signed
or signed with the wrong key, OVMF refuses to execute it:

```
OVMF Secure Boot: Enabled
Secure Boot violation
  Image failed Secure Boot verification.
```

If you see this, re-run §12.2 or §12.3 and confirm the snakeoil cert
(`/usr/share/OVMF/OVMF_VARS_4M.snakeoil.fd`) is in use.

**Stop:**

```bash
phase2-qemu-vm/lab-vm.sh stop    pxe-secureboot
phase2-qemu-vm/lab-vm.sh destroy pxe-secureboot --force
```

### 12.5 Real hardware — generate a MOK and enroll it

On real hardware with Secure Boot enabled by the firmware vendor (e.g., a
laptop shipped with Windows keys in the db), you need to add your own key
to the **Machine Owner Key (MOK)** database.

```bash
# Step 1: generate a MOK key pair and sign iPXE
netboot/sign-ipxe.sh \
    --generate-mok \
    --input  ~/netboot/ipxe.efi \
    --output ~/netboot/ipxe-signed.efi
```

**Expect:**

```
[info] generating MOK key pair → ~/.config/lab-netboot/MOK.{key,crt}
[info]   key : ~/.config/lab-netboot/MOK.key
[info]   cert: ~/.config/lab-netboot/MOK.crt
[info] signing: .../ipxe.efi → .../ipxe-signed.efi
[info] signature valid ✓
[info] MOK enrollment (real hardware, requires physical presence):
[info]   sudo mokutil --import ~/.config/lab-netboot/MOK.crt
[info]   # → reboot → 'Enroll MOK' in the blue MokManager screen → reboot again
```

```bash
# Step 2: enroll the MOK (requires a monitor + keyboard at the machine)
sudo mokutil --import ~/.config/lab-netboot/MOK.crt
# → enter a one-time password (you'll confirm it in the firmware screen)

# Step 3: reboot into the MokManager screen
sudo reboot
# → Blue "Shim UEFI key management" screen
# → "Enroll MOK" → "Continue" → enter the password → "Yes" → reboot

# Step 4: verify the MOK is enrolled
mokutil --list-enrolled | grep -A3 "Lab iPXE MOK"
# → Issuer: CN=Lab iPXE MOK <year>
```

```bash
# Step 5: use the signed binary
cp ~/netboot/ipxe-signed.efi ~/netboot/ipxe.efi
# Boot the target machine from USB or PXE — Secure Boot accepts the signed iPXE
```

### 12.6 Verify: Secure Boot rejects an unsigned binary

```bash
# Keep ipxe-signed.efi, then test that the UNSIGNED binary fails:
cp ~/netboot/ipxe.efi /tmp/unsigned-ipxe.efi
sbverify --cert /usr/share/ovmf/PkKek-1-snakeoil.pem \
         /tmp/unsigned-ipxe.efi 2>&1 | grep -q "failed\|no signature" \
    && echo "unsigned binary correctly rejected by sbverify"
```

### 12.7 Secure Boot troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Secure Boot violation` in OVMF | Unsigned binary or wrong signing key | Re-run `sign-ipxe.sh --use-snakeoil`; confirm snakeoil VARS in use |
| `sbverify: No signature found` | Binary not signed | `sign-ipxe.sh --use-snakeoil` or `--generate-mok` |
| OVMF doesn't show "Secure Boot: Enabled" | Wrong OVMF code file | Ensure `--secure-boot` in the VM TOML; check firmware path via `LAB_LOG_LEVEL=debug` |
| `mokutil --import` fails | mokutil not installed or SB not in user-mode | `sudo apt-get install mokutil`; Secure Boot must already be on for MOK enrollment |
| Signed binary rejected on real hw | Machine uses Microsoft UEFI CA, not MOK | You enrolled MOK correctly but the machine's db only trusts MS-signed shim; either enroll MOK via shim's `MokManager.efi` or disable Secure Boot in BIOS |

---

## 13. Verified A/B payload boot (`imgverify`) — ✅ verified end-to-end

"Reboot pulls newest" must mean **newest *verified***, not "whatever the HTTP
server returned" (closes `AUDIT.md` **F2**). This section signs the payload and
has iPXE **cryptographically verify it before boot**, with **A/B rollback** when
verification fails — so a payload the fleet operator did not sign can never run.
Unlike §12 (which Secure-Boot-signs the iPXE *binary*) this signs the *payload*
(kernel + initrd) iPXE downloads.

> **How it works.** iPXE's `imgverify` checks a detached **CMS** signature
> against a code-signing root **compiled into the iPXE binary** (`TRUST=`). The
> signing leaf carries a `codeSigning` EKU (iPXE requires it), and the CA rides
> *inside* the CMS (`-certfile`) so iPXE can build leaf→CA→trusted-root — omit
> that and imgverify fails "No usable certificates" (`ipxe.org/err/0216eb3c`).
> `imgverify` is independent of TLS: HTTPS (§10) gives confidentiality, imgverify
> gives payload *authenticity*.
>
> **Honest trust framing.** `sign-payload.sh --gen-keys` mints a **snakeoil** CA
> — fine to prove the mechanism, but *not* a real anchor. In production the
> signing key is an offline/HSM-held fleet key; point `--keydir` at real material
> and drop `--gen-keys`.

### 13.1 Sign the payload and build a verifying iPXE

```bash
# Slotted layout the verified boot script expects: <base>/<slot>/<file>{,.sig}
mkdir -p ~/netboot/images/dns/current ~/netboot/images/dns/previous
# (populate each slot with a kernel `vmlinuz` + initrd `initrd.gz`; e.g. from
#  export-initrd, or micro-linux/out/x86_64/{kernel,initramfs.cpio.gz})

# Sign both slots; emit the DER trust root for the iPXE build:
netboot/sign-payload.sh --gen-keys --out-trust ~/netboot/codesign/ca.der \
    ~/netboot/images/dns/current/vmlinuz  ~/netboot/images/dns/current/initrd.gz \
    ~/netboot/images/dns/previous/vmlinuz ~/netboot/images/dns/previous/initrd.gz
# → writes <file>.sig beside each; self-verifies each signature.

# Build iPXE that verifies before booting and rolls back on failure:
netboot/build-ipxe.sh \
    --server http://10.0.2.2:8181/images/dns \
    --kernel-path /vmlinuz --initrd-path /initrd.gz --append "console=ttyS0" \
    --imgverify --payload-trust ~/netboot/codesign/ca.der
# The embedded boot.ipxe now does, per slot:
#   kernel …/vmlinuz  → imgverify vmlinuz …/vmlinuz.sig  → initrd …  → imgverify … → boot
#   on any failure: imgfree, current→previous; if previous fails too: refuse.
```

### 13.2 Verified results (KVM, 2026-07-23)

Boot the verifying `ipxe.qcow2` while serving `~/netboot/images/dns/`. Payload =
`micro-linux/out/x86_64/{kernel,initramfs.cpio.gz}` (small, boots to a shell).
Three scenarios, real serial output:

```
# ── both slots valid ──────────────────────────────────────────────────────
# → iPXE: slot current VERIFIED -- booting
# → [    0.027676] Kernel command line: console=ttyS0 slot=current
# → [    1.356256] Run /init as init process        ← verified image booted ✓

# ── current tampered (1 byte flipped in initrd.gz; .sig left stale) ────────
# → http://…/current/initrd.gz.sig... ok
# → Could not verify: Permission denied (https://ipxe.org/0227e13c)   ← digest mismatch
# → iPXE: imgverify FAILED for slot current
# → iPXE: rolling back current -> previous
# → iPXE: slot previous VERIFIED -- booting
# → [    0.028343] Kernel command line: console=ttyS0 slot=previous    ← rolled back ✓
# → [    1.357726] Run /init as init process

# ── BOTH slots tampered ────────────────────────────────────────────────────
# → iPXE: imgverify FAILED for slot current
# → iPXE: rolling back current -> previous
# → iPXE: imgverify FAILED for slot previous
# → iPXE: no verified image in either slot -- refusing to boot   ← never boots unverified ✓
#   (0 "Kernel command line" lines in the transcript — no kernel ran)
```

Note the two distinct iPXE error codes: **0216eb3c** = "No usable certificates"
(a broken chain or a bad clock — cert not valid *now*), **0227e13c** = digest
mismatch (the tamper was cryptographically caught). They are distinguishable in
the log, which matters when diagnosing a real failure.

### 13.3 The signing half in CI (no QEMU/Docker)

```bash
netboot/tests/test-sign-payload.sh
# → PASS: sign-payload.sh: CMS-signs (codeSigning EKU), verifies, rejects tampering, fails closed
```

This is the load-bearing building block for the RAM-resident infrastructure lab
family — see [`../RAM_INFRA_LAB_PLAN.md`](../RAM_INFRA_LAB_PLAN.md).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `imgverify: command not found` | iPXE built without `IMAGE_TRUST_CMD` | Rebuild with `--imgverify` (it defines `IMAGE_TRUST_CMD` in `config/local/general.h`) |
| `Could not verify: … (0216eb3c)` "No usable certificates" | CA not in the CMS, or bad clock | `sign-payload.sh` bundles the CA via `-certfile`; check host/RTC time is correct |
| `Could not verify: … (0227e13c)` | Payload changed after signing (or genuine tamper) | Re-sign after any rebuild: `sign-payload.sh <file>` regenerates `<file>.sig` |
| imgverify rejects everything | `--imgverify` without `--payload-trust` | Pass `--payload-trust <ca.der>` (from `sign-payload.sh --out-trust`) |
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
