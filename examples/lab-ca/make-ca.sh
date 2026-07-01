#!/usr/bin/env bash
# make-ca.sh — establish the **shared mklab lab root CA** (idempotent).
#
# This is deliberately NOT a throwaway cert inside one lab: it's a reusable, highly
# trusted **root** that every lab needing TLS or signed artifacts anchors to (the
# linuxboot-uefi-kexec pxeboot HTTPS tier / System Transparency, and any netboot lab
# that wants *real* — non `-k` — HTTPS). See README.md for the trust model.
#
# The teachable PKI split:
#   ✅ TRACKED in git:  lab-ca.crt + lab-ca.fingerprint  (the PUBLIC trust anchor)
#   🚫 NEVER tracked:   private/  (the root private key + issued leaf keys)  — gitignored
# Losing the key just means re-running this (a new root) and re-baking the new
# lab-ca.crt. Committing the key would let anyone forge a "trusted" cert/OSPKG the
# ROM accepts — which is the whole thing P2/P3 exist to prevent.
#
#   ./make-ca.sh          # generate the root once (no-op if it already exists)
#   ./make-ca.sh --force  # regenerate (new root; you must re-bake lab-ca.crt everywhere)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KEYDIR="${LAB_CA_KEYDIR:-$HERE/private}"          # keystore (gitignored); override for ~/.config/lab-ca
CAKEY="$KEYDIR/lab-ca.key"
CACRT="$HERE/lab-ca.crt"                          # PUBLIC anchor (tracked)
CAFP="$HERE/lab-ca.fingerprint"                   # PUBLIC fingerprint (tracked)
SUBJ="${LAB_CA_SUBJECT:-/O=mklab/CN=mklab Lab Root CA}"
DAYS="${LAB_CA_DAYS:-3650}"                        # 10-year root
command -v openssl >/dev/null || { echo "openssl required" >&2; exit 1; }

# Belt-and-suspenders: make sure the key can never be staged, even before it exists.
mkdir -p "$KEYDIR"
cat > "$HERE/.gitignore" <<'EOF'
# The lab CA's PRIVATE material — never commit. Only lab-ca.crt + lab-ca.fingerprint
# (the public trust anchor) are tracked. Regenerate with ./make-ca.sh if lost.
private/
*.key
*key.pem
*.srl
EOF

if [[ "${1:-}" != "--force" && -f "$CAKEY" && -f "$CACRT" ]]; then
  echo "==> lab CA already exists (idempotent) — $CACRT"
else
  echo "==> generating a fresh mklab lab root CA (ECDSA P-256, ${DAYS}d) → $KEYDIR"
  openssl ecparam -name prime256v1 -genkey -noout -out "$CAKEY"
  chmod 600 "$CAKEY"
  # Self-signed root: CA:true, cert-signing only (no serverAuth on the root itself).
  openssl req -x509 -new -key "$CAKEY" -sha256 -days "$DAYS" -subj "$SUBJ" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$CACRT"
fi

# Record the SHA-256 fingerprint of the public root (this is what labs pin / display).
openssl x509 -in "$CACRT" -noout -fingerprint -sha256 | sed 's/^.*=//' > "$CAFP"

echo "==> root CA public anchor (TRACKED in git):"
echo "    cert:        $CACRT"
echo "    fingerprint: $(cat "$CAFP")"
openssl x509 -in "$CACRT" -noout -subject -dates | sed 's/^/    /'
echo "==> private key (gitignored, guarded): $CAKEY"
echo "    issue a TLS server cert:  ./issue-server-cert.sh 10.0.2.2"
