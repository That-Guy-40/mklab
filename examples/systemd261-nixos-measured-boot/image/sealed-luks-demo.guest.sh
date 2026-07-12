#!/usr/bin/env bash
# sealed-luks-demo.guest.sh — runs INSIDE the measured VM (nixos261v).
# The host-side driver `sealed-luks-demo.sh` pushes this over the serial console
# and captures the verdict; it is also baked into the sealed image at
# /etc/lab/sealed-luks-demo (see image/sealed.nix).
#
# Proves the systemd-261 sealed-storage + attestation chain end to end:
#   1. a LUKS2 volume with a bootstrap passphrase slot
#   2. systemd-cryptenroll seals a SECOND keyslot to the TPM, bound to PCR 7+11
#      (secure-boot state + measured OS/UKI)
#   3. systemd-cryptsetup UNSEALS it with the TPM alone — no passphrase — because
#      the live PCRs still match the sealing policy
#   4. a Keylime-style attestation stub: an AK signs a nonce-fresh PCR quote,
#      a verifier checks the signature + nonce (the remote-attestation primitive)
#   5. NEGATIVE: extend PCR 11 (as if a different OS booted) → the TPM now REFUSES
#      to unseal. The seal is bound to the *measured state*, not just "a key in a chip".
#
# HONEST FRAMING: this TPM is swtpm (manufacturer "IBM" = the software emulator).
# It exercises the plumbing faithfully, but it is NOT a trust anchor — anything
# that can read its userspace can forge PCR state or the AK. A hardware TPM, a
# hypervisor-backed vTPM rooted in host silicon, or confidential computing is the
# real production anchor.
set -uo pipefail
export TPM2TOOLS_TCTI="device:/dev/tpmrm0"   # talk to the kernel RM directly (no tabrmd)

note() { echo "  - $*"; }
pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }

CRYPTENROLL="$(command -v systemd-cryptenroll)" || skip "systemd-cryptenroll absent"
CRYPTSETUP_HELPER="$(dirname "$(readlink -f "$CRYPTENROLL")")/systemd-cryptsetup"
[ -x "$CRYPTSETUP_HELPER" ] || skip "systemd-cryptsetup absent"
[ -e /dev/tpmrm0 ] || skip "no TPM resource-manager device (boot with tpm=true)"

WORK="$(mktemp -d)"
IMG="$WORK/data.luks.img"
PASSFILE="$WORK/bootstrap.key"
MAPPER="sealeddemo"
LOOP=""
PCRS="7+11"
printf 'lab-luks-bootstrap-secret' > "$PASSFILE"
chmod 600 "$PASSFILE"

cleanup() {
  "$CRYPTSETUP_HELPER" detach "$MAPPER" 2>/dev/null || cryptsetup close "$MAPPER" 2>/dev/null || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

modprobe dm_crypt loop 2>/dev/null || true

echo "== systemd 261 — TPM2-sealed LUKS + attestation (measured VM $(hostname)) =="
note "TPM manufacturer: $(tpm2_getcap properties-fixed 2>/dev/null | awk '/MANUFACTURER/{getline; print $2}') (0x49424D00='IBM' = swtpm; plumbing, NOT a trust anchor)"
note "live PCRs sealing binds to:"
tpm2_pcrread "sha256:7,11" 2>/dev/null | sed -n 's/^/      /p' | grep -E '7 :|11:' || true

# 1. LUKS2 volume in a loopback file; keyslot 0 = bootstrap passphrase.
truncate -s 64M "$IMG"
LOOP="$(losetup --find --show "$IMG")" || fail "losetup failed"
cryptsetup luksFormat --type luks2 --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
  "$LOOP" "$PASSFILE" || fail "luksFormat failed"
note "LUKS2 volume created on $LOOP (keyslot 0 = bootstrap passphrase)"

# 2. Seal a second keyslot to the TPM, bound to PCR 7 + 11.
if ! "$CRYPTENROLL" --unlock-key-file="$PASSFILE" --tpm2-device=auto --tpm2-pcrs="$PCRS" "$LOOP"; then
  fail "systemd-cryptenroll TPM2 enroll (sealed to PCR $PCRS) failed"
fi
SLOTS="$(cryptsetup luksDump "$LOOP" | grep -c 'systemd-tpm2')"
note "TPM2 keyslot enrolled, sealed to PCR $PCRS (luks token count: $SLOTS)"

# 3. Unseal with the TPM ALONE — no passphrase (headless: never prompt).
if "$CRYPTSETUP_HELPER" attach "$MAPPER" "$LOOP" - tpm2-device=auto,headless=true; then
  [ -b "/dev/mapper/$MAPPER" ] || fail "attach reported success but /dev/mapper/$MAPPER missing"
  note "UNSEALED by the TPM against live PCRs — /dev/mapper/$MAPPER opened, zero passphrase"
  "$CRYPTSETUP_HELPER" detach "$MAPPER" 2>/dev/null || cryptsetup close "$MAPPER" 2>/dev/null || true
else
  fail "TPM2 unseal failed on UNCHANGED PCRs (should have succeeded)"
fi

# 4. Attestation stub (Keylime-style): AK signs a nonce-fresh PCR quote; verify it.
NONCE="$(tpm2_getrandom 20 2>/dev/null | od -An -tx1 | tr -d ' \n')"
[ -n "$NONCE" ] || fail "could not draw an attestation nonce from the TPM"
if tpm2_createek -c "$WORK/ek.ctx" -G rsa -u "$WORK/ek.pub" >/dev/null 2>&1 \
   && tpm2_createak -C "$WORK/ek.ctx" -c "$WORK/ak.ctx" -G rsa -g sha256 -s rsassa \
        -u "$WORK/ak.pub" -f pem -n "$WORK/ak.name" >/dev/null 2>&1 \
   && tpm2_quote -c "$WORK/ak.ctx" -l sha256:7,11 -q "$NONCE" \
        -m "$WORK/quote.msg" -s "$WORK/quote.sig" -o "$WORK/quote.pcrs" -g sha256 >/dev/null 2>&1; then
  if tpm2_checkquote -u "$WORK/ak.pub" -m "$WORK/quote.msg" -s "$WORK/quote.sig" \
       -f "$WORK/quote.pcrs" -g sha256 -q "$NONCE" >/dev/null 2>&1; then
    note "attestation: AK-signed PCR 7+11 quote over nonce ${NONCE:0:12}… VERIFIED (fresh + TPM-signed)"
    note "  caveat: this AK is rooted in swtpm's self-made EK — proves 'a TPM signed it', NOT 'genuine hardware'"
  else
    fail "tpm2_checkquote REJECTED a fresh quote (signature/nonce mismatch)"
  fi
else
  fail "could not produce a TPM PCR quote (AK/quote generation failed)"
fi

# 5. NEGATIVE: change PCR 11 (as if a different OS measured) → unseal must FAIL.
TAMPER="$(printf 'a-different-os' | sha256sum | cut -d' ' -f1)"
tpm2_pcrextend "11:sha256=$TAMPER" >/dev/null 2>&1 || fail "could not extend PCR 11 for the negative test"
if "$CRYPTSETUP_HELPER" attach "$MAPPER" "$LOOP" - tpm2-device=auto,headless=true 2>/dev/null; then
  "$CRYPTSETUP_HELPER" detach "$MAPPER" 2>/dev/null || cryptsetup close "$MAPPER" 2>/dev/null || true
  fail "REGRESSION: TPM unsealed AFTER PCR 11 changed — the seal is NOT bound to measured state"
fi
note "after PCR 11 changed, the TPM REFUSED to unseal — the seal is bound to the measured OS ✅"

pass "TPM2-sealed LUKS: seal→unseal-on-good-PCRs→refuse-on-changed-PCRs, plus a verified AK PCR-quote"
