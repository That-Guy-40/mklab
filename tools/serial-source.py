#!/usr/bin/env python3
"""serial-source.py — a fake serial device that EMITS a stream, for testing anything
that READS a serial console: an IPMI SOL bridge (ipmi_sim), a QEMU `-serial tcp:` /
`-serial pty` consumer, a boot-progress/milestone parser, or the expect side of
tools/drive-*-repl.py. It is the emitter counterpart to tools/tests/lossy-console.py
(which models a console that *receives* input badly).

WHY THIS IS A REAL PROGRAM (the footgun it dodges): a shell generator like
    socat TCP-LISTEN:9101,fork SYSTEM:'while :; do printf "tick\\n"; sleep 1; done'
delivers NOTHING. libc BLOCK-buffers stdout when it is a pipe/socket (not a tty), and
the loop never exits to flush — so the bytes pile up in the buffer forever and the
reader sees silence, with no error. (Found the hard way wiring ipmi_sim SOL in the
bmc-toolkit lab.) This program writes with an EXPLICIT flush after every line, so a
byte emitted is a byte on the wire.

SINKS (where the stream goes):
  --tcp PORT     listen on --bind ADDR:PORT (default 127.0.0.1) and stream to each
                 reader, RE-ACCEPTING on disconnect (so a consumer like ipmi_sim, which
                 connects out to a `tcp:host:port` SOL device, can reconnect freely).
  --pty [LINK]   allocate a pty; print its slave device path, and symlink LINK -> it if
                 given (the QEMU `-serial pty` / device-path shape).
  (default)      stdout.

CONTENT (what the stream says):
  --marker STR   emit "STR <n>" every --interval seconds (default; a monotonic counter
                 so a reader can tell fresh lines from a stalled stream).
  --replay FILE  emit FILE's lines in order, one per --interval — a canned console log,
                 the deterministic fixture for a milestone/progress parser.
  --once         emit the content once, then exit (default: loop forever).

Lines are CRLF-terminated (like a real serial console) unless --no-crlf.

Examples:
  serial-source.py --tcp 9101 --marker NODE-SERIAL          # feed an ipmi_sim SOL device
  serial-source.py --replay boot.log --interval 0.1 --once  # replay a captured boot to a parser
  serial-source.py --pty /tmp/ttyfake --marker HELLO        # a device path for a reader to open

Lab-only: binds loopback by default; do not point a reader on an untrusted network at it.
"""
import argparse
import os
import socket
import sys
import time

DEFAULT_MARKER = "SERIAL-SOURCE tick"


def lines(args):
    """Yield the (endless, unless --once) sequence of text lines to emit."""
    if args.replay:
        with open(args.replay, "r") as fh:
            base = [ln.rstrip("\n") for ln in fh] or [""]
        while True:
            yield from base
            if args.once:
                return
    else:
        n = 0
        while True:
            yield f"{args.marker} {n}"
            n += 1
            if args.once:
                return


def encode(line, crlf):
    return (line + ("\r\n" if crlf else "\n")).encode("utf-8", "replace")


def emit_fd(fd, args):
    """Write to a raw fd (pty master / stdout). os.write is unbuffered — no libc buffer."""
    for line in lines(args):
        os.write(fd, encode(line, args.crlf))
        time.sleep(args.interval)


def emit_conn(conn, args):
    for line in lines(args):
        conn.sendall(encode(line, args.crlf))  # sendall = explicit, no buffering
        time.sleep(args.interval)


def run_tcp(args):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.bind, args.tcp))
    srv.listen(1)
    print(f"serial-source: TCP {args.bind}:{args.tcp} (waiting for a reader)", file=sys.stderr)
    while True:
        conn, _peer = srv.accept()
        try:
            emit_conn(conn, args)
        except OSError:
            pass  # reader went away mid-stream; loop back and re-accept
        finally:
            conn.close()
        if args.once:
            return


def run_pty(args):
    master, slave = os.openpty()
    slave_path = os.ttyname(slave)
    if args.pty:
        try:
            os.unlink(args.pty)
        except FileNotFoundError:
            pass
        os.symlink(slave_path, args.pty)
    print(args.pty or slave_path, flush=True)  # stdout: the path a reader should open
    print(f"serial-source: PTY {args.pty or slave_path}", file=sys.stderr)
    emit_fd(master, args)


def main():
    ap = argparse.ArgumentParser(
        description="Fake serial source: emit a stream for a serial reader to consume."
    )
    sink = ap.add_mutually_exclusive_group()
    sink.add_argument("--tcp", type=int, metavar="PORT",
                      help="listen on a TCP port and stream to readers (re-accepts)")
    sink.add_argument("--pty", nargs="?", const="", metavar="LINK",
                      help="emit on a pty; optional stable symlink path")
    content = ap.add_mutually_exclusive_group()
    content.add_argument("--marker", default=DEFAULT_MARKER,
                         help="repeating marker text; emits 'MARKER <n>'")
    content.add_argument("--replay", metavar="FILE",
                         help="emit the lines of FILE (a canned console log)")
    ap.add_argument("--interval", type=float, default=1.0, metavar="SEC",
                    help="delay between lines (default 1.0)")
    ap.add_argument("--bind", default="127.0.0.1",
                    help="TCP bind address (default 127.0.0.1; lab-only)")
    ap.add_argument("--once", action="store_true", help="emit the content once, then exit")
    ap.add_argument("--no-crlf", dest="crlf", action="store_false",
                    help="LF line endings instead of CRLF")
    args = ap.parse_args()
    try:
        if args.tcp is not None:
            run_tcp(args)
        elif args.pty is not None:
            run_pty(args)
        else:
            emit_fd(sys.stdout.fileno(), args)
    except (KeyboardInterrupt, BrokenPipeError):
        pass


if __name__ == "__main__":
    main()
