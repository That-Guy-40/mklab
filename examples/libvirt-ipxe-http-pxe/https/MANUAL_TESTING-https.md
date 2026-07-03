# HTTPS extension — manual testing / verification

The core gem — iPXE fetching over HTTPS and **verifying the server against the
lab CA** — is verifiable **rootless, without libvirt**, by booting the custom
`ipxe.lkrn` directly in qemu against a local TLS server. Verified 2026-07-02;
positive **and** negative.

```bash
cd examples/libvirt-ipxe-http-pxe/https
CA=../../lab-ca
```

---

## §0 — Build the custom iPXE

```bash
(cd "$CA" && ./issue-server-cert.sh 192.168.122.1 IP:10.0.2.2)   # 10.0.2.2 = qemu slirp host
# stage a tree first if you haven't (any Server DVD, or a synthetic one for a smoke test)
PXE_HTTP_DIR=~/.cache/lab-create/libvirt-ipxe-http-pxe/pxeserver \
  ./build-ipxe-https.sh --ip 10.0.2.2            # target the slirp host for the qemu test
```

**Pass:** it clones iPXE, re-enables HTTPS for pcbios, bakes `TRUST=lab-ca.crt` +
the embedded script, and drops `ipxe-https.lkrn` + a chainloader `boot.ipxe` into
the tree:

```text
[ipxe-https] install source: Fedora-Server-…iso
[ipxe-https] building ipxe.lkrn (HTTPS + TRUST=lab-ca.crt + serial + EMBED) …
[ipxe-https] installed: …/ipxe-https.lkrn  +  chainloader …/boot.ipxe
```

## §1 — Positive: lab-CA cert → HTTPS boot succeeds

Serve the tree over TLS with the **lab-CA leaf**, boot the `.lkrn` in qemu:

```bash
TREE=~/.cache/lab-create/libvirt-ipxe-http-pxe/pxeserver
./serve-https.py --dir "$TREE" --port 8443 --bind 127.0.0.1 \
    --cert "$CA/private/certs/192.168.122.1-fullchain.crt" \
    --key  "$CA/private/certs/192.168.122.1.key" &
qemu-system-x86_64 -m 512 -nographic -no-reboot -kernel "$TREE/ipxe-https.lkrn" \
    -netdev user,id=n0 -device e1000,netdev=n0
```

**Pass** — iPXE validates the cert against the baked-in lab CA and downloads over
TLS (and the server's access log shows the `GET`s return `200`):

```text
== iPXE HTTPS boot: kernel+initrd over TLS, verified vs the lab CA ==
https://10.0.2.2:8443/Fedora-Server-…/images/pxeboot/vmlinuz... ok
https://10.0.2.2:8443/Fedora-Server-…/images/pxeboot/initrd.img... ok
```

(With dummy kernel bytes it then says `Could not boot` — harmless; the **fetch**
is what we're proving.)

## §2 — Negative: rogue cert → iPXE refuses

Serve the *same* tree with a self-signed cert that has the right SANs but is
**not** signed by the lab CA, and boot again:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout bad.key -out bad.crt -days 3 \
    -subj "/CN=192.168.122.1" -addext "subjectAltName=IP:10.0.2.2"
./serve-https.py --dir "$TREE" --port 8443 --bind 127.0.0.1 --cert bad.crt --key bad.key &
qemu-system-x86_64 -m 512 -nographic -no-reboot -kernel "$TREE/ipxe-https.lkrn" \
    -netdev user,id=n0 -device e1000,netdev=n0
```

**Pass** — iPXE rejects the untrusted certificate and boots nothing:

```text
== iPXE HTTPS boot: kernel+initrd over TLS, verified vs the lab CA ==
https://10.0.2.2:8443/…/vmlinuz... Permission denied (https://ipxe.org/0216eb3c)
Nothing to boot: No such file or directory (https://ipxe.org/2d03e13b)
```

`0216eb3c` is iPXE's TLS certificate-validation failure — proof the `TRUST=`
anchor is doing real work.

---

## §3 — Full run under libvirt *(yours to run)*

Same as the base lab, but the payload comes over HTTPS. Build with the real
bridge IP (`./build-ipxe-https.sh`, default `--ip 192.168.122.1`), run **both**
servers (HTTP `:8000` for `boot.ipxe`+`.lkrn`, `serve-https.py` `:8443` for
kernel/initrd), then `../setup-pxe-http.sh netxml --variant ipxe` + `virtinstall`.
The serial console shows the stock iPXE chainloading `ipxe-https.lkrn`, then the
HTTPS fetches above, then Anaconda.

## Gotchas baked in

| Symptom | Cause | Handled by |
|---|---|---|
| stock iPXE: `https:// … not supported` / no HTTPS | modern iPXE `#undef DOWNLOAD_PROTO_HTTPS` for `PLATFORM_pcbios` | builder re-enables it in `config/general.h` |
| `... Permission denied (https://ipxe.org/02…)` with the *right* cert | server leaf not signed by the trusted CA, or wrong `TRUST=` | build with `TRUST=lab-ca.crt`; serve the lab-CA leaf |
| cert rejected though CA is trusted | leaf SAN doesn't match the URL host | issue the leaf with the bridge IP in SAN (`issue-server-cert.sh 192.168.122.1`) |
| iPXE prints nothing on `--nographics` | default is the VGA console | builder enables `CONSOLE_SERIAL` |
| `make` wants `gcc -m32` | default iPXE arch is i386 | builder targets `bin-x86_64-pcbios/` |
