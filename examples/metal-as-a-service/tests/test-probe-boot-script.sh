#!/usr/bin/env bash
# Verdict: `inspect --boot` TELLS the node what to boot, and refuses when it cannot.
#
# THE BUG THIS TEST EXISTS FOR. `inspect --boot` used to set bootdev=pxe, power the
# node on, and wait 120s for facts — without ever writing a boot script. On the mock
# BMC that is invisible; on a real fleet the node netbooted whatever single payload the
# PXE network had baked in (a busybox shell), gathered nothing, reported nothing, and
# the only symptom was a timeout that blamed "the probe console". The first live
# end-to-end run failed exactly this way. So:
#
#   the probe boots what WE say       a per-node iPXE script, like every deploy driver
#   carrying its identity             maas.node= — the sink files facts per node
#   and where to report               maas.md=   — a probe that measures a machine and
#                                     has nowhere to send the answer is worse than one
#                                     that never booted, because it looks like progress
#   and it refuses, by name, when     no metadata URL / no probe initramfs / no kernel:
#   any of that is missing            refuse BEFORE powering the node on, not after
#
# The last one is the point. Powering a node on and then discovering the boot is
# unserviceable burns two minutes and leaves the operator reading the wrong error.
#
# SAFETY: mock BMC, throwaway registry, fixture artifacts. Nothing boots, no PXE.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
maas_env
export MOCK_BMC_POWER_DIR="$SANDBOX/power"
export MAAS_NETBOOT_DIR="$SANDBOX/netboot"
export MAAS_POLL_INTERVAL=0
unset MAAS_MD_URL                       # the environment must not smuggle one in

MD="http://192.0.2.1:8282"              # TEST-NET-1: guaranteed unroutable
SCRIPT="$MAAS_NETBOOT_DIR/maas/n1.ipxe"

prep() {  # prep <node> <port>  -> enrolled + manageable
    ( "$MAAS" enroll "$1" --bmc-port "$2" ) >/dev/null 2>&1 || fail "enroll $1"
    ( "$MAAS" manage "$1" ) >/dev/null 2>&1 || fail "manage $1"
}

prep n1 6280

# ── 1. no metadata URL -> refuse, and DO NOT power the node on ──────────────
: > "$MOCK_BMC_LOG"
out="$( ( "$MAAS" inspect n1 --boot --timeout 1 ) 2>&1 )" \
    && fail "REGRESSION: inspect --boot ran with no metadata URL. The probe would boot, measure the machine and have nowhere to POST the answer — a node that looks like it is making progress and never will"
grep -Fq 'maas.md=' <<<"$out" \
    || fail "the refusal does not name the missing metadata URL / cmdline key (got: ${out//$'\n'/ })"
grep -q 'power on' "$MOCK_BMC_LOG" \
    && fail "REGRESSION: the node was POWERED ON despite an unserviceable boot. The refusal must come before the BMC is touched, or the operator waits out a timeout to read the wrong error"
note "no --md-url: refused by name, and the node was never powered on  ✓"

# ── 2. metadata URL, but no probe initramfs staged -> refuse, naming the build ──
: > "$MOCK_BMC_LOG"
mkdir -p "$MAAS_NETBOOT_DIR"
printf 'FIXTURE-KERNEL\n' > "$MAAS_NETBOOT_DIR/kernel"
out="$( ( "$MAAS" inspect n1 --boot --md-url "$MD" --timeout 1 ) 2>&1 )" \
    && fail "REGRESSION: inspect --boot ran with no probe initramfs in the PXE docroot — the node would fetch a 404 and stop at the iPXE prompt"
grep -Fq 'build-probe-initramfs.sh' <<<"$out" \
    || fail "the refusal does not name the command that builds the probe (got: ${out//$'\n'/ })"
grep -q 'power on' "$MOCK_BMC_LOG" \
    && fail "REGRESSION: the node was powered on with no probe staged"
note "no probe initramfs: refused, naming build-probe-initramfs.sh  ✓"

# ── 3. …and no kernel to boot it with -> refuse, naming that separately ─────
# An initramfs is not bootable on its own. Distinguishing this from §2 matters: the
# two are staged by different tools and a merged message sends you to the wrong one.
: > "$MOCK_BMC_LOG"
printf 'FIXTURE-INITRAMFS\n' > "$MAAS_NETBOOT_DIR/probe-initramfs.cpio.gz"
mv "$MAAS_NETBOOT_DIR/kernel" "$SANDBOX/kernel.away"
out="$( ( "$MAAS" inspect n1 --boot --md-url "$MD" --timeout 1 ) 2>&1 )" \
    && fail "REGRESSION: inspect --boot ran with no kernel in the PXE docroot"
grep -Fq 'probe kernel' <<<"$out" \
    || fail "the missing-kernel refusal does not distinguish itself from the missing initramfs (got: ${out//$'\n'/ })"
note "initramfs staged but no kernel: refused separately  ✓"
mv "$SANDBOX/kernel.away" "$MAAS_NETBOOT_DIR/kernel"

# ── 4. the positive control: everything staged -> a real boot script ────────
# It still times out (nothing is going to POST facts here) — that is the mock BMC
# doing its job. What is under test is the artifact written on the way.
: > "$MOCK_BMC_LOG"
rm -f "$SCRIPT"
( "$MAAS" inspect n1 --boot --md-url "$MD" --timeout 1 ) >/dev/null 2>&1
[[ -f "$SCRIPT" ]] \
    || fail "REGRESSION: no per-node iPXE script was written for the introspection boot ($SCRIPT). The node would netboot the PXE network's default and report nothing — the exact failure that made the first live run time out"
grep -q '^#!ipxe'                 "$SCRIPT" || fail "the boot script is not an iPXE script"
grep -q "^kernel .*/kernel "      "$SCRIPT" || fail "the boot script does not load a kernel"
grep -q "^initrd .*probe-initramfs" "$SCRIPT" || fail "the boot script does not load the PROBE initramfs"
grep -Fq "maas.node=n1"           "$SCRIPT" \
    || fail "REGRESSION: the probe is not told which node it is (maas.node=). Facts would arrive unattributable, or be filed against the wrong machine"
grep -Fq "maas.md=$MD"            "$SCRIPT" \
    || fail "REGRESSION: the probe is not told where to report (maas.md=). It would boot, measure the machine, and drop the answer"
grep -q '^boot'                   "$SCRIPT" || fail "the boot script never says 'boot'"
grep -q 'power on' "$MOCK_BMC_LOG" \
    || fail "with a serviceable boot script the node should have been powered on"
note "everything staged: a per-node script carrying maas.node= and maas.md=, then power on  ✓"

# ── 5. the cmdline keys are the ones probe-init.sh actually parses ──────────
# The script and the probe are edited by different hands at different times; a rename
# on either side would leave both looking correct and the pair silently broken.
for key in maas.node maas.md; do
    grep -Fq "$key=" "$LAB_DIR/probe-init.sh" \
        || fail "REGRESSION: the boot script sets $key= but probe-init.sh no longer parses it — the probe would boot without an identity or without a sink and report nothing"
done
note "maas.node= / maas.md= are the keys probe-init.sh parses (the two ends agree)  ✓"

pass "inspect --boot writes the probe's own iPXE script carrying its identity and its sink, and refuses — before touching the BMC — when the URL, the initramfs or the kernel is missing"
