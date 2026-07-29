#!/usr/bin/env python3
"""dhcp-probe.py — ask a DHCP server what it would tell a given kind of client to boot.

    dhcp-probe.py --probe bios:0 --probe efi:7 --probe efi-ipxe:7:iPXE
    bios=boot.ipxe
    efi=ipxe.efi
    efi-ipxe=boot.ipxe

A test fixture, in the same family as mock-bmc.sh and tools/serial-source.py: a real
client speaking the real protocol, so what is proven is the server's actual behaviour
rather than a reading of its config file.

WHY A PROGRAM AND NOT `dhclient`/`nmap`. The whole question here is what the server
answers to a client that claims a particular *architecture* (DHCP option 93) or
*user class* (option 77). No ordinary client will lie about those on request — that
is exactly the input under test — so the packet has to be built by hand.

Each --probe is `label:arch[:userclass]`, where arch is a number or `none` (omit
option 93 entirely, as an old BIOS client does). Prints `label=<filename>` per probe;
`label=TIMEOUT` when the server declined to answer at all, which is itself a result
and must not be mistaken for an empty filename.
"""
import argparse
import random
import socket
import struct
import sys

MAGIC = b"\x63\x82\x53\x63"


def discover(server_port, client_port, arch, userclass, mac, timeout):
    """One DHCPDISCOVER; returns the offered boot filename, or None on timeout."""
    xid = random.randrange(1 << 32)
    mb = bytes(int(x, 16) for x in mac.split(":"))
    pkt = struct.pack(
        "!BBBBIHH4s4s4s4s16s64s128s",
        1, 1, 6, 0, xid, 0, 0x8000,          # BOOTREQUEST, ethernet, broadcast flag
        b"\0" * 4, b"\0" * 4, b"\0" * 4, b"\0" * 4,
        mb + b"\0" * 10, b"\0" * 64, b"\0" * 128,
    ) + MAGIC
    pkt += bytes([53, 1, 1])                                    # DHCPDISCOVER
    if arch is not None:
        pkt += bytes([93, 2]) + struct.pack("!H", arch)         # client-arch (RFC 4578)
    if userclass:
        u = userclass.encode()
        pkt += bytes([77, len(u) + 1, len(u)]) + u              # user-class (what iPXE sends)
    pkt += bytes([55, 4, 1, 3, 66, 67])                         # please include next-server/bootfile
    pkt += b"\xff"

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("0.0.0.0", client_port))          # 0.0.0.0, so the broadcast reply arrives
    # Every probe must use the SAME port: the server broadcasts its reply to the one
    # client port it was configured with, so a probe listening anywhere else waits
    # forever on an answer that was correctly sent. (It cost one debugging round —
    # dnsmasq's own log showed the right filename going out while the probe timed
    # out.) Replies are matched by xid instead, and anything stale is drained first.
    s.setblocking(False)
    try:
        while True:
            s.recv(4096)
    except BlockingIOError:
        pass
    s.setblocking(True)
    s.settimeout(timeout)
    try:
        s.sendto(pkt, ("127.0.0.1", server_port))
        while True:
            data, _ = s.recvfrom(4096)
            if len(data) < 240 or struct.unpack("!I", data[4:8])[0] != xid:
                continue                       # someone else's reply; keep waiting
            fname = data[108:236].split(b"\0")[0].decode(errors="replace")
            # Option 67 overrides the fixed `file` field when the server sends both.
            i, opts = 240, {}
            while i < len(data) and data[i] != 255:
                if data[i] == 0:
                    i += 1
                    continue
                t, ln = data[i], data[i + 1]
                opts[t] = data[i + 2:i + 2 + ln]
                i += 2 + ln
            if 67 in opts:
                fname = opts[67].split(b"\0")[0].decode(errors="replace")
            return fname
    except socket.timeout:
        return None
    finally:
        s.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--probe", action="append", default=[], metavar="LABEL:ARCH[:USERCLASS]")
    p.add_argument("--server-port", type=int, default=1067)
    p.add_argument("--client-port", type=int, default=1068)
    p.add_argument("--mac", default="52:54:00:aa:bb:cc")
    p.add_argument("--timeout", type=float, default=5.0)
    a = p.parse_args()
    if not a.probe:
        print("dhcp-probe: no --probe given", file=sys.stderr)
        return 2

    for spec in a.probe:
        parts = spec.split(":")
        label, arch_s = parts[0], parts[1]
        userclass = parts[2] if len(parts) > 2 else None
        arch = None if arch_s in ("none", "") else int(arch_s)
        got = discover(a.server_port, a.client_port, arch, userclass, a.mac, a.timeout)
        print(f"{label}={got if got is not None else 'TIMEOUT'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
