# RUNBOOK — do it all by hand

Everything the scripts do, unrolled into the exact commands you'd type yourself.
[`setup-pxe-http.sh`](setup-pxe-http.sh) and
[`https/build-ipxe-https.sh`](https/build-ipxe-https.sh) are conveniences — this
is what they run under the hood, so you can follow the two Dusty Mabe posts
step-by-step and see every moving part. The **HTTPS section (§B)** is the
centerpiece: enabling HTTPS in iPXE is *an edit to a source file and a
recompile*, shown in full.

### Where each step runs — host vs. container

Most of this is **inherently host-side**: libvirt/`virsh`/`virt-install` drive
*your* host's `qemu:///system`, and the HTTP/HTTPS servers must sit on the
`192.168.122.1` bridge the guest talks to. Those can't meaningfully move into a
container. The **one** step with no host coupling is compiling the custom HTTPS
iPXE — pure toolchain in, one `.lkrn` out. So §B offers it **two ways**: a
disposable **container** ([`https/Containerfile`](https/Containerfile)) that
keeps a C toolchain off your host, or the raw commands if you'd rather watch the
build happen. Either way you end up with the same `ipxe-https.lkrn`.

Conventions used below:

```bash
IP=192.168.122.1                                  # libvirt default bridge (virbr0)
WWW=~/.cache/lab-create/libvirt-ipxe-http-pxe/pxeserver   # the HTTP root
ISO=~/Downloads/Fedora-Server-dvd-x86_64-41-1.4.iso       # any current Server DVD
ISOBASE=$(basename "$ISO")
mkdir -p "$WWW"
```

---

# §A — Plain HTTP PXE, by hand (the two posts, modernized)

## A1. Stage the HTTP tree — *without* a sudo loop-mount

The posts do `sudo mount -o loop "$ISO" mnt/`. The rootless equivalent is to
**extract** the ISO — no root, no leftover mounts:

```bash
xorriso -osirrox on -indev "$ISO" -extract / "$WWW/$ISOBASE"
ls "$WWW/$ISOBASE/images/pxeboot/"        # → initrd.img  vmlinuz  (sanity check)
```

## A2. Write the kickstart (verbatim from post 1, + two modern lines)

```bash
cat > "$WWW/kickstart.cfg" <<EOF
url --url http://$IP:8000/$ISOBASE/
reboot
rootpw --plaintext foobar
services --enabled="sshd,chronyd"
zerombr
clearpart --all
autopart --type lvm
network --bootproto=dhcp
timezone --utc Etc/UTC
%packages
@core
%end
EOF
```

(`network`/`timezone` weren't in the 2019 kickstart; modern Anaconda halts a
headless install without them.)

## A3a. The **minus-pxelinux** bootfile (post 2) — an iPXE script

```bash
cat > "$WWW/boot.ipxe" <<EOF
#!ipxe
kernel $ISOBASE/images/pxeboot/vmlinuz console=ttyS0 inst.ks=http://$IP:8000/kickstart.cfg
initrd $ISOBASE/images/pxeboot/initrd.img
boot
EOF
```

## A3b. …or the **pxelinux** bootfile (post 1) — needs syslinux

```bash
# Fedora: sudo dnf install -y syslinux ; Debian: sudo apt-get install -y syslinux-common pxelinux
cp /usr/share/syslinux/{pxelinux.0,ldlinux.c32} "$WWW/"
mkdir -p "$WWW/pxelinux.cfg"
cat > "$WWW/pxelinux.cfg/default" <<EOF
DEFAULT pxeboot
TIMEOUT 20
PROMPT 0
LABEL pxeboot
    KERNEL $ISOBASE/images/pxeboot/vmlinuz
    APPEND initrd=$ISOBASE/images/pxeboot/initrd.img console=ttyS0 inst.ks=http://$IP:8000/kickstart.cfg
IPAPPEND 2
EOF
```

## A4. Serve it — one server, no TFTP

```bash
( cd "$WWW" && python3 -m http.server 8000 )        # leave running
```

## A5. Point libvirt's DHCP at the HTTP bootfile

The post uses `virsh net-edit default` (opens `$EDITOR`). The scriptable version
— dump, inject one line, redefine:

```bash
virsh -c qemu:///system net-dumpxml default > net-default.orig.xml    # BACKUP
# add, as the last child of <dhcp>:  (bootfile = boot.ipxe, or pxelinux.0 for §A3b)
cp net-default.orig.xml net-default-ipxe.xml
sed -i "s#\(\s*\)</dhcp>#\1  <bootp file='http://$IP:8000/boot.ipxe'/>\n\1</dhcp>#" net-default-ipxe.xml
xmllint --noout net-default-ipxe.xml && echo OK

virsh -c qemu:///system net-destroy default
virsh -c qemu:///system net-define  net-default-ipxe.xml
virsh -c qemu:///system net-start   default
```

The resulting `<dhcp>` block:

```xml
<dhcp>
  <range start='192.168.122.2' end='192.168.122.254'/>
  <bootp file='http://192.168.122.1:8000/boot.ipxe'/>
</dhcp>
```

## A6. Boot the installer VM (watch it HTTP-boot on serial)

```bash
virt-install --connect qemu:///system --pxe --network network=default \
    --name pxe --memory 2048 --disk size=10 \
    --nographics --boot menu=on,useserial=on \
    --osinfo detect=on,require=off
```

`--osinfo …` is the one modern addition — current `virt-install` errors without
an `--osinfo`/`--os-variant`. You'll see iPXE take a DHCP lease, fetch
`http://…/boot.ipxe`, then the kernel+initrd — all over HTTP.

## A7. Tear down / restore

```bash
virsh -c qemu:///system destroy pxe
virsh -c qemu:///system undefine pxe --remove-all-storage
virsh -c qemu:///system net-destroy default
virsh -c qemu:///system net-define  net-default.orig.xml    # put DHCP back
virsh -c qemu:///system net-start   default
```

---

# §B — HTTPS PXE, by hand — **enable HTTPS with an edit + a recompile**

The whole point: HTTPS in iPXE is not a runtime flag — you **turn it on in the
source and rebuild the firmware.** Here is exactly that.

## B1. Issue a server certificate from the lab CA

```bash
( cd ../lab-ca && ./make-ca.sh )                       # once, if the CA doesn't exist
( cd ../lab-ca && ./issue-server-cert.sh $IP IP:10.0.2.2 )   # leaf w/ SAN IP:192.168.122.1 (+10.0.2.2 for the qemu test)
```

The SAN **must** contain the address in the URL — iPXE matches the leaf's
`subjectAltName` against the host it connected to.

## B2★. Escape hatch — build the firmware in a container (skip B2–B6)

Don't want a C toolchain on your libvirt host? Build the `.lkrn` in a disposable
box instead. The **HTTPS edit and the recompile still happen** — they're just
baked into [`https/Containerfile`](https/Containerfile) (the `RUN sed …
DOWNLOAD_PROTO_HTTPS …` line) and [`https/container-build.sh`](https/container-build.sh)
(the `make … TRUST= EMBED=`), so nothing is hidden:

```bash
podman build -t mklab/ipxe-https https/
podman run --rm \
    -v "$PWD/../lab-ca:/ca:ro" \                 # the lab CA (only lab-ca.crt is read)
    -v "$WWW:/out" \                             # where the artifact lands
    -e IP="$IP" -e ISOBASE="$ISOBASE" \
    mklab/ipxe-https
# → $WWW/ipxe-https.lkrn  +  $WWW/boot.ipxe (chainloader) — then jump to B7
```

Only the finished `ipxe-https.lkrn` crosses back to the host; the toolchain,
the iPXE clone, and the build all stay in the container. **Or** do it by hand on
the host — B2–B6:

## B2. Get the iPXE source (host path)

```bash
git clone --depth=1 https://github.com/ipxe/ipxe.git
cd ipxe
```

## B3. ⭐ THE EDIT — re-enable HTTPS (modern iPXE disables it on BIOS)

Look at `src/config/general.h`. HTTPS is defined at the top…

```c
#define DOWNLOAD_PROTO_HTTPS	/* Secure Hypertext Transfer Protocol */
```

…but then **explicitly removed for BIOS builds** a few lines down:

```c
/* Disable protocols not historically included in BIOS builds */
#if defined ( PLATFORM_pcbios )
  #undef DOWNLOAD_PROTO_HTTPS        <-- THIS is why stock iPXE can't do HTTPS
  #undef HTTP_AUTH_NTLM
#endif
```

A SeaBIOS VM uses a pcbios iPXE, so it has **no HTTPS at all**. Delete/comment
that `#undef` (by hand, or with sed):

```bash
sed -i 's|^  #undef DOWNLOAD_PROTO_HTTPS|  /* keep HTTPS for the lab */|' src/config/general.h
grep -n 'DOWNLOAD_PROTO_HTTPS' src/config/general.h     # confirm the #undef is gone
```

While here, turn on the serial console so iPXE prints on `virt-install
--nographics` (edit `src/config/console.h`):

```bash
sed -i 's|^//#define\s*CONSOLE_SERIAL|#define CONSOLE_SERIAL|' src/config/console.h
```

## B4. Write the script iPXE will run once it can do HTTPS

```bash
cat > boot-https.ipxe <<EOF
#!ipxe
dhcp || exit 1
echo == iPXE HTTPS boot: kernel+initrd over TLS, verified vs the lab CA ==
kernel https://$IP:8443/$ISOBASE/images/pxeboot/vmlinuz console=ttyS0 inst.ks=http://$IP:8000/kickstart.cfg
initrd https://$IP:8443/$ISOBASE/images/pxeboot/initrd.img
boot
EOF
```

## B5. ⭐ THE RECOMPILE — bake in HTTPS, the lab-CA trust, and the script

`TRUST=` is what makes iPXE trust our **private** CA (instead of the public web
PKI); `EMBED=` bakes the script above into the binary. Targeting
`bin-x86_64-pcbios/` avoids needing `gcc -m32`:

```bash
make -C src bin-x86_64-pcbios/ipxe.lkrn \
    EMBED="$PWD/boot-https.ipxe" \
    TRUST="$PWD/../../lab-ca/lab-ca.crt" \
    -j"$(nproc)"
# → src/bin-x86_64-pcbios/ipxe.lkrn   (a firmware that speaks HTTPS + trusts the lab CA)
```

## B6. Install it + chainload it from the stock HTTP bootfile

The stock ROM still can't do HTTPS, so it fetches `boot.ipxe` over HTTP and
**chainloads** our custom iPXE, which takes it from there over TLS:

```bash
cp src/bin-x86_64-pcbios/ipxe.lkrn "$WWW/ipxe-https.lkrn"
cat > "$WWW/boot.ipxe" <<EOF
#!ipxe
chain http://$IP:8000/ipxe-https.lkrn
EOF
```

## B7. Serve two ports — HTTP bootstraps, HTTPS carries the payload

```bash
( cd "$WWW" && python3 -m http.server 8000 ) &                       # boot.ipxe + the .lkrn
CERTS=../lab-ca/private/certs
./https/serve-https.py --dir "$WWW" --port 8443 \                    # kernel + initrd, over TLS
    --cert "$CERTS/$IP-fullchain.crt" --key "$CERTS/$IP.key"
```

(`serve-https.py` is just `http.server` wrapped in an `ssl.SSLContext` loaded
with the lab-CA leaf — 20 lines you can read.)

## B8. Prove it — and prove it *rejects* an untrusted cert (no libvirt needed)

Boot the firmware directly in qemu; slirp reaches the host's TLS server at
`10.0.2.2`. **Positive** (lab-CA leaf, as served in B7):

```bash
qemu-system-x86_64 -m 512 -nographic -no-reboot -kernel "$WWW/ipxe-https.lkrn" \
    -netdev user,id=n0 -device e1000,netdev=n0
# → https://10.0.2.2:8443/.../vmlinuz... ok
#   https://10.0.2.2:8443/.../initrd.img... ok
```

**Negative** — re-serve with a self-signed cert that is *not* from the lab CA,
and iPXE refuses:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout bad.key -out bad.crt -days 3 \
    -subj "/CN=$IP" -addext "subjectAltName=IP:10.0.2.2"
./https/serve-https.py --dir "$WWW" --port 8443 --cert bad.crt --key bad.key
# boot again → https://10.0.2.2:8443/.../vmlinuz... Permission denied (https://ipxe.org/0216eb3c)
#              Nothing to boot: No such file or directory
```

That `Permission denied (…02…)` is iPXE's certificate-validation failure — the
`TRUST=` anchor doing exactly its job.

## B9. Run under libvirt

Rebuild B5 with the real bridge IP (`$IP=192.168.122.1`, no `10.0.2.2` needed),
keep both servers from B7 running, then the libvirt steps are **identical to
§A5–A7** — the DHCP bootfile is still `http://…/boot.ipxe`; only what it
chainloads changed.

---

See also: [`README.md`](README.md) (overview + the gems),
[`MANUAL_TESTING.md`](MANUAL_TESTING.md) (HTTP verification),
[`https/MANUAL_TESTING-https.md`](https/MANUAL_TESTING-https.md) (HTTPS
pos/neg transcripts).
