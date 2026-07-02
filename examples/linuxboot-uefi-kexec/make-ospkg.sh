#!/usr/bin/env bash
# make-ospkg.sh <alma|rocky|kali> [--rogue] — PLAN-PXEBOOT P3: wrap an OS installer
# into a System Transparency **OS package** and sign it with the shared lab CA.
#
# An OSPKG is stboot's unit of trust: a .zip archive (kernel + initramfs + cmdline)
# plus a .json descriptor that carries the Ed25519 signature(s). stboot fetches the
# descriptor, verifies the signature chains to the trusted root (lab-ca.crt) and meets
# the threshold, then kexecs the kernel. This script builds that artifact from the
# SAME installer kernel/initrd/cmdline the P1/P2 tiers boot — the single source of
# truth is boot-<os>.ipxe (rendered by fetch-netboot-os.sh) — so P3 provisions the
# identical Alma/Rocky/Kali install, just gated on a signature.
#
# The OSPKG's kernel cmdline is verbatim from boot-<os>.ipxe: the kexec'd installer
# still does its OWN kernel `ip=dhcp` (works over slirp) and pulls inst.stage2/inst.ks
# (or the preseed) over plain http :8181 — P3 verifies the ROM→kernel artifact, not the
# installer's later distro-side downloads (same scope split as P2; see POC-PXEBOOT-P3.md).
#
#   --rogue : sign with a throwaway cert NOT chaining to the lab CA — the NEGATIVE test
#             (stboot must refuse it). Produces the same filenames so run-stboot.sh boots it.
#
#   ./make-ospkg.sh alma            # positive: signed by the lab-CA leaf
#   ./make-ospkg.sh alma --rogue    # negative: signed by an untrusted key
set -euo pipefail
OS="${1:-alma}"; MODE="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
NETBOOT_DIR="${NETBOOT_DIR:-$HOME/netboot}"
LABCA="${LABCA:-$HERE/../lab-ca}"
BIN="$WORKDIR/st-p3/bin"; STMGR="$BIN/stmgr"
HTTP="http://10.0.2.2:8181"
OSPKG_ZIP_URL="${OSPKG_ZIP_URL:-https://10.0.2.2:8443/stboot-ospkg.zip}"
IPXE="$NETBOOT_DIR/boot-$OS.ipxe"
[[ -x "$STMGR" ]] || { echo "no stmgr — run ./build-st.sh first" >&2; exit 1; }
[[ -f "$IPXE"  ]] || { echo "no $IPXE — run ./fetch-netboot-os.sh $OS" >&2; exit 1; }

# --- derive kernel file / initrd file / cmdline from the P1 iPXE script -------------
# kernel line:  kernel <url> <args...> [|| goto retry]      initrd line: initrd <url> [|| ...]
kline="$(grep -E '^kernel ' "$IPXE" | head -1 | sed 's/ *|| goto retry *$//')"
iline="$(grep -E '^initrd ' "$IPXE" | head -1 | sed 's/ *|| goto retry *$//')"
KURL="$(awk '{print $2}' <<<"$kline")"; KARGS="$(cut -d' ' -f3- <<<"$kline")"
IURL="$(awk '{print $2}' <<<"$iline")"
# map the served URL back to a local file under $NETBOOT_DIR
KFILE="$NETBOOT_DIR/${KURL#$HTTP/}"; IFILE="$NETBOOT_DIR/${IURL#$HTTP/}"
[[ -f "$KFILE" ]] || { echo "kernel file missing: $KFILE" >&2; exit 1; }
[[ -f "$IFILE" ]] || { echo "initrd file missing: $IFILE" >&2; exit 1; }
echo "==> OSPKG payload for $OS:"
echo "    kernel : $KFILE"
echo "    initrd : $IFILE"
echo "    cmdline: $KARGS"

# --- create the OSPKG (.zip + .json) at the fixed name the stboot UKI points at -----
OUT="$NETBOOT_DIR/stboot-ospkg"
rm -f "$OUT.zip" "$OUT.json"
"$STMGR" ospkg create -kernel "$KFILE" -initramfs "$IFILE" \
  -cmdline "$KARGS" -url "$OSPKG_ZIP_URL" \
  -label "mklab P3 $OS installer" -out "$OUT"
echo "==> created $(basename "$OUT").zip ($(du -h "$OUT.zip" | cut -f1)) + .json"

# --- sign it ------------------------------------------------------------------------
if [[ "$MODE" == "--rogue" ]]; then
  # NEGATIVE: a self-signed Ed25519 cert that does NOT chain to the lab CA.
  ROGUE="$WORKDIR/st-p3/rogue"; mkdir -p "$ROGUE"
  if [[ ! -f "$ROGUE/rogue-sign.crt" ]]; then
    echo "==> minting a ROGUE (untrusted) Ed25519 signing cert"
    openssl genpkey -algorithm ed25519 -out "$ROGUE/rogue-sign.key" 2>/dev/null
    openssl req -new -x509 -key "$ROGUE/rogue-sign.key" -days 30 \
      -subj "/O=NOT-mklab/CN=rogue-ospkg-signer" -out "$ROGUE/rogue-sign.crt" 2>/dev/null
  fi
  CERT="$ROGUE/rogue-sign.crt"; KEY="$ROGUE/rogue-sign.key"
  echo "==> signing with ROGUE key (expect stboot to REFUSE this)"
else
  # POSITIVE: the lab-CA Ed25519 signing leaf (issue-signing-cert.sh).
  CERT="$LABCA/private/certs/ospkg-signer-sign.crt"; KEY="$LABCA/private/certs/ospkg-signer-sign.key"
  [[ -f "$CERT" && -f "$KEY" ]] || { echo "==> issuing lab-CA signing leaf"; ( cd "$LABCA" && ./issue-signing-cert.sh ospkg-signer ); }
  echo "==> signing with the lab-CA Ed25519 leaf (chains to lab-ca.crt)"
fi
"$STMGR" ospkg sign -cert "$CERT" -key "$KEY" -ospkg "$OUT.json"

# stmgr writes the OSPKG 0600; the rootless-nginx user must read it → world-readable.
chmod 0644 "$OUT.zip" "$OUT.json"

echo "==> signature(s) in descriptor:"
jq -r '.signatures | length as $n | "    \($n) signature(s)"' "$OUT.json" 2>/dev/null || true
echo "==> OSPKG ready at $OUT.{zip,json}  (served by ./serve-netboot.sh up --tls)"
[[ "$MODE" == "--rogue" ]] && echo "    (ROGUE build — the negative test)"
echo "Next:  ./run-stboot.sh $OS${MODE:+  }$MODE"
