#!/usr/bin/env bash
# issue-signing-cert.sh <name> — mint an **Ed25519 code-signing** leaf signed by the
# shared lab root CA (make-ca.sh). For System Transparency OSPKG signing (P3): the
# OSPKG is signed by this leaf's key, and the ROM's trust policy anchors to the shared
# lab-ca.crt. Ed25519 is what ST/stmgr uses.
#
#   ./issue-signing-cert.sh ospkg-signer
#
# Output (gitignored keystore): certs/<name>-sign.key + certs/<name>-sign.crt.
# NOTE: P3's `stmgr` has its own cert model; build-st.sh adapts these as needed. This
# script exists so all signing trust chains to ONE root (the reuse requirement).
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <name>" >&2; exit 1; }
NAME="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEYDIR="${LAB_CA_KEYDIR:-$HERE/private}"
CAKEY="$KEYDIR/lab-ca.key"; CACRT="$HERE/lab-ca.crt"
DAYS="${LAB_CERT_DAYS:-825}"
[[ -f "$CAKEY" && -f "$CACRT" ]] || { echo "no lab CA yet — run ./make-ca.sh first" >&2; exit 1; }

CERTS="$KEYDIR/certs"; mkdir -p "$CERTS"
KEY="$CERTS/$NAME-sign.key"; CRT="$CERTS/$NAME-sign.crt"

echo "==> issuing Ed25519 code-signing leaf '$NAME' signed by the lab CA (${DAYS}d)"
openssl genpkey -algorithm ed25519 -out "$KEY"; chmod 600 "$KEY"
openssl req -new -key "$KEY" -subj "/O=mklab/CN=$NAME" -out "$CERTS/$NAME.csr"
openssl x509 -req -in "$CERTS/$NAME.csr" -CA "$CACRT" -CAkey "$CAKEY" \
  -CAcreateserial -CAserial "$KEYDIR/lab-ca.srl" -days "$DAYS" \
  -extfile <(printf 'basicConstraints=CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n') \
  -out "$CRT"
rm -f "$CERTS/$NAME.csr"

echo "==> verifying against the lab CA:"; openssl verify -CAfile "$CACRT" "$CRT" | sed 's/^/    /'
echo "    key:  $KEY"; echo "    cert: $CRT"
