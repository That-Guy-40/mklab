#!/usr/bin/env bash
# run-coreboot-pxe-https.sh — PLAN-PXEBOOT P2: provision an OS from the ROM over
# **HTTPS**, with the fetch verified against the shared lab CA.
#
# WHY this instead of `pxeboot -file https://…`: u-root's `pxeboot` has NO https
# scheme (curl.DefaultSchemes = tftp/http/file only; no -tls flag). But its `wget`
# DOES do https via Go's SystemCertPool — and the ROM bakes lab-ca.crt at
# /etc/ssl/certs/ca-certificates.crt (CONFIG_LINUXBOOT_UROOT_FILES). So P2 fetches
# the kernel+initrd with `wget https://…` (real cert verification, no patched
# payload) and boots them with the `kexec` command. Positive + negative proof in
# POC-PXEBOOT-P2.md.
#
# Reuse: the kernel/initrd URLs + kernel cmdline come from the SAME boot-<os>.ipxe
# rendered by fetch-netboot-os.sh — we just rewrite the u-root-fetched kernel+initrd
# URLs to https://…:8443. The installer's OWN downloads (inst.stage2/inst.ks /
# preseed) stay on http :8181: P2 secures the ROM's trust boundary (u-root → the
# kernel it kexecs); making Anaconda/d-i trust the lab CA is a separate distro
# exercise (see POC-PXEBOOT-P2.md "scope").
#
#   ./serve-netboot.sh up --tls                 # HTTPS server on :8443 (lab-CA cert)
#   ./run-coreboot-pxe-https.sh [alma|rocky|kali]   (default: alma)
set -euo pipefail
OS="${1:-alma}"
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
ROM="${ROM:-$WORKDIR/coreboot/build/coreboot.rom}"
NETBOOT_DIR="${NETBOOT_DIR:-$HOME/netboot}"
HTTP="${HTTP:-http://10.0.2.2:8181}"; HTTPS="${HTTPS:-https://10.0.2.2:8443}"
IPXE="$NETBOOT_DIR/boot-$OS.ipxe"
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$ROM" ]] || { echo "no ROM at $ROM — build the pxeboot ROM (see build-coreboot.sh)"; exit 1; }
[[ -f "$IPXE" ]] || { echo "no $IPXE — run ./fetch-netboot-os.sh $OS"; exit 1; }
curl -fsI --cacert "$HERE/../lab-ca/lab-ca.crt" --resolve 10.0.2.2:8443:127.0.0.1 \
  "$HTTPS/vmlinuz" >/dev/null 2>&1 || echo "warn: :8443 not serving — run ./serve-netboot.sh up --tls" >&2

# --- derive kernel URL / cmdline / initrd URL from the P1 iPXE script ---
# lines look like:  kernel <url> <args...> [|| goto retry]   and   initrd <url> [|| ...]
kline="$(grep -E '^kernel ' "$IPXE" | head -1 | sed 's/ *|| goto retry *$//')"
iline="$(grep -E '^initrd ' "$IPXE" | head -1 | sed 's/ *|| goto retry *$//')"
KURL="$(awk '{print $2}' <<<"$kline")"
KARGS="$(cut -d' ' -f3- <<<"$kline")"                 # the installer cmdline (unchanged)
IURL="$(awk '{print $2}' <<<"$iline")"
# rewrite ONLY the u-root-fetched kernel+initrd to HTTPS :8443 (leave cmdline http):
KURL_S="${KURL/$HTTP/$HTTPS}"; IURL_S="${IURL/$HTTP/$HTTPS}"

DRIVE="wget -O /tmp/k $KURL_S; wget -O /tmp/i $IURL_S; kexec -l /tmp/k -i /tmp/i -c \"$KARGS\"; kexec -e"

DISK="${DISK:-$WORKDIR/pxe-target-https-$OS.qcow2}"
[[ -f "$DISK" ]] || qemu-img create -f qcow2 "$DISK" 12G >/dev/null
SOCK="$WORKDIR/ttyHTTPS-$OS.sock"; LOG="$WORKDIR/pxe-https-$OS-boot.log"; rm -f "$SOCK"
if [[ -w /dev/kvm ]]; then ACCEL=kvm; CPU="${CPU:-host}"; else ACCEL=tcg; CPU="${CPU:-Nehalem}"; fi

echo "==> P2 HTTPS boot: $OS  (accel=$ACCEL cpu=$CPU)"
echo "    wget $KURL_S  +  $IURL_S  → kexec (cmdline over $HTTP)"
qemu-system-x86_64 -M q35 -accel "$ACCEL" -cpu "$CPU" -m 4096 \
  -bios "$ROM" \
  -netdev user,id=n0 -device e1000,netdev=n0 -device virtio-rng-pci \
  -drive file="$DISK",format=qcow2,if=virtio \
  -chardev socket,id=s0,path="$SOCK",server=on,wait=on -serial chardev:s0 \
  -display none -no-reboot >/dev/null 2>&1 &
QPID=$!
python3 "$HERE/drive-boot.py" "$SOCK" "$LOG" "$DRIVE" 180 || true
kill "$QPID" 2>/dev/null || true          # stop the VM by PID (never by pattern)

echo "==> proof — wget HTTPS (lab-CA verified) → kexec → installer:"
sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r/\n/g' "$LOG" \
  | grep -iE "Got DHCP answer|Welcome to u-root|Linux version [0-9]|Welcome to (Alma|Rocky|Kali)|anaconda .* started|Starting automated|Loading additional|Installing the base|x509|failed to verify" \
  | grep -viE "compiled-in|self-test|parser|Loading comp" | awk '!seen[$0]++' | head -15