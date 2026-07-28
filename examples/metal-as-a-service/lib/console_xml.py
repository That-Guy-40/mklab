#!/usr/bin/env python3
"""console_xml.py — rewrite a libvirt domain's serial console to a FILE.

Reads domain XML on stdin, writes the modified XML on stdout.

    virsh dumpxml node1 | console_xml.py /var/lib/libvirt/maas-console/node1.log \\
        | sudo virsh define /dev/stdin

WHY THIS EXISTS. Every health gate in this lab greps a node's console log, and on a
live fleet *nothing was writing one*. The sibling lab defines its domain with
`--console pty`, which is a terminal you attach to, not a record: if no one is
attached, the output is gone. So the first real end-to-end run was blind — a node
that booted the wrong payload and one that never booted at all produced the identical
symptom (a timeout) and no evidence either way.

A file-backed serial is the fix, and the reason to prefer it over a capture process:

  * it is RACELESS. A `virsh console` tailer has to be started before the node powers
    on and re-attached after every power cycle, and the early boot lines it misses in
    between are exactly the ones that say why a boot failed.
  * there is NO SECOND CONSUMER. libvirt's console is single-consumer; a capture
    process and an operator running `virsh console` silently steal bytes from each
    other. (The repo has been bitten by this before — see CLAUDE.md on serial
    consoles.)
  * it survives the power cycles the deploy path performs, with no supervision.

THE TRADE, stated plainly: serial0 is now a log file, so `virsh console <node>` no
longer gives an interactive shell on a fleet node. That is the right trade here — MAAS
gives you a console *log*, and the interactive console lives on in the single-node
sibling lab. Set FLEET_CONSOLE=pty in create-fleet.sh to keep the old behaviour (and
lose the health gates that read the log).

PERMISSIONS. qemu runs as libvirt-qemu, so the log file must be pre-created writable
by it (create-fleet.sh does: `sudo install -m 0666 /dev/null <path>`), in a directory
under /var/lib/libvirt so libvirt's AppArmor helper grants the path.
"""
import sys
import xml.etree.ElementTree as ET


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: console_xml.py <console-log-path>  (domain XML on stdin)",
              file=sys.stderr)
        return 2
    path = sys.argv[1]

    try:
        root = ET.fromstring(sys.stdin.read())
    except ET.ParseError as e:
        print(f"console_xml: could not parse the domain XML: {e}", file=sys.stderr)
        return 1

    devices = root.find("devices")
    if devices is None:
        print("console_xml: domain has no <devices> element — is this domain XML?",
              file=sys.stderr)
        return 1

    # Drop whatever serial0/console0 is there. Leaving the old pty in place is not an
    # option: libvirt maps <console> onto serial port 0, so two definitions of port 0
    # is a define-time error, and a second serial would be ttyS1 — which the payloads
    # do not write to (their cmdline says console=ttyS0), so the log would stay empty
    # and we would be back to a blind run that *looks* instrumented.
    removed = 0
    for tag in ("serial", "console"):
        for el in devices.findall(tag):
            devices.remove(el)
            removed += 1

    ser = ET.SubElement(devices, "serial", {"type": "file"})
    ET.SubElement(ser, "source", {"path": path, "append": "on"})
    ET.SubElement(ser, "target", {"type": "isa-serial", "port": "0"})

    con = ET.SubElement(devices, "console", {"type": "file"})
    ET.SubElement(con, "source", {"path": path, "append": "on"})
    ET.SubElement(con, "target", {"type": "serial", "port": "0"})

    print(f"console_xml: replaced {removed} console device(s) with a file-backed "
          f"serial at {path}", file=sys.stderr)
    sys.stdout.write(ET.tostring(root, encoding="unicode"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
