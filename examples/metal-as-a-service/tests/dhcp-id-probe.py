#!/usr/bin/env python3
"""dhcp-id-probe.py — which ADDRESS does a DHCP server hand a client, given its identity?

Sibling of dhcp-probe.py, which asks the *filename* question ("what would you tell
this kind of client to boot?"). Here the variable is the client's **identity** — its
MAC, whether it sends a client-identifier (option 61), whether it sends a hostname
(option 12) — and the answer read out is `yiaddr`.

    dhcp-id-probe.py --probe 'mac-only,52:54:00:aa:bb:cc,none,none,discover'
    mac-only=127.0.0.102

WHY A PROGRAM AND NOT dhclient/udhcpc. The question is what the server does with a
client that presents a *particular* identity. No ordinary client will omit its own
client-id or claim someone else's hostname on request — that is exactly the input
under test — so the packet is built by hand.

Each --probe is `LABEL,MAC,CLID,HOSTNAME,MODE`:

    CLID      none | self | <text>   `self` = 0x01 + the MAC, what busybox udhcpc sends
    HOSTNAME  none | <text>          DHCP option 12
    MODE      discover | lease       `lease` follows the OFFER with a REQUEST, so the
                                     address is actually committed and the next probe
                                     in the same run meets a server that has a lease

Prints `LABEL=<address>` per probe. `NO-OFFER` means the server declined to answer at
all, which is a result in its own right and must not read as an empty address;
`<addr>/NO-ACK` and `<addr>/NAK(n)` distinguish an offer that was never committed.
"""
import argparse
import random
import socket
import struct
import sys

MAGIC = b"\x63\x82\x53\x63"


def build(msgtype, mac, clid, host, xid, req_ip=None, server_id=None):
    """One BOOTREQUEST carrying exactly the identity options asked for."""
    mb = bytes(int(x, 16) for x in mac.split(":"))
    pkt = struct.pack(
        "!BBBBIHH4s4s4s4s16s64s128s",
        1, 1, 6, 0, xid, 0, 0x8000,          # BOOTREQUEST, ethernet, broadcast flag
        b"\0" * 4, b"\0" * 4, b"\0" * 4, b"\0" * 4,
        mb + b"\0" * 10, b"\0" * 64, b"\0" * 128,
    ) + MAGIC
    pkt += bytes([53, 1, msgtype])
    if clid is not None:
        pkt += bytes([61, len(clid)]) + clid
    if host is not None:
        h = host.encode()
        pkt += bytes([12, len(h)]) + h
    if req_ip is not None:
        pkt += bytes([50, 4]) + socket.inet_aton(req_ip)
    if server_id is not None:
        pkt += bytes([54, 4]) + server_id
    pkt += bytes([55, 3, 1, 3, 6])
    pkt += b"\xff"
    return pkt


def parse(data):
    yiaddr = socket.inet_ntoa(data[16:20])
    i, opts = 240, {}
    while i < len(data) and data[i] != 255:
        if data[i] == 0:
            i += 1
            continue
        t, ln = data[i], data[i + 1]
        opts[t] = data[i + 2:i + 2 + ln]
        i += 2 + ln
    return yiaddr, opts


def exchange(sock, pkt, xid, server_port, timeout):
    # Every probe reuses ONE client port: the server broadcasts to the single client
    # port it was configured with, so a probe listening anywhere else waits forever on
    # an answer that was sent correctly. Replies are matched by xid, stale ones drained.
    sock.setblocking(False)
    try:
        while True:
            sock.recv(4096)
    except BlockingIOError:
        pass
    sock.setblocking(True)
    sock.settimeout(timeout)
    sock.sendto(pkt, ("127.0.0.1", server_port))
    try:
        while True:
            data, _ = sock.recvfrom(4096)
            if len(data) < 240 or struct.unpack("!I", data[4:8])[0] != xid:
                continue
            return parse(data)
    except socket.timeout:
        return None, None


def run(spec, server_port, client_port, timeout):
    try:
        label, mac, clid_s, host_s, mode = spec.split(",")
    except ValueError:
        raise SystemExit(f"dhcp-id-probe: bad --probe {spec!r}"
                         " (want LABEL,MAC,CLID,HOSTNAME,MODE)")

    if clid_s == "none":
        clid = None
    elif clid_s == "self":
        clid = bytes([1]) + bytes(int(x, 16) for x in mac.split(":"))
    else:
        clid = clid_s.encode()
    host = None if host_s == "none" else host_s

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("0.0.0.0", client_port))          # 0.0.0.0, so the broadcast reply arrives
    try:
        xid = random.randrange(1 << 32)
        yi, opts = exchange(s, build(1, mac, clid, host, xid), xid, server_port, timeout)
        if yi is None:
            return f"{label}=NO-OFFER"
        if mode != "lease":
            return f"{label}={yi}"
        xid2 = random.randrange(1 << 32)
        pkt = build(3, mac, clid, host, xid2, req_ip=yi, server_id=opts.get(54))
        yi2, opts2 = exchange(s, pkt, xid2, server_port, timeout)
        if yi2 is None:
            return f"{label}={yi}/NO-ACK"
        mt = opts2.get(53, b"\0")[0]
        return f"{label}={yi2}" + ("" if mt == 5 else f"/NAK({mt})")
    finally:
        s.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--probe", action="append", default=[],
                   metavar="LABEL,MAC,CLID,HOSTNAME,MODE")
    p.add_argument("--server-port", type=int, default=1067)
    p.add_argument("--client-port", type=int, default=1068)
    p.add_argument("--timeout", type=float, default=5.0)
    a = p.parse_args()
    if not a.probe:
        print("dhcp-id-probe: no --probe given", file=sys.stderr)
        return 2
    for spec in a.probe:
        print(run(spec, a.server_port, a.client_port, a.timeout))
        sys.stdout.flush()   # probes run in order and later ones depend on earlier
    return 0


if __name__ == "__main__":
    sys.exit(main())
