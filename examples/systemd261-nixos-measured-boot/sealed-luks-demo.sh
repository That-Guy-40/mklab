#!/usr/bin/env bash
# sealed-luks-demo.sh — Spike G host driver.
#
# Drives the measured VM (nixos261v, built with `tpm=true`) over its serial
# console and runs sealed-luks-demo.guest.sh INSIDE it, proving the systemd-261
# sealed-storage + attestation chain against the real swtpm PCR state:
#   seal a LUKS keyslot to PCR 7+11 → unseal with the TPM alone → verify an
#   AK-signed PCR quote → change PCR 11 → the TPM refuses to unseal.
#
# The guest has no SSH key (cloud_init=false), so serial is the channel. We push
# the guest script base64-encoded in small chunks — a booted Linux getty has a
# real tty line discipline (flow control), unlike a GRUB/firmware console, so a
# paced push arrives intact.
#
#   phase2-qemu-vm/lab-vm.sh create --config examples/systemd261-nixos-measured-boot/vm-nixos261-verity.toml
#   phase2-qemu-vm/lab-vm.sh start  nixos261v
#   examples/systemd261-nixos-measured-boot/sealed-luks-demo.sh
#
# HONEST FRAMING: the TPM is swtpm (a *software* emulator on QEMU/KVM). It runs
# the plumbing faithfully but is NOT a trust anchor — the guest script says so,
# and so does RUNBOOK-sealed-luks.md. A hardware TPM / hypervisor vTPM / CC is
# the production anchor.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUEST="$HERE/image/sealed-luks-demo.guest.sh"   # canonical copy (in the flake tree)
VM="${1:-nixos261v}"
STATE="${LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lab-create}"
SOCK="$STATE/vms/$VM/serial.sock"

[ -f "$GUEST" ]   || { echo "FAIL: guest script missing: $GUEST"; exit 1; }
[ -S "$SOCK" ]    || { echo "SKIP: $VM not running (no $SOCK). Start it: phase2-qemu-vm/lab-vm.sh start $VM"; exit 77; }

B64="$(base64 -w0 "$GUEST")"

python3 - "$SOCK" "$B64" <<'PY'
import socket, sys, time
sock_path, b64 = sys.argv[1], sys.argv[2]
SENT = "___SEALED_DONE___"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(30):
    try: s.connect(sock_path); break
    except OSError: time.sleep(1)
s.setblocking(False)

def send(line):
    # paced, chunked write — the getty tty buffers, but be gentle anyway
    data = (line + "\n").encode()
    for i in range(0, len(data), 128):
        s.sendall(data[i:i+128]); time.sleep(0.02)

# wake the shell, stage the script from base64, run it, print rc
send("")
send("cat > /tmp/sealed.b64 <<'EOF'")
for i in range(0, len(b64), 256):
    send(b64[i:i+256])
send("EOF")
send("base64 -d /tmp/sealed.b64 > /tmp/sealed.sh && echo STAGED_OK || echo STAGED_FAIL")
send("bash /tmp/sealed.sh; echo RC=$?; echo %s" % SENT)

buf = b""; deadline = time.time() + 150
while time.time() < deadline:
    try:
        c = s.recv(65536)
        if c: buf += c
    except BlockingIOError:
        time.sleep(0.2)
    if buf.count(SENT.encode()) >= 2:   # our echo + the shell echoing the command
        break
s.close()

text = buf.decode("utf-8", "replace")
# Strip the base64 staging noise; show from the demo banner onward.
mark = text.find("== systemd 261")
sys.stdout.write(text[mark:] if mark >= 0 else text)
# Machine-checkable verdict for the caller: the guest must have printed its
# own PASS line AND exited 0.
sys.exit(0 if ("PASS:" in text and "RC=0" in text) else 1)
PY
rc=$?
echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: sealed-LUKS + attestation verified in $VM (see transcript above)"
else
  echo "FAIL: sealed-LUKS demo did not reach PASS/RC=0 in $VM (see transcript above)"
fi
exit "$rc"
