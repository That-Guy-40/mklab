#!/usr/bin/env bash
# Verdict: the bmc.sh verb surface + capability model behave — registry resolves,
# `inspect` reports caps, and an unsupported verb is REFUSED loudly (never a silent
# no-op or faked success). Pure/headless: no daemons, no libvirt.
. "$(dirname "$0")/lib.sh"
need python3

# 1. registry list resolves all three backends
out="$("$BMC" list)" || fail "bmc.sh list failed"
for b in vbmcd ipmi_sim redfish; do
  grep -q "$b" <<<"$out" || fail "REGRESSION: 'list' missing backend $b"
done
note "list shows vbmcd + ipmi_sim + redfish"

# 2. inspect --json is valid JSON and reports the redfish virtual-media capability
js="$("$BMC" node3 inspect --json)" || fail "inspect --json failed"
python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["capabilities"]["insert-media"]=="yes", d' <<<"$js" \
  || fail "REGRESSION: redfish node does not advertise insert-media=yes"
note "redfish inspect --json advertises insert-media=yes (the vmedia capability)"

# 3. THE capability gate: unsupported verb refused, non-zero, with a hint
if "$BMC" node1 insert-media x.iso 2>/dev/null; then
  fail "REGRESSION: vbmcd accepted 'insert-media' — capability gate did not refuse a no-op"
fi
msg="$("$BMC" node1 insert-media x.iso 2>&1 || true)"
grep -qi "does not implement 'insert-media'" <<<"$msg" || fail "refusal lacked a clear message: $msg"
grep -qi "redfish" <<<"$msg" || fail "refusal lacked the actionable hint (point at a redfish node)"
note "vbmcd refuses insert-media loudly + hints at a redfish-backed node"

# 4. ipmi_sim refuses power (0xCC) and points at the coexist vbmcd path
pmsg="$("$BMC" node2 power on 2>&1 || true)"
grep -qi "does not implement 'power'" <<<"$pmsg" || fail "ipmi_sim did not refuse power"
grep -qi "coexist" <<<"$pmsg" || fail "ipmi_sim power refusal lacked the coexist hint"
note "ipmi_sim refuses power + hints coexist (real SOL here, power on vbmcd)"

# 5. substitute proceeds but flags itself (vbmcd sol = libvirt console, not IPMI SOL)
smsg="$("$BMC" node1 sol 2>&1 || true)"
grep -qi "SUBSTITUTE" <<<"$smsg" || fail "vbmcd 'sol' did not flag itself as a substitute"
note "vbmcd sol flags itself a substitute (no IPMI SOL) and prints the console command"

pass "bmc.sh dispatch + capability model behave (list, inspect, loud refusal, substitute caveat)"
