#!/usr/bin/env python3
"""Teach the PXE network to answer BIOS and UEFI clients differently.

    virsh net-dumpxml vbmc-pxe | dnsmasq_arch_xml.py | sudo virsh net-define /dev/stdin
    dnsmasq_arch_xml.py --emit-options      # just the dnsmasq lines, for tests

Third sibling of rom_xml.py and tpm_xml.py: rewrite the XML rather than hand-edit
it, replace rather than append, and refuse rather than half-apply.

WHY THIS EXISTS. This lab's network hands EVERY client the same filename —
`<bootp file='boot.ipxe'/>`, an iPXE *script*. That works only because a BIOS node's
option ROM is already iPXE: it fetches the script and executes it. A UEFI node has
no such ROM. Its firmware TFTPs `boot.ipxe`, finds `#!ipxe` where a PE binary should
be, and stops. So a UEFI node cannot netboot this fleet at all.

That collides head-on with measured boot, which is the one thing that REQUIRES UEFI:
under BIOS the firmware measures the boot sector and the partition table and nothing
in the filesystem, so a PCR policy over a BIOS boot blesses any payload (see
lib/tpm_xml.py). The measured node must be UEFI; the network only speaks BIOS.

The fix is to answer by client architecture — DHCP option 93, which every PXE client
sends — handing UEFI firmware `ipxe.efi` (a real PE binary) and everything else the
script as before.

THE TRAP, AND THE LINE THAT AVOIDS IT. The obvious form of this is:

    dhcp-match=set:efi64,option:client-arch,7
    dhcp-boot=tag:efi64,ipxe.efi

...and it chainloads forever. `ipxe.efi` boots, and iPXE does its OWN DHCP; it is
still architecture 7, so it is handed `ipxe.efi` again, and again. The BIOS path
never showed this because a script is executed, not re-loaded. iPXE identifies
itself in DHCP option 77 (user-class "iPXE"), so the tag has to mean "EFI firmware
that is NOT already iPXE" — which is what the `tag-if` line below says, and it is
the only line here that is not obvious. Both directions are proven against a real
dnsmasq in tests/test-uefi-netboot-dhcp.sh, including the naive config looping.

Architecture 7 is EFI x86-64 and 9 is EFI x86-64 again (RFC 4578 assigned both; real
firmware sends either). 0 is legacy BIOS and stays on the untagged default, so the
BIOS nodes and their verifying option ROM are untouched by this change.
"""
import sys
import xml.etree.ElementTree as ET

DNSMASQ_NS = "http://libvirt.org/schemas/network/dnsmasq/1.0"

# THE single source of truth for these lines. The XML rewrite below embeds them and
# tests/test-uefi-netboot-dhcp.sh feeds the SAME list to a real dnsmasq — so what is
# proven is what gets installed, rather than a hand-copied approximation of it that
# can drift (the mistake this repo has now paid for in two other places).
def options(efi_binary: str = "ipxe.efi"):
    return [
        # UEFI x86-64 firmware announces itself in DHCP option 93.
        "dhcp-match=set:efi64,option:client-arch,7",
        "dhcp-match=set:efi64,option:client-arch,9",
        # iPXE announces itself in option 77. This is the loop break: without it,
        # ipxe.efi is handed ipxe.efi forever.
        "dhcp-userclass=set:ipxe,iPXE",
        "tag-if=set:efi-fw,tag:efi64,tag:!ipxe",
        f"dhcp-boot=tag:efi-fw,{efi_binary}",
    ]


# Every line we own starts with one of these, so a re-run replaces our block and
# leaves anything an operator added by hand alone.
OWNED_PREFIXES = (
    "dhcp-match=set:efi64,",
    "dhcp-userclass=set:ipxe,",
    "tag-if=set:efi-fw,",
    "dhcp-boot=tag:efi-fw,",
)


def die(msg):
    sys.exit(f"dnsmasq_arch_xml: {msg}")


def main(argv):
    efi = "ipxe.efi"
    if "--efi" in argv:
        efi = argv[argv.index("--efi") + 1]
    if "--emit-options" in argv:
        for line in options(efi):
            print(line)
        return

    ET.register_namespace("dnsmasq", DNSMASQ_NS)
    try:
        root = ET.fromstring(sys.stdin.read())
    except ET.ParseError as e:
        die(f"input is not valid network XML ({e})")
    name = (root.findtext("name") or "?").strip()

    ip = root.find("ip")
    if ip is None or ip.find("dhcp") is None:
        die(f"network '{name}' has no <ip><dhcp> — there is no DHCP server here to teach")

    # The untagged default must exist, or this change would give UEFI clients a
    # filename and BIOS clients nothing at all — trading one broken half for the
    # other. libvirt renders <bootp file=/> as the untagged dhcp-boot.
    if ip.find("dhcp/bootp") is None:
        die(f"network '{name}' has no <bootp file='...'/>: the BIOS nodes would lose their\n"
            f"        boot filename. Run netboot-chain.sh install first.")
    if root.find("ip/tftp") is None:
        die(f"network '{name}' serves no TFTP root — a UEFI client has nowhere to fetch\n"
            f"        {efi} from. Expected <tftp root='...'/>.")

    # Replace our lines, keep foreign ones, and reuse the existing block if there is
    # one: appending a second <dnsmasq:options> is not an error libvirt reports
    # usefully (the same lesson rom_xml.py learned about appending devices).
    block = root.find(f"{{{DNSMASQ_NS}}}options")
    kept = []
    if block is not None:
        for el in block.findall(f"{{{DNSMASQ_NS}}}option"):
            val = el.get("value", "")
            if not val.startswith(OWNED_PREFIXES):
                kept.append(val)
        root.remove(block)
    block = ET.SubElement(root, f"{{{DNSMASQ_NS}}}options")
    for val in kept + options(efi):
        ET.SubElement(block, f"{{{DNSMASQ_NS}}}option", {"value": val})

    sys.stdout.write(ET.tostring(root, encoding="unicode"))
    print(f"dnsmasq_arch_xml: {name}: UEFI clients -> {efi}, everything else -> "
          f"{ip.find('dhcp/bootp').get('file')}", file=sys.stderr)
    if kept:
        print(f"dnsmasq_arch_xml: kept {len(kept)} dnsmasq option(s) this script does not own",
              file=sys.stderr)
    print("dnsmasq_arch_xml: NOTE libvirt only re-renders dnsmasq's config when the network",
          file=sys.stderr)
    print("dnsmasq_arch_xml: RESTARTS — net-destroy + net-start, which drops every domain's",
          file=sys.stderr)
    print("dnsmasq_arch_xml: link on it. Stop the fleet first.", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
