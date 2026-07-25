#!/usr/bin/env bash
# Verdict: REAL IPMI Serial-over-LAN over RMCP+/lanplus — `bmc.sh node2 sol` streams the
# node's serial through a genuine ipmitool -I lanplus session. Headless & rootless (POC-A).
#
# The node's serial is exposed on tcp:127.0.0.1:<serial_tcp> (as a QEMU <serial type='tcp'>
# would be); here a socat generator feeds that port a repeating marker, deterministically,
# so the test asserts the SOL *bridge* (the real risk) without a VM boot-race. Booting a
# real VM's serial over this same SOL path is shown in RUNBOOK/MANUAL_TESTING.
. "$(dirname "$0")/lib.sh"
need ipmi_sim ipmitool python3

SERIAL_TCP=9101                      # matches fleet-bmc.toml node2.serial_tcp
MARKER="BMC_TOOLKIT_SOL_TEST_$$"
SRC_PID=""
OUT="$(mktemp)"

cleanup() {
  "$BMC" node2 bmc-down >/dev/null 2>&1 || true
  [[ -n "$SRC_PID" ]] && kill "$SRC_PID" 2>/dev/null || true       # kill by recorded PID
  rm -f "$OUT"
}
trap 'cleanup' EXIT

note "start the node's serial source (repo tool: tools/serial-source.py --tcp $SERIAL_TCP)"
python3 "$LAB_DIR/../../tools/serial-source.py" --tcp "$SERIAL_TCP" --marker "$MARKER" >/dev/null 2>&1 &
SRC_PID=$!
sleep 1
kill -0 "$SRC_PID" 2>/dev/null || fail "serial source failed to start on :$SERIAL_TCP"

note "bmc.sh node2 bmc-up (ipmi_sim; SOL bridges tcp:127.0.0.1:$SERIAL_TCP)"
"$BMC" node2 bmc-up || fail "bmc-up (ipmi_sim) failed"

note "sanity: RMCP+ session works (raw lanplus chassis status via ipmitool)"
ipmitool -I lanplus -H 127.0.0.1 -p 9001 -U ipmiusr -P test -C 3 chassis status >/dev/null 2>&1 \
  || fail "REGRESSION: RMCP+/lanplus session did not establish"

note "REAL SOL: bmc.sh node2 sol (capture mode), expect the marker to stream"
BMC_SOL_CAPTURE=8 "$BMC" node2 sol >"$OUT" 2>&1 || true
grep -q "SOL Session operational" "$OUT" || note "(no 'operational' banner — checking for data anyway)"
if grep -q "$MARKER" "$OUT"; then
  n=$(grep -c "$MARKER" "$OUT")
  pass "real IPMI SOL over RMCP+ streamed the node serial via 'ipmitool -I lanplus sol activate' ($n marker lines)"
else
  note "sol capture:"; sed 's/^/    /' "$OUT" >&2
  fail "REGRESSION: SOL session did not stream the node serial (marker '$MARKER' absent)"
fi
