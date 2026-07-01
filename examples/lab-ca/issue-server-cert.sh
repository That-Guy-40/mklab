#!/usr/bin/env bash
# issue-server-cert.sh <cn> [extra-SAN ...] — mint a TLS **server** leaf signed by the
# shared lab root CA (make-ca.sh). Used by serve-netboot.sh --tls (P2) and the System
# Transparency provisioning HTTPS (P3).
#
# The CN doubles as the primary SAN. For the QEMU-slirp netboot host the guest reaches
# the server at 10.0.2.2, so that's the usual CN; pass extra names/IPs as more args.
#   ./issue-server-cert.sh 10.0.2.2 netboot.lab
#   ./issue-server-cert.sh netboot.lab DNS:pxe.lab IP:10.0.2.2
#
# Output (in the gitignored keystore): <cn>.key + <cn>.crt (+ <cn>-fullchain.crt =
# leaf then root, for servers that want to present the chain). Clients trust lab-ca.crt.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <cn> [extra-SAN ...]" >&2; exit 1; }
CN="$1"; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
KEYDIR="${LAB_CA_KEYDIR:-$HERE/private}"
CAKEY="$KEYDIR/lab-ca.key"; CACRT="$HERE/lab-ca.crt"
DAYS="${LAB_CERT_DAYS:-825}"                       # ~27 mo (under the 825d browser cap)
[[ -f "$CAKEY" && -f "$CACRT" ]] || { echo "no lab CA yet — run ./make-ca.sh first" >&2; exit 1; }

CERTS="$KEYDIR/certs"; mkdir -p "$CERTS"
KEY="$CERTS/$CN.key"; CRT="$CERTS/$CN.crt"; FULL="$CERTS/$CN-fullchain.crt"

# Build the SAN list: CN as IP or DNS (auto-detect), plus any extra args. Extra args
# may be bare (auto-typed) or already prefixed (IP:/DNS:).
is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
san=(); if is_ip "$CN"; then san+=("IP:$CN"); else san+=("DNS:$CN"); fi
for a in "$@"; do
  if [[ "$a" == IP:* || "$a" == DNS:* ]]; then san+=("$a")
  elif is_ip "$a"; then san+=("IP:$a"); else san+=("DNS:$a"); fi
done
SAN="$(IFS=,; echo "${san[*]}")"

echo "==> issuing server leaf CN=$CN  SAN=$SAN  (${DAYS}d) signed by the lab CA"
openssl ecparam -name prime256v1 -genkey -noout -out "$KEY"; chmod 600 "$KEY"
openssl req -new -key "$KEY" -subj "/O=mklab/CN=$CN" -out "$CERTS/$CN.csr"
openssl x509 -req -in "$CERTS/$CN.csr" -CA "$CACRT" -CAkey "$CAKEY" \
  -CAcreateserial -CAserial "$KEYDIR/lab-ca.srl" \
  -days "$DAYS" -sha256 \
  -extfile <(printf 'basicConstraints=CA:false\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$SAN") \
  -out "$CRT"
rm -f "$CERTS/$CN.csr"
cat "$CRT" "$CACRT" > "$FULL"

echo "==> verifying leaf against the lab CA (openssl verify):"
openssl verify -CAfile "$CACRT" "$CRT" | sed 's/^/    /'
echo "==> server material (gitignored keystore):"
echo "    key:        $KEY"
echo "    cert:       $CRT"
echo "    fullchain:  $FULL   (leaf+root; hand this to nginx ssl_certificate)"
