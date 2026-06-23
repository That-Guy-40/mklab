#!/usr/bin/env python3
# capture-login.py — attach to the node's libvirt serial console, log in over
# serial (throwaway lab creds), prove it's the freshly-installed OS, detach.
#
# Used to capture the AlmaLinux PXE-install finale's installed-OS login for
# MANUAL_TESTING.md.  Drives `virsh console` through a pty (pty.fork) so it works
# even when launched from a non-tty shell.  One consumer at a time on the console.
import os, pty, select, sys, time

DOM  = os.environ.get("NODE", "alpine-node")
USER = os.environ.get("LOGIN_USER", "root")
PW   = os.environ.get("LOGIN_PW", "alpine")
PROOF = "cat /etc/os-release | grep PRETTY_NAME; uname -r; echo ALMA_CAPTURE_OK"

pid, fd = pty.fork()
if pid == 0:                                   # child: become virsh console
    os.execvp("virsh", ["virsh", "-c", "qemu:///system", "console", DOM, "--force"])
    os._exit(127)

def send(s):                                   # type slowly — gettys are gentler
    for b in s.encode():                       # than GRUB, but be safe anyway
        os.write(fd, bytes([b])); time.sleep(0.03)

buf = b""; whole = b""; state = "login"
deadline = time.time() + 360
time.sleep(2); os.write(fd, b"\r")             # nudge the getty to print a prompt
last = time.time()
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1.0)
    if r:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        os.write(1, d)                         # echo through to stdout (tee'd)
        buf += d; whole += d; tail = buf[-400:]
        if state == "login" and b"login:" in tail:
            time.sleep(0.7); send(USER + "\r"); state = "pw"; buf = b""
        elif state == "pw" and b"assword:" in tail:
            time.sleep(0.7); send(PW + "\r"); state = "shell"; buf = b""; time.sleep(1.5)
        elif state == "shell":
            t = buf.replace(b"\r", b"").rstrip()
            if t.endswith(b"#") or t.endswith(b"$"):
                time.sleep(0.5); send(PROOF + "\r"); state = "done"; buf = b""
        elif state == "done" and b"ALMA_CAPTURE_OK" in buf and b"PRETTY_NAME" in whole:
            time.sleep(0.7); send("exit\r"); time.sleep(1.0); break
    else:
        if state in ("login", "pw") and time.time() - last > 5:
            os.write(fd, b"\r"); last = time.time()

os.write(fd, b"\x1d")                          # Ctrl-] detaches virsh console
time.sleep(0.3)
sys.stdout.flush()
print("\n[capture-login] state at exit:", state)
