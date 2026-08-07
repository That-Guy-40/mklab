#!/usr/bin/env bash
# Verdict: `describe <image>` is the ownership gate for all four drivers — each one
# claims only its own payload shape, refuses another driver's by name, and
# `image+measured` additionally refuses an image it could never attest.
#
# WHY THIS EXISTS. `gate()` in maas-lab.sh asks `describe <image>` before anything
# destructive happens, because an A/B rollback once handed the INSTALL driver a RAM
# payload: it netbooted a live node and then waited 30 minutes for an installer that was
# never there. F2 could not catch it — the image was correctly signed, it was simply the
# wrong driver's image.
#
# `ramdisk` and `install` answered that question. `image` and `image+measured` printed a
# generic sentence and exited 0 for **any** name, so for two of the four drivers the
# gate could not refuse anything, and a gate that cannot refuse cannot protect. Noted in
# DEFERRED.md as "describe is meaningful for only two of four drivers"; fixed 2026-08-06.
#
# Every refusal below is asserted by its OUTCOME (non-zero, naming the right driver),
# and §5 is the control: the images each driver DOES own must still be claimed, or a
# driver that refuses everything would pass every assertion above it.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl

maas_env
maas_env_drivers
# maas_env_drivers points MAAS_DRIVER_DIR at tests/ so `--driver mock` resolves; §4
# drives the REAL drivers through `maas-lab.sh deploy`, so point it back.
export MAAS_DRIVER_DIR="$LAB_DIR/drivers"
DRV_IMAGE="$LAB_DIR/drivers/image.sh"
DRV_MEAS="$LAB_DIR/drivers/image-measured.sh"
DRV_RAM="$LAB_DIR/drivers/ramdisk.sh"
DRV_INST="$LAB_DIR/drivers/install.sh"

# ── fixtures: one image of each shape, in the same store ───────────────────
GOLD="$SANDBOX/golden.raw"; printf 'GOLDEN-WHOLE-DISK\n' > "$GOLD"
( "$DRV_IMAGE" stage disk1 --from "$GOLD" ) >/dev/null 2>&1 \
    || fail "the harness could not stage a whole-disk image — nothing below is testable"
( "$DRV_IMAGE" stage sealed --from "$GOLD" ) >/dev/null 2>&1 || fail "staging 'sealed' failed"
printf '# image-sha256: %s\n7:aaaa\n11:bbbb\n' \
    "$(sha256sum "$MAAS_IMAGES_DIR/sealed/disk.raw" | cut -d' ' -f1)" \
    > "$MAAS_IMAGES_DIR/sealed/pcrs.expected"

# a RAM payload and an installer payload, in the shapes their own drivers stage
mkdir -p "$MAAS_IMAGES_DIR/rampay" "$MAAS_IMAGES_DIR/instpay"
printf 'KERNEL\n' > "$MAAS_IMAGES_DIR/rampay/kernel"
printf 'INITRD\n' > "$MAAS_IMAGES_DIR/rampay/initrd"
printf 'console=ttyS0\n' > "$MAAS_IMAGES_DIR/rampay/cmdline"
printf 'KERNEL\n' > "$MAAS_IMAGES_DIR/instpay/kernel"
printf 'INITRD\n' > "$MAAS_IMAGES_DIR/instpay/initrd"
printf 'install\n' > "$MAAS_IMAGES_DIR/instpay/ks.cfg"

# refuses <label> <driver> <image> <expected-substring>
refuses() {
    local label="$1" drv="$2" img="$3" want="$4" out
    out="$( ( "$drv" describe "$img" ) 2>&1 )" \
        && fail "REGRESSION: $label — describe exited 0, so gate() would let this deploy proceed. A gate that cannot refuse cannot protect. Output: ${out//$'\n'/ }"
    # `--`, or grep reads a pattern beginning with `--` as an option.
    grep -Fq -- "$want" <<<"$out" \
        || fail "$label was refused, but without saying $want — the operator's next question is 'then whose?', and this answer does not have it. Got: ${out//$'\n'/ }"
}

# ── 1. the image driver claims only whole-disk images ─────────────────────
refuses "the image driver handed a RAM payload" "$DRV_IMAGE" rampay "--driver ramdisk"
refuses "the image driver handed an installer payload" "$DRV_IMAGE" instpay "--driver install"
refuses "the image driver handed a name nothing staged" "$DRV_IMAGE" nosuch "nothing is staged"
note "image: refuses a RAM payload, an installer payload and an unstaged name, each naming the owner  ✓"

# ── 2. image+measured refuses what it cannot attest ───────────────────────
# The half that `verify` also covers — but `deploy --no-verify` skips verify entirely,
# and then describe is the ONLY gate before a destructive write.
refuses "image+measured handed an image with no PCR policy" "$DRV_MEAS" disk1 "no expected PCR policy"
refuses "image+measured handed a RAM payload" "$DRV_MEAS" rampay "--driver ramdisk"
note "image+measured: refuses an unmeasurable image AND another driver's payload  ✓"

# ── 3. the other two drivers still refuse a whole-disk image ──────────────
# They had this before; asserted here so the four-driver contract is checked in one
# place and a regression in either shows up beside the new ones.
out="$( ( "$DRV_RAM" describe disk1 ) 2>&1 )" \
    && fail "REGRESSION: the ramdisk driver claimed a whole-disk image ('disk1'). Its payload is a kernel+initrd it netboots; handed a disk image it has nothing to boot"
out="$( ( "$DRV_INST" describe rampay ) 2>&1 )" \
    && fail "REGRESSION: the install driver claimed a RAM payload — this is the exact case that netbooted a live node and waited 30 minutes for an installer that was never there"
note "ramdisk and install still refuse payloads that are not theirs  ✓"

# ── 4. the control plane keeps the driver's own words ─────────────────────
# "it does not own it" is true of all three refusals in §1 and tells the operator
# nothing. gate() reports the driver's first line, the way it already does for verify.
( "$MAAS" enroll dn1 --bmc-port 7401 ) >/dev/null 2>&1 || fail "enroll dn1"
( "$MAAS" manage dn1 )  >/dev/null 2>&1 || fail "manage dn1"
( "$MAAS" provide dn1 ) >/dev/null 2>&1 || fail "provide dn1"
out="$( ( "$MAAS" deploy dn1 --driver image --image rampay ) 2>&1 )" \
    && fail "REGRESSION: deploying a RAM payload with --driver image SUCCEEDED — the ownership gate is not wired into deploy"
grep -Fq -- "--driver ramdisk" <<<"$out" \
    || fail "deploy refused, but the reason reaching the operator did not carry the driver's own sentence naming the right driver. Got: ${out//$'\n'/ }"
note "deploy refuses, and the reason carries the driver's own words (not just 'does not own it')  ✓"

# ── 5. THE CONTROL: each driver still claims what it DOES own ─────────────
# Without this, a driver that refuses everything would satisfy every assertion above,
# and the gate would be broken in the opposite, quieter direction — nothing deploys.
( "$DRV_IMAGE" describe disk1 ) >/dev/null 2>&1 \
    || fail "the image driver REFUSED its own whole-disk image ('disk1') — it now refuses everything, so §1's refusals prove nothing"
( "$DRV_MEAS" describe sealed ) >/dev/null 2>&1 \
    || fail "image+measured REFUSED an image that has both a disk.raw and a PCR policy ('sealed') — it now refuses everything"
out="$( "$DRV_IMAGE" describe disk1 2>&1 )"
grep -Fq "whole-disk image" <<<"$out" \
    || fail "image described its own image without saying what it is: ${out//$'\n'/ }"
out="$( "$DRV_MEAS" describe sealed 2>&1 )"
grep -Fq "PCR index" <<<"$out" \
    || fail "image+measured described its own image without reporting the policy it will enforce: ${out//$'\n'/ }"
( "$DRV_IMAGE" describe ) >/dev/null 2>&1 \
    || fail "describe with NO argument (the 'what does this driver do' form) now fails — the catalog listing in maas-lab.sh depends on it"
( "$DRV_MEAS" describe ) >/dev/null 2>&1 \
    || fail "image+measured describe with no argument now fails"
note "each driver still claims its own image, describes it usefully, and the no-arg form still works  ✓"

pass "describe is the ownership gate for all four drivers: image and image+measured now refuse another driver's payload by name, an unstaged name, and (for image+measured) an image with no PCR policy — deploy carries the driver's own sentence to the operator, and each driver still claims the image it does own"
