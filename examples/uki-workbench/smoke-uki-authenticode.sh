#!/usr/bin/env bash
# smoke-uki-authenticode.sh — the UKI's Authenticode signature, extracted and verified
# host-side. The third leg of the attestation strand, and the plan's deferred
# "Authenticode extract-and-host-verify": a UKI is a PE, and Secure Boot checks an
# Authenticode signature embedded in it against a trusted certificate BEFORE the
# firmware will run it — a separate, earlier gate than the TPM measurement
# (smoke-uki-pcrsig.sh / smoke-uki-attest-boot.sh). This proves that signature is
# real, chains to the lab's key, and covers the whole image.
#
# WHAT IT GRADES, foreign-oracle (sbsigntool's sbverify, not ukify's own word):
#   1. ukify signs the UKI with a lab Secure Boot key (--signtool sbsign);
#   2. sbverify --cert <lab.crt> ACCEPTS it — the embedded Authenticode signature
#      verifies against the lab certificate;
#   3. the signature is really there (sbverify --list shows a signature table entry);
#   and TWO controls that bite:
#   4. the WRONG certificate (a rogue self-signed CA) is REJECTED — the signature is
#      bound to the lab key, not merely present;
#   5. a TAMPERED section makes sbverify report a HASH MISMATCH — Authenticode covers
#      the image content, so a post-sign edit (the rescue arc's own kind of edit)
#      invalidates it, which is exactly what Secure Boot is for.
#
# Host-side, no boot — the complement to smoke-uki-attest-boot.sh's live TPM boot.
# Exit 0 pass / 1 fail / 77 skip.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
KERNEL="${CAPTURE_KERNEL:-$HOME/.cache/mklab-kernel/vmlinuz}"
WD=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-uki-authenticode.sh exited early (rc=$rc)"' EXIT
skip() { echo "SKIP: $*"; exit 77; }
fail() { echo "FAIL: $*"; exit 1; }
note() { echo "  - $*"; }
pass() { echo "PASS: $*"; exit 0; }

for t in ukify sbsign sbverify openssl objcopy; do command -v "$t" >/dev/null || skip "$t not installed — the Authenticode sign/verify path needs it"; done
[[ -f "$STUB" ]] || skip "no systemd-stub at $STUB (systemd-boot) — a UKI needs the EFI stub"
[[ -r "$KERNEL" ]] || skip "no kernel at $KERNEL (set CAPTURE_KERNEL=; any bzImage for the .linux section)"

WD="$(mktemp -d)"
# a lab Secure Boot keypair, and a ROGUE one for the wrong-key control
openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=mklab UKI SecureBoot" \
    -keyout "$WD/sb.key" -out "$WD/sb.crt" >/dev/null 2>&1 || fail "could not mint the lab Secure Boot keypair"
openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=rogue, not the lab key" \
    -keyout "$WD/rogue.key" -out "$WD/rogue.crt" >/dev/null 2>&1 || fail "could not mint the rogue control cert"
printf 'ID=mklab-authc\nPRETTY_NAME="mklab UKI authenticode"\n' > "$WD/osrel"
printf 'console=ttyS0 quiet\n' > "$WD/cmdline"

# ── sign the UKI with the lab key (ukify --signtool sbsign) ───────────────────
ukify build --linux="$KERNEL" --cmdline="@$WD/cmdline" --os-release="@$WD/osrel" --stub="$STUB" \
    --signtool sbsign --secureboot-private-key="$WD/sb.key" --secureboot-certificate="$WD/sb.crt" \
    --output="$WD/uki.efi" >"$WD/ukify.log" 2>&1 || { tail -5 "$WD/ukify.log"; fail "ukify failed to build a Secure Boot-signed UKI"; }
[[ -s "$WD/uki.efi" ]] || fail "ukify produced no UKI"

# 1+3. the signature is present and verifies against the LAB certificate
sbverify --list "$WD/uki.efi" 2>/dev/null | grep -qiE 'signature|image signature list' \
    || fail "sbverify --list shows no Authenticode signature in the UKI — ukify did not actually sign it"
sbverify --cert "$WD/sb.crt" "$WD/uki.efi" >"$WD/ok.log" 2>&1 \
    || { cat "$WD/ok.log"; fail "sbverify REJECTED a UKI signed with the lab key against that same key — the signature does not verify against its own certificate"; }
grep -qiF 'Signature verification OK' "$WD/ok.log" \
    || fail "sbverify did not report OK for the lab-signed UKI (got: $(tr -d '\n' < "$WD/ok.log" | head -c 120))"
note "the UKI carries an Authenticode signature that verifies against the lab Secure Boot certificate (sbverify OK)"

# 4. CONTROL — the WRONG certificate is rejected (the signature is bound to the lab key)
if sbverify --cert "$WD/rogue.crt" "$WD/uki.efi" >"$WD/rogue.log" 2>&1; then
    fail "NEGATIVE CONTROL FAILED: sbverify ACCEPTED the UKI against a ROGUE certificate — the signature is not actually bound to the lab key, so any key would 'verify'"
fi
note "control: verifying against a rogue certificate is REJECTED — the signature is bound to the lab key, not merely present"

# 5. CONTROL — a tampered section makes the Authenticode hash mismatch (it covers content)
cp "$WD/uki.efi" "$WD/uki-tampered.efi"
printf 'TAMPER' | dd of="$WD/uki-tampered.efi" bs=1 seek=4096 count=6 conv=notrunc status=none
if sbverify --cert "$WD/sb.crt" "$WD/uki-tampered.efi" >"$WD/tamper.log" 2>&1; then
    fail "NEGATIVE CONTROL FAILED: sbverify still verified a UKI with 6 bytes overwritten — Authenticode is not covering the image content"
fi
grep -qiE "Hash doesn't match|verification failed" "$WD/tamper.log" \
    || fail "the tampered UKI was rejected, but not with a hash/verification failure (got: $(tr -d '\n' < "$WD/tamper.log" | head -c 120))"
note "control: overwriting 6 bytes makes sbverify report a HASH MISMATCH — Authenticode covers the whole image, so a post-sign edit invalidates it"

pass "the UKI's AUTHENTICODE signature, extracted and verified host-side (the plan's deferred Authenticode half). ukify signs the UKI with a lab Secure Boot key (--signtool sbsign); sbverify — the foreign oracle, not ukify's own word — ACCEPTS it against the lab certificate and lists the embedded signature. Both controls bite: a rogue certificate is REJECTED (the signature is bound to the lab key, not just present), and overwriting six bytes makes sbverify report a HASH MISMATCH (Authenticode covers the image content, so any post-sign edit — including the rescue arc's — invalidates it, which is what Secure Boot enforces before the firmware will run the UKI). This is the SIGNATURE gate that sits BEFORE the TPM MEASUREMENT gate that smoke-uki-pcrsig.sh predicts and smoke-uki-attest-boot.sh measures live"
