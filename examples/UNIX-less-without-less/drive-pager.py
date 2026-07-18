#!/usr/bin/env python3
"""drive-pager.py — deterministically drive a full-screen terminal program
through a REAL pty, the way a human would type at it.

Why this exists: `script(1)` cannot faithfully exercise a raw-mode TUI from a
pipe, and there is a sharper trap underneath — bash's `read -n1` swaps its own
termios in for the duration of every read (ICRNL and ISIG come back ON), so
what the program experiences is not what its `stty raw` line suggests. Driving
a real pty master is the only honest harness. (Same family as the repo's
serial-console drivers: send SLOWLY, one byte at a time — see CLAUDE.md.)

Usage:
    drive-pager.py --out FILE [--timeout SECS] [--rows N] [--cols N] \
        [-k DELAY:TEXT]... -- COMMAND [ARG...]

Each -k waits DELAY seconds, then sends TEXT (python escapes allowed: \\r,
\\x03, ...) one byte at a time with a 40 ms gap. All pty output is captured to
FILE. Exits with the child's exit code (128+N if signal N killed it), or 124
on timeout (the child is then killed BY PID).
"""
import argparse, fcntl, os, pty, select, struct, sys, termios, time

ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
ap.add_argument("--timeout", type=float, default=15.0)
ap.add_argument("--rows", type=int, default=24)
ap.add_argument("--cols", type=int, default=80)
ap.add_argument("-k", "--key", action="append", default=[],
                metavar="DELAY:TEXT", help="wait DELAY s, then slow-send TEXT")
ap.add_argument("cmd", nargs="+")
args = ap.parse_args()

keys = []
for spec in args.key:
    delay, _, text = spec.partition(":")
    keys.append((float(delay), text.encode().decode("unicode_escape").encode("latin1")))

pid, fd = pty.fork()
if pid == 0:
    # FORCE a known terminal type: the caller's TERM (say, xterm-ghostty)
    # may have no terminfo entry inside a container, and a deterministic
    # harness must not inherit the operator's terminal anyway.
    os.environ["TERM"] = "xterm"
    os.execvp(args.cmd[0], args.cmd)

# Deterministic geometry: the program's tput lines/cols must not depend on
# whoever runs this.
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", args.rows, args.cols, 0, 0))

out = open(args.out, "wb")
t0 = time.time()
ki = 0
next_key = t0 + (keys[0][0] if keys else 0)
rc = 124
while True:
    if time.time() - t0 > args.timeout:
        os.kill(pid, 15)          # kill by PID, never by pattern
        os.waitpid(pid, 0)
        rc = 124
        break
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:            # pty closed: child is gone
            chunk = b""
        if not chunk:
            _, status = os.waitpid(pid, 0)
            rc = os.waitstatus_to_exitcode(status)
            if rc < 0:             # killed by signal N -> shell-style 128+N
                rc = 128 - rc
            break
        out.write(chunk)
    if ki < len(keys) and time.time() >= next_key:
        for b in keys[ki][1]:      # one byte every 40 ms -- no bursts
            os.write(fd, bytes([b]))
            time.sleep(0.04)
        ki += 1
        if ki < len(keys):
            next_key = time.time() + keys[ki][0]
out.close()
sys.exit(rc)
