# Testing the PXE transports by hand — TFTP & HTTPS

A hands-on walkthrough for **testing the file transfers a PXE boot depends on**,
from the client's side, using the probes in [`tools/`](tools/):

- **TFTP** — how firmware pulls `ipxe.efi` (the bootfile DHCP option 67 names).
- **HTTP / HTTPS** — how iPXE then pulls the `kernel` and `initramfs`.

The point isn't to boot a VM (the [`vm-pxe-*.toml`](README.md) labs do that) —
it's to run each fetch *on its own*, watch the status line / headers / TLS
handshake, and record a session you can replay. That's the fastest way to learn
where a netboot actually breaks.

> This is the task-oriented companion to [`tools/README.md`](tools/README.md)
> (which documents *what the tools do*) and to
> [`../../netboot/MANUAL_TESTING.md`](../../netboot/MANUAL_TESTING.md) §§10–11
> (the full server-side + in-VM boot test). Here we focus on **client-side
> transport testing with `pxe-fetch.sh` and `socwrap.sh`.**

## Run these from the host (the client vantage point)

| Transport | Served by | How you reach it from the host |
|---|---|---|
| HTTP    | nginx container (`../podman-netboot-server.toml`) | `http://localhost:8181` |
| HTTPS   | nginx TLS (you stand it up — §2 below) | `https://localhost:8443` |
| TFTP    | dnsmasq ProxyDHCP+TFTP container (§3 below) | `tftp://localhost:69` |

> **`10.0.2.2` is the QEMU slirp gateway — only reachable *inside* a slirp VM.**
> From the host the same artifacts are on `localhost`. `pxe-fetch.sh from-ipxe`
> rewrites `10.0.2.2` → your `--server` automatically. And QEMU slirp's *own*
> built-in TFTP is internal to the VM's NAT — it can't be probed from the host,
> which is why the TFTP test below uses the dnsmasq container instead.

---

## 1. HTTP — the warm-up

Start a plain HTTP artifact server, then probe it.

```bash
# Serve ~/netboot on :8181 (rootless podman):
phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml

cd examples/pxe-boot-mechanics

# What's actually served? (HEAD sweep)
tools/pxe-fetch.sh probe
```

```
[pxe-fetch] probing http://localhost:8181  (HEAD; what is actually served?)
  PATH           STATUS SIZE
  /kernel        200    8206272
  /initrd.gz     200    325917927
  /vmlinuz       200    15178568
  /initrd.img    200    223259072
  /ipxe.efi      200    1158144
  /boot.ipxe     200    413
```

Then replay the **exact** GETs your iPXE will perform — authoritative, because
it reads your real `boot.ipxe`:

```bash
tools/pxe-fetch.sh from-ipxe ~/netboot/boot.ipxe
```

```
[pxe-fetch]   kernel → http://10.0.2.2:8181/vmlinuz
── GET http://localhost:8181/vmlinuz
  response:
      HTTP/1.1 200 OK
      Server: nginx/...
      Content-Length: 15178568
[pxe-fetch]   200  (body discarded)
...
```

A `200` with a `Content-Length` on each line = everything iPXE needs is being
served. (Use `--save DIR` to keep the files; default discards the body.)

---

## 2. HTTPS — fetching kernel + initramfs over TLS

iPXE can fetch over HTTPS, but only if (a) it was **compiled with HTTPS support
and a trusted cert embedded**, and (b) the server actually speaks TLS. We test
both halves: the server with `pxe-fetch.sh`/`curl`, then the iPXE build.

### 2.1 One-time: generate the self-signed cert

```bash
netboot/setup-netboot-dir.sh --tls
# writes, under ~/.config/lab-netboot/ :
#   netboot.crt / netboot.key  (PEM)   netboot.der  (DER — embed THIS in iPXE)
#   SAN covers IP 127.0.0.1 and 10.0.2.2
```

### 2.2 Build HTTPS-capable iPXE

```bash
netboot/build-ipxe.sh \
    --server  https://10.0.2.2:8443 \
    --tls \
    --tls-cert ~/.config/lab-netboot/netboot.der
```

This flips `boot.ipxe` to `https://` URLs and embeds the cert in iPXE's trust
store. Confirm:

```bash
grep -E '^kernel|^initrd' ~/netboot/boot.ipxe   # → https://10.0.2.2:8443/...
```

### 2.3 Serve the artifacts over TLS on :8443

```bash
CONF=~/.config/lab-netboot
cat > ~/netboot/nginx-tls.conf <<EOF
server {
    listen 8443 ssl;
    server_name _;
    ssl_certificate     $CONF/netboot.crt;
    ssl_certificate_key $CONF/netboot.key;
    include             $CONF/ipxe-ssl.conf;
    root /srv/netboot;
    autoindex on;
    location / { try_files \$uri =404; }
}
EOF

docker run --rm -d --name netboot-https -p 8443:8443 \
    -v ~/netboot:/srv/netboot:ro \
    -v ~/.config/lab-netboot:/certs:ro \
    -v ~/netboot/nginx-tls.conf:/etc/nginx/conf.d/tls.conf:ro \
    nginx:alpine
```

(Full detail + the rootless/podman variant: `netboot/MANUAL_TESTING.md` §10.4.)

### 2.4 Test the HTTPS fetch with the probe

```bash
# --tls is shorthand for: --server https://localhost:8443  + curl -k
tools/pxe-fetch.sh probe --tls
tools/pxe-fetch.sh from-ipxe ~/netboot/boot.ipxe --tls
```

```
[pxe-fetch] probing https://localhost:8443  (HEAD; what is actually served?)
[pxe-fetch]   (TLS cert verification OFF — snakeoil/self-signed)
  PATH           STATUS SIZE
  /kernel        200    8206272
  ...
```

> **Why `-k` (verification off)?** The cert's SAN lists the *IP* `127.0.0.1`,
> not the name `localhost`, so verifying by name fails. Two honest ways to see
> real verification succeed instead of skipping it:
> ```bash
> # Verify against the IP SAN (no -k needed):
> tools/pxe-fetch.sh probe --server https://127.0.0.1:8443
> # Or trust the cert explicitly:
> curl --cacert ~/.config/lab-netboot/netboot.crt -sI https://127.0.0.1:8443/kernel
> ```
> Inside QEMU, iPXE connects to `10.0.2.2:8443` and verifies for real against
> the embedded cert — that's the path §2.2 set up.

### 2.5 Guided, recordable HTTPS walkthrough (socwrap)

socwrap can speak TLS too, so you can hand-type the HTTPS request and watch the
handshake + response:

```bash
cd examples/pxe-boot-mechanics/tools
./socwrap.sh --macros --macro-file macros/pxe-fetch.json \
             --crlf --tls --no-tls-verify -t localhost 8443
#   //set HOST localhost   //set KERNEL /kernel   //set INITRD /initrd.gz
#   //demo-kernel          # full GET of the kernel over TLS
```

(`--no-tls-verify` is socwrap's equivalent of `curl -k`, for the snakeoil cert.)

### 2.6 Clean up

```bash
docker stop netboot-https
```

---

## 3. TFTP — fetching ipxe.efi the way firmware does

TFTP is **binary, over UDP**, with a port-switch handshake (RRQ→DATA→ACK in
512-byte blocks). You can't hand-type it over a raw socket the way you can HTTP,
so the probe uses `curl tftp://` (and socwrap drives the real `tftp` client).
And as noted above, QEMU slirp's TFTP isn't reachable from the host — so we use
the **dnsmasq ProxyDHCP+TFTP** container, which binds host `:69`.

### 3.1 Stand up a reachable TFTP server

```bash
# Populate a TFTP root (copies ipxe.efi + boot.ipxe into ~/netboot/tftp/):
netboot/setup-dhcp-tftp.sh --server-ip 127.0.0.1 --iface lo --dir ~/netboot

# Run dnsmasq (needs root + host networking to bind :69):
sudo docker run --rm -d --name pxe-dnsmasq --network host --cap-add NET_ADMIN \
    -v ~/netboot/tftp:/tftp:ro \
    -v ~/.config/lab-netboot/dnsmasq-pxe.conf:/etc/dnsmasq.conf:ro \
    alpine:latest sh -c 'apk add -q dnsmasq && dnsmasq --no-daemon --log-facility=-'

ss -ulnp | grep ':69 '    # should show dnsmasq bound to the TFTP port
```

> For a **local fetch test** the ProxyDHCP half is irrelevant — there are no
> real DHCP clients on `lo`; all we need is dnsmasq's `enable-tftp` to bind
> `:69` so `curl tftp://localhost:69/…` has something to talk to. The
> `--server-ip`/`--iface` values only matter for the real-LAN story in
> `netboot/MANUAL_TESTING.md` §§11.4–11.5 (where they go into the DHCP boot
> options handed to physical machines).

### 3.2 Test the TFTP fetch with the probe

```bash
cd examples/pxe-boot-mechanics
tools/pxe-fetch.sh tftp ipxe.efi --host localhost
```

```
[pxe-fetch] TFTP fetch from tftp://localhost:69  (binary/octet)
── tftp GET ipxe.efi
      transfer: 1158144 bytes in 0.4s
[pxe-fetch]   fetched ipxe.efi (discarded)
```

### 3.3 Guided TFTP walkthrough (socwrap + tftp.json)

socwrap drives the *real* `tftp` client in exec mode (binary UDP isn't
hand-typable), with the connect/binary/get steps as macros:

```bash
cd examples/pxe-boot-mechanics/tools
./socwrap.sh --macros --macro-file macros/tftp.json -p 'tftp> ' -- tftp
#   //set HOST localhost   //set FILE ipxe.efi
#   //connect   //binary   //verbose   //get   //quit
```

> **Needs a `tftp` client installed** (`apt-get install tftp-hpa`, or `atftp`).
> If you don't have one, stick with `pxe-fetch.sh tftp` (curl) from §3.2 —
> `curl -V | grep tftp` confirms your curl can do it.

### 3.4 Clean up

```bash
sudo docker stop pxe-dnsmasq
```

---

## 4. Record a test for replay

Both tools can capture a session you can play back later — handy for notes or
showing someone the sequence:

```bash
# Native probe → script(1) typescript (asciinema if you have it):
tools/pxe-fetch.sh --record /tmp/https-test.cast from-ipxe ~/netboot/boot.ipxe --tls

# socwrap → asciicast v2 (built in — no asciinema needed), then replay:
cd tools
./socwrap.sh --record tftp-walk.cast --macros --macro-file macros/tftp.json -p 'tftp> ' -- tftp
./socwrap.sh --replay tftp-walk.cast --replay-speed 2
```

---

## 5. Troubleshooting

Read the **curl exit code** the probe prints — it pinpoints the layer:

| Symptom / exit code | Layer | Likely cause & fix |
|---|---|---|
| `curl failed (exit 7)` | TCP connect | Server not up, or wrong port. Host sees nginx on `localhost:8181`, **not** `10.0.2.2`. Start the server (§1/§2.3). |
| `curl failed (exit 28)` | timeout | For TFTP: dnsmasq not up (UDP never "refuses" — that's why the probe sets a timeout). `ss -ulnp \| grep :69`. |
| `curl failed (exit 35/60)` | TLS | Handshake / cert verify failed. Snakeoil cert → use `--tls` (adds `-k`) or `--server https://127.0.0.1:8443` to match the IP SAN. |
| HTTP `404` on a path | HTTP | That artifact name isn't served. Run `probe` to see real names; the minimal lab serves `/kernel`+`/initrd.gz`, distro labs `/vmlinuz`+`/initrd.img`. |
| iPXE in QEMU: `Error 0x… Untrusted` | iPXE TLS | Cert not embedded / wrong file. Rebuild with `--tls --tls-cert …netboot.der` (DER, not PEM). See `netboot/MANUAL_TESTING.md` §10.6. |
| `curl -V` shows no `tftp` | client | This curl lacks TFTP support; install a `tftp` client and use socwrap + `tftp.json` (§3.3). |

---

## ⚠️ Security

Lab use on an **isolated** network only. TFTP and plain HTTP have **no
authentication**; the HTTPS path here uses a **snakeoil** self-signed cert with
**no real trust** — never enroll or rely on it off the bench. Don't point these
probes at hosts you don't own, and don't bridge the netboot network to anything
untrusted. See [`README.md`](README.md) and [`tools/README.md`](tools/README.md).
