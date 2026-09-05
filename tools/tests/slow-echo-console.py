#!/usr/bin/env python3
"""slow-echo-console.py — a fake console that echoes every byte it accepts, but
LATE. Test fixture for drive-pty-repl.py's --echo-gate acknowledgment grace.

It models the one thing the lossy-console fixture does NOT: a console that
accepts every byte (drops nothing) but is slow to echo the FIRST byte typed
after it has been busy — exactly ppc under TCG right after a heavy `evaluate`,
whose output the console is still flushing when the next command's first byte
arrives (see CLAUDE.md, the 2026-09-05 tlv-primitives finding).

Model: read a byte, hold it BUSY seconds (as if flushing prior output), then
echo it and accept it into the line. So a driver that gates on echo with a
grace SHORTER than BUSY will time out waiting for the echo and RESEND the byte
-- and because this console dropped nothing, the resend DUPLICATES it. A driver
whose grace EXCEEDS BUSY sees the echo and never resends. On CR it prints
"GOT:<accepted line>" and exits, so the caller compares intent vs reality.

Reads stdin raw with the tty's own echo OFF, so every echoed byte came from
THIS program genuinely consuming it, not the line discipline.
"""
import os, sys, termios, time, tty

BUSY = float(os.environ.get("SLOW_ECHO_BUSY", "3.0"))  # echo latency, seconds

tty.setraw(0)
os.write(1, b"READY\r\n")
line = bytearray()
first = True
while True:
    try:
        b = os.read(0, 1)
    except OSError:
        b = b""
    if not b:
        time.sleep(0.02)
        continue
    if first:
        time.sleep(BUSY)   # the console is still flushing prior output
        first = False
    ch = b[0]
    if ch in (0x0d, 0x0a):
        os.write(1, b"\r\nGOT:" + bytes(line) + b"\r\n")
        time.sleep(0.2)
        sys.exit(0)
    line.append(ch)
    os.write(1, bytes([ch]))   # echo, now that we are done being busy
