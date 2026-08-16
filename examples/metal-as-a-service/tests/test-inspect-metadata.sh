#!/usr/bin/env bash
# Verdict: the inspection chain works headlessly — the probe /init gathers correct
# facts from /proc+/sys, the metadata service records a probe POST and serves
# NoCloud user-data, and `inspect --from-metadata` ingests the facts into a
# schedulable summary (and refuses when the probe never reported). No libvirt/boot:
# the real PXE boot is stubbed by POSTing exactly what the probe's wget would.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need python3
on_exit '[[ -n "${MDPID:-}" ]] && kill "$MDPID" 2>/dev/null'
maas_env

PROBE="$LAB_DIR/probe-init.sh"
META="$LAB_DIR/lib/metadata.py"

# ── the probe /init gathers correct facts from fixture /proc + /sys ──────────
fix="$SANDBOX/procfix"
mkdir -p "$fix/class/net/eth0" "$fix/class/net/lo"
printf 'processor\t: 0\nprocessor\t: 1\nprocessor\t: 2\nprocessor\t: 3\n' > "$fix/cpuinfo"
printf 'MemTotal:        8192000 kB\n' > "$fix/meminfo"
printf '00:00:00:00:00:00\n' > "$fix/class/net/lo/address"
printf '52:54:00:aa:bb:cc\n' > "$fix/class/net/eth0/address"
json="$(PROC_ROOT="$fix" SYS_ROOT="$fix" "$PROBE" --emit)" || fail "probe --emit failed"
python3 -c '
import json,sys
d=json.loads(sys.argv[1])
assert d["cpus"]==4, d
assert d["mem_kb"]==8192000, d
assert d["mac"]=="52:54:00:aa:bb:cc", d   # skipped lo, picked eth0
' "$json" || fail "probe emitted wrong facts: $json"
note "probe /init gathers cpus/mem/mac (skips lo) ✓"

# ── enroll + manage a node, start the metadata service on an ephemeral port ──
( "$MAAS" enroll node1 --bmc-port 6230 ) >/dev/null 2>&1 || fail "enroll node1"
( "$MAAS" manage node1 ) >/dev/null 2>&1 || fail "manage node1"
STATE="$("$MAAS" _state-root)"
out="$SANDBOX/md.out"
python3 "$META" serve --state "$STATE" --port 0 --host 127.0.0.1 > "$out" 2>&1 &
MDPID=$!
for _ in $(seq 1 25); do grep -q 'listening on' "$out" && break; sleep 0.2; done
PORT="$(sed -n 's#.*http://127.0.0.1:\([0-9]*\).*#\1#p' "$out")"
[[ -n "$PORT" ]] || fail "metadata service did not announce a port: $(cat "$out")"
note "metadata service up on :$PORT ✓"

post() {  # post <node> <json>  -> HTTP via urllib (mimics the probe's busybox wget)
    python3 -c '
import urllib.request,sys
r=urllib.request.urlopen(urllib.request.Request(sys.argv[1],data=sys.argv[2].encode()),timeout=5)
sys.stdout.write(r.read().decode())
' "http://127.0.0.1:$PORT/facts/$1" "$2"
}
get() { python3 -c 'import urllib.request,sys; sys.stdout.write(urllib.request.urlopen(sys.argv[1],timeout=5).read().decode())' "http://127.0.0.1:$PORT/$1"; }

# ── the probe POSTs facts; the service records them ──────────────────────────
# Capture, then test: `post … | grep -q … || fail` puts the verdict downstream of a
# pipe, and the producer here is a python3 subprocess that can still be writing when
# grep exits on its first match — SIGPIPE + pipefail then invert a match into a miss.
post_out="$(post node1 "$json")"
grep -q 'recorded facts for node1' <<<"$post_out" || fail "metadata service did not record the POST"
[[ -f "$STATE/node1/facts.json" ]] || fail "facts.json not written by the service"
[[ -f "$STATE/node1/facts.received" ]] || fail "facts.received marker not written"
note "probe POST recorded (facts.json + facts.received) ✓"

# ── NoCloud user-data is served per node ─────────────────────────────────────
ud_out="$(get node1/user-data)"; md_out="$(get node1/meta-data)"
grep -q 'hostname: node1'    <<<"$ud_out" || fail "user-data missing hostname"
grep -q 'instance-id: node1' <<<"$md_out" || fail "meta-data missing instance-id"
note "NoCloud meta-data + user-data served per node ✓"

# a POST for an un-enrolled node is refused (404), never silently written
if post ghost "$json" 2>/dev/null | grep -q 'recorded'; then
    fail "REGRESSION: metadata service recorded facts for an un-enrolled node 'ghost'"
fi
note "facts POST for an un-enrolled node refused ✓"

# ── inspect --from-metadata ingests the facts into a schedulable summary ─────
( "$MAAS" inspect node1 --from-metadata ) >/dev/null 2>&1 || fail "inspect --from-metadata failed"
sched="$("$MAAS" show node1 | sed -n 's/^schedulable *//p')"
[[ "$sched" == "cpus=4 mem_mb=8000 mac=52:54:00:aa:bb:cc" ]] \
    || fail "REGRESSION: schedulable summary wrong: '$sched'"
assert_state node1 manageable
note "inspect --from-metadata -> schedulable facts (cpus=4 mem_mb=8000) ✓"

# ── inspect --from-metadata REFUSES a node that never reported ───────────────
( "$MAAS" enroll node2 --bmc-port 6231 ) >/dev/null 2>&1 || fail "enroll node2"
( "$MAAS" manage node2 ) >/dev/null 2>&1 || fail "manage node2"
if ( "$MAAS" inspect node2 --from-metadata ) >/dev/null 2>&1; then
    fail "REGRESSION: inspect --from-metadata succeeded for a node that never POSTed facts"
fi
note "inspect --from-metadata refuses a node with no reported facts ✓"

pass "inspection chain headless: probe facts, metadata POST+user-data, inspect ingest + refusal"
