#!/usr/bin/env python3
# drive-boot.py — drive the coreboot/u-root serial console: wait for the u-root
# shell, type `boot`, and capture u-root's localboot finding the disk's OS and
# kexec-ing it. Used by run-coreboot-boot-disk.sh for the Tier A "boot a real OS"
# finale.
#
# Why we *type* `boot` instead of it running automatically: coreboot's LinuxBoot
# payload only wires an auto-uinit (`SPECIFIC_BOOTLOADER_BOOT` -> uinit=`boot`) for
# u-root **main**, which needs Go >= 1.23. We pin u-root v0.14.0 (Go 1.22), so no
# uinit runs and u-root drops to a shell — exactly the interactive LinuxBoot prompt
# a human would type `boot` at. (Build with u-root main on a newer Go to get the
# hands-off version.)
import socket, time, sys, os, threading

SOCK = sys.argv[1] if len(sys.argv) > 1 else "ttyA.sock"
LOG  = sys.argv[2] if len(sys.argv) > 2 else "tierA-boot.log"

for _ in range(150):                       # wait for qemu to create the socket
    if os.path.exists(SOCK): break
    time.sleep(0.1)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(150):
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

# Wait for the gosh line editor to be READY (its hint line) — typing during the
# kernel's cgroup spew gets dropped (serial input has no flow control).
if not wait_for(b"toggle key help", 90):
    print("never saw the u-root shell prompt", file=sys.stderr); sys.exit(1)
time.sleep(2)
s.sendall(b"\n"); time.sleep(1)            # wake a fresh prompt
for ch in b"boot":                          # type slowly
    s.sendall(bytes([ch])); time.sleep(0.08)
time.sleep(0.5); s.sendall(b"\n")           # execute
time.sleep(40)                              # let boot scan the disk + kexec the OS
print("done; captured", len(buf), "bytes")
