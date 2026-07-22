#!/usr/bin/env python3
"""drive-serial-repl.py — deterministically drive a REPL on a QEMU serial socket.

Generalization of examples/linuxboot-uefi-kexec/drive-boot.py: instead of one
banner-gated command, this runs an ordered script of --expect/--send steps
against a firmware/bootloader/initramfs prompt (Open Firmware's `ok`, GRUB,
a getty, u-root...) over QEMU's `-serial unix:<path>,server=on,wait=off`.

House serial doctrine applies (see CLAUDE.md): firmware serial input has no
flow control, so every byte is sent slowly (default 40 ms gap); exactly ONE
client may hold the socket; the caller owns the QEMU lifecycle and kills it
BY PID — this tool only connects, converses, and reports.

--echo-gate is the DURABLE answer to dropped characters. A fixed --char-delay
is a guess, and this repo has re-guessed it twice (Rocky's GRUB needed 0.08;
OpenBIOS-x86 dropped chars even at 0.04) — the right gap depends on what the
consumer is doing at that instant, not on a constant. --echo-gate SELF-CLOCKS:
send one byte, wait for the console to echo it back, then send the next. It
cannot outrun the consumer at any speed, and a byte that never echoes is
RESENT (then reported) instead of vanishing into a garbled command line.

Only printable ASCII is gated: control bytes echo unpredictably (\\r comes back
as \\r\\n, Ctrl-X as ^X or nothing, DEL as "\\b \\b"), so they keep the plain
--char-delay. Echo-gating is OPT-IN because a non-echoing prompt (a password,
a raw-mode reader) would never confirm and every byte would be resent.

Usage:
    drive-serial-repl.py SOCK OUT.LOG [--timeout SECS] [--char-delay SECS] \
        [--echo-gate [--echo-timeout SECS] [--echo-retries N]] \
        --expect TEXT [--send TEXT] [--expect TEXT ...]

Steps run strictly in the order given on the command line. --expect waits
until TEXT appears in the (cumulative) serial stream past the previous match;
--send transmits TEXT (python escapes allowed: \\r, \\x03) byte-by-byte.
All serial output is teed to OUT.LOG. Exit 0 when every step has completed,
124 if the overall deadline expires first (the log shows how far it got), 125
if --echo-gate could not get a byte through (the console is dropping input).
"""
import argparse, socket, sys, time


class Step(argparse.Action):
    def __call__(self, parser, ns, value, option_string=None):
        kind = "expect" if option_string == "--expect" else "send"
        ns.steps.append((kind, value))


ap = argparse.ArgumentParser()
ap.add_argument("sock")
ap.add_argument("out")
ap.add_argument("--timeout", type=float, default=60.0)
ap.add_argument("--char-delay", type=float, default=0.04)
ap.add_argument("--echo-gate", action="store_true",
                help="send each printable byte only once the console has "
                     "echoed the previous one (self-clocking; resends drops)")
ap.add_argument("--echo-timeout", type=float, default=2.0,
                metavar="SECS", help="how long to wait for one byte's echo")
ap.add_argument("--echo-retries", type=int, default=2, metavar="N",
                help="resend attempts before giving up on a byte (exit 125)")
ap.add_argument("--expect", action=Step, dest="steps", default=[],
                metavar="TEXT", help="wait for TEXT on the serial stream")
ap.add_argument("--send", action=Step, dest="steps",
                metavar="TEXT", help="slow-send TEXT (python escapes ok)")
args = ap.parse_args()

deadline = time.time() + args.timeout

# Retry until the socket exists: launch QEMU with -serial unix:...,server=on
# (wait left ON) so the guest does not boot until we are connected — otherwise
# early output (banners, "press any key" windows) is emitted into the void
# before the client arrives and can never be matched.
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
while True:
    try:
        s.connect(args.sock)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        if time.time() > deadline:
            print(f"TIMEOUT connecting to {args.sock}", file=sys.stderr)
            sys.exit(124)
        time.sleep(0.1)
s.settimeout(0.1)
buf = b""          # cumulative stream
scanned = 0        # matches must land past the previous match (no re-matching)
log = open(args.out, "wb")


def pump():
    global buf
    try:
        chunk = s.recv(4096)
        if chunk:
            buf += chunk
            log.write(chunk)
            log.flush()
    except socket.timeout:
        pass


def send_byte(b):
    """Put one byte on the wire. Returns True once it is (believed) taken.

    Plain mode: write it, wait --char-delay, hope. Echo-gated mode: write it,
    then wait for that same byte to come back in the output we receive AFTER
    the write — the console's own echo is the acknowledgement, so we advance
    exactly as fast as it consumes. A byte that never echoes was dropped by a
    console with no flow control, so resend it rather than let the command line
    silently garble.
    """
    printable = 0x20 <= b <= 0x7e
    if not (args.echo_gate and printable):
        s.sendall(bytes([b]))
        time.sleep(args.char_delay)   # no bursts: firmware drops chars
        pump()                        # keep draining while typing
        return True
    for _ in range(args.echo_retries + 1):
        mark = len(buf)               # only echo arriving after this counts
        s.sendall(bytes([b]))
        echo_end = time.time() + args.echo_timeout
        while time.time() < echo_end:
            pump()
            if buf.find(bytes([b]), mark) >= 0:
                return True           # acknowledged — no artificial delay needed
            if time.time() > deadline:
                return False
    return False


rc = 0
for i, (kind, text) in enumerate(args.steps):
    if kind == "expect":
        needle = text.encode()
        while True:
            idx = buf.find(needle, scanned)
            if idx >= 0:
                scanned = idx + len(needle)
                break
            if time.time() > deadline:
                print(f"TIMEOUT waiting for step {i} expect {text!r}",
                      file=sys.stderr)
                rc = 124
                break
            pump()
        if rc:
            break
    else:
        data = text.encode().decode("unicode_escape").encode("latin1")
        for pos, b in enumerate(data):
            if not send_byte(b):
                print(f"ECHO-GATE: step {i} byte {pos} ({bytes([b])!r}) never "
                      f"echoed after {args.echo_retries + 1} attempts — the "
                      f"console is dropping input", file=sys.stderr)
                rc = 125
                break
        if rc:
            break

# Drain briefly so the log captures the aftermath of the last send.
tail_end = min(time.time() + 1.0, deadline)
while time.time() < tail_end:
    pump()
log.close()
sys.exit(rc)
