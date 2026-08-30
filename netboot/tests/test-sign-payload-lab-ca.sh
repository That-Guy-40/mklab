#!/usr/bin/env bash
# test-sign-payload-lab-ca.sh — netboot payloads must be signable under the SHARED lab
# root CA, not a root this lab mints for itself (TODO 15.4).
#
# WHY. examples/lab-ca/ is this repo's shared trust anchor — the pxeboot HTTPS tier and
# System Transparency OSPKG signing both chain to it. Until 2026-08-30 `git grep lab-ca
# netboot/` returned NOTHING: every signing run minted a fresh snakeoil root, so the
# RAM-infra family's "reboot pulls the newest VERIFIED image" thesis chained to a key each
# lab had made for itself. A trust anchor with one consumer is not a trust anchor; it is a
# self-signed certificate with extra steps.
#
# WHAT THIS DOES AND DOES NOT PROVE. Everything here is openssl agreeing with openssl.
# That is worth guarding cheaply, but it is NOT the property — "a green host-side gate can
# bless certs the firmware rejects" is a lesson this repo paid for once already (iPXE
# rejects a leaf with no codeSigning EKU that openssl is perfectly happy with). The
# OUTCOME — iPXE's imgverify accepting a payload signed under this root, on a real boot —
# is measured in netboot/MANUAL_TESTING.md §13.3.
#
# It drives a THROWAWAY root, not the shipped one: the shared root's private key is
# gitignored, so a test that could only use the real key would SKIP everywhere except one
# machine, and a guard that skips in CI is an UNKNOWN rather than a pass. LAB_CA_DIR and
# LAB_CA_KEYDIR exist for exactly this.
#
# One verdict (house rule). PASS requires ALL of:
#   1. --lab-ca with no leaf REFUSES, naming the command that mints one
#   2. --lab-ca --gen-keys is refused as contradictory (shared root vs throwaway root)
#   3. the leaf is ECDSA with a codeSigning EKU — both of the things iPXE needs
#   4. a payload signed with it verifies against the SHARED root
#   5. the emitted DER trust root IS that root — compared by digest, not by path
#   6. a one-byte tamper is rejected
#   7. the stboot leaf (Ed25519, NO EKU) is REFUSED by the netboot signer, which is what
#      makes "two leaf profiles under one root" a measurement instead of a comment
#   8. the tracked lab-ca.crt matches the tracked lab-ca.fingerprint beside it
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

SIGNER="$NETBOOT_DIR/sign-payload.sh"
LABCA_SRC="$NETBOOT_DIR/../examples/lab-ca"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sign-lab-ca-test.XXXXXX")"; TMPDIRS+=("$TMP")

require_cmd openssl
[[ -f "$SIGNER" ]] || fail "missing tool: $SIGNER"
[[ -d "$LABCA_SRC" ]] || fail "missing the shared lab CA at $LABCA_SRC — netboot has nothing to anchor to"

# ── 8. the SHIPPED anchor first: cert and fingerprint must agree ────────────────────────
# Both are tracked, and a fingerprint file that has drifted from the cert beside it is a
# cached fact about a file in the same directory — the cheapest possible place to be wrong.
want_fp="$(tr -d '\r\n' < "$LABCA_SRC/lab-ca.fingerprint")"
got_fp="$(openssl x509 -in "$LABCA_SRC/lab-ca.crt" -noout -fingerprint -sha256 | sed 's/^.*=//')"
[[ "$want_fp" == "$got_fp" ]] \
    || fail "REGRESSION: examples/lab-ca/lab-ca.fingerprint does not match lab-ca.crt beside it — every lab that pins the anchor by fingerprint is pinning something else (tracked: $want_fp, derived: $got_fp)"
note "the tracked anchor matches its tracked fingerprint"

# ── a throwaway root, so this runs anywhere ─────────────────────────────────────────────
CA="$TMP/lab-ca"
mkdir -p "$CA"
cp "$LABCA_SRC/make-ca.sh" "$LABCA_SRC/issue-codesign-cert.sh" "$LABCA_SRC/issue-signing-cert.sh" "$CA/"
export LAB_CA_KEYDIR="$CA/private"
( cd "$CA" && ./make-ca.sh ) >/dev/null 2>&1 || fail "make-ca.sh failed to establish a throwaway root"
export LAB_CA_DIR="$CA"

payload="$TMP/vmlinuz"
head -c 65536 /dev/urandom > "$payload" 2>/dev/null || fail "could not make a test payload"

# ── 1. no leaf yet: refuse, and say what to run ─────────────────────────────────────────
out="$( "$SIGNER" --lab-ca netboot-payload "$payload" 2>&1 )" && rc=0 || rc=$?
(( rc != 0 )) || fail "signing succeeded with NO code-signing leaf under the shared root — the signer accepted material that does not exist"
grep -q "issue-codesign-cert.sh" <<<"$out" \
    || fail "the refusal does not name the command that mints the leaf; the operator is told no and not told what to do: $out"
note "no leaf → refused, naming issue-codesign-cert.sh"

# ── 2. --lab-ca --gen-keys is a contradiction ───────────────────────────────────────────
out="$( "$SIGNER" --lab-ca netboot-payload --gen-keys "$payload" 2>&1 )" && rc=0 || rc=$?
(( rc != 0 )) \
    || fail "--lab-ca --gen-keys was accepted: anchoring to the SHARED root and minting a throwaway one are opposites, and silently doing one of them is how a lab ends up trusting a key nobody meant to make"
note "--lab-ca with --gen-keys → refused as contradictory"

# ── mint the leaf ───────────────────────────────────────────────────────────────────────
( cd "$CA" && ./issue-codesign-cert.sh netboot-payload ) >/dev/null 2>&1 \
    || fail "issue-codesign-cert.sh failed to mint a leaf under the throwaway root"
LEAF="$CA/private/certs/netboot-payload-codesign.crt"

# ── 3. the leaf is what iPXE needs: ECDSA, codeSigning EKU ──────────────────────────────
openssl x509 -in "$LEAF" -noout -ext extendedKeyUsage 2>/dev/null | grep -q "Code Signing" \
    || fail "REGRESSION: the code-signing leaf lacks the codeSigning EKU iPXE imgverify requires"
alg="$(openssl x509 -in "$LEAF" -noout -text | sed -n 's/.*Public Key Algorithm: //p' | head -1)"
[[ "$alg" == "id-ecPublicKey" ]] \
    || fail "the code-signing leaf is '$alg'; iPXE v2.0.0 verifies RSA and ECDSA (crypto/ecdsa.c, p256.c, p384.c) and has NO Ed25519 — a leaf it cannot parse fails at boot, not here"
note "leaf: ECDSA with a codeSigning EKU (both required by imgverify)"

# ── 4-5. sign, verify against the SHARED root, and check the DER trust root IS that root ─
( "$SIGNER" --lab-ca netboot-payload --out-trust "$TMP/ca.der" "$payload" ) >/dev/null 2>&1 \
    || fail "signing with a leaf issued by the shared root failed"
[[ -f "$payload.sig" ]] || fail "no detached signature was produced"
openssl cms -verify -binary -purpose any -inform DER -in "$payload.sig" \
    -content "$payload" -CAfile "$CA/lab-ca.crt" -out /dev/null 2>/dev/null \
    || fail "the signature does not verify against the SHARED root it was supposed to chain to"
note "payload signed by the shared root's leaf verifies against that root"

# The trust root that gets BAKED INTO THE FIRMWARE must be the shared anchor. Comparing
# paths would prove only that the right file was named; compare the bytes' digest.
der_fp="$(openssl x509 -inform DER -in "$TMP/ca.der" -noout -fingerprint -sha256 | sed 's/^.*=//')"
ca_fp="$(openssl x509 -in "$CA/lab-ca.crt" -noout -fingerprint -sha256 | sed 's/^.*=//')"
[[ "$der_fp" == "$ca_fp" ]] \
    || fail "--out-trust emitted a DER root that is NOT the shared anchor (der=$der_fp anchor=$ca_fp) — iPXE would be built trusting something else, and everything would still verify at the host"
note "the DER trust root is the shared anchor, by digest"

# ── 6. tamper → rejected ────────────────────────────────────────────────────────────────
# The positive case above verified an untouched payload; an assertion never seen to fail is
# not known to be checking anything.
printf 'X' | dd of="$payload" bs=1 seek=1024 count=1 conv=notrunc status=none
if openssl cms -verify -binary -purpose any -inform DER -in "$payload.sig" \
        -content "$payload" -CAfile "$CA/lab-ca.crt" -out /dev/null 2>/dev/null; then
    fail "REGRESSION: a payload with one flipped byte still verified — the signature is not covering the content"
fi
note "one flipped byte → the signature is rejected"

# ── 7. the OTHER leaf profile must NOT work here ────────────────────────────────────────
# issue-signing-cert.sh mints Ed25519 with NO EKU, deliberately: stboot's Go x509 defaults
# to requiring serverAuth when KeyUsages is unset, so a codeSigning leaf is REJECTED there.
# iPXE is the mirror image. One root, two leaf profiles — and this asserts they are really
# not interchangeable, so that "simplifying" one into the other fails loudly here instead
# of quietly at someone's boot.
( cd "$CA" && ./issue-signing-cert.sh ospkg-signer ) >/dev/null 2>&1 \
    || fail "issue-signing-cert.sh failed to mint the stboot-profile leaf"
ST_LEAF="$CA/private/certs/ospkg-signer-sign.crt"
if openssl x509 -in "$ST_LEAF" -noout -ext extendedKeyUsage 2>/dev/null | grep -q "Code Signing"; then
    fail "REGRESSION: the System Transparency leaf has grown a codeSigning EKU — stboot's descriptor.Verify() will reject it with 'certificate specifies an incompatible key usage', and the OSPKG path breaks at boot with nothing here to say why"
fi
mkdir -p "$TMP/stdir/certs"
cp "$ST_LEAF" "$TMP/stdir/certs/wrongprofile-codesign.crt"
cp "$CA/private/certs/ospkg-signer-sign.key" "$TMP/stdir/certs/wrongprofile-codesign.key"
out="$( LAB_CA_KEYDIR="$TMP/stdir" "$SIGNER" --lab-ca wrongprofile "$payload" 2>&1 )" && rc=0 || rc=$?
(( rc != 0 )) \
    || fail "the netboot signer ACCEPTED the stboot leaf (Ed25519, no EKU). iPXE imgverify would refuse it at boot — which is the failure this gate exists to move to the host"
grep -qi "codeSigning EKU" <<<"$out" \
    || fail "the signer refused the stboot leaf but not by naming the missing codeSigning EKU: $out"
note "the stboot leaf (Ed25519, no EKU) is refused here, by name — the profiles are not interchangeable"

pass "netboot payloads sign under the SHARED lab root CA (TODO 15.4): a leaf minted by issue-codesign-cert.sh is ECDSA with a codeSigning EKU, its signature verifies against that root, the DER trust root baked into iPXE is that same anchor by digest, a flipped byte is rejected, and the Ed25519 no-EKU leaf System Transparency needs is refused by name — one root, two deliberately different leaf profiles"
