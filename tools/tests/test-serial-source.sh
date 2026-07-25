#!/usr/bin/env bash
# Regression for tools/serial-source.py — the fake serial EMITTER.
# Guards the block-buffering footgun (CLAUDE.md): a byte emitted must be a byte on the
# wire. A shell `printf` loop over a socket delivers NOTHING (libc block-buffers, the loop
# never flushes); this program must deliver PROMPTLY. Also checks --replay determinism.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SS="$HERE/../serial-source.py"

VERDICT=0; SP=""
pass(){ VERDICT=1; printf 'PASS: %s\n' "$*"; exit 0; }
fail(){ VERDICT=1; printf 'FAIL: %s\n' "$*"; exit 1; }
skip(){ VERDICT=1; printf 'SKIP: %s\n' "$*"; exit 77; }
cleanup(){ rc=$?; [[ -n "$SP" ]] && kill "$SP" 2>/dev/null
           [[ $VERDICT -eq 0 ]] && printf 'FAIL: test exited early (rc=%s)\n' "$rc"; }
trap cleanup EXIT

command -v python3 >/dev/null || skip "python3 not found"
[[ -f "$SS" ]] || fail "serial-source.py not found at $SS"

# --- 1. --replay --once emits the file's lines verbatim, in order, once ---
tmp="$(mktemp)"; printf 'partitioning\ninstalling\nlogin:\n' > "$tmp"
out="$(python3 "$SS" --replay "$tmp" --once --interval 0 --no-crlf)"; rm -f "$tmp"
[[ "$out" == $'partitioning\ninstalling\nlogin:' ]] \
  || fail "REGRESSION: --replay did not emit the canned lines verbatim (got: $(printf %q "$out"))"

# --- 2. TCP flush: a reader gets marker lines PROMPTLY (the buffering guard) ---
PORT=$(( (RANDOM % 2000) + 24000 ))
python3 "$SS" --tcp "$PORT" --marker TICK --interval 0.15 >/dev/null 2>&1 &
SP=$!
for _ in $(seq 1 20); do
  python3 -c "import socket,sys; socket.create_connection(('127.0.0.1',$PORT),timeout=0.2).close()" 2>/dev/null && break
  sleep 0.1
done
n="$(python3 - "$PORT" <<'PY'
import socket, sys, time
c = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2); c.settimeout(1.2)
buf = b""; t = time.time()
try:
    while time.time() - t < 1.0:
        buf += c.recv(256)
except OSError:
    pass
print(buf.decode(errors="replace").count("TICK"))
PY
)"
[[ "${n:-0}" -ge 3 ]] \
  || fail "REGRESSION: TCP emitter delivered ${n:-0} < 3 lines in ~1s — the block-buffering footgun is back"

pass "serial-source emits promptly on TCP (${n} lines/s) and replays a canned log verbatim"
