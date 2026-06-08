# Hand-walk: *Booting Rocky Linux via PXE (Lorax, dnsmasq, TFTP)*, by hand

Follow the CIQ KB article **inside a RHEL-family container that carries its
server stack** — use **Lorax** to build PXE boot images, then **dnsmasq**
(DHCP+TFTP) + HTTP to network-boot the Rocky installer. The **install target** is
the repo's existing QEMU client.

- **The post (byte-exact archive):** [`../upstream-tutorial/`](../upstream-tutorial/) ·
  canonical: <https://kb.ciq.com/article/rocky-linux/rl-booting-rocky-linux-via-pxe>
- **The environment as code:** [`Containerfile`](Containerfile) — Rocky Linux +
  `lorax` + `dnsmasq` + `tftp-server` + `python3`.
- **Client + automated take:** install target is
  [`../rocky-pxe-lab.toml`](../rocky-pxe-lab.toml); the repo's automated lab
  (Path A) fetches upstream pxeboot images instead of running Lorax. This
  hand-walk follows the *article's* Lorax route by hand.

> **One step is author-only in this sandbox.** `lorax` builds boot media through a
> throwaway install root that needs **loop devices + `mknod`** — which this build
> sandbox blocks even with `--privileged`. So **§1 (Lorax) you run on your own
> host** (which grants loop/mknod); §2–§3 (dnsmasq/TFTP/HTTP) run anywhere. This
> is flagged honestly rather than pretending it ran here.

---

## 0. Bring up the box (on your host)

```bash
# from the repo root:
phase4-podman/lab-podman.sh build --tag rockypxe-handwalk \
    --context examples/rocky-pxe-lab/hand-walk
mkdir -p out
podman run --rm -it --privileged -v "$PWD/out:/out:Z" rockypxe-handwalk bash
```

`--privileged` because Lorax needs real loop/`mknod`; on your own machine podman
grants them (this CI-style sandbox does not — hence the §1 caveat).

---

## 1. Build the PXE boot images with Lorax  ⚠️ *needs loop/mknod (host)*

The article's exact command (it targets Rocky **10**; change `10`→`9` everywhere
to feed the repo's Rocky-9 client):

```bash
cd /work
lorax --product "RockyLinux" --version "10" --release "10" \
  --source "https://download.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/" \
  --source "https://download.rockylinux.org/pub/rocky/10/AppStream/x86_64/os/" \
  --isfinal --logfile lorax.log --buildarch x86_64 --volid "RL10_LIVENET" \
  /out/lorax-out
```

**What Lorax does.** It spins up a temporary install root from the Rocky repos and
bakes a bootable install environment, emitting (among other things)
`/out/lorax-out/images/pxeboot/{vmlinuz,initrd.img}` — the kernel + installer
initrd you'll serve. That temp root is *why* it needs loop/`mknod` and real root.

---

## 2. dnsmasq: DHCP + TFTP

```bash
mkdir -p /srv/tftp
cp /out/lorax-out/images/pxeboot/{vmlinuz,initrd.img} /srv/tftp/
cat > /etc/dnsmasq.d/pxe.conf <<'EOF'
# DHCP + TFTP for PXE.  Use ProxyDHCP (port=0 + dhcp-range ...,proxy) to coexist
# with an existing LAN DHCP; or a full range if this box owns DHCP.
port=0
dhcp-range=192.168.1.0,proxy
dhcp-boot=pxelinux.0           # or ipxe.efi for UEFI clients
enable-tftp
tftp-root=/srv/tftp
EOF
dnsmasq --test --conf-file=/etc/dnsmasq.d/pxe.conf      # → "syntax check OK"
dnsmasq -d --conf-file=/etc/dnsmasq.d/pxe.conf          # run in foreground
```

(For real hardware you'd run the box `--network host --cap-add NET_ADMIN`, or use
the repo's host-level [`netboot/setup-dhcp-tftp.sh`](../../../netboot/setup-dhcp-tftp.sh).)

---

## 3. Serve the install tree + kickstart over HTTP

```bash
ln -s /out/lorax-out /out/www 2>/dev/null || true
mkdir -p /out/www/ks && cp /lab/rocky9-zerotouch.ks /out/www/ks/default.ks   # if /lab bind-mounted
cd /out/www && python3 -m http.server 8181        # 8181, not 8080 (SABnzbd owns 8080 here)
```

The installer pulls its stage2 + kickstart over this; Anaconda runs unattended.

---

## 4. Install the client (the existing QEMU VM)

On the host, with the server up:

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/rocky-pxe-lab/rocky-pxe-lab.toml
phase2-qemu-vm/lab-vm.sh start   rocky-pxe-install     # ~10–15 min, unattended
phase2-qemu-vm/lab-vm.sh console rocky-pxe-install     # optional: watch Anaconda
# after:  lab-vm.sh ssh rocky-pxe-install              # login: lab / lab
```

---

## 5. Tear down & provenance

`exit` the `--rm` box; `out/` stays on the host. `podman rmi rockypxe-handwalk`.
Destroy the VM: `phase2-qemu-vm/lab-vm.sh destroy rocky-pxe-install --force`.

- **Provenance.** The archived article under [`../upstream-tutorial/`](../upstream-tutorial/)
  is a **CIQ Knowledge Base** work; all rights remain with CIQ/the authors.
  Vendored for offline reference (it's a Next.js page — archived as complete text,
  not pixel-perfect); this runbook only operationalises it. Prefer the
  [canonical page](https://kb.ciq.com/article/rocky-linux/rl-booting-rocky-linux-via-pxe).
- **Verified in this box:** the RHEL-family environment builds and carries a
  working `lorax`, `dnsmasq` (config `--test` OK), and `tftp-server`. **The Lorax
  *run* (§1) is author-only here** (needs loop/`mknod`, blocked in this sandbox) —
  run it on your host; the install then follows the parent lab's tested path.
