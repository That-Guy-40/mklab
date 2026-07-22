#!/usr/bin/env python3
"""drive-pty-repl.py — drive a console REPL on a real pty.

Sibling of drive-serial-repl.py for programs whose console input only works
on a terminal, not a socket. The motivating case (openbios-the-rival-that-
shipped lab): OpenBIOS-ppc under `qemu-system-ppc -nographic` reads keys
from the muxed stdio just fine, but delivers NOTHING from a bare
`-serial unix:` socket — so the socket driver can watch it and never type.
This driver forks the target onto a pty (the terminal QEMU muxes onto) and
converses there. Also fits any curses/termios-fussy program (see
examples/UNIX-less-without-less/drive-pager.py, its ancestor).

House serial doctrine still applies: bytes are slow-sent (default 40 ms —
firmware input has no flow control), and the child is killed BY PID.

--echo-gate is the DURABLE answer to dropped characters (see CLAUDE.md).
A fixed --char-delay is a guess, and this repo has re-guessed it twice
(Rocky's GRUB needed 0.08; OpenBIOS-x86 dropped chars even at 0.04) — because
the right gap depends on what the consumer is doing at that instant, not on a
constant. --echo-gate instead SELF-CLOCKS: send one byte, wait for the console
to echo that byte back, then send the next. It cannot outrun the consumer at
any speed, and a byte that never echoes is RESENT (then reported as a hard
error) instead of vanishing silently into a garbled command line.

Only printable ASCII is gated: control bytes echo unpredictably (\\r comes back
as \\r\\n, Ctrl-X as ^X or nothing, DEL as "\\b \\b"), so they keep the plain
--char-delay. Echo-gating is OPT-IN because a non-echoing prompt (a password,
a raw-mode reader) would never confirm and every byte would be resent.

Usage:
    drive-pty-repl.py OUT.LOG [--timeout SECS] [--char-delay SECS] \
        [--echo-gate [--echo-timeout SECS] [--echo-retries N]] \
        --expect TEXT [--send TEXT ...] -- CMD [ARG...]

Steps run strictly in command-line order against the cumulative pty stream
(matches must land past the previous match). --send allows python escapes
(\\r, \\x03). All pty output is teed to OUT.LOG. Exit 0 when every step has
completed, 124 if the deadline expires (the log shows how far it got), 125 if
--echo-gate could not get a byte through (the console is dropping input).
"""
import argparse, os, pty, select, sys, time


class Step(argparse.Action):
    def __call__(self, parser, ns, value, option_string=None):
        kind = "expect" if option_string == "--expect" else "send"
        ns.steps.append((kind, value))


ap = argparse.ArgumentParser()
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
                metavar="TEXT", help="wait for TEXT on the pty stream")
ap.add_argument("--send", action=Step, dest="steps",
                metavar="TEXT", help="slow-send TEXT (python escapes ok)")

# Split on "--" BY HAND. An argparse REMAINDER positional next to option
# flags greedily swallows the flags too — steps came back empty, every run
# "passed" in 0 steps, and the child exec'd "--timeout". Never again.
argv = sys.argv[1:]
if "--" not in argv:
    ap.error("no command given (append: -- CMD ARG...)")
split = argv.index("--")
cmd = argv[split + 1:]
args = ap.parse_args(argv[:split])
if not cmd:
    ap.error("empty command after --")
if not args.steps:
    ap.error("no --expect/--send steps given")

pid, fd = pty.fork()
if pid == 0:
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        print(f"exec {cmd[0]}: {e}", file=sys.stderr)
        os._exit(127)

deadline = time.time() + args.timeout
buf = b""          # cumulative stream
scanned = 0        # matches must land past the previous match
log = open(args.out, "wb")


def pump():
    global buf
    r, _, _ = select.select([fd], [], [], 0.1)
    if fd in r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:      # child exited, pty gone
            return
        if chunk:
            buf += chunk
            log.write(chunk)
            log.flush()


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
        os.write(fd, bytes([b]))
        time.sleep(args.char_delay)   # no bursts: firmware drops chars
        pump()                        # keep draining while typing
        return True
    for _ in range(args.echo_retries + 1):
        mark = len(buf)               # only echo arriving after this counts
        os.write(fd, bytes([b]))
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
try:
    os.kill(pid, 15)   # by PID, never by pattern
except ProcessLookupError:
    pass
sys.exit(rc)
