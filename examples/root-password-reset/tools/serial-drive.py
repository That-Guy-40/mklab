#!/usr/bin/env python3
"""serial-drive.py — script a QEMU serial console (GRUB, an init shell, a getty).

Built for the root-password-reset lab to drive `lab-vm.sh` VMs over their unix
`serial.sock` — interrupting GRUB, editing the kernel command line, and logging in
to confirm a reset — but it works for any QEMU `-serial unix:...,server=on` socket.

WHY THIS EXISTS — the hard-won lesson (see ../../../CLAUDE.md and ../MANUAL_TESTING.md):
GRUB's serial input has **no flow control and silently drops characters** fed
faster than it consumes them. A long `linux …` line or a rapid key burst arrives
garbled, the edit "didn't take", and there is no error. So this driver:

  * sends everything **one byte at a time with a ~40 ms delay** (CHAR_DELAY), and
  * single-steps keystrokes, using single-byte **emacs** motions (Ctrl-n/p/a/e)
    rather than arrow escapes (`\\x1b[B`) — in GRUB's editor the leading Esc of an
    arrow sequence is read as "discard edits / exit".

Other traps it respects: only **one** client may attach to the serial socket at a
time (a second steals the bytes); the QEMU **monitor `sendkey` does NOT reach a
serial GRUB** (it targets the emulated PS/2/VGA keyboard) — you must write the
UART, which is what this does; any keypress cancels GRUB's countdown.

A human typing at `lab-vm.sh console` is naturally slow enough to hit none of
this — the fragility is purely an automation concern. Ground-truth a reset with
the booted kernel's `/proc/cmdline`, not by screen-scraping GRUB's ANSI redraws.

USAGE
  serial-drive.py SOCK [--timeout N] [--log FILE] < script    # run a DSL script
  serial-drive.py SOCK --capture SECONDS [--log FILE]         # passive: read & dump

  SOCK is the VM's serial socket, e.g.
    ~/.local/state/lab-create/vms/<name>/serial.sock
  Stop the VM first so nothing else holds the socket:
    lab-vm.sh stop <name> --force && lab-vm.sh start <name>

SCRIPT DSL (one command per line; blank lines and '#' comments ignored)
  EXPECT <substr>        wait until <substr> appears in the stream (uses --timeout)
  EXPECT[T] <substr>     same, with an explicit per-step timeout of T seconds
  SEND <text>            type <text> char-by-char (40 ms each), NO trailing newline
  SENDLN <text>          SEND then Enter (\\r)
  ENTER                  send a bare \\r
  CTRL <letter>          send one control byte, e.g.  CTRL n   (Ctrl-n = cursor down)
  KEY <hexbytes>         send raw bytes, e.g.  KEY 18  (Ctrl-x = boot edited entry)
  SLEEP <secs>           idle, still draining/​logging output
  MARK <text>            write a marker into the transcript only (no bytes sent)

EXAMPLE — interrupt GRUB and append init=/bin/bash via the editor (Debian/BIOS):
  EXPECT automatically in        # catch the countdown ("… automatically in 5s")
  KEY 20                         # Space: cancel countdown, stop on the menu
  SEND e                         # edit the highlighted entry
  CTRL n                         #   (repeat to reach the `linux` line; see RUNBOOK)
  CTRL e                         # end of the linux line
  SEND  init=/bin/bash           # slow-typed; leading space intentional
  KEY 18                         # Ctrl-x: boot the edited entry
  EXPECT[120] root@              # land at the PID-1 shell

Exit status: 0 on success, 2 if an EXPECT times out (the substring is reported on
stderr; the full byte stream is in the --log transcript, default /tmp/sc.transcript).
"""
import sys, socket, time, select, re

CHAR_DELAY = 0.04        # per-character send delay — the flow-control workaround
DEFAULT_TIMEOUT = 60.0


def main():
    args = sys.argv[1:]
    if not args:
        sys.stderr.write(__doc__); sys.exit(2)
    sock_path = args.pop(0)
    timeout = DEFAULT_TIMEOUT
    log_path = "/tmp/sc.transcript"
    capture = None
    i = 0
    while i < len(args):
        if args[i] == "--timeout":   timeout = float(args[i + 1]); i += 2
        elif args[i] == "--log":     log_path = args[i + 1];       i += 2
        elif args[i] == "--capture": capture = float(args[i + 1]); i += 2
        else: i += 1
    logf = open(log_path, "ab", buffering=0)

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.setblocking(False)
    buf = bytearray()

    def pump(deadline):
        """Read whatever is available until `deadline`; append to buf and log."""
        while True:
            r, _, _ = select.select([s], [], [], max(0, deadline - time.monotonic()))
            if not r:
                return
            try:
                data = s.recv(65536)
            except BlockingIOError:
                continue
            if not data:                 # peer closed
                return
            buf.extend(data); logf.write(data)
            if time.monotonic() >= deadline:
                return

    def expect(substr, t):
        target = substr.encode()
        deadline = time.monotonic() + t
        while time.monotonic() < deadline:
            if target in bytes(buf):
                return True
            pump(min(deadline, time.monotonic() + 0.3))
        return target in bytes(buf)

    def send_slow(text):
        for ch in text.encode():
            s.sendall(bytes([ch]))
            time.sleep(CHAR_DELAY)
            pump(time.monotonic())       # drain the echo so buf tracks reality

    if capture is not None:
        logf.write(b"\n--- CAPTURE START ---\n")
        pump(time.monotonic() + capture)
        logf.write(b"\n--- CAPTURE END ---\n")
        sys.stdout.write(bytes(buf).decode("utf-8", "replace"))
        return

    for raw in sys.stdin:
        line = raw.rstrip("\n")
        if not line or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^EXPECT(?:\[(\d+(?:\.\d+)?)\])?\s+(.*)$", line)
        if m:
            t = float(m.group(1)) if m.group(1) else timeout
            ok = expect(m.group(2), t)
            logf.write(f"\n[[EXPECT {'OK' if ok else 'TIMEOUT'}: {m.group(2)!r}]]\n".encode())
            if not ok:
                sys.stderr.write(f"EXPECT TIMEOUT: {m.group(2)!r}\n")
                sys.exit(2)
            continue
        op, _, rest = line.partition(" ")
        if op == "SEND":     send_slow(rest)
        elif op == "SENDLN": send_slow(rest); s.sendall(b"\r")
        elif op == "ENTER":  s.sendall(b"\r")
        elif op == "KEY":    s.sendall(bytes.fromhex(rest.replace(" ", "")))
        elif op == "CTRL":   s.sendall(bytes([ord(rest.strip().lower()) - ord('a') + 1]))
        elif op == "SLEEP":  pump(time.monotonic() + float(rest))
        elif op == "MARK":   logf.write(f"\n[[MARK {rest}]]\n".encode())
        else:                sys.stderr.write(f"unknown op: {line!r}\n")
        pump(time.monotonic() + 0.05)

    pump(time.monotonic() + 1.0)
    logf.write(b"\n--- SCRIPT DONE ---\n")


if __name__ == "__main__":
    main()
