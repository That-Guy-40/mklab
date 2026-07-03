# HTTPS extension — PXE-boot kernel+initrd over TLS, verified against the lab CA

An extension to [`../`](../README.md): keep the whole easy-PXE flow, but fetch the
**kernel and initrd over HTTPS**, with the server certificate **verified against
the shared [lab CA](../../lab-ca/README.md)** — the same trust anchor the
LinuxBoot P2/P3 tiers use. This is "PXE, but the boot artifacts arrive over TLS
from a server your firmware actually authenticates."

## Why this needs a *custom* iPXE (two build-time gems)

libvirt's stock iPXE ROM can't do it, for two reasons both fixed only at **build
time** — which is the whole lesson:

1. **Modern iPXE disables HTTPS on BIOS builds.** `config/general.h` literally
   does:
   ```c
   #if defined ( PLATFORM_pcbios )
     #undef DOWNLOAD_PROTO_HTTPS
   #endif
   ```
   so a BIOS iPXE (what a SeaBIOS VM uses) has **no HTTPS at all**. We re-enable it.
2. **iPXE only trusts CAs baked in with `TRUST=`.** To trust a *private* CA (our
   lab CA) rather than the public web PKI, we build with `TRUST=lab-ca.crt`. iPXE
   then validates the server's leaf against it — and the leaf's `subjectAltName`
   must match the address in the URL (so the lab-CA leaf carries
   `IP:192.168.122.1`).

We also enable `CONSOLE_SERIAL` (so iPXE shows on `virt-install --nographics`)
and `EMBED` a boot script so the custom iPXE runs the HTTPS fetch unattended.

## The chain

The DHCP bootfile stays the **stock HTTP** path (the stock ROM can't speak
HTTPS), so `boot.ipxe` is rewritten to *chainload* our custom iPXE over HTTP;
that new iPXE does everything else over TLS:

```
DHCP → stock iPXE ─HTTP→ boot.ipxe ─HTTP→ chain ipxe-https.lkrn
     → (custom iPXE: HTTPS + lab-CA trust) ─HTTPS→ vmlinuz + initrd → boot
```

The one HTTP hop that remains is the bootstrap (`boot.ipxe` + the `.lkrn`). To
remove it entirely you'd bake the custom ROM into libvirt's NIC
(`<interface><rom file='ipxe-https.rom'/>`) so HTTPS starts at the firmware —
noted as a hardening step, not wired here (it needs a ROM readable by
`qemu:///system`).

## Walk through it

Assumes you've already `stage`d the HTTP tree (`../setup-pxe-http.sh stage --iso
… --variant ipxe`) and the [lab CA exists](../../lab-ca/README.md)
(`../../lab-ca/make-ca.sh`).

```bash
cd examples/libvirt-ipxe-http-pxe/https

# 1. Issue a lab-CA server leaf for the bridge IP (adds IP:192.168.122.1 SAN):
(cd ../../lab-ca && ./issue-server-cert.sh 192.168.122.1)

# 2. Build the custom iPXE + rewrite boot.ipxe to chainload it (clones iPXE, ~1–2 min):
./build-ipxe-https.sh                       # --ip / --http-port / --https-port to override

# 3. Serve the tree twice — HTTP bootstraps, HTTPS carries the payload:
( cd ~/.cache/lab-create/libvirt-ipxe-http-pxe/pxeserver && python3 -m http.server 8000 )   # terminal A
./serve-https.py --port 8443 \                                                               # terminal B
    --dir ~/.cache/lab-create/libvirt-ipxe-http-pxe/pxeserver \
    --cert ../../lab-ca/private/certs/192.168.122.1-fullchain.crt \
    --key  ../../lab-ca/private/certs/192.168.122.1.key

# 4. Point libvirt + launch — unchanged from the HTTP lab (bootfile is still http boot.ipxe):
../setup-pxe-http.sh netxml --variant ipxe
../setup-pxe-http.sh virtinstall
```

On the serial console you'll see the custom iPXE take over and fetch over TLS:

```text
== iPXE HTTPS boot: kernel+initrd over TLS, verified vs the lab CA ==
https://192.168.122.1:8443/Fedora-Server-…/images/pxeboot/vmlinuz... ok
https://192.168.122.1:8443/Fedora-Server-…/images/pxeboot/initrd.img... ok
```

## What's verified vs. yours to run

**Verified rootless here (2026-07-02)** — the core gem, positive **and**
negative, in plain qemu (`-kernel ipxe-https.lkrn`, slirp, e1000):

- **positive:** with the lab-CA leaf, iPXE fetches `https://…/vmlinuz... ok` +
  `initrd.img... ok`;
- **negative:** with a rogue self-signed cert (same SANs, wrong CA), iPXE
  refuses — `vmlinuz... Permission denied (https://ipxe.org/0216eb3c)` → `Nothing
  to boot`. So the trust is real, not "accept anything."

Transcripts + the exact commands: [MANUAL_TESTING-https.md](MANUAL_TESTING-https.md).
The **libvirt half** (chainload from the default network, run the VM) is yours to
run, same as the base lab.

## Going further — HTTPS for Anaconda too

This secures the transport iPXE controls (bootstrap → kernel → initrd). The
`inst.ks=` kickstart and the `url --url` repo are **Anaconda's** fetches — a
separate TLS trust domain (the installer's own CA store, not iPXE's). The
embedded script keeps those on HTTP so the lab works out of the box. To push them
onto HTTPS you'd make Anaconda trust the lab CA — either inject it
(`inst.ks=https://…` with the CA added to the installer's trust, e.g. a
`%pre`-fetched bundle) or, bluntly, `inst.noverifyssl` (which throws away the
verification the lab exists to demonstrate — so prefer trusting the CA).

## ⚠️ Security

The custom iPXE **trusts the lab CA for all TLS** — it's a lab trust anchor, so
never ship this `.lkrn` outside the lab. Keep the lab-CA **private key**
(`../../lab-ca/private/`) gitignored, as it is. The HTTP bootstrap hop is
unauthenticated (see above); fine on the libvirt NAT, not on a hostile network.
