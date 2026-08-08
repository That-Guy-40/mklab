#!/usr/bin/env bash
# guest-peer-wire.sh <my-mac> <my-cidr> <peer-ip> — bring up this guest's half of the
# private wire and PROVE a frame crossed it. Runs as root inside a two-node guest.
#
# ── THE INTERFACE IS FOUND BY MAC, NOT BY NAME ──────────────────────────────────────────
#
# `enp0s4` is a guess about PCI slot numbering, firmware, and udev's naming policy — three
# things this script does not control and any of which can move the name without moving the
# device. The MAC is the identity the spec actually set, so that is what is matched. If it
# resolves to nothing, that is a REFUSAL with the MAC named, not a fallback to whatever
# interface happened to be second.
set -uo pipefail
say() { printf 'WIRE-%s\n' "$*"; }

MYMAC="${1:?usage: guest-peer-wire.sh <my-mac> <my-cidr> <peer-ip>}"
MYCIDR="${2:?}"
PEER="${3:?}"

dev=""
for p in /sys/class/net/*/address; do
    [[ "$(cat "$p" 2>/dev/null)" == "$MYMAC" ]] || continue
    dev="$(basename "$(dirname "$p")")"; break
done
if [[ -z "$dev" ]]; then
    say "FATAL no interface has MAC $MYMAC. Present: $(for p in /sys/class/net/*/address; do printf '%s=%s ' "$(basename "$(dirname "$p")")" "$(cat "$p")"; done)"
    exit 2
fi
say "DEV $dev mac=$MYMAC"

# CARRIER IS NOT CONNECTIVITY, and this repo has been caught by exactly that before: a tap's
# carrier=1 means the VMM holds the device open, not that anything is on the other end. It is
# reported here as an observation and never as the success signal — the success signal is the
# ping below, which requires a frame to have made a round trip.
ip link set "$dev" up
ip addr flush dev "$dev" 2>/dev/null
ip addr add "$MYCIDR" dev "$dev" || { say "FATAL could not address $dev with $MYCIDR"; exit 2; }
say "ADDR $dev $MYCIDR carrier=$(cat "/sys/class/net/$dev/carrier" 2>/dev/null || echo '?') operstate=$(cat "/sys/class/net/$dev/operstate" 2>/dev/null || echo '?')"

# ⚠️ Unlike the slirp NIC, ICMP works here: this is a real L2 segment between two QEMU
# processes, not slirp's userspace NAT (which drops ICMP for an unprivileged user and has
# made this repo misdiagnose a working guest as having no network).
t0=$SECONDS; ok=no
while (( SECONDS - t0 < 60 )); do
    if ping -c 1 -W 2 "$PEER" >/dev/null 2>&1; then ok=yes; break; fi
    sleep 2
done
say "PEER $PEER reachable=$ok after=$((SECONDS - t0))s"
[[ "$ok" == yes ]] || exit 1
