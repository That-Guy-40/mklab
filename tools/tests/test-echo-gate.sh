#!/usr/bin/env bash
# test-echo-gate.sh — prove drive-pty-repl.py's --echo-gate survives a console
# that drops input, and that a plain slow-send does not.
#
# Host-only: no QEMU, no root, no network. tools/tests/lossy-console.py stands
# in for the firmware — a receive FIFO with no flow control that services
# itself every 300 ms and discards whatever else piled up (exactly the failure
# that garbled `load-base` into `lo` at the OpenBIOS-x86 prompt, and `boot`
# into `obot` at Rocky's GRUB).
#
# The word typed is `load-base` — the real OpenBIOS word that got mangled, and
# inert as data: nothing here is ever evaluated by a shell.
#
# One verdict, per house rule. PASS requires BOTH halves: the drop must
# reproduce without the gate (else the fixture proves nothing), and the gate
# must deliver the word intact.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/../drive-pty-repl.py"
CONSOLE="$HERE/lossy-console.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/echo-gate-test.XXXXXX")"
WORD='load-base'

skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

# Safety net: no silent exits (house rule). Any path out that is not an
# explicit verdict prints one here.
trap 'rc=$?; rm -rf -- "$TMP"; [[ $rc == 0 || $rc == 77 || $rc == 1 ]] || \
      printf "FAIL: test exited early (rc=%s)\n" "$rc" >&2' EXIT

command -v python3 >/dev/null 2>&1 || skip "python3 not available"
[[ -f "$DRIVER"  ]] || fail "missing driver: $DRIVER"
[[ -f "$CONSOLE" ]] || fail "missing fixture: $CONSOLE"

# Returns the console's reported line ("GOT:..."), or the empty string if the
# console never got a full line (input so mangled the CR was lost too).
drive() {
    local log="$1"; shift
    python3 "$DRIVER" "$log" --timeout 40 \
        "$@" \
        --expect 'READY' --send "$WORD" --send '\r' --expect 'GOT:' \
        -- python3 "$CONSOLE" >/dev/null 2>&1
    sed -n 's/.*GOT:\([^\r]*\).*/\1/p' "$log" | tail -1
}

# --- Half 1: without the gate, the lossy console MUST mangle the word --------
plain="$(drive "$TMP/plain.log")"
note "plain 40 ms send    -> console accepted: '${plain}'"
if [[ "$plain" == "$WORD" ]]; then
    fail "fixture is not lossy: a plain send delivered '$WORD' intact, so this test cannot prove --echo-gate does anything (raise DRAIN / lower FIFO in lossy-console.py)"
fi

# --- Half 2: with the gate, every byte must arrive --------------------------
gated="$(drive "$TMP/gated.log" --echo-gate)"
note "--echo-gate send    -> console accepted: '${gated}'"
if [[ "$gated" != "$WORD" ]]; then
    fail "REGRESSION: --echo-gate did not protect the send — console accepted '${gated}', expected '$WORD' (self-clocking is broken; the driver is outrunning the consumer again)"
fi

pass "--echo-gate delivered '$WORD' intact through a console that mangled it to '${plain}' without the gate"
