#!/usr/bin/env bash
# Verdict: F2's two halves can be separated at the ONE seam where that is possible, and
# the other half stays armed when it is.
#
# THE INCIDENT. F2 has two halves that read the same artifacts:
#
#   host-side   `verify` — OpenSSL CMS against the CA, BEFORE the node is touched
#   on-node     `imgverify` in the iPXE script — the firmware checks the same .sig
#               files as it fetches them
#
# This fleet's firmware is QEMU's stock iPXE ROM, which has no IMAGE_TRUST_CMD: an
# `imgverify` line aborts the script and boots nothing, with no serial output. So the
# on-node half has to be skippable. The first attempt skipped it by re-staging the image
# `--unsigned`, reasoning that no signatures means no imgverify line. It does — and it
# also disarms the half that was supposed to keep running, because BOTH halves read the
# .sig files. The live run got:
#
#     maas: F2 signature verification failed for image 'micro-linux-x86_64'
#     maas: ... and no previous image to roll back to — node 'node1' -> error
#
# and never reached the firmware at all. Printed directly above it was the claim "the
# host-side gate still runs at 'verify'" — a message asserting the opposite of what the
# next line showed. A wrong knob is a bug; a wrong knob that narrates its own success is
# the failure mode this repo's chaos ladder calls LIED.
#
# The seam that DOES separate them is the generated boot script: sign normally, and omit
# the `imgverify` line at the point the firmware reads it (MAAS_NO_IMGVERIFY=1).
#
# SAFETY: the driver's `deploy` verb is never invoked — the boot-script writer is
# exercised through it with a stub BMC, no domain, no netboot, no power.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
maas_env
need openssl

RAMDISK="$LAB_DIR/drivers/ramdisk.sh"
[[ -x "$RAMDISK" ]] || fail "drivers/ramdisk.sh is missing"

# ── a staged, SIGNED image, built the way the lab builds one ───────────────
export MAAS_IMAGES_DIR="$SANDBOX/images"
export MAAS_NETBOOT_DIR="$SANDBOX/netboot"
mkdir -p "$MAAS_IMAGES_DIR/trust" "$MAAS_NETBOOT_DIR"
"$LAB_DIR/drivers/verify-lib.sh" gen-keys --dir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1 \
    || fail "could not generate an F2 keypair"
IMG="$MAAS_IMAGES_DIR/testimg"
mkdir -p "$IMG"
printf 'not-a-kernel\n' > "$IMG/kernel"
printf 'not-an-initrd\n' > "$IMG/initrd"
printf 'console=ttyS0\n' > "$IMG/cmdline"
for f in kernel initrd; do
    "$LAB_DIR/drivers/verify-lib.sh" sign "$IMG/$f" --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1 \
        || fail "could not sign $f"
done
[[ -f "$IMG/kernel.sig" && -f "$IMG/initrd.sig" ]] || fail "signing produced no .sig files"

# A catalog the driver will accept — `deploy` refuses an image it cannot describe, which
# is the right behaviour and means the fixture needs an entry rather than a bypass.
export MAAS_CATALOG="$SANDBOX/catalog.toml"
cat > "$MAAS_CATALOG" <<'EOS'
[[image]]
name    = "testimg"
summary = "fixture payload for the F2 boot-script test — never booted"
lab     = "examples/metal-as-a-service/"
build   = "n/a — this image exists only inside tests/test-imgverify-halves.sh"
kernel  = "/dev/null"
initrd  = "/dev/null"
cmdline = "console=ttyS0"
health  = "console"
marker  = "never-matched-by-this-test"
EOS

# write_script — run the driver's boot-script writer and return the script it wrote.
# `deploy` powers a node afterwards; the stub BMC makes that a no-op, and the script is
# on disk by then either way.
SCRIPT="$MAAS_NETBOOT_DIR/maas/tnode.ipxe"
cat > "$SANDBOX/bmc-stub.sh" <<'EOS'
#!/usr/bin/env bash
case "$2" in power) [[ "$3" == status ]] && printf 'on\n' ;; esac
exit 0
EOS
chmod +x "$SANDBOX/bmc-stub.sh"
write_script() {
    rm -f "$SCRIPT"
    MAAS_BMC="$SANDBOX/bmc-stub.sh" MAAS_STATE="$SANDBOX/state" \
    MAAS_POWERON_TIMEOUT=2 \
        "$RAMDISK" deploy tnode testimg current >/dev/null 2>&1
    [[ -f "$SCRIPT" ]] || fail "the driver wrote no boot script at $SCRIPT"
}

# ── 1. the default: a signed image ARMS the on-node half ───────────────────
# The positive control for §2, and the property that must survive it. If this ever
# stops holding, F2's on-node half is off for everyone and nothing says so.
MAAS_NO_IMGVERIFY=0 write_script
grep -q '^imgverify kernel ' "$SCRIPT" \
    || fail "REGRESSION: a SIGNED image produced a boot script with no 'imgverify kernel' line. The on-node half of F2 is silently off — the node would fetch and boot a payload the firmware never checked"
grep -q '^imgverify initrd ' "$SCRIPT" \
    || fail "REGRESSION: the boot script verifies the kernel but not the initrd. A signed kernel with an unverified initrd is not a chain — the initrd is where the userspace comes from"
note "a signed image arms 'imgverify' for BOTH kernel and initrd  ✓"

# ── 2. MAAS_NO_IMGVERIFY=1 drops ONLY the on-node half ─────────────────────
MAAS_NO_IMGVERIFY=1 write_script
grep -q '^imgverify' "$SCRIPT" \
    && fail "REGRESSION: MAAS_NO_IMGVERIFY=1 still emitted an 'imgverify' line. On a ROM without IMAGE_TRUST_CMD the script aborts and boots nothing, with no serial output — a 120s silence that looks exactly like a dead payload"
note "MAAS_NO_IMGVERIFY=1 omits the in-firmware check  ✓"

# The half that must STILL be armed. This is the assertion the old mechanism failed:
# the signatures have to survive, because the host-side gate reads them.
[[ -f "$IMG/kernel.sig" && -f "$IMG/initrd.sig" ]] \
    || fail "REGRESSION: skipping the on-node half removed the signatures. That disarms the HOST-side gate too — which is the whole bug: 'F2 signature verification failed ... -> error', with the run claiming the host-side gate was still running"
MAAS_IMAGES_DIR="$MAAS_IMAGES_DIR" "$RAMDISK" verify testimg >/dev/null 2>&1 \
    || fail "REGRESSION: the host-side F2 gate no longer passes for an image deployed with MAAS_NO_IMGVERIFY=1. Exactly one half may be skipped, and it is not this one"
note "the payload is still signed and the HOST-side gate still passes  ✓"

# And the script must SAY the check was dropped. A boot script that quietly lacks a line
# is indistinguishable from one written before signing existed.
grep -qi 'MAAS_NO_IMGVERIFY' "$SCRIPT" \
    || fail "the boot script omits imgverify without recording why. Someone reading it later cannot tell a deliberate skip from an unsigned payload"
note "the script records WHY the check is absent  ✓"

# ── 3. the negative control: --unsigned really does fail the host gate ─────
# Not an assumption — it is the behaviour that made the old mechanism wrong, so prove it
# still holds rather than trusting it. (It is also correct behaviour in its own right:
# an unsigned image MUST be refused.)
rm -f "$IMG/kernel.sig" "$IMG/initrd.sig"
if MAAS_IMAGES_DIR="$MAAS_IMAGES_DIR" "$RAMDISK" verify testimg >/dev/null 2>&1; then
    fail "REGRESSION: the host-side F2 gate PASSED an image with no signatures at all. That is the gate failing open — the one outcome worse than failing closed"
fi
note "control: with the .sig files gone the host-side gate refuses the image — which is why removing them was never a way to skip only the on-node half  ✓"

MAAS_NO_IMGVERIFY=0 write_script
grep -q '^imgverify' "$SCRIPT" \
    && fail "an unsigned image emitted an imgverify line pointing at signatures that do not exist"
note "control: an unsigned image emits no imgverify line either — the two mechanisms are indistinguishable in the SCRIPT, and differ entirely in the GATE  ✓"

# ── 4. the live driver asks for the right one ──────────────────────────────
# The knob only helps if run-e2e.sh reaches for it. It reached for the wrong one once.
E2E="$LAB_DIR/run-e2e.sh"
grep -q 'MAAS_NO_IMGVERIFY=1' "$E2E" \
    || fail "REGRESSION: run-e2e.sh does not set MAAS_NO_IMGVERIFY. If it goes back to staging --unsigned, the deploy is refused by the host-side gate and the run ends in 'error' having never booted anything"
grep -qE 'stage "\$IMAGE" --unsigned' "$E2E" \
    && fail "REGRESSION: run-e2e.sh is re-staging the payload --unsigned again. That disarms the HOST-side gate, which is the half that must keep running; the live run failed at 'verify' and never reached the firmware"
note "run-e2e.sh skips the on-node half at the boot script, not at the signing step  ✓"

pass "F2's two halves separate only at the boot script: MAAS_NO_IMGVERIFY=1 drops the in-firmware check, leaves the payload signed and the host-side gate passing, and says so in the script — while an unsigned payload is still refused outright"
