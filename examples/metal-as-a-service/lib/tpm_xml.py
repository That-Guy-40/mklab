#!/usr/bin/env python3
"""Give a libvirt domain a TPM 2.0 device and UEFI firmware, on stdin -> stdout.

    virsh dumpxml <dom> | tpm_xml.py [--ovmf CODE.fd] | virsh define /dev/stdin

Sibling of console_xml.py and rom_xml.py: the same shape, the same rule — rewrite
the domain XML rather than hand-editing it, and refuse rather than half-apply.

WHY BOTH, AND WHY THEY ARE NOT SEPARABLE. A TPM alone buys nothing here. Measured
under swtpm, a **BIOS** domain measures the boot-sector code and the partition
table and *nothing in the filesystem*: two golden images with completely different
kernels measure identically, so a PCR policy over a BIOS boot blesses any payload.
Under UEFI the firmware measures the binary it loads, so a UKI payload IS the
measurement. A domain given a TPM but left on BIOS would produce quotes that
verify, match a policy, and mean nothing — the worst possible outcome for an
attestation gate, because everything looks green. So this script sets both, and
refuses to set only one.

The `loader`/`nvram` pair is what switches a domain to UEFI. The NVRAM file is
per-domain writable state (EFI variables); libvirt creates it from the template on
first start.
"""
import sys
import xml.etree.ElementTree as ET

OVMF_CANDIDATES = [
    ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
    ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
    ("/usr/share/edk2/ovmf/OVMF_CODE.fd", "/usr/share/edk2/ovmf/OVMF_VARS.fd"),
]


def die(msg):
    sys.exit(f"tpm_xml: {msg}")


def main(argv):
    code = vars_tpl = None
    if "--ovmf" in argv:
        i = argv.index("--ovmf")
        code = argv[i + 1]
        vars_tpl = code.replace("CODE", "VARS")
    else:
        import os
        for c, v in OVMF_CANDIDATES:
            if os.path.isfile(c) and os.path.isfile(v):
                code, vars_tpl = c, v
                break
    if not code:
        die("no OVMF firmware found — install ovmf, or pass --ovmf <OVMF_CODE.fd>.\n"
            "        Without UEFI a TPM measures no payload, so this refuses rather\n"
            "        than produce a domain whose attestation would be meaningless.")

    try:
        tree = ET.parse(sys.stdin)
    except ET.ParseError as e:
        die(f"input is not valid domain XML ({e})")
    root = tree.getroot()
    name = (root.findtext("name") or "?").strip()

    os_el = root.find("os")
    if os_el is None:
        die(f"domain '{name}' has no <os> element — cannot set firmware")

    # UEFI: replace any existing loader/nvram rather than appending a second one.
    for tag in ("loader", "nvram"):
        for el in os_el.findall(tag):
            os_el.remove(el)
    loader = ET.SubElement(os_el, "loader")
    loader.set("readonly", "yes")
    loader.set("type", "pflash")
    loader.text = code
    nvram = ET.SubElement(os_el, "nvram")
    nvram.set("template", vars_tpl)
    nvram.text = f"/var/lib/libvirt/qemu/nvram/{name}_VARS.fd"

    devices = root.find("devices")
    if devices is None:
        die(f"domain '{name}' has no <devices> element")

    # ── the NIC, which is not optional either ───────────────────────────────
    # FOUND LIVE, 2026-07-29: node3 was given UEFI + a TPM and then booted straight
    # to the EFI internal shell — "map: No mapping found", no PXE attempt at all,
    # despite the NIC carrying bootindex=1.
    #
    # The cause is a collision between this script and the verifying option ROM.
    # OVMF's NetworkPkg supplies the PXE *protocol stack*, but the Simple Network
    # Protocol driver for the card has to come from somewhere: for e1000 that is the
    # card's UEFI option ROM (QEMU's efi-e1000.rom, an iPXE image with both a legacy
    # and an EFI driver). Attaching this lab's verifying ROM REPLACES that image with
    # a legacy-only one, so a UEFI firmware finds no driver, produces no network boot
    # option, and silently falls through to the shell.
    #
    # So a measured node uses **virtio-net with no option ROM at all**: OVMF has
    # VirtioNetDxe built in, so it drives the card itself. That is also the arrangement
    # the fleet's arch-conditional DHCP is built for — OVMF's own PXE client does NOT
    # announce user-class iPXE, so it is handed `ipxe.efi` (the verifying build) rather
    # than the script, and the firmware half of F2 runs on this node exactly as the
    # option ROM provides it on the BIOS ones. Leaving the stock iPXE oprom in place
    # would be worse than either: it announces itself as iPXE, is handed the script,
    # and has no imgverify to run it with.
    nics = devices.findall("interface")
    if not nics:
        die(f"domain '{name}' has no <interface> — a measured node has to netboot its\n"
            f"        payload, and there is nothing here to boot it from.")
    for nic in nics:
        model = nic.find("model")
        if model is None:
            model = ET.SubElement(nic, "model")
        model.set("type", "virtio")
        # Replace any <rom> (a file= from the verifying-ROM step, or an earlier run of
        # this script) with an explicit "no option ROM".
        for el in nic.findall("rom"):
            nic.remove(el)
        rom = ET.SubElement(nic, "rom")
        rom.set("enabled", "no")

    # TPM: replace, so re-running is idempotent (the same rule rom_xml.py learned —
    # appending produced domains with two devices and an unhelpful libvirt error).
    for el in devices.findall("tpm"):
        devices.remove(el)
    tpm = ET.SubElement(devices, "tpm")
    tpm.set("model", "tpm-tis")
    backend = ET.SubElement(tpm, "backend")
    backend.set("type", "emulator")
    backend.set("version", "2.0")

    sys.stdout.write(ET.tostring(root, encoding="unicode"))
    print(f"tpm_xml: {name}: TPM 2.0 (emulator) + UEFI firmware ({code})", file=sys.stderr)
    print(f"tpm_xml: {name}: {len(nics)} NIC(s) -> virtio with NO option ROM, so OVMF drives",
          file=sys.stderr)
    print("tpm_xml: them itself and its PXE client fetches the verifying ipxe.efi.", file=sys.stderr)
    print("tpm_xml: NOTE swtpm is faithful plumbing, NOT a trust anchor — anything that",
          file=sys.stderr)
    print("tpm_xml: can read the emulator's state can forge these measurements.", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
