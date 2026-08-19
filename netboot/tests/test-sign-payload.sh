#!/usr/bin/env bash
# test-sign-payload.sh — prove netboot/sign-payload.sh produces iPXE-shaped
# code signatures and fails closed.
#
# Host-only: no QEMU, no Docker, no root, no network — just openssl. The
# QEMU-level "iPXE imgverify actually boots the signed image / rolls back /
# refuses" proof is in netboot/MANUAL_TESTING.md (needs a full iPXE build);
# this guards the signing half that CI can run cheaply.
#
# One verdict (house rule). PASS requires ALL of:
#   1. a detached CMS signature is produced and cryptographically verifies,
#   2. the signing leaf carries the codeSigning EKU iPXE requires,
#   3. a one-byte tamper is REJECTED (the whole point — regression guard),
#   4. signing refuses when no keys exist and --gen-keys was not given.
# Verdict helpers, the scratch-dir sweep and the EXIT net all come from lib.sh. This test
# used to carry its own inline `trap … EXIT`, which is the shape CLAUDE.md now forbids:
# bash keeps ONE EXIT trap per shell, so an inlined one silently REPLACES the shared net.
# Its version also treated rc=1 as an acceptable silent exit, so a `die` inside the tool
# under test would have ended the run with no verdict at all.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

SIGNER="$NETBOOT_DIR/sign-payload.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sign-payload-test.XXXXXX")"; TMPDIRS+=("$TMP")

require_cmd openssl
[[ -f "$SIGNER" ]] || fail "missing tool: $SIGNER"

keydir="$TMP/codesign"
payload="$TMP/vmlinuz"
head -c 65536 /dev/urandom > "$payload" 2>/dev/null || fail "could not make a test payload"

# 1) sign (mint snakeoil keys), emit the DER trust root
if ! ( "$SIGNER" --gen-keys --keydir "$keydir" --out-trust "$keydir/ca.der" "$payload" ) >/dev/null 2>&1; then
    fail "sign-payload.sh --gen-keys failed on a fresh payload"
fi
[[ -f "$payload.sig"    ]] || fail "no detached signature produced ($payload.sig)"
[[ -f "$keydir/ca.der"  ]] || fail "--out-trust did not emit the DER trust root"
note "signature + DER trust root produced"

# 2) the signing leaf must carry codeSigning EKU (iPXE requires it)
if ! openssl x509 -in "$keydir/codesign.crt" -noout -ext extendedKeyUsage 2>/dev/null \
        | grep -q "Code Signing"; then
    fail "REGRESSION: signing leaf lacks the codeSigning EKU iPXE imgverify requires"
fi
note "signing leaf has codeSigning EKU"

# 3a) untampered signature verifies (-purpose any: a codeSigning-only leaf is
#     correctly not valid for openssl's default smimesign purpose)
if ! openssl cms -verify -binary -purpose any -inform DER -in "$payload.sig" \
        -content "$payload" -CAfile "$keydir/ca.crt" -out /dev/null 2>/dev/null; then
    fail "valid signature did not verify against its own CA"
fi
note "untampered payload verifies"

# 3b) a one-byte tamper MUST be rejected
#
# THE TAMPER IS DERIVED FROM THE BYTE IT REPLACES, AND THEN CHECKED.
# This used to write a constant `\xff` at offset 1024 of a payload made of 65536 bytes of
# /dev/urandom. One run in 256, that byte is ALREADY 0xff — so "the tamper" changed nothing,
# openssl verified an untouched payload exactly as it should, and this test reported
# `REGRESSION: a tampered payload verified against the untampered signature` about a signing
# tool that was working perfectly. Seen in CI 2026-08-19 while every local run passed, which
# is what a 0.4% flake looks like from the outside.
#
# It is this repo's own lesson pointed at its own negative control: a control that does not
# verify it actually broke something is not known to be controlling anything — and this one
# failed in the WORSE direction, manufacturing a security regression out of a coin flip.
# `cmp` is the outcome check; "I ran dd" was the mechanism check.
tampered="$TMP/vmlinuz.tampered"
cp "$payload" "$tampered"
orig_byte="$(dd if="$payload" bs=1 skip=1024 count=1 status=none | od -An -tu1 | tr -d '[:space:]')"
[[ -n "$orig_byte" ]] || fail "could not read byte 1024 of the test payload, so the tamper below cannot be aimed"
new_byte=$(( (orig_byte + 1) % 256 ))
# shellcheck disable=SC2059  # the format IS the computed byte; that is the point
printf "$(printf '\\x%02x' "$new_byte")" \
    | dd of="$tampered" bs=1 seek=1024 count=1 conv=notrunc status=none 2>/dev/null
cmp -s "$payload" "$tampered" \
    && fail "the tamper did not change the payload (byte 1024 is still $orig_byte), so the verification below would prove nothing about tamper detection"
note "tamper applied and confirmed: byte 1024 changed $orig_byte -> $new_byte"

if openssl cms -verify -binary -purpose any -inform DER -in "$payload.sig" \
        -content "$tampered" -CAfile "$keydir/ca.crt" -out /dev/null 2>/dev/null; then
    fail "REGRESSION: a tampered payload verified against the untampered signature"
fi
note "tampered payload rejected"

# 4) fail closed: no keys + no --gen-keys must refuse
if ( "$SIGNER" --keydir "$TMP/absent" "$payload" ) >/dev/null 2>&1; then
    fail "signing succeeded with no keys and no --gen-keys (should refuse)"
fi
note "refuses to sign without keys unless --gen-keys"

pass "sign-payload.sh: CMS-signs (codeSigning EKU), verifies, rejects tampering, fails closed"
