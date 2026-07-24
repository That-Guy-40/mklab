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
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SIGNER="$HERE/../sign-payload.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sign-payload-test.XXXXXX")"

skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

# Safety net: no silent exits (house rule).
trap 'rc=$?; rm -rf -- "$TMP"; [[ $rc == 0 || $rc == 77 || $rc == 1 ]] || \
      printf "FAIL: test exited early (rc=%s)\n" "$rc" >&2' EXIT

command -v openssl >/dev/null 2>&1 || skip "openssl not available"
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
tampered="$TMP/vmlinuz.tampered"
cp "$payload" "$tampered"
printf '\xff' | dd of="$tampered" bs=1 seek=1024 count=1 conv=notrunc status=none 2>/dev/null
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
