#!/usr/bin/env bash
# Verdict: the probe gets a network device on the NIC the fleet actually gives it.
#
# THE INCIDENT. The probe booted, ran, and reported:
#
#     MAAS inspection probe: DHCP failed (continuing)
#     MAAS inspection probe: collected facts cpus=1 node=node1
#     MAAS inspection probe: FAILED to post facts to http://192.168.123.1:8282
#
# It measured the machine correctly and had nothing to send the answer over. The fleet's
# domains were created with `model=virtio`, and NEITHER kernel this lab netboots drives
# virtio-net: the repo's netboot kernel is Debian stock (virtio_net=m, and an initramfs
# carries no modules), and micro-linux's is a defconfig build that omits it. The guest
# therefore had NO network device at all — not a down link, not a DHCP timeout, no eth0
# in the first place — and the failure surfaced 120s later as an introspection timeout.
#
# This is the whole reason the check has to BOOT something. A NIC model and a kernel are
# configured in two different files by two different tools, and every static check on
# either one passes: `model=virtio` is a perfectly good NIC, the kernel is a perfectly
# good kernel. Only running them together shows there is no driver between them.
#
# SAFETY: QEMU with -netdev user (slirp: no host port, no bridge, no root) and
# -no-reboot, booting an initramfs that powers itself off. Nothing touches the fleet.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need qemu-system-x86_64
trap 'cleanup_sandboxes' EXIT
maas_env

# The model the fleet gives its nodes — read from create-fleet.sh, so this test tracks
# the fleet rather than restating it.
MODEL="$(sed -nE 's/^FLEET_NIC_MODEL="\$\{FLEET_NIC_MODEL:-([a-z0-9-]+)\}".*/\1/p' \
         "$LAB_DIR/create-fleet.sh" | head -1)"
[[ -n "$MODEL" ]] || fail "could not read FLEET_NIC_MODEL out of create-fleet.sh — has it been renamed?"
note "the fleet gives its nodes a '$MODEL' NIC"
[[ "$MODEL" != virtio ]] \
    || fail "REGRESSION: the fleet is back on a virtio NIC. Neither kernel this lab netboots drives virtio-net, so the guest gets no network device at all — the probe boots, measures the machine and cannot post its facts"

# A kernel to boot. Prefer the one the probe is actually netbooted with.
KERNEL=""
# Same order run-e2e.sh stages: the probe kernel, NOT the generic netboot one.
for k in "${MAAS_PROBE_KERNEL_PATH:-}" "$HOME/netboot/probe-kernel" \
         "$LAB_DIR/../../micro-linux/out/x86_64/kernel" "$HOME/netboot/kernel"; do
    [[ -n "$k" && -f "$k" ]] && { KERNEL="$k"; break; }
done
[[ -n "$KERNEL" ]] || skip "no netboot kernel available to boot the probe with"

BB=""
for c in "${MAAS_BUSYBOX:-}" /usr/bin/busybox; do [[ -n "$c" && -x "$c" ]] && { BB="$c"; break; }; done
[[ -n "$BB" ]] || skip "no static busybox to build the probe initramfs"
INITRD="$SANDBOX/probe.cpio.gz"
( MAAS_ARTIFACTS="$SANDBOX/art" "$LAB_DIR/build-probe-initramfs.sh" --out "$INITRD" --busybox "$BB" ) \
    >/dev/null 2>&1 || fail "could not build the probe initramfs"

# boot <nic-model> -> console output on stdout. TEST-NET-1 as the sink: the POST must
# fail FAST, so use a refused port on the slirp host rather than a blackholed address:
boot() {
    timeout 90 qemu-system-x86_64 -m 1024 -nographic -no-reboot \
        -kernel "$KERNEL" -initrd "$INITRD" \
        -netdev user,id=n0 -device "$1,netdev=n0" \
        -append "console=ttyS0 ip=dhcp maas.node=qtest maas.md=http://10.0.2.2:1" 2>&1
}

# ── 1. the probe boots at all on the fleet's NIC ───────────────────────────
out="$(boot "$MODEL")"
grep -q 'MAAS inspection probe: booting' <<<"$out" \
    || fail "the probe did not reach its own /init on a '$MODEL' NIC (kernel: $KERNEL). Output tail: $(tail -3 <<<"$out" | tr '\n' '|')"
note "the probe reaches /init on a '$MODEL' NIC  ✓"

# ── 2. …and the kernel gives it a network interface ────────────────────────
# The assertion that matters. Everything else about introspection is downstream of
# there being an eth0 to speak through.
grep -qE 'eth0' <<<"$out" \
    || fail "REGRESSION: the kernel registered NO network interface on a '$MODEL' NIC. The probe will boot, measure the machine and have nothing to post its facts over — which reads at the control plane as a 120s introspection timeout, nowhere near the cause"
note "the kernel registers eth0 on a '$MODEL' NIC  ✓"

# ── 3. the negative control, run for real: virtio gives nothing ────────────
# Not an assumption — the point of the test is that a NIC can be valid and still have
# no driver, so prove the failing case still fails rather than trusting it does.
vout="$(boot virtio-net-pci)"
if grep -qE 'eth0' <<<"$vout"; then
    note "NOTE: this kernel now DOES drive virtio-net — the e1000 default is no longer forced"
else
    note "control: the same kernel on a virtio NIC registers NO interface — the driver, not the NIC, is what differs  ✓"
fi

pass "the probe boots and gets an eth0 on the NIC the fleet actually gives its nodes ('$MODEL'), with the virtio case run as a live control"
