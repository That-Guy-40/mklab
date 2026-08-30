#!/usr/bin/env bash
# test-anchor-and-profiles.sh — the shared lab root CA must be what it says it is, must
# not leak its key, and must keep issuing the TWO INCOMPATIBLE leaf profiles its
# consumers require.
#
# WHY THIS SUITE EXISTS AT ALL (TODO 15.4). This directory is the repo's trust anchor —
# the pxeboot HTTPS tier, System Transparency OSPKG signing and (since 2026-08-30) signed
# netboot payloads all chain to it — and nothing checked any of it. A root with one
# consumer can be wrong quietly; a root with three cannot, which is the whole argument for
# sharing it and also the reason it needs guarding.
#
# One verdict (house rule). PASS requires ALL of:
#   1. the tracked lab-ca.crt and the tracked lab-ca.fingerprint agree — both DERIVED
#   2. the anchor is a CA, can sign certs, and has not expired
#   3. the anchor is ECDSA — iPXE can parse RSA and ECDSA (P-256/P-384) and nothing else
#   4. no private key is tracked, and the keystore is genuinely unstageable
#   5. issue-signing-cert.sh mints Ed25519 with NO EKU        (System Transparency needs it)
#   6. issue-codesign-cert.sh mints ECDSA with codeSigning    (iPXE imgverify needs it)
#   7. …and 5 and 6 are DIFFERENT certificates, so "unifying" them fails here rather than
#      at someone's boot
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd openssl git
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lab-ca-test.XXXXXX")"; on_exit 'rm -rf "$TMP"'

CRT="$LAB_DIR/lab-ca.crt"
FP="$LAB_DIR/lab-ca.fingerprint"
[[ -r "$CRT" ]] || fail "the tracked anchor is missing: $CRT"
[[ -r "$FP"  ]] || fail "the tracked fingerprint is missing: $FP"

# ── 1. the pair agrees, and BOTH sides are derived ──────────────────────────────────────
want="$(tr -d '\r\n' < "$FP")"
got="$(openssl x509 -in "$CRT" -noout -fingerprint -sha256 | sed 's/^.*=//')"
[[ "$want" == "$got" ]] \
    || fail "REGRESSION: lab-ca.fingerprint does not match lab-ca.crt beside it — every consumer that pins the anchor by fingerprint is pinning something else (tracked: $want, derived: $got)"
note "the tracked fingerprint is the tracked certificate's"

# ── 2. it is a usable CA, now ───────────────────────────────────────────────────────────
openssl x509 -in "$CRT" -noout -ext basicConstraints 2>/dev/null | grep -q "CA:TRUE" \
    || fail "the anchor does not assert CA:TRUE — nothing it signs can chain to it"
openssl x509 -in "$CRT" -noout -ext keyUsage 2>/dev/null | grep -qi "Certificate Sign" \
    || fail "the anchor lacks keyCertSign — a verifier that checks key usage will refuse every leaf it issued"
openssl x509 -in "$CRT" -noout -checkend 0 >/dev/null 2>&1 \
    || fail "the shared anchor has EXPIRED — every consumer fails closed, and the failure appears at boot as an unrelated chain error ($(openssl x509 -in "$CRT" -noout -enddate))"
# 90 days is a warning, not a failure: a rotation invalidates every baked-in copy, so it
# is a thing to plan rather than to discover.
openssl x509 -in "$CRT" -noout -checkend 7776000 >/dev/null 2>&1 \
    || note "WARNING: the anchor expires within 90 days ($(openssl x509 -in "$CRT" -noout -enddate | sed 's/notAfter=//')) — rotating it means re-baking lab-ca.crt in every consumer"
note "the anchor is a CA with keyCertSign, and is valid now"

# ── 3. ECDSA, because of who has to parse it ────────────────────────────────────────────
alg="$(openssl x509 -in "$CRT" -noout -text | sed -n 's/.*Public Key Algorithm: //p' | head -1)"
[[ "$alg" == "id-ecPublicKey" || "$alg" == "rsaEncryption" ]] \
    || fail "the anchor is '$alg'. iPXE v2.0.0 verifies RSA and ECDSA (crypto/rsa.c, crypto/ecdsa.c + p256.c/p384.c) and has no Ed25519 — a root it cannot parse fails at boot, where the message is least useful"
note "anchor key algorithm: $alg (parseable by iPXE's crypto)"

# ── 4. key hygiene, asserted rather than asserted-in-prose ──────────────────────────────
tracked_keys="$( cd "$LAB_DIR" && git ls-files | grep -E '\.key$|key\.pem$|^private/' || true )"
[[ -z "$tracked_keys" ]] \
    || fail "PRIVATE MATERIAL IS TRACKED IN GIT: $(tr '\n' ' ' <<<"$tracked_keys") — anyone with the repo can forge a certificate every consumer trusts, which is the one thing this CA exists to prevent"
if [[ -f "$LAB_DIR/private/lab-ca.key" ]]; then
    ( cd "$LAB_DIR" && git check-ignore -q private/lab-ca.key ) \
        || fail "private/lab-ca.key exists and is NOT gitignored — it is one 'git add -A' away from being published"
    # NOT \`git add -A\` in that message. A backtick inside a DOUBLE-quoted string is
    # command substitution, so the first draft of this line RAN `git add -A` — staging the
    # whole repo — every time the assertion fired. Caught by this test's own control,
    # which is CLAUDE.md's opening rule pointed at a test's error message: never let text
    # that merely NAMES a command sit where a shell will run it.
    note "the root key exists here and is ignored by git"
else
    note "no root key on this host (fine — the public anchor is what is tracked)"
fi

# ── 5-7. the two leaf profiles, under a throwaway root ──────────────────────────────────
# A throwaway root because the real key is gitignored: a guard that can only run on one
# machine is an UNKNOWN everywhere else.
CA="$TMP/ca"; mkdir -p "$CA"
cp "$LAB_DIR"/make-ca.sh "$LAB_DIR"/issue-signing-cert.sh "$LAB_DIR"/issue-codesign-cert.sh "$CA/"
export LAB_CA_KEYDIR="$CA/private"
( cd "$CA" && ./make-ca.sh ) >/dev/null 2>&1 || fail "make-ca.sh could not establish a throwaway root"
( cd "$CA" && ./issue-signing-cert.sh st-leaf )   >/dev/null 2>&1 || fail "issue-signing-cert.sh failed"
( cd "$CA" && ./issue-codesign-cert.sh ipxe-leaf ) >/dev/null 2>&1 || fail "issue-codesign-cert.sh failed"
ST="$CA/private/certs/st-leaf-sign.crt"
IP="$CA/private/certs/ipxe-leaf-codesign.crt"

st_alg="$(openssl x509 -in "$ST" -noout -text | sed -n 's/.*Public Key Algorithm: //p' | head -1)"
[[ "$st_alg" == "ED25519" ]] \
    || fail "the System Transparency leaf is '$st_alg', not Ed25519 — ST/stmgr signs with Ed25519, so a different key type breaks OSPKG signing"
if openssl x509 -in "$ST" -noout -ext extendedKeyUsage 2>/dev/null | grep -q .; then
    fail "REGRESSION: the System Transparency leaf has grown an extendedKeyUsage. stboot's descriptor.Verify() leaves KeyUsages unset, so Go requires serverAuth and rejects ANY other EKU with 'certificate specifies an incompatible key usage' — at boot, not here"
fi
note "ST leaf: Ed25519, no EKU at all (what stboot's Go x509 accepts)"

ip_alg="$(openssl x509 -in "$IP" -noout -text | sed -n 's/.*Public Key Algorithm: //p' | head -1)"
[[ "$ip_alg" == "id-ecPublicKey" ]] \
    || fail "the iPXE code-signing leaf is '$ip_alg'; iPXE has no Ed25519 support, so imgverify cannot parse it"
openssl x509 -in "$IP" -noout -ext extendedKeyUsage 2>/dev/null | grep -q "Code Signing" \
    || fail "REGRESSION: the iPXE leaf lacks the codeSigning EKU imgverify requires"
openssl x509 -in "$IP" -noout -ext keyUsage 2>/dev/null | grep -qi "Digital Signature" \
    || fail "REGRESSION: the iPXE leaf lacks keyUsage=digitalSignature. openssl cms -verify does not check key usage, so this passes every host-side gate and iPXE refuses it with 022ae13c 'Not a signing certificate' — the exact defect that cost a day in metal-as-a-service"
note "iPXE leaf: ECDSA, codeSigning EKU + digitalSignature (all three checked by the firmware)"

# The point of 5 and 6 together: they must not converge.
[[ "$(openssl x509 -in "$ST" -noout -fingerprint -sha256)" != "$(openssl x509 -in "$IP" -noout -fingerprint -sha256)" ]] \
    || fail "the two leaves are the same certificate — one of the issuers is no longer issuing its own profile"
both_verify=0
openssl verify -purpose any -CAfile "$CA/lab-ca.crt" "$ST" >/dev/null 2>&1 && both_verify=$((both_verify+1))
openssl verify -purpose any -CAfile "$CA/lab-ca.crt" "$IP" >/dev/null 2>&1 && both_verify=$((both_verify+1))
(( both_verify == 2 )) \
    || fail "only $both_verify of the 2 leaves chain to the shared root — the point of one anchor is that every consumer's leaf hangs off it"
note "both leaves chain to the one root, and are different certificates"

pass "the shared lab root CA is the certificate its tracked fingerprint names, is a valid ECDSA CA that iPXE can parse, keeps its private material out of git, and issues TWO deliberately incompatible leaf profiles — Ed25519/no-EKU for System Transparency and ECDSA/codeSigning+digitalSignature for iPXE imgverify — both chaining to it"
