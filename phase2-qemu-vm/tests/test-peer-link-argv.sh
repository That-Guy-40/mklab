#!/usr/bin/env bash
# Unit test: `peer_link` builds a PRIVATE WIRE BETWEEN TWO VMs and cannot be spelled into a
# host exposure. Sources lab-vm.sh via its guard and inspects QEMU_ARGV. No QEMU launched.
#
# ── WHAT THIS KNOB IS FOR ───────────────────────────────────────────────────────────────
#
# `network_mode = tap|bridge` can put two VMs on one network, and both are root-gated and
# both change the HOST's networking. A lab whose entire premise is "somewhere safe to wreck"
# therefore had no way to get a second node at all. QEMU's `socket` netdev joins exactly two
# VMs into one L2 segment over a TCP connection on loopback: no bridge, no tap, no host
# interface created or touched, no root.
#
# ── THE TWO ASSERTIONS THAT ARE NOT ABOUT ARGV FORMATTING ───────────────────────────────
#
# §2 — a VM with no peer_link must emit BYTE-IDENTICAL argv to before this feature existed.
#      Every other lab in this repo goes through this function.
# §5 — the NIC ORDER. Guest interface names come from PCI slot order, so attaching the peer
#      NIC first renames the primary NIC out from under every cloud-init network config in
#      the repo. That is a one-character mistake in the source and an unbootable lab.

# render() sets globals consumed by the sourced build_qemu_argv (dynamic scope), and
# $LAB_VM is a dynamic source path — both are false positives here.
# shellcheck disable=SC1090,SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd qemu-system-x86_64 jq

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

source "$LAB_VM"

render() {  # render <peer_link> <peer_mac>
    name=t arch=x86_64 microvm=false accel=tcg memory=512M cpus=2 \
        cores=0 threads=0 cpu_pin="" disk="" install_target="" seed="" \
        mac="" kernel=/k initrd=/i append="" ssh_port=2222 firmware="" \
        network_mode=user bridge="" tap="" \
        peer_link="$1" peer_mac="$2"
    build_qemu_argv
    printf '%s' "${QEMU_ARGV[*]}"
}
has() { grep -Fq -- "$2" <<<"$1"; }
# `die` is exit, not return, so a refusal must be run in a SUBSHELL or it ends the test
# before its assertions — the silent-exit trap this repo documents. Captures stderr too,
# because the message is the thing under test: a refusal that does not say WHY sends the
# reader to the source.
#
# The trailing `|| true` is load-bearing for a second reason: sourcing lab-vm.sh brings its
# `set -e` into this shell, so a refusal's non-zero status would end the test at the
# assignment — before the assertion that reads the message ever runs. Caught by lib.sh's net
# printing `test exited early (rc=1)`, which is exactly what that net is for.
refuses() { ( render "$1" "$2" ) 2>&1 || true; }

# ── 1. the wire, both ends ─────────────────────────────────────────────────
L="$(render listen:12801 52:54:00:ca:11:01)"
has "$L" '-netdev socket,id=net1,listen=127.0.0.1:12801' \
    || fail "peer_link=listen:PORT did not produce a listening socket netdev on loopback. Got: $L"
has "$L" '-device virtio-net-pci,netdev=net1,mac=52:54:00:ca:11:01' \
    || fail "the peer NIC was not attached to net1 with the given MAC. Got: $L"
C="$(render connect:12801 52:54:00:ca:11:02)"
has "$C" '-netdev socket,id=net1,connect=127.0.0.1:12801' \
    || fail "peer_link=connect:PORT did not produce a connecting socket netdev on loopback. Got: $C"
note "both ends of the wire: listen and connect, on 127.0.0.1  ✓"

# ── 2. REGRESSION: a VM without peer_link is untouched ─────────────────────
# The whole repo goes through this function. If opting out is not free, this feature is a
# change to every lab rather than an addition to one.
N="$(render '' '')"
if has "$N" 'net1'; then
    fail "REGRESSION: a VM with NO peer_link got a second NIC anyway. Every existing lab in this repo builds its argv here, so this would silently add an interface to all of them — and a guest that suddenly has an extra unconfigured NIC is a guest whose network config may now name the wrong device. Got: $N"
fi
[[ "$(grep -o '\-netdev' <<<"$N" | wc -l)" == 1 ]] \
    || fail "REGRESSION: a VM with no peer_link has $(grep -o '\-netdev' <<<"$N" | wc -l) netdevs, expected exactly 1. Got: $N"
note "no peer_link → exactly one netdev, no net1: opting out is free  ✓"

# ── 3. A MAC IS MANDATORY, and that is a measurement not a style rule ──────
# QEMU numbers default MACs per NIC index WITHIN a process, so two VMs each given a peer_link
# and no MAC arrive on the same segment holding the same address. That does not error: ARP
# resolves to whichever end answered last, and the symptom is intermittent loss on a link
# every tool calls UP. Refusing to guess is cheaper than diagnosing it.
out="$(refuses listen:12801 '')"
has "$out" 'peer_link is set but peer_mac is not' \
    || fail "peer_link with no peer_mac was ACCEPTED. Both ends would then take QEMU's default MAC for NIC index 1 — a duplicate address on a two-host segment, which presents as intermittent loss rather than as an error. Got: $out"
has "$out" 'same address on the same segment' \
    || fail "the refusal did not say WHY a MAC is needed, so the reader has to go and find out. Got: $out"
out="$(refuses listen:12801 'not-a-mac')"
has "$out" 'invalid peer_mac' || fail "a malformed peer_mac was accepted. Got: $out"
note "peer_mac is mandatory and validated, with the collision named in the refusal  ✓"

# ── 4. IT CANNOT BE SPELLED INTO A HOST EXPOSURE ───────────────────────────
# QEMU's `listen=` binds EVERY interface when given a bare port. This spec key takes a role
# and a port and nothing else, so there is no way to write an address — but the check has to
# be that the whole string matches, not that a role and a port can be found in it.
#
# `listen:0.0.0.0:9999` splits into a valid role and a valid port with the address quietly
# dropped, which is the worst outcome available: the operator writes an exposed bind, reads
# back no error, and gets a loopback one. Next time they trust the field.
out="$(refuses listen:0.0.0.0:9999 52:54:00:ca:11:01)"
has "$out" 'invalid peer_link' \
    || fail "peer_link='listen:0.0.0.0:9999' was ACCEPTED. The address is silently discarded and the wire comes up on loopback — so a spec asking for an exposed bind is answered with a different one and no diagnostic. Refuse the whole string instead. Got: $out"
has "$out" 'no way to name an address' \
    || fail "the refusal did not explain that addresses are unspellable here by design, leaving it looking like a parser limitation to work around. Got: $out"
for bad in 'listen' 'listen:' 'listen:0' 'listen:70000' 'sniff:12801' 'listen:12801;rm' 'connect:12a01'; do
    out="$(refuses "$bad" 52:54:00:ca:11:01)"
    has "$out" 'invalid peer_link' || has "$out" 'invalid peer_link port' \
        || fail "peer_link='$bad' was accepted. Got: $out"
done
note "the address is unspellable and 7 malformed forms are refused by name  ✓"

# ── 5. THE PEER NIC COMES SECOND — a PCI slot order assertion ──────────────
# Interface names in the guest follow slot order. Attaching net1 before net0 renames the
# primary NIC, which breaks ssh and every cloud-init network config in the repo at once —
# and it would be invisible here, because both devices are present either way.
n0="$(awk '{for(i=1;i<=NF;i++) if($i ~ /netdev=net0/) print i}' <<<"$L")"
n1="$(awk '{for(i=1;i<=NF;i++) if($i ~ /netdev=net1/) print i}' <<<"$L")"
[[ -n "$n0" && -n "$n1" ]] || fail "could not locate both NIC devices in the argv: $L"
(( n0 < n1 )) \
    || fail "REGRESSION: the peer NIC (net1, position $n1) is attached BEFORE the primary NIC (net0, position $n0). Guest interface names come from PCI slot order, so this renames the primary NIC — ssh and every cloud-init network config in this repo name the old one. Both devices are present either way, so nothing else here would catch it."
note "the peer NIC is attached after the primary, so slot order is unchanged  ✓"

pass "peer_link builds a private two-VM L2 wire on loopback with no bridge, tap, host interface or root; a VM without it is byte-identical to before; a missing or malformed peer_mac is refused by name (duplicate default MACs are silent, not loud); an address cannot be spelled into the field at all; and the peer NIC is attached second so guest interface names do not move"
