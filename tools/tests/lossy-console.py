#!/usr/bin/env python3
"""lossy-console.py — a fake console that drops typed input, on purpose.

Test fixture for tools/drive-*-repl.py's --echo-gate. It models the one thing
firmware serial consoles actually do wrong (see CLAUDE.md): a receive FIFO with
NO FLOW CONTROL. The device wakes only every DRAIN seconds, takes the first
FIFO bytes that piled up, and DISCARDS the rest — silently, with no error, the
way GRUB and OpenBIOS discard the tail of a fast-typed line.

It echoes exactly the bytes it accepted, so a driver that gates on echo can
tell what got through and a driver that doesn't, cannot. On CR it prints
"GOT:<accepted line>" and exits, so the caller can compare intent vs reality.

Reads its own stdin in raw mode with the terminal's echo OFF: every echoed byte
you see came from THIS program having genuinely consumed it, not from the tty
layer reflecting it. Without that, echo-gating would appear to work even
against a console that consumed nothing.
"""
import fcntl, os, sys, termios, time, tty

FIFO = 1        # bytes accepted per wake-up; the rest of the burst is lost
DRAIN = 0.30    # how often the "UART" is serviced (much slower than typing)

tty.setraw(0)                                    # no line discipline, no echo
fl = fcntl.fcntl(0, fcntl.F_GETFL)
fcntl.fcntl(0, fcntl.F_SETFL, fl | os.O_NONBLOCK)

IDLE_TICKS = 5  # report after this many quiet wake-ups, even without a CR


def report(line):
    os.write(1, b"\r\nGOT:" + bytes(line) + b"\r\n")
    time.sleep(0.2)                              # let the driver read it
    sys.exit(0)


os.write(1, b"READY\r\n")
line = bytearray()
idle = 0
while True:
    time.sleep(DRAIN)
    try:
        chunk = os.read(0, 65536)
    except (BlockingIOError, OSError):
        chunk = b""
    if not chunk:
        # The sender has gone quiet. If we accepted anything, say so — the CR
        # itself is often among the bytes we dropped, and a caller that only
        # reported on CR would look like a hang instead of like corruption.
        idle += 1
        if line and idle >= IDLE_TICKS:
            report(line)
        continue
    idle = 0
    for b in chunk[:FIFO]:                       # chunk[FIFO:] overruns → lost
        if b in (13, 10):
            report(line)
        line.append(b)
        os.write(1, bytes([b]))                  # echo ONLY what we accepted
