#!/usr/bin/env bash
# Verdict: the vbmcd backend drives power over IPMI. vbmcd is ROOTFUL (qemu:///system
# socket is root:libvirt), so this test SKIPs unless a vbmc BMC is already up on the
# registry endpoint (author-run: examples/virtualbmc-ipmi-lab/ ./vbmc-lab.sh up && add).
# When live, it asserts a real `ipmitool ... chassis power status` round-trips.
. "$(dirname "$0")/lib.sh"
need ipmitool python3

eval "$(python3 "$LAB_DIR/lib/registry.py" "$LAB_DIR/fleet-bmc.toml" get node1)"
H="${NODE_IPMI_HOST:-127.0.0.1}"; P="${NODE_IPMI_PORT:-6230}"
U="${NODE_IPMI_USER:-admin}"; PW="${NODE_IPMI_PASS:-password}"

if ! ipmitool -I lanplus -H "$H" -p "$P" -U "$U" -P "$PW" chassis status >/dev/null 2>&1; then
  skip "no vbmc BMC on $H:$P — bring it up author-run (examples/virtualbmc-ipmi-lab: ./vbmc-lab.sh up && add), it's rootful"
fi

note "vbmc BMC is live on $H:$P — exercising the vbmcd backend via bmc.sh"
out="$("$BMC" node1 power status 2>&1)" || fail "bmc.sh node1 power status failed"
grep -qi "Chassis Power is" <<<"$out" || fail "power status did not return a chassis power line: $out"
note "power status: $out"
pass "vbmcd backend round-trips IPMI power via bmc.sh (chassis power status)"
