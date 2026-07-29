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
    print("tpm_xml: NOTE swtpm is faithful plumbing, NOT a trust anchor — anything that",
          file=sys.stderr)
    print("tpm_xml: can read the emulator's state can forge these measurements.", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
