#!/usr/bin/env python3
"""tun-open.py <tapname> — can THIS user actually attach to that tap?

Exit 0 if the `TUNSETIFF` ioctl succeeds, 1 with the errno on the line if it does not.

WHY THIS EXISTS RATHER THAN READING /sys/class/net/<tap>/owner. The owner file is the
*mechanism*; the thing that matters is the *outcome* — whether the VMM can open the
device. This repo has been caught by that distinction before: `ip tuntap add` returning
0 was read as "the tap is usable" when the operation a consumer actually performs is
this ioctl. A tap can exist, be enslaved to the right bridge, show `carrier 1`, and
still hand an unprivileged Firecracker `EPERM` here — which is exactly the defect
`fabric.sh retap` was written to repair.

So the test runs this as the unprivileged owner (`runuser -u <owner>`), before and after
`retap`. The run that must SUCCEED is what gives the run that must FAIL its meaning: if
both fail, the harness could not open /dev/net/tun at all and has proven nothing.

Deliberately does NOT create anything: IFF_TAP without IFF_TUN_EXCL attaches to an
existing persistent tap, and the fd is closed on exit, so the tap survives untouched.
"""
import ctypes
import fcntl
import os
import struct
import sys

TUNSETIFF = 0x400454CA
IFF_TAP = 0x0002
IFF_NO_PI = 0x1000


def main():
    if len(sys.argv) != 2:
        print("usage: tun-open.py <tapname>", file=sys.stderr)
        return 2
    name = sys.argv[1]
    try:
        fd = os.open("/dev/net/tun", os.O_RDWR)
    except OSError as e:
        # A different failure from the one under test, and it must not be mistaken for
        # it: no /dev/net/tun means the harness cannot ask the question at all.
        print(f"NO-TUN-DEVICE errno={e.errno} ({e.strerror})", file=sys.stderr)
        return 3
    try:
        ifr = struct.pack("16sH22s", name.encode(), IFF_TAP | IFF_NO_PI, b"")
        try:
            fcntl.ioctl(fd, TUNSETIFF, ifr)
        except OSError as e:
            print(f"TUNSETIFF-FAILED errno={e.errno} ({e.strerror})", file=sys.stderr)
            return 1
        print(f"TUNSETIFF-OK {name} uid={os.getuid()}")
        return 0
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
