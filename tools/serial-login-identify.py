#!/usr/bin/env python3
"""serial-login-identify.py — log in to a QEMU serial console and capture the
installed system's identity (distro / kernel / uid / disk layout).

A small, single-purpose companion to examples/root-password-reset/tools/serial-drive.py
(which is a general EXPECT/SEND DSL driver).  This one does exactly one job: attach
to a `lab-vm.sh` VM's unix `serial.sock`, wait for the getty `login:`, log in
(default `root`/`lab`), and run an identity probe — handy for confirming what a
freshly-installed VM actually booted (e.g. "did the kickstart really install
AlmaLinux 9, on /dev/vda, with uid 0 reachable?").  Written while verifying the
AlmaLinux kickstart gallery, where a stale stage2 had silently produced the *wrong*
distro — so "what did this actually boot?" needed a ground-truth answer.

WHY CHAR-BY-CHAR (the hard-won lesson — see ../CLAUDE.md):
A QEMU serial line has **no flow control**; GRUB and some early consoles silently
**drop characters** fed faster than they consume them.  A getty is more forgiving
than GRUB, but the safe habit is the same: send **one byte at a time** with a small
delay (CHAR_DELAY, ~40 ms).  Only **one** client may attach to the serial socket at
a time — a second connection steals the bytes — so detach any `lab-vm.sh console`
or capture `socat` first.  (To free a capture, kill it **by PID**: a broad
`pkill -f <vm>/serial.sock` also matches QEMU's own command line and kills the VM.)

USAGE
  serial-login-identify.py SOCK [--user U] [--password P] [--disk DEV]
                                [--char-delay S] [--login-timeout N] [--log FILE]

  SOCK   path to the VM's serial socket, e.g.
         ~/.local/state/lab-create/vms/<vm>/serial.sock

EXIT STATUS
  0  login reached and `id` reported uid=0(root)
  1  reached the login prompt but could not confirm a root shell
  2  never saw a login prompt within --login-timeout
"""
import argparse
import re
import socket
import sys
import time


def make_pump(sock, buf):
    def pump(secs):
        end = time.time() + secs
        while time.time() < end:
            try:
                d = sock.recv(4096)
                if d:
                    buf.extend(d)
            except socket.timeout:
                pass
    return pump


def make_send(sock, char_delay):
    def send(text):
        # One byte at a time: serial has no flow control (see module docstring).
        for ch in text:
            sock.sendall(ch.encode())
            time.sleep(char_delay)
    return send


def clean(buf):
    """Decode + strip CRs and ANSI escapes so prompt-matching is reliable."""
    t = buf.decode(errors="replace").replace("\r", "")
    return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", t)


def main():
    ap = argparse.ArgumentParser(
        description="Log in over a QEMU serial socket and capture system identity.")
    ap.add_argument("sock", help="path to the VM's unix serial.sock")
    ap.add_argument("--user", default="root", help="login user (default: root)")
    ap.add_argument("--password", default="lab", help="login password (default: lab)")
    ap.add_argument("--disk", default="vda", help="disk to lsblk (default: vda)")
    ap.add_argument("--char-delay", type=float, default=0.04,
                    help="seconds between sent bytes (default: 0.04 ≈ 40 ms)")
    ap.add_argument("--login-timeout", type=float, default=90.0,
                    help="seconds to wait for the getty login: prompt (default: 90)")
    ap.add_argument("--log", help="also write the full raw transcript to this file")
    args = ap.parse_args()

    buf = bytearray()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1.0)
    try:
        s.connect(args.sock)
    except OSError as e:
        print(f"error: cannot connect to {args.sock}: {e}", file=sys.stderr)
        return 2
    pump = make_pump(s, buf)
    send = make_send(s, args.char_delay)

    # Wait for the getty login: prompt (nudge with a newline each poll).  If a shell
    # prompt is already up (already logged in), skip straight to the probe.
    deadline = time.time() + args.login_timeout
    state = None
    while time.time() < deadline:
        pump(3)
        t = clean(buf)
        if re.search(r"[#$]\s*$", t):
            state = "shell"
            break
        if re.search(r"login:\s*$", t):
            state = "login"
            break
        send("\n")

    if state is None:
        _finish(buf, args.log)
        print("=== never reached a login prompt ===", file=sys.stderr)
        return 2

    if state == "login":
        send(args.user + "\n")
        pump(2)
        send(args.password + "\n")
        pump(4)

    # Identity probe, fenced with markers so it's easy to extract from the scrollback.
    probe = (
        "echo IDENT-START; "
        ". /etc/os-release 2>/dev/null; echo \"OS=$PRETTY_NAME\"; "
        "echo \"KERNEL=$(uname -r)\"; id; "
        f"lsblk -no NAME,SIZE,TYPE,MOUNTPOINT /dev/{args.disk} 2>/dev/null; "
        "echo IDENT-END\n"
    )
    send(probe)
    pump(6)
    out = _finish(buf, args.log)

    block = out
    i, j = out.find("IDENT-START"), out.rfind("IDENT-END")
    if i >= 0 and j > i:
        block = out[i:j + len("IDENT-END")]
    print(block)

    if re.search(r"uid=0\(root\)", out):
        print("\n=== OK: logged in, uid=0(root) confirmed ===", file=sys.stderr)
        return 0
    print("\n=== reached login but could not confirm a root shell ===", file=sys.stderr)
    return 1


def _finish(buf, logpath):
    out = clean(buf)
    if logpath:
        try:
            with open(logpath, "w") as fh:
                fh.write(out)
        except OSError as e:
            print(f"warning: could not write --log {logpath}: {e}", file=sys.stderr)
    return out


if __name__ == "__main__":
    sys.exit(main())
