# Hand-walk: *Installing AlmaLinux over the network, no hands*, by hand

Follow Kenneth Finnegan's zero-touch PXE post **inside a disposable container that
carries the PXE-server prerequisites** — build an iPXE EFI binary with an embedded
script, serve the AlmaLinux installer + a kickstart over HTTP, and (for real
hardware) run a `dnsmasq` ProxyDHCP/TFTP responder. The **install target** is the
repo's existing QEMU client.

- **The post (byte-exact archive):** [`../upstream-tutorial/`](../upstream-tutorial/) ·
  canonical: <https://blog.thelifeofkenneth.com/2026/01/almalinux-pxe-zerotouh.html>
- **The environment as code:** [`Containerfile`](Containerfile) — iPXE build
  toolchain + `dnsmasq` + `python3` (HTTP).
- **Client + automated take:** the install target is
  [`../vm-almalinux-pxe-install.toml`](../vm-almalinux-pxe-install.toml); the
  one-shot automated version is [`../almalinux-pxe-lab.toml`](../almalinux-pxe-lab.toml)
  (Phase-4 nginx + Phase-2 VM). This hand-walk is the *by-hand server build*.

> **Reuse the lab's assets.** Don't re-invent the installer fetch or the
> kickstarts — bind-mount the lab dir and use
> [`../fetch-almalinux-installer.sh`](../fetch-almalinux-installer.sh) and the
> ready [`../almalinux-zerotouch.ks`](../almalinux-zerotouch.ks) /
> [`../almalinux-uefi-zerotouch.ks`](../almalinux-uefi-zerotouch.ks).

---

## 0. Bring up the box

HTTP serving needs no privileges; the optional Path-B `dnsmasq` does. Build via
the phase tool, publish :8181, bind an `out/` dir for the served tree + the lab
dir (read-only) for the fetch script + kickstarts:

```bash
# from the repo root:
phase4-podman/lab-podman.sh build --tag almapxe-handwalk \
    --context examples/almalinux-pxe-lab/hand-walk
mkdir -p out
podman run --rm -it -p 8181:8181 \
    -v "$PWD/out:/out:Z" -v "$PWD/examples/almalinux-pxe-lab:/lab:ro" \
    almapxe-handwalk bash
```

---

## 1. Fetch the AlmaLinux installer (kernel + initrd + stage2)

iPXE will chainload the *upstream* `pxeboot/vmlinuz` + `initrd.img`; the ~1 GB
stage2 (`install.img`) is best served locally so a slow link doesn't truncate it.
The lab already has a verified fetcher (checks sha256 against `.treeinfo`):

```bash
/lab/fetch-almalinux-installer.sh --dest /out      # vmlinuz, initrd.img, images/install.img
```

(Or by hand, per the post: `wget` them from
`http://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/images/pxeboot/`.)

---

## 2. Build the iPXE EFI binary with an embedded boot script

This is the post's core step. The embedded script DHCPs, then chainloads the
installer with `inst.repo` + `inst.ks` (kickstart) parameters:

```bash
cd /work
git clone --depth 1 https://github.com/ipxe/ipxe.git
cd ipxe/src
cat > almascript.ipxe <<'EOF'
#!ipxe
dhcp
set repo http://10.0.2.2:8181/
kernel ${repo}vmlinuz inst.repo=${repo} inst.stage2=${repo} inst.ks=${repo}ks/${net0/mac}.cfg inst.text console=ttyS0 ip=dhcp
initrd ${repo}initrd.img
boot
EOF
make -j"$(nproc)" bin-x86_64-efi/ipxe.efi EMBED=almascript.ipxe
cp bin-x86_64-efi/ipxe.efi /out/
```

**Why `EMBED=`.** Baking the script into the ROM means the client needs *no*
interactive iPXE config — it boots, runs your script, and installs. Kenneth's
script keys the kickstart URL off the NIC's MAC (`${net0/mac}`) so each machine
gets its own answer file. (`10.0.2.2:8181` is the QEMU-slirp host alias + the
repo's netboot port.)

---

## 3. Stage the kickstart + serve everything over HTTP

```bash
mkdir -p /out/ks
# name the kickstart after the client's MAC (iPXE substitutes it):
cp /lab/almalinux-zerotouch.ks /out/ks/52-54-00-a1-9a-01.cfg
cd /out && python3 -m http.server 8181        # 8181, not 8080 (SABnzbd owns 8080 here)
```

Verify from another shell: `curl -sI http://localhost:8181/vmlinuz` → `200`.

---

## 4. (Path B — real hardware) dnsmasq ProxyDHCP + TFTP

For physical targets you need a PXE responder. `dnsmasq` in **ProxyDHCP** mode
coexists with your existing router DHCP and just adds the boot info, handing out
`ipxe.efi` over TFTP. This needs `NET_ADMIN` + the ability to bind DHCP ports, so
launch the box with `--cap-add NET_ADMIN --cap-add NET_BIND_SERVICE --network host`
(or use the repo's host-level [`netboot/setup-dhcp-tftp.sh`](../../../netboot/setup-dhcp-tftp.sh)):

```bash
mkdir -p /srv/tftp && cp /out/ipxe.efi /srv/tftp/
cat > /etc/dnsmasq.d/pxe.conf <<'EOF'
port=0                       # DNS off — DHCP/TFTP only (ProxyDHCP)
dhcp-range=192.168.1.0,proxy
dhcp-boot=ipxe.efi
enable-tftp
tftp-root=/srv/tftp
EOF
dnsmasq --test               # validate the config
dnsmasq -d --conf-file=/etc/dnsmasq.d/pxe.conf   # run in foreground
```

For the QEMU client below you don't need Path B at all — the VM boots the
installer directly (Path A).

---

## 5. Install the client (the existing QEMU VM)

On the **host** (not in the box), with the artifact server from §3 up:

```bash
phase2-qemu-vm/lab-vm.sh create --config examples/almalinux-pxe-lab/vm-almalinux-pxe-install.toml
phase2-qemu-vm/lab-vm.sh start   almalinux-pxe-install     # zero-touch — walk away
phase2-qemu-vm/lab-vm.sh console almalinux-pxe-install     # optional: watch Anaconda
# after install:  lab-vm.sh ssh almalinux-pxe-install      # login: lab / lab
```

Anaconda pulls your kickstart over HTTP and installs AlmaLinux with **no
keystrokes** — the whole point of the post.

---

## 6. Tear down & provenance

`exit` the `--rm` box; `out/` artifacts stay on the host (delete when done).
`podman rmi almapxe-handwalk`. Destroy the VM with
`phase2-qemu-vm/lab-vm.sh destroy almalinux-pxe-install --force`.

- **Provenance.** The archived post under [`../upstream-tutorial/`](../upstream-tutorial/)
  is the work of **Kenneth Finnegan**; all rights remain with the author.
  Vendored for offline reference; this runbook only operationalises it. Prefer the
  [canonical page](https://blog.thelifeofkenneth.com/2026/01/almalinux-pxe-zerotouh.html).
- **Verified in this box:** the iPXE **EFI** build (`bin-x86_64-efi/ipxe.efi`,
  `EMBED=`) and the `dnsmasq --test` config. The installer fetch, HTTP serve, and
  the Anaconda install follow the parent lab's already-tested path.
