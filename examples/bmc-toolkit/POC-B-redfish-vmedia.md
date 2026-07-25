# POC-B — Redfish virtual media as a deploy path (the centerpiece)

**Spike goal** (`BMC_TOOLKIT_LAB_PLAN.md` §4): prove Redfish **virtual media** is a real
OS-delivery model — `InsertMedia` mounts an ISO and the node **boots it, with NO
PXE/DHCP/TFTP**. This is the lab's centerpiece and the pre-built 5th MAAS deploy driver.

**Result: ✅ PASS — proven fully headless AND rootless.** Ran end-to-end over
`qemu:///session` (user-session libvirt) with sushy-tools driven by `curl`+`jq`. No root,
no system libvirt, no PXE stack of any kind.

## Environment
- `sushy-tools` **2.2.0** in a venv (reusing system `libvirt-python`), `sushy-emulator`.
- `qemu:///session` libvirt (user is in `kvm`+`libvirt` groups, `/dev/kvm` usable).
- Serial source ISO: **isolinux/BIOS** ISO (`genisoimage` + `/usr/lib/ISOLINUX`) that
  boots `~/netboot/vmlinuz` with the marker baked into the **kernel command line**.

## Verified transcript (real)
```
System: /redfish/v1/Systems/df593f7a-8c77-479a-aafb-565cc2a294f0
--- VirtualMedia BEFORE ---  Inserted=False Image=
InsertMedia http://127.0.0.1:8899/proof.iso        InsertMedia HTTP 204
--- VirtualMedia AFTER ---   Inserted=True  Image=http://127.0.0.1:8899/proof.iso
set one-time boot override -> Cd                    PATCH Boot HTTP 204
--- domain XML now has the virtual CD? ---
      <disk type='file' device='cdrom'>
        <driver name='qemu' type='raw'/>
        <source file='…/pool/proof-iso-<uuid>.img'/>
        <target dev='hdc' bus='ide'/>
power On (Redfish Reset)                            Reset HTTP 204
--- node serial ---
  [    0.000000] Command line: BOOT_IMAGE=/vmlinuz console=ttyS0,115200 BMC_TOOLKIT_VMEDIA_BOOT_PROOF=inserted-cd
PASS: Redfish InsertMedia attached the ISO and the node BOOTED it over virtual media — no PXE/DHCP/TFTP
```

Two independent proofs in one run: **control-plane** (`VirtualMedia.Inserted=True` +
the domain XML gains a `<disk device='cdrom'>` pointing at the uploaded ISO) and **boot**
(the node's serial shows the kernel that came off that virtual CD).

## Gotchas found (→ the `redfish` backend + RUNBOOK teaching moments)
1. **`InsertMedia` `Image` must be an HTTP(S) URL.** sushy's `_get_image` uses
   `requests.get(url)` — a bare path or `file://` won't fetch. So the toolkit **serves
   the ISO over HTTP** (localhost is fine). This is *faithful to real BMCs* — Redfish
   virtual media downloads the ISO from a URL. `bmc.sh … insert-media <iso>` will spin up
   a tiny local HTTP server (or accept a URL directly).
2. **sushy `_upload_image` requires a libvirt storage pool** (`SUSHY_EMULATOR_STORAGE_POOL`,
   default `default`) and copies the ISO in as a volume. `qemu:///session` has **no pools
   by default** → create a `default` dir-pool first (`virsh pool-define-as default dir …`).
3. **sushy ADDS the cdrom itself** — the node does **not** need a pre-provisioned spare
   cdrom slot. `_add_boot_image` appends a fresh `<disk device='cdrom'>` on `hdc/ide`.
   → **Plan correction:** §4a's "provision a second (empty) cdrom device" is **unnecessary**
   for the Redfish path; the node just needs an IDE controller (i440fx has one).
4. **The domain must be persistent** (`virsh define`, not transient `create`) — sushy uses
   `defineXML` to attach the media.
5. **UEFI vs BIOS (the plan's open axis) — BIOS proven, UEFI needs a config override.**
   sushy's default `BOOT_LOADER_MAP` UEFI x86_64 path is `/usr/share/OVMF/OVMF_CODE.secboot.fd`,
   which is **absent** here (host ships `OVMF_CODE_4M.fd`). BIOS/Legacy (`x86_64: None`)
   needs no loader and booted cleanly, so **v1 uses BIOS**; UEFI works by overriding
   `SUSHY_EMULATOR_BOOT_LOADER_MAP` to the real OVMF path — a one-line config, documented.
6. **syslinux `SAY`/`DISPLAY` don't reliably mirror to serial** (only the `boot:` prompt
   and the ISOLINUX banner do). Robust unique marker = bake it into the **kernel command
   line**; the kernel echoes `Command line: …` on `console=ttyS0` in early boot.
7. **sushy-emulator has no auth by default** (plain `curl`); `--feature-set` default
   (full) provides power + vmedia both. `qemu:///session` + `<serial type='file'>` logs
   the node console to a file with no apparmor friction on this host.

## Significance
- Redfish virtual media is a **distinct deploy model** from everything else in the repo:
  PXE-install needs dnsmasq/TFTP/HTTP (the whole `setup-pxe-net.sh` stack); this needs
  **only an ISO URL**. That contrast *is* the centerpiece teaching moment.
- It's the **5th MAAS deploy driver**, now proven: `bmc.sh <node> insert-media <iso> &&
  bootdev cdrom && power cycle` against a redfish-backed node.

## Reusable artifacts (promote to `examples/bmc-toolkit/` at assembly)
- `node.xml.template` — the session node shape (BIOS, serial→file, IDE controller).
- `build-proof-iso` steps — isolinux + kernel-cmdline-marker (a self-contained bootable
  serial ISO for tests; the real lab feeds real installer ISOs).
- `run-spikeB.sh` — the InsertMedia→boot proof (one verdict; virsh-lifecycle teardown).
- The `default` session storage-pool + HTTP-serve idioms → the `redfish` backend.
