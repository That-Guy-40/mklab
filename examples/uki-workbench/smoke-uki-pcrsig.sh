#!/usr/bin/env bash
# smoke-uki-pcrsig.sh — the UKI's self-predicted TPM measurement, graded host-side.
#
# A UKI built with a PCR key carries its OWN pre-computed, SIGNED prediction of the
# PCR-11 values a measured boot will produce — the `.pcrsig` section (per TPM bank,
# per boot phase-path) plus the public key `.pcrpkey` to check it. This is the UKI
# plan's §5 "single richest thing in the lab": the artifact tells the truth about
# what it will measure to, and that claim is CHECKABLE without booting.
#
# THE GRADE — two independent host computations agree:
#   The UKI CARRIES a .pcrsig. An independent `systemd-measure sign` over the UKI's
#   OWN extracted sections (.linux/.osrel/.cmdline/.uname/.sbat/.pcrpkey) + the same
#   key + the same phase-paths REPRODUCES the carried policy digests (pol) EXACTLY —
#   so the carried prediction is a faithful computation over the UKI's own bytes, not
#   stale, random, or tampered. And `.pcrpkey` IS the lab signing key (DER match).
#
# CONTROL THAT BITES: re-signing over a TAMPERED section (one changed .cmdline byte)
# produces DIFFERENT pol digests than the carried ones — the prediction tracks the
# exact artifact; a wrong/stale section is caught.
#
# THE HONEST BOUNDARY (UNKNOWN != PASS): this grades the PREDICTION the UKI carries,
# host-side. That an ACTUAL OVMF+swtpm boot measures PCR 11 to this value is the
# attestation strand's heavy half and is DEFERRED (needs a live OVMF+swtpm). This
# track never claims the boot measurement — only that the self-prediction is faithful
# and artifact-bound. No firmware, no QEMU; pure host.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: BZIMAGE (a readable bzImage for .linux).
set -u
usage() {
    cat <<'USAGE'
smoke-uki-pcrsig.sh   the UKI's self-predicted PCR measurement, checked host-side

Generates a lab RSA keypair, builds a PCR-keyed UKI (ukify --pcr-*-key --measure),
and asserts: the UKI carries .pcrsig + .pcrpkey; an independent `systemd-measure sign`
over the UKI's own sections + key + phase-paths reproduces the carried policy digests
exactly; .pcrpkey is the lab key. Control: a tampered section yields different digests.
The actual OVMF+swtpm boot PCR is DEFERRED (the heavy half), never claimed here.
SKIPs by name without ukify / systemd-measure / openssl / objcopy / a bzImage.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

RIVAL="$(cd "$(dirname "$0")/../openbios-the-rival-that-shipped" && pwd)"
MEASURE=/usr/lib/systemd/systemd-measure
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
WD=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-uki-pcrsig.sh exited early (rc=$rc)"' EXIT

command -v ukify >/dev/null || skip "ukify not installed (systemd-ukify)"
[[ -x "$MEASURE" ]] || skip "systemd-measure not found at $MEASURE (systemd-boot)"
command -v openssl >/dev/null || skip "openssl not installed (for the lab PCR keypair)"
command -v objcopy >/dev/null && command -v objdump >/dev/null || skip "binutils not installed"
command -v python3 >/dev/null || skip "python3 not installed (parses the .pcrsig JSON)"
[[ -f "$STUB" ]] || skip "missing the systemd EFI stub $STUB (systemd-boot-efi)"

# a readable bzImage for .linux (same discovery as the rival lab's UKI fixture builder)
is_bz() { [[ -r "$1" ]] && file -b "$1" 2>/dev/null | grep -q 'Linux kernel x86.*bzImage'; }
SRC=""
for c in "${BZIMAGE:-}" \
  "$RIVAL/../../micro-linux/out/x86_64/build/linux-6.12.30/arch/x86/boot/bzImage" \
  /media/sqs/COLD_STORAGE/LAB_CREATE_V2/micro-linux/out/x86_64/build/linux-6.12.30/arch/x86/boot/bzImage; do
  [[ -n "$c" ]] && is_bz "$c" && { SRC="$c"; break; }
done
[[ -z "$SRC" ]] && for k in /boot/vmlinuz-*; do is_bz "$k" && { SRC="$k"; break; }; done
[[ -n "$SRC" ]] || skip "no readable bzImage found (set BZIMAGE=/path/to/bzImage) — the .linux subject"

WD="$(mktemp -d)"
dd if="$SRC" of="$WD/linux" bs=1024 count=64 2>/dev/null       # the 64 KiB setup prefix
printf 'console=ttyS0 root=/dev/sda1 ro\n' > "$WD/cmdline"
printf 'ID=lab\nPRETTY_NAME="Lab UKI"\n' > "$WD/osrel"
openssl genrsa -out "$WD/pcr.key" 2048 2>/dev/null || fail "openssl could not generate the lab PCR key"
openssl rsa -in "$WD/pcr.key" -pubout -out "$WD/pcr.pub" 2>/dev/null || fail "openssl could not derive the public key"

# build a UKI WITH a PCR key so ukify writes .pcrsig/.pcrpkey (the measure half)
ukify build --linux="$WD/linux" --stub="$STUB" --cmdline="@$WD/cmdline" --os-release="@$WD/osrel" \
    --pcr-private-key="$WD/pcr.key" --pcr-public-key="$WD/pcr.pub" --measure \
    --output="$WD/uki.efi" >"$WD/ukify.log" 2>&1 || fail "ukify failed to build the PCR-keyed UKI — see $WD/ukify.log"
[[ -s "$WD/uki.efi" ]] || fail "ukify produced no UKI"

# the UKI must carry both the signed prediction and the public key
objdump -h "$WD/uki.efi" | grep -qE '[[:space:]]\.pcrsig[[:space:]]'  || fail "the UKI has no .pcrsig section — ukify did not sign a prediction"
objdump -h "$WD/uki.efi" | grep -qE '[[:space:]]\.pcrpkey[[:space:]]' || fail "the UKI has no .pcrpkey section — no public key to check the prediction"
for s in linux osrel cmdline uname sbat pcrpkey pcrsig; do
    objcopy -O binary --only-section=".$s" "$WD/uki.efi" "$WD/sec.$s" 2>/dev/null || fail "objcopy could not extract .$s"
done
note "subject: $(stat -c%s "$WD/uki.efi")-byte PCR-keyed UKI carrying .pcrsig ($(stat -c%s "$WD/sec.pcrsig") B) + .pcrpkey"

# .pcrpkey IS the lab signing key (DER digests match)
K1="$(openssl rsa -pubin -in "$WD/pcr.pub" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
K2="$(openssl rsa -pubin -in "$WD/sec.pcrpkey" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
[[ -n "$K1" && "$K1" == "$K2" ]] || fail "the UKI's .pcrpkey ($K2) is not the lab signing key ($K1)"

# ukify's default signed phase-paths (4)
PHASES=(--phase=enter-initrd --phase=enter-initrd:leave-initrd \
        --phase=enter-initrd:leave-initrd:sysinit --phase=enter-initrd:leave-initrd:sysinit:ready)

# independent sign over the UKI's OWN sections — must reproduce the carried pol set
msign() { # <cmdline-file> <out.json>
    "$MEASURE" sign --linux="$WD/sec.linux" --osrel="$WD/sec.osrel" --cmdline="$1" \
        --uname="$WD/sec.uname" --sbat="$WD/sec.sbat" --pcrpkey="$WD/sec.pcrpkey" \
        --private-key="$WD/pcr.key" --public-key="$WD/pcr.pub" --bank=sha256 \
        "${PHASES[@]}" --json=short >"$2" 2>>"$WD/measure.err"
}
msign "$WD/sec.cmdline" "$WD/fresh.json" || fail "systemd-measure sign failed — see $WD/measure.err"

VERDICT="$(python3 - "$WD/sec.pcrsig" "$WD/fresh.json" <<'PY'
import json,sys
carried=sorted(e['pol'] for e in json.load(open(sys.argv[1]))['sha256'])
fresh  =sorted(e['pol'] for e in json.load(open(sys.argv[2]))['sha256'])
print("MATCH" if carried==fresh and len(carried)>0 else "MISMATCH")
print(len(carried)); print(carried[0][:24] if carried else "")
PY
)"
read -r MV NPOL POL0 <<<"$(tr '\n' ' ' <<<"$VERDICT")"
[[ "$MV" == MATCH ]] \
    || fail "the carried .pcrsig did NOT match an independent systemd-measure computation over the UKI's own sections — the self-prediction is not faithful (or the section set/phases differ)"
note "self-prediction faithful: an independent systemd-measure sign reproduced all $NPOL carried sha256 policy digests (pol[0]=$POL0…) over the UKI's own sections"

# CONTROL: re-sign over a TAMPERED .cmdline — the digests must DIFFER from the carried
printf 'console=ttyS0 root=/dev/sda1 ro TAMPER=1\n' > "$WD/cmdline.bad"
msign "$WD/cmdline.bad" "$WD/bad.json" || fail "systemd-measure sign (tamper) failed"
BV="$(python3 - "$WD/sec.pcrsig" "$WD/bad.json" <<'PY'
import json,sys
carried=sorted(e['pol'] for e in json.load(open(sys.argv[1]))['sha256'])
bad    =sorted(e['pol'] for e in json.load(open(sys.argv[2]))['sha256'])
print("DIFFER" if carried!=bad else "SAME")
PY
)"
[[ "$BV" == DIFFER ]] \
    || fail "CONTROL did NOT bite: a tampered .cmdline produced the SAME prediction — the self-prediction does not track the artifact (the grade would pass a stale/wrong section)"
note "control: a tampered .cmdline predicts DIFFERENT PCR-11 policy digests — the prediction tracks the exact artifact"

pass "the UKI's self-predicted PCR-11 measurement is faithful and artifact-bound: its carried .pcrsig reproduces exactly under an independent systemd-measure computation over the UKI's own sections + key + phase-paths ($NPOL sha256 phases), .pcrpkey is the lab signing key, and a one-byte .cmdline change predicts a different measurement. The ACTUAL OVMF+swtpm boot PCR is the attestation strand's deferred heavy half — UNKNOWN, not PASS, and not claimed here"
