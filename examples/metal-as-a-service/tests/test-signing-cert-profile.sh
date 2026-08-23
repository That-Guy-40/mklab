#!/usr/bin/env bash
# test-signing-cert-profile.sh — the certificate profile F2 signs with must be one
# that VERIFYING FIRMWARE accepts, not merely one that OpenSSL accepts.
#
# WHY THIS TEST EXISTS. F2's two halves read the same .sig files: the host-side gate
# (`openssl cms -verify`, before the node is touched) and the on-node half (iPXE
# `imgverify`, after the control plane is out of the picture). OpenSSL does not look
# at key usage; iPXE does. So a leaf carrying only `extendedKeyUsage=codeSigning`
# passes every host-side check and every test in this suite, and is refused outright
# by the firmware with "Not a signing certificate" (https://ipxe.org/022ae1).
#
# That was true of this lab for its entire history, and nothing on the host could
# see it — it took booting a real verifying ROM to find. §4 below is the assertion
# that pins the two signers together so they cannot drift apart again; §5 records,
# as an executable fact, exactly why the host-side gate could not have caught it.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need openssl
VERIFY_LIB="$LAB_DIR/drivers/verify-lib.sh"
SIGN_PAYLOAD="$LAB_DIR/../../netboot/sign-payload.sh"

WORK="$(mktemp -d)"
on_exit 'rm -rf "$WORK"'

# exts <crt> — the extension set that matters here, one per line, normalised.
exts() {
    local crt="$1" out=""
    openssl x509 -in "$crt" -noout -ext basicConstraints,keyUsage,extendedKeyUsage 2>/dev/null \
        | tr -d ' \t' | grep -v '^$' | sort
}

# ─── §1 gen-keys mints the firmware-acceptable profile ───────────────────────
"$VERIFY_LIB" gen-keys --dir "$WORK/new" >/dev/null 2>&1 \
    || fail "verify-lib.sh gen-keys failed outright"
leaf="$WORK/new/codesign.crt"
[[ -f "$leaf" ]] || fail "gen-keys did not produce codesign.crt"

leaf_ku="$(openssl x509 -in "$leaf" -noout -ext keyUsage 2>/dev/null)"
grep -qi 'Digital Signature' <<<"$leaf_ku" \
    || fail "REGRESSION: the minted code-signing leaf has no keyUsage=digitalSignature — iPXE imgverify refuses it as 'Not a signing certificate' (022ae1), so no signed payload can boot on verifying firmware"
# Capture, then test: a verdict must not hang off a pipe into `grep -q` (it exits on the
# first match, the producer can take SIGPIPE, and with pipefail the pipeline is non-zero,
# so a match that WAS found reads as absent). Invisible to tools/tests/test-no-pipe-gates.sh
# until 2026-08-22, because that scanner read PHYSICAL lines and this gate spans a
# backslash continuation. `|| true` keeps the capture from tripping errexit where it is set.
leaf_eku="$(openssl x509 -in "$leaf" -noout -ext extendedKeyUsage 2>/dev/null || true)"
grep -qi 'Code Signing' <<<"$leaf_eku" \
    || fail "REGRESSION: the minted leaf has no extendedKeyUsage=codeSigning — iPXE refuses it as 'Not a code-signing certificate'"
leaf_bc="$(openssl x509 -in "$leaf" -noout -ext basicConstraints 2>/dev/null || true)"
grep -qi 'CA:FALSE' <<<"$leaf_bc" \
    || fail "REGRESSION: the minted code-signing leaf claims CA:TRUE — a signer must not also be a certificate authority"
note "leaf: CA:FALSE + digitalSignature + codeSigning"

ca_crt="$WORK/new/ca.crt"
ca_bc="$(openssl x509 -in "$ca_crt" -noout -ext basicConstraints 2>/dev/null || true)"
grep -qi 'CA:TRUE' <<<"$ca_bc" \
    || fail "REGRESSION: the minted CA is not marked CA:TRUE — it cannot issue the leaf"
ca_ku="$(openssl x509 -in "$ca_crt" -noout -ext keyUsage 2>/dev/null || true)"
grep -qi 'Certificate Sign' <<<"$ca_ku" \
    || fail "REGRESSION: the minted CA has no keyUsage=keyCertSign"
note "CA: CA:TRUE + keyCertSign"

# ─── §2 check-keys accepts it ────────────────────────────────────────────────
( "$VERIFY_LIB" check-keys --dir "$WORK/new" ) >/dev/null 2>&1 \
    || fail "check-keys rejected a keydir that gen-keys just minted — the two disagree about the same profile"

# ─── §3 NEGATIVE CONTROL: the legacy profile must be caught ──────────────────
# Mint exactly what this lab used to mint (EKU only, no keyUsage). If check-keys
# passes this, §2 proves nothing: it would accept anything.
mkdir -p "$WORK/legacy"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/legacy/ca.key" -out "$WORK/legacy/ca.crt" \
    -days 3650 -subj '/CN=legacy CA' >/dev/null 2>&1 || skip "openssl could not mint the control CA"
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/legacy/codesign.key" -out "$WORK/legacy/c.csr" \
    -subj '/CN=legacy leaf' >/dev/null 2>&1 || skip "openssl could not mint the control CSR"
printf 'extendedKeyUsage=codeSigning\n' > "$WORK/legacy/e.ext"
openssl x509 -req -in "$WORK/legacy/c.csr" -CA "$WORK/legacy/ca.crt" -CAkey "$WORK/legacy/ca.key" \
    -CAcreateserial -days 3650 -extfile "$WORK/legacy/e.ext" -out "$WORK/legacy/codesign.crt" >/dev/null 2>&1 \
    || skip "openssl could not mint the control leaf"

legacy_out="$WORK/legacy-check.txt"
if ( "$VERIFY_LIB" check-keys --dir "$WORK/legacy" ) >"$legacy_out" 2>&1; then
    fail "REGRESSION: check-keys ACCEPTED the legacy EKU-only leaf — the guard does not bite, and a fleet can go back to signing payloads verifying firmware will refuse"
fi
grep -q '022ae1' "$legacy_out" \
    || fail "check-keys rejected the legacy leaf but did not name the iPXE error (022ae1) it will produce — the reader is left to guess what the machine will say"
note "negative control bites: legacy EKU-only leaf refused, and the message names 022ae1"

# ─── §4 ANTI-DRIFT: both halves' signers mint the same profile ───────────────
# netboot/sign-payload.sh is the signer the RAM-infra lab PROVED against real iPXE.
# This lab keeps its own copy for self-containment; that is only safe while the two
# agree, and they silently did not.
if [[ -x "$SIGN_PAYLOAD" ]]; then
    mkdir -p "$WORK/proven"
    printf 'payload\n' > "$WORK/proven/f.bin"
    if ( "$SIGN_PAYLOAD" --gen-keys --keydir "$WORK/proven" "$WORK/proven/f.bin" ) >/dev/null 2>&1; then
        ours="$(exts "$leaf")"
        theirs="$(exts "$WORK/proven/codesign.crt")"
        if [[ "$ours" != "$theirs" ]]; then
            printf '  verify-lib.sh leaf:\n%s\n  sign-payload.sh leaf:\n%s\n' "$ours" "$theirs" >&2
            fail "REGRESSION: verify-lib.sh and netboot/sign-payload.sh mint DIFFERENT certificate profiles — the two halves of F2 read the same .sig files, so they must agree on what signs them"
        fi
        note "profile matches netboot/sign-payload.sh (the iPXE-proven signer) exactly"
    else
        note "sign-payload.sh --gen-keys unavailable here; anti-drift check skipped"
    fi
else
    note "netboot/sign-payload.sh not executable; anti-drift check skipped"
fi

# ─── §5 why the host-side gate could not have caught this ───────────────────
# Executable proof that the legacy leaf's signatures still pass host-side
# verification. This is not a bug to fix — it is the reason the gap was invisible,
# and the reason the on-node half is not optional.
printf 'PAYLOAD\n' > "$WORK/legacy/payload.img"
openssl cms -sign -binary -noattr -outform DER \
    -signer "$WORK/legacy/codesign.crt" -inkey "$WORK/legacy/codesign.key" -certfile "$WORK/legacy/ca.crt" \
    -in "$WORK/legacy/payload.img" -out "$WORK/legacy/payload.img.sig" >/dev/null 2>&1 \
    || fail "could not CMS-sign with the legacy leaf"
if ! ( "$VERIFY_LIB" verify "$WORK/legacy/payload.img" --ca "$WORK/legacy/ca.crt" ) >/dev/null 2>&1; then
    fail "the host-side gate rejected the legacy-leaf signature — if that were true the gap would have been visible all along, and this test's premise is wrong"
fi
note "the host-side gate ACCEPTS a signature the firmware refuses — which is why only a booted ROM could find this"

pass "F2 signs with a certificate iPXE accepts (digitalSignature + codeSigning), the guard catches the legacy profile, and both signers agree"
