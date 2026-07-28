#!/usr/bin/env python3
"""rom_xml.py — attach a NIC option ROM to a libvirt domain's interfaces.

Reads domain XML on stdin, writes the modified XML on stdout.

    virsh dumpxml node1 | rom_xml.py /var/lib/libvirt/maas-rom/ipxe-8086100e.rom \\
        | sudo virsh define /dev/stdin

WHY THIS EXISTS. F2 (payload signing) has two halves, and the on-node half is a
property of the FIRMWARE, not of anything the control plane can arrange. A libvirt
NIC boots QEMU's stock iPXE ROM, which is compiled without IMAGE_TRUST_CMD: the
`imgverify` line in the boot script is an unknown command, so the script aborts and
nothing boots. Replacing the ROM is the whole mechanism — everything else about the
deploy path is already in place.

It also restores the instrument. Measured on this repo's own fleet: a node's console
log begins at "Linux version ..." with not one SeaBIOS or iPXE line in it, because
libvirt does not run QEMU with -nographic and so nothing carries the BIOS console to
the serial port. The replacement ROM is built with CONSOLE_SERIAL, which puts iPXE's
own output — including why it refused a payload — into that same log. Side by side,
in libvirt's invocation: stock ROM 0 bytes, this one 617.

WHAT THIS IS NOT: a hardware root of trust. Whoever can edit this domain XML can put
back a ROM that verifies nothing, and could equally have swapped the CA. It is a
faithful stand-in for firmware that a real fleet flashes and locks, and it proves the
thing that could not otherwise be shown at all — that the MACHINE refuses a payload
the fleet did not sign, with the control plane out of the picture.
"""
import os
import sys
import xml.etree.ElementTree as ET


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: rom_xml.py <rom-file-path>  (domain XML on stdin)",
              file=sys.stderr)
        return 2
    path = sys.argv[1]

    # Fail here, not at domain-start. libvirt reports a missing/unreadable romfile as
    # a start-time permission error naming a path that plainly exists, which reads as
    # a libvirt problem rather than "the file is under $HOME and qemu is another user".
    if not os.path.isfile(path):
        print(f"rom_xml: no such ROM file: {path}", file=sys.stderr)
        return 1

    try:
        root = ET.fromstring(sys.stdin.read())
    except ET.ParseError as e:
        print(f"rom_xml: could not parse the domain XML: {e}", file=sys.stderr)
        return 1

    devices = root.find("devices")
    if devices is None:
        print("rom_xml: domain has no <devices> element — is this domain XML?",
              file=sys.stderr)
        return 1

    interfaces = devices.findall("interface")
    if not interfaces:
        print("rom_xml: domain has no <interface> — nothing to attach a ROM to",
              file=sys.stderr)
        return 1

    for iface in interfaces:
        # One <rom> per interface; replace rather than append, so re-running is
        # idempotent instead of producing a domain libvirt refuses to define.
        for old in iface.findall("rom"):
            iface.remove(old)
        ET.SubElement(iface, "rom", {"file": path})

    print(f"rom_xml: attached {path} to {len(interfaces)} interface(s)",
          file=sys.stderr)
    sys.stdout.write(ET.tostring(root, encoding="unicode"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
