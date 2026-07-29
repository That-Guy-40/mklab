#!/usr/bin/env bash
# Verdict: the measured golden image measures something REAL — a PCR that changes
# when the payload changes — and refuses to claim attestation it did not achieve.
#
# THE FAILURE THIS EXISTS TO PREVENT is not a crash; it is a gate that passes.
# The first version of build-golden-measured.sh produced a BIOS/syslinux disk, and
# measuring it showed the attestation gate would have been theatre:
#
#   two DIFFERENT golden images (96 MB vs 160 MB)     -> PCR4 IDENTICAL
#   the same image, files swapped INSIDE the FAT      -> every PCR IDENTICAL
#
# SeaBIOS measures the boot-sector code and the partition table, and nothing in the
# filesystem: a completely different kernel measures the same. A policy over those
# values would have blessed any payload, while the driver's name promised the
# opposite. Under OVMF with a UKI the firmware measures the binary it loads, so the
# payload IS the measurement — and §3 below asserts exactly that, by changing one
# byte of the kernel command line and requiring PCR4 to move.
#
# HONEST FRAMING (the same one drivers/image-measured.sh carries): swtpm is faithful
# plumbing, NOT a trust anchor, and the attestation key is baked into the image
# rather than TPM-resident. This test proves the MECHANISM and the REFUSAL PATH. It
# does not prove — and must never be read as proving — the integrity of a machine.
#
# SAFETY: builds into a sandbox and boots QEMU with no network and no host port.
# Nothing on the fleet is touched; no libvirt, no root.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need qemu-system-x86_64 openssl

command -v ukify >/dev/null   || skip "ukify is not installed (systemd-ukify) — cannot build a UKI"
command -v swtpm >/dev/null   || skip "swtpm is not installed — no TPM to measure into"
command -v mformat >/dev/null || skip "mtools is not installed — cannot build the ESP"
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -f "$c" ]] && { OVMF_CODE="$c"; break; }
done
[[ -n "$OVMF_CODE" ]] || skip "OVMF is not installed — UEFI measured boot cannot be exercised"
OVMF_VARS="${OVMF_CODE/CODE/VARS}"
[[ -f "$OVMF_VARS" ]] || skip "OVMF vars template not found beside $OVMF_CODE"
KERNEL="${MAAS_MEASURED_KERNEL:-$HOME/netboot/vmlinuz}"
[[ -f "$KERNEL" ]] || skip "no TPM-capable kernel at $KERNEL (run-e2e-install.sh's preflight stages it)"

maas_env
maas_env_drivers                      # gives us a lab CA at $MAAS_IMAGES_DIR/trust

# swtpm's control socket path has a hard length limit, so the TPM state lives in a
# short /tmp dir rather than the sandbox (which carries the test's long name).
TPMROOT="$(mktemp -d /tmp/mmi.XXXX)"
# shellcheck disable=SC2154
trap '_rc=$?; rm -rf "$TPMROOT"; cleanup_sandboxes; [[ $_rc == 0 || $_rc == 77 ]] || printf "FAIL: test exited early (rc=%s)\n" "$_rc" >&2' EXIT

# boot_measured <image> <tag> -> prints the console log path
boot_measured() {
    local img="$1"
    local tag="$2"
    local d="$TPMROOT/$tag"
    mkdir -p "$d"
    cp "$OVMF_VARS" "$d/vars.fd"
    swtpm socket --tpmstate "dir=$d" --ctrl "type=unixio,path=$d/s" --tpm2 --daemon 2>/dev/null
    sleep 1
    [[ -S "$d/s" ]] || fail "swtpm did not create its control socket — no TPM to measure into"
    timeout 180 qemu-system-x86_64 -m 1024 -display none -serial "file:$d/con.log" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$d/vars.fd" \
        -drive "file=$img,format=raw,if=virtio" \
        -chardev "socket,id=c,path=$d/s" -tpmdev emulator,id=t,chardev=c -device tpm-tis,tpmdev=t \
        -net none >/dev/null 2>&1
    printf '%s' "$d/con.log"
}
# PCR4 from the console. The image prints a labelled PCR4 line ALWAYS, and dumps
# every PCR as "<n>:<hex>" only when it has no delivery URL — so parse the labelled
# line, which is present either way. (Parsing only the dump made §3 read an empty
# value from the image that DOES have a URL, and report it as "no PCR4".)
pcr4_of() { grep -a 'MAAS-ATTEST: PCR4' "$1" | tr -d '\r' | sed 's/.*= //' | head -1; }

# ── 1. it builds, and the build proves what it packed ───────────────────────
IMG_A="$SANDBOX/golden-measured-a.raw"
( MAAS_ARTIFACTS="$SANDBOX" "$LAB_DIR/build-golden-measured.sh" \
    --out "$IMG_A" --kernel "$KERNEL" --trust "$MAAS_IMAGES_DIR/trust" ) >/dev/null 2>&1 \
    || fail "build-golden-measured.sh failed to build the measured image"
[[ -f "$IMG_A" ]] || fail "the builder reported success but produced no image"
note "built the measured golden image (UEFI ESP + UKI)  ✓"

# ── 2. it MEASURES, on a real TPM, and signs on the node ────────────────────
LOG_A="$(boot_measured "$IMG_A" a)"
grep -qa 'MAAS-ATTEST: measured .* PCRs from a real TPM' "$LOG_A" \
    || fail "REGRESSION: the image booted but never measured any PCR. Console tail: $(tail -3 "$LOG_A" | tr -d '\r' | tr '\n' '|')"
grep -qa 'MAAS-ATTEST: signed the quote' "$LOG_A" \
    || fail "REGRESSION: the node measured but did not SIGN its quote — an unsigned quote is a claim, not evidence, and the driver refuses it"
A4="$(pcr4_of "$LOG_A")"
[[ -n "$A4" ]] || fail "no PCR4 value on the console"
[[ "$A4" =~ ^0+$ ]] \
    && fail "REGRESSION: PCR4 is all zeros — the firmware measured NOTHING, so any policy over it is vacuous"
note "boots under OVMF, reads real PCRs from a TPM 2.0, signs the quote on the node  ✓"

# ── 3. THE ANTI-THEATRE CHECK: the measurement must follow the payload ──────
# One byte of kernel command line differs. Under BIOS this changed nothing at all;
# under UEFI the UKI *is* the measured object, so PCR4 must move. If this ever
# stops holding, the gate has become decoration and every image would attest the
# same — which is precisely how a "measured" deploy blesses an unmeasured node.
IMG_B="$SANDBOX/golden-measured-b.raw"
( MAAS_ARTIFACTS="$SANDBOX" "$LAB_DIR/build-golden-measured.sh" \
    --out "$IMG_B" --kernel "$KERNEL" --trust "$MAAS_IMAGES_DIR/trust" \
    --md-url "http://127.0.0.1:1/different" ) >/dev/null 2>&1 \
    || fail "could not build the second (differing) measured image"
cmp -s "$IMG_A" "$IMG_B" && fail "the two images are byte-identical — §3 would prove nothing"
LOG_B="$(boot_measured "$IMG_B" b)"
B4="$(pcr4_of "$LOG_B")"
[[ -n "$B4" ]] || fail "the second image produced no PCR4"
[[ "$A4" != "$B4" ]] \
    || fail "REGRESSION: two golden images with DIFFERENT payloads measured the SAME PCR4 ($A4). The attestation gate is theatre: a policy over this value blesses any payload. This is exactly what BIOS/syslinux did, and why this image is UEFI+UKI"
note "a payload change MOVES the measurement (PCR4 ${A4:0:12}… -> ${B4:0:12}…) — the gate is real  ✓"

# ── 4. …and the same payload measures the SAME, or no policy could exist ────
# Sensitivity without determinism is just as useless: a PCR that changes on every
# boot can never be written into pcrs.expected.
LOG_A2="$(boot_measured "$IMG_A" a2)"
A4b="$(pcr4_of "$LOG_A2")"
[[ "$A4" == "$A4b" ]] \
    || fail "REGRESSION: the SAME image measured differently across two boots ($A4 vs $A4b) — no PCR policy could ever be written, so the gate could never pass honestly"
note "the same payload measures identically across boots — a policy can be pinned  ✓"

# ── 5. it refuses to claim what it did not achieve ──────────────────────────
# Image B carries a delivery URL and these boots have no network, so delivery
# CANNOT succeed. It must say so and park — not print its activation marker
# anyway. (Image A has no URL at all: it prints the quote and finishes, which is
# a different, honest path — so the assertion belongs on B.)
grep -qa 'MAAS-ATTEST: FAILED: could not deliver' "$LOG_B" \
    || fail "the image was given a delivery URL it could not reach, and never reported the failure. Console tail: $(tail -3 "$LOG_B" | tr -d '\r' | tr '\n' '|')"
grep -qa 'attestation complete' "$LOG_B" \
    && fail "REGRESSION: the image announced 'attestation complete' after failing to deliver its quote. A node that cannot report its measurement must not look attested"
note "with no route to the control plane it reports the failure and parks, never claiming attestation  ✓"

pass "the measured golden image reads real PCRs from a TPM, signs the quote on the node, moves its measurement when the payload changes (and only then), repeats identically across boots so a policy can be pinned, and refuses to claim attestation it could not deliver"
