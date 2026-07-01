#!/usr/bin/env python3
# drive-boot.py — drive the coreboot/u-root serial console: wait for the u-root
# shell to be READY, type a boot-policy command, and capture u-root running it.
#
# Two callers, one mechanism:
#   • run-coreboot-boot-disk.sh   types `boot`     → localboot: parse a disk's
#                                                    grub.cfg, kexec the disk's OS
#   • run-coreboot-pxe.sh         types `pxeboot`  → netboot: DHCP, fetch the iPXE
#                                                    script, kexec the installer
#
# Why we *type* the command instead of it running automatically:
#   • disk-boot (v0.14.0): coreboot only wires an auto-uinit (SPECIFIC_BOOTLOADER_*
#     -> uinit=<cmd>) for u-root **main**; the disk tier pins v0.14.0 (Go 1.22), so
#     no uinit runs and u-root drops to a shell.
#   • pxeboot (u-root main): even though main *can* auto-uinit, we set
#     SPECIFIC_BOOTLOADER_NONE on purpose — a uinit symlink can't carry the `-file`
#     flag `pxeboot` needs (POC-PXEBOOT.md), so we type `pxeboot -file <URI>` too.
# Either way u-root drops to exactly the interactive LinuxBoot prompt a human would
# type at. (A hands-off pxeboot needs a uinit *wrapper* script — PLAN-PXEBOOT.md.)
#
# Usage: drive-boot.py <serial.sock> <out.log> [command=boot] [post_wait_secs=40]
#   command        what to type at the u-root shell (default "boot")
#   post_wait_secs how long to keep capturing after Enter — network boot needs
#                  longer (DHCP + fetch kernel/initrd + boot the installer).
import socket, time, sys, os, threading

SOCK = sys.argv[1] if len(sys.argv) > 1 else "ttyA.sock"
LOG  = sys.argv[2] if len(sys.argv) > 2 else "tierA-boot.log"
CMD  = sys.argv[3] if len(sys.argv) > 3 else "boot"
WAIT = int(sys.argv[4]) if len(sys.argv) > 4 else 40

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

# Wait for the shell to be READY before typing — serial input has no flow control,
# so bytes sent during the kernel's boot/cgroup spew get silently dropped.
# u-root v0.14.0's gosh prints a "toggle key help" hint line; u-root *main* just
# prints a bare "$ " prompt. Both print the "Welcome to u-root!" banner first, so we
# gate on that, then prefer the editor-ready hint but fall back to a settle delay.
if not wait_for(b"Welcome to u-root!", 90):
    print("never saw the u-root banner", file=sys.stderr); sys.exit(1)
wait_for(b"toggle key help", 8)             # v0.14.0 editor-ready (best-effort)
time.sleep(4)                               # let boot spew drain / main's $ appear
s.sendall(b"\n"); time.sleep(1)            # wake a fresh prompt
for ch in CMD.encode():                     # type the command slowly
    s.sendall(bytes([ch])); time.sleep(0.08)
time.sleep(0.5); s.sendall(b"\n")           # execute
time.sleep(WAIT)                            # let the boot policy run (scan/fetch + kexec)
print("done; typed", repr(CMD), "captured", len(buf), "bytes")
