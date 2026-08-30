#!/usr/bin/env bash
# issue-codesign-cert.sh <name> — mint an **ECDSA P-256 code-signing** leaf signed by the
# shared lab root CA (make-ca.sh), for iPXE's `imgverify`.
#
#   ./issue-codesign-cert.sh netboot-payload
#
# Output (gitignored keystore): certs/<name>-codesign.key + certs/<name>-codesign.crt.
#
# ── WHY THIS IS A SECOND SCRIPT AND NOT A FLAG ON issue-signing-cert.sh ──────────────────
#
# The two consumers of a "signing leaf" in this repo want CONTRADICTORY certificates, and
# that is not a wart to be tidied away — it is the finding. One root, two leaf profiles:
#
#   stboot / System Transparency (issue-signing-cert.sh)   iPXE imgverify (this file)
#   ----------------------------------------------------   ---------------------------
#   Ed25519, because that is what ST/stmgr uses             ECDSA P-256 (or RSA)
#   NO extendedKeyUsage AT ALL                              extendedKeyUsage=codeSigning
#
# stboot's descriptor.Verify() builds x509.VerifyOptions with KeyUsages UNSET, so Go
# defaults to requiring ExtKeyUsageServerAuth; a leaf carrying codeSigning is REJECTED
# with "x509: certificate specifies an incompatible key usage". iPXE is the mirror image:
# imgverify REQUIRES codeSigning and rejects a leaf without it. A single leaf cannot
# satisfy both, so DO NOT "fix" either script into the other — tests/test-two-leaf-profiles.sh
# exists to stop exactly that, and names both failure modes.
#
# ── WHY ECDSA P-256 ─────────────────────────────────────────────────────────────────────
#
# The shared root is ECDSA P-256 (make-ca.sh), so the leaf's signature is verified with
# that key whatever the leaf's own algorithm is. iPXE could not do this at all until
# v2.0.0: the pinned tree (netboot/versions.env, v2.0.0 = 12798ec) is the first release
# carrying crypto/ecdsa.c plus crypto/p256.c and crypto/p384.c. Ed25519 is NOT among them,
# which is the second reason the ST leaf cannot be reused here.
#
# THE HOST-SIDE CHECK IS NOT THE PROOF. `openssl verify` blessing this chain says nothing
# about what the firmware does with it — a green host-side gate has blessed certs iPXE
# rejected before. The outcome is measured in netboot/MANUAL_TESTING.md §13.3, by booting
# an iPXE built with this root and watching imgverify accept a payload signed by this leaf.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <name>" >&2; exit 1; }
NAME="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEYDIR="${LAB_CA_KEYDIR:-$HERE/private}"
CAKEY="$KEYDIR/lab-ca.key"; CACRT="$HERE/lab-ca.crt"
DAYS="${LAB_CERT_DAYS:-825}"
[[ -f "$CAKEY" && -f "$CACRT" ]] || { echo "no lab CA yet — run ./make-ca.sh first" >&2; exit 1; }

CERTS="$KEYDIR/certs"; mkdir -p "$CERTS"
KEY="$CERTS/$NAME-codesign.key"; CRT="$CERTS/$NAME-codesign.crt"

echo "==> issuing ECDSA P-256 code-signing leaf '$NAME' signed by the lab CA (${DAYS}d)"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$KEY" 2>/dev/null
chmod 600 "$KEY"
openssl req -new -key "$KEY" -subj "/O=mklab/CN=$NAME code signing" -out "$CERTS/$NAME.csr"
# keyUsage=digitalSignature AND extendedKeyUsage=codeSigning: iPXE checks both, and has
# rejected a leaf missing either. Both critical, as ipxe.org/appnote/codesigning shows.
openssl x509 -req -in "$CERTS/$NAME.csr" -CA "$CACRT" -CAkey "$CAKEY" \
  -CAcreateserial -CAserial "$KEYDIR/lab-ca.srl" -days "$DAYS" -sha256 \
  -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n') \
  -out "$CRT"
rm -f "$CERTS/$NAME.csr"

echo "==> verifying against the lab CA:"
openssl verify -purpose any -CAfile "$CACRT" "$CRT" | sed 's/^/    /'
openssl x509 -in "$CRT" -noout -ext extendedKeyUsage | sed 's/^/    /'
echo "    key:  $KEY"
echo "    cert: $CRT"
echo "==> sign netboot payloads with it:"
echo "    netboot/sign-payload.sh --lab-ca $NAME --out-trust ~/netboot/codesign/ca.der <file>..."
