#!/usr/bin/env bash
# issue-signing-cert.sh <name> — mint an **Ed25519 signing** leaf signed by the shared
# lab root CA (make-ca.sh). For System Transparency OSPKG signing (P3): the OSPKG is
# signed by this leaf's key, and the trust policy's ospkg_signing_root.pem anchors to
# the shared lab-ca.crt. Ed25519 is what ST/stmgr uses.
#
#   ./issue-signing-cert.sh ospkg-signer
#
# Output (gitignored keystore): certs/<name>-sign.key + certs/<name>-sign.crt.
#
# EKU GOTCHA (stboot interop, learned the hard way — POC-PXEBOOT-P3.md): stboot's
# descriptor.Verify() builds x509.VerifyOptions with KeyUsages UNSET, so Go's x509
# defaults to requiring **ExtKeyUsageServerAuth** on the signing leaf. A leaf carrying
# `extendedKeyUsage=codeSigning` (the semantically-obvious choice) is therefore REJECTED
# with "x509: certificate specifies an incompatible key usage". So we mint the leaf with
# NO EKU extension — Go treats a no-EKU leaf as valid for any usage, satisfying the check
# — and rely on the basic keyUsage=digitalSignature. (The root carries no EKU either, so
# the chain is unconstrained.)
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
  -extfile <(printf 'basicConstraints=CA:false\nkeyUsage=critical,digitalSignature\n') \
  -out "$CRT"
rm -f "$CERTS/$NAME.csr"

echo "==> verifying against the lab CA:"; openssl verify -CAfile "$CACRT" "$CRT" | sed 's/^/    /'
echo "    key:  $KEY"; echo "    cert: $CRT"
