#!/usr/bin/env python3
# smoke-uroot.py — drive the u-root LinuxBoot shell over a QEMU serial socket and
# probe what a "full-featured rescue shell" is (and isn't). Unlike drive-boot.py
# (which types ONE boot-policy command), this types a SEQUENCE of probes, each fenced
# by a unique marker so smoke-uroot.sh can slice the transcript per probe.
#
# It answers, empirically, the questions you'd ask of any boot/rescue environment:
#   - what happens if you type `exit` at PID 1  (spoiler: the kernel panics)
#   - is there job control (&, jobs, fg, Ctrl-Z) and signal delivery (Ctrl-C)
#   - do pipes / redirection / globbing / variables work
#   - what commands ship in the initramfs
# The `exit` probe is deliberately LAST — it kills init, so nothing runs after it.
#
# Serial input has no flow control (see CLAUDE.md), so every byte is sent slowly and
# each probe waits for its own marker to echo back before moving on.
#
# Usage: smoke-uroot.py <serial.sock> <out.log> [settle_secs=3]
import socket, time, sys, os, threading

SOCK = sys.argv[1]
LOG  = sys.argv[2]
SETTLE = int(sys.argv[3]) if len(sys.argv) > 3 else 3

# (name, keystrokes) — keystrokes may embed control bytes (\x03=Ctrl-C, \x1a=Ctrl-Z).
# Each probe is preceded by an `echo` marker so the transcript is sliceable.
PROBES = [
    ("shell-identity",   "echo SHELL=$0; cat /proc/version"),
    ("commands-in-bbin", "ls /bbin | wc -l; echo ---; ls /bbin"),
    ("builtins-cd-pwd",  "cd /tmp; pwd; cd /; pwd"),
    ("pipe",             "echo pipe_ok | cat"),
    ("redirection",      "echo redir_ok > /tmp/r; cat /tmp/r"),
    ("glob",             "ls -d /b*"),
    ("variables",        "FOO=bar123; echo val=$FOO"),
    ("cmd-substitution", "echo now=$(date +%s 2>/dev/null || echo NODATE)"),
    ("background-job",   "sleep 20 &"),
    ("jobs-builtin",     "jobs"),
    ("not-found",        "this_command_does_not_exist_42"),
    ("ctrl-c",           "sleep 12\x03"),          # start sleep, then Ctrl-C mid-run
    ("ctrl-z-then-jobs", "sleep 12\x1ajobs"),      # start sleep, Ctrl-Z, then jobs
    ("EXIT-PID1-PANIC",  "exit"),                  # LAST: exiting PID 1 → kernel panic
]

# --- connect to the serial socket -------------------------------------------------
for _ in range(200):
    if os.path.exists(SOCK): break
    time.sleep(0.1)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(200):
    try: s.connect(SOCK); break
    except OSError: time.sleep(0.1)

buf = bytearray(); out = open(LOG, "wb")
def reader():
    while True:
        try: d = s.recv(4096)
        except OSError: return
        if not d: return
        buf.extend(d); out.write(d); out.flush()
threading.Thread(target=reader, daemon=True).start()

def wait_for(tok, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if tok in bytes(buf): return True
        time.sleep(0.2)
    return False

def send(text):
    for ch in text.encode():
        s.sendall(bytes([ch])); time.sleep(0.05)

# --- wait for the u-root shell to be ready ----------------------------------------
if not wait_for(b"Welcome to u-root!", 90):
    print("never saw the u-root banner", file=sys.stderr); sys.exit(1)
wait_for(b"toggle key help", 8)     # v0.14.0 editor-ready hint (best effort)
time.sleep(4)                       # let boot spew drain / main's `$` appear
s.sendall(b"\n"); time.sleep(1)

# --- run the probes ---------------------------------------------------------------
for name, keys in PROBES:
    marker = f"===PROBE:{name}==="
    send(f"echo {marker}"); s.sendall(b"\n"); wait_for(marker.encode(), 5); time.sleep(0.5)
    send(keys); s.sendall(b"\n")
    time.sleep(SETTLE if not keys.startswith("sleep") else SETTLE + 1)

time.sleep(3)
print(f"done; sent {len(PROBES)} probes; captured {len(buf)} bytes → {LOG}")
