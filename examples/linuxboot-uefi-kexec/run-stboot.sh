#!/usr/bin/env bash
# run-stboot.sh <alma|rocky|kali> [--negative] — PLAN-PXEBOOT P3: boot the stboot UKI
# under OVMF and watch System Transparency verify a SIGNED OS package before kexec.
#
# No typing (unlike the pxeboot tiers): stboot is autonomous — as PID 1 it loads e1000,
# configures the static IP, fetches the OSPKG descriptor over HTTPS (cert verified vs
# lab-ca.crt), fetches + verifies the OSPKG's Ed25519 signature against the baked-in
# lab-CA root, and only then kexecs the installer. We just capture the serial log and
# read the verdict from it.
#
#   --negative : boot a ROGUE-signed OSPKG (make-ospkg.sh --rogue) and prove stboot
#                REFUSES it (signature doesn't chain to the trusted root) — no kexec.
#
# Prereqs (this script drives them):  ./build-st.sh  once, then per run it ensures the
# OSPKG exists (make-ospkg.sh) and both netboot servers are up (:8443 for the signed
# OSPKG, :8181 for the installer's own stage2/kickstart — see make-ospkg.sh scope note).
#
#   ./run-stboot.sh alma              # positive: verified signed boot → installer
#   ./run-stboot.sh alma --negative   # negative: rogue OSPKG refused
set -euo pipefail
OS="${1:-alma}"; NEG="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
LABCA="$HERE/../lab-ca"
ESP="$WORKDIR/stboot-esp.img"
SECS="${SECS:-240}"
[[ -f "$ESP" ]] || { echo "no stboot ESP ($ESP) — run ./build-st.sh first" >&2; exit 1; }

# --- 1. build the OSPKG for this run (positive or rogue) ---------------------------
if [[ "$NEG" == "--negative" ]]; then "$HERE/make-ospkg.sh" "$OS" --rogue >/dev/null
else "$HERE/make-ospkg.sh" "$OS" >/dev/null; fi
echo "==> OSPKG staged for $OS${NEG:+  (NEGATIVE / rogue-signed)}"

# --- 2. ensure both servers are up (HTTPS for the OSPKG, HTTP for installer stage2) --
"$HERE/serve-netboot.sh" status --tls >/dev/null 2>&1 || "$HERE/serve-netboot.sh" up --tls >/dev/null
"$HERE/serve-netboot.sh" status       >/dev/null 2>&1 || "$HERE/serve-netboot.sh" up       >/dev/null
echo "==> servers: :8443 (HTTPS, OSPKG)  +  :8181 (HTTP, installer stage2/ks)"

# --- 3. boot the stboot UKI under OVMF ---------------------------------------------
LOG="$WORKDIR/stboot-$OS${NEG:+-negative}.log"; rm -f "$LOG"
VARS="$WORKDIR/stboot-vars.fd"; cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS"
if [[ -w /dev/kvm ]]; then ACCEL=kvm; CPU="${CPU:-host}"; else ACCEL=tcg; CPU="${CPU:-Nehalem}"; fi
echo "==> OVMF boot of stboot (accel=$ACCEL cpu=$CPU, ${SECS}s cap) → $LOG"

timeout "$SECS" qemu-system-x86_64 \
  -machine q35,accel="$ACCEL" -cpu "$CPU" -m 4096 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$ESP",format=raw,if=virtio,readonly=on \
  -netdev user,id=n0 -device e1000,netdev=n0 \
  -display none -no-reboot -serial "file:$LOG" || true

# --- 4. verdict --------------------------------------------------------------------
clean() { sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r/\n/g' "$LOG"; }
echo
if [[ "$NEG" == "--negative" ]]; then
  echo "==> NEGATIVE proof — stboot must REFUSE the rogue OSPKG (no kexec):"
  clean | grep -iE "signature|verif|unknown authority|not enough|invalid|no valid|error|fail" \
    | grep -viE "compiled-in" | awk '!seen[$0]++' | head -15
  if clean | grep -qiE "Welcome to (Alma|Rocky|Kali)|anaconda .* started|Starting automated"; then
    echo "!! an installer booted — negative test FAILED (rogue OSPKG was accepted)"; exit 1
  else echo "== no installer kernel booted — refusal confirmed"; fi
else
  echo "==> POSITIVE proof — signed OSPKG verified vs lab-CA → kexec → installer:"
  clean | grep -iE "ST BOOT|Loading OS package|signature|verif|kexec|Linux version [0-9]|Welcome to (Alma|Rocky|Kali)|anaconda .* started|Starting automated" \
    | grep -viE "compiled-in" | awk '!seen[$0]++' | head -20
fi
echo
echo "    full log: $LOG"
