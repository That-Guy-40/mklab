# libvirt-ipxe-http-pxe — manual testing / walkthrough

Every stage, with **real expected output**. The lab splits cleanly in two:

- **Rootless half** (§0–§3) — staging + HTTP serving + XML generation. Needs no
  root and no VM; **verified here 2026-07-02** and safe to re-run.
- **libvirt half** (§4–§6) — pointing the network at the HTTP bootfile and
  running the installer VM. This **edits your `default` network and spins a
  guest**, so it's **yours to run**; the expected serial output below is quoted
  from the upstream posts.

```bash
cd examples/libvirt-ipxe-http-pxe
ISO=~/Downloads/Fedora-Server-dvd-x86_64-41-1.4.iso   # any current Server DVD
```

> This lab uses `qemu:///system`. Your user must reach it without `sudo` (be in
> the `libvirt` group) — check with `virsh -c qemu:///system net-list --all`.

---

## §0 — Preflight

```bash
# Fedora:  sudo dnf install -y libvirt virt-install xorriso syslinux
# Debian:  sudo apt-get install -y libvirt-daemon-system virtinst xorriso syslinux-common pxelinux
```

`xorriso` is for the rootless ISO extract; `syslinux`/`pxelinux` only for the
`pxelinux` variant. **Pass:** `virt-install --version` and `xorriso -version`
both print.

## §1 — Stage the HTTP tree (rootless)

```bash
./setup-pxe-http.sh stage --iso "$ISO" --variant ipxe
```

**Pass** = the ISO is extracted (no `sudo`, no loop-mount) and configs generated:

```text
[pxe-http] extracting Fedora-Server-…iso (rootless, via xorriso — no loop-mount) …
[pxe-http] generated: kickstart.cfg + boot.ipxe
├── boot.ipxe
├── Fedora-Server-…iso/   (EFI images isolinux Packages repodata …)
└── kickstart.cfg
```

Inspect the generated `boot.ipxe` — note your ISO's name is substituted in:

```text
#!ipxe
kernel Fedora-Server-…iso/images/pxeboot/vmlinuz console=ttyS0 inst.ks=http://192.168.122.1:8000/kickstart.cfg
initrd Fedora-Server-…iso/images/pxeboot/initrd.img
boot
```

## §2 — Serve it, and prove the fetch paths resolve

In one terminal:

```bash
./setup-pxe-http.sh serve            # Serving HTTP on 0.0.0.0 port 8000 …
```

In another, confirm every URL iPXE and Anaconda will request returns **200**
(this is the whole "HTTP only" claim, verified):

```bash
for p in boot.ipxe kickstart.cfg \
         Fedora-Server-*/images/pxeboot/vmlinuz \
         Fedora-Server-*/repodata/repomd.xml; do
  curl -s -o /dev/null -w "%{http_code}  /$p\n" "http://127.0.0.1:8000/$p"
done
```
```text
200  /boot.ipxe
200  /kickstart.cfg
200  /…/images/pxeboot/vmlinuz
200  /…/repodata/repomd.xml
```

## §3 — Generate the libvirt network XML (read-only dump + inject)

```bash
./setup-pxe-http.sh netxml --variant ipxe
```

**Pass:** it dumps your `default` net **read-only**, writes a modified copy with
the `<bootp>` line added (and backs up the original), and it passes `xmllint`:

```text
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
      <bootp file='http://192.168.122.1:8000/boot.ipxe'/>
    </dhcp>
```

Nothing has touched libvirt yet — only files under `PXE_HTTP_DIR`.

---

## §4 — Apply the network change *(you run this — edits libvirt)*

`netxml` printed these; run them to swap in the bootfile:

```bash
virsh -c qemu:///system net-destroy default
virsh -c qemu:///system net-define  <PXE_HTTP_DIR>/net-default-ipxe.xml
virsh -c qemu:///system net-start   default
```

## §5 — Launch the installer VM *(you run this — spins a guest)*

```bash
virt-install --connect qemu:///system --pxe --network network=default \
    --name pxe --memory 2048 --disk size=10 \
    --nographics --boot menu=on,useserial=on \
    --osinfo detect=on,require=off
```

**Verified non-mutating check:** the same command with `--dry-run` appended
returns `Dry run completed successfully` here. **Expected on a real run** (serial
console) — iPXE HTTP-boots with no TFTP:

```text
iPXE 1.0.0+ -- Open Source Network Boot Firmware -- http://ipxe.org
Features: DNS HTTP iSCSI TFTP AoE ELF MBOOT PXE bzImage Menu PXEXT
Configuring (net0 …)... ok
net0: 192.168.122.216/255.255.255.0 gw 192.168.122.1
Filename: http://192.168.122.1:8000/boot.ipxe
http://192.168.122.1:8000/boot.ipxe... ok
boot.ipxe : 209 bytes [script]
Fedora-Server-…/images/pxeboot/vmlinuz... ok
Fedora-Server-…/images/pxeboot/initrd.img... ok
Probing EDD (edd=off to disable)... ok
```

Anaconda then fetches `kickstart.cfg` over HTTP and installs `@core` unattended,
`reboot`s, and (per the kickstart) the VM comes up with `root` / `foobar`.

For the **`pxelinux` variant**, `stage --variant pxelinux` instead (needs
`syslinux`), point `netxml --variant pxelinux` (bootfile → `pxelinux.0`), and the
serial log shows `PXELINUX 6.04` loading the kernel rather than a bare `#!ipxe`
script.

## §6 — Tear down *(you run this)*

```bash
virsh -c qemu:///system destroy pxe
virsh -c qemu:///system undefine pxe --remove-all-storage
# restore your network (command printed by netxml; uses the backed-up XML):
virsh -c qemu:///system net-destroy default
virsh -c qemu:///system net-define  <PXE_HTTP_DIR>/net-default.orig.xml
virsh -c qemu:///system net-start   default
./setup-pxe-http.sh clean            # remove the HTTP tree
```

---

## Gotchas baked in

| Symptom | Cause | Handled by |
|---|---|---|
| `virt-install: error … --os-variant/--osinfo required` | modern virt-install demands OS info | printed command adds `--osinfo detect=on,require=off` |
| would need `sudo mount -o loop` | the post loop-mounts the DVD | `xorriso -osirrox` extract (rootless) |
| Anaconda halts on a headless install | no `network`/`timezone` in kickstart | both added (2019 kickstart otherwise verbatim) |
| `pxelinux.0` missing (Debian) | pxelinux ships separately | `stage` warns; `apt install syslinux-common pxelinux` |
| other VMs lose normal DHCP afterward | you left the `<bootp>` line in `default` | restore `net-default.orig.xml` (§6) |
